import CSkyLight
import CoreGraphics
import Foundation

/// Picks the user-visible front window using the SLS connection-filtered
/// query pattern (JankyBorders/src/misc/window.h:`get_front_window`).
///
/// **Why this exists:**
///   * AX `kAXFocusedWindow` lies for apps like Arc that maintain multiple
///     overlapping NSWindows for a single user-perceived window — Arc
///     shifts AX focus between siblings without raising any of them in
///     CG z-order, so AX-derived focus flips spuriously.
///   * `CGWindowListCopyWindowInfo` includes Arc's chrome / cached
///     surfaces that aren't real top-level UI windows.
///   * SLS's `SLSCopyWindowsWithOptionsAndTags` returns windows for a
///     specific process connection on a specific Space, in WindowServer
///     z-order. Combined with the `window_suitable` predicate this
///     matches what the WindowServer compositor treats as a user-visible
///     window of that app.
///
/// JB has no per-pid stickiness or special-case Arc handling — the
/// connection-filtered SLS path naturally returns the visually-front
/// surface.
///
/// Graceful degradation: every symbol is dlsym'd. If
/// `canResolveFrontWindow` is false on this OS, `init?` returns nil and
/// callers fall through to AX-based focus.
public final class SLSActiveWindowResolver: @unchecked Sendable {
    private let symbols: SkyLightSymbols
    private let connectionID: CGSConnectionID

    public init?(symbols: SkyLightSymbols = .resolveFromSkyLight()) {
        guard symbols.canResolveFrontWindow,
              let getCID = symbols.mainConnectionID
        else { return nil }
        self.symbols = symbols
        self.connectionID = getCID()
    }

    /// JB's `window_suitable` predicate, ported. Reject anything that
    /// isn't a top-level user-visible window of its app.
    private func suitable(iterator: CFTypeRef) -> Bool {
        guard let getTags = symbols.windowIteratorGetTags,
              let getAttributes = symbols.windowIteratorGetAttributes,
              let getParent = symbols.windowIteratorGetParentID
        else { return false }
        let tags = getTags(iterator)
        let attributes = getAttributes(iterator)
        let parentID = getParent(iterator)

        let TAG_DOCUMENT:      UInt64 = 1 << 0
        let TAG_FLOATING:      UInt64 = 1 << 1
        let TAG_ATTACHED:      UInt64 = 1 << 7
        let TAG_IGNORES_CYCLE: UInt64 = 1 << 18
        let TAG_MODAL:         UInt64 = 1 << 31
        let MAGIC_TAG:         UInt64 = 0x400000000000000

        guard parentID == 0 else { return false }
        let attrPass = (attributes & 0x2) != 0 || (tags & MAGIC_TAG) != 0
        guard attrPass else { return false }
        if (tags & TAG_ATTACHED) != 0 { return false }
        if (tags & TAG_IGNORES_CYCLE) != 0 { return false }
        let isDocument = (tags & TAG_DOCUMENT) != 0
        let isFloatingModal = (tags & TAG_FLOATING) != 0 && (tags & TAG_MODAL) != 0
        return isDocument || isFloatingModal
    }

    /// Resolve the active space ID via the menu-bar-display path. Mirrors
    /// JB's `get_active_space_id`. Single-display setups also work
    /// because `SLSCopyActiveMenuBarDisplayIdentifier` returns the only
    /// display when there's just one.
    private func activeSpaceID() -> CGSSpaceID? {
        guard let copyMenuBar = symbols.copyActiveMenuBarDisplayIdentifier,
              let getCurrentSpace = symbols.managedDisplayGetCurrentSpace
        else { return nil }
        // Function pointer returns CFStringRef — Swift bridges as
        // Unmanaged<CFString>. The "Copy" name convention means +1
        // retained; `takeRetainedValue` hands ownership to ARC.
        guard let unmanagedUUID = copyMenuBar(connectionID) else { return nil }
        let uuid = unmanagedUUID.takeRetainedValue()
        let sid = getCurrentSpace(connectionID, uuid)
        return sid == 0 ? nil : sid
    }

    /// JB's `get_front_window`, but returns *all* suitable wids in
    /// iteration order rather than just the first. Apps like Arc keep
    /// multiple stacked NSWindows that all pass `window_suitable` — for
    /// those, the SLS query's internal iteration order can shuffle
    /// between calls without any user interaction, so just taking the
    /// first match flips the active border between visually-equivalent
    /// surfaces every recompute.
    ///
    /// Callers (WindowTracker) use the list to add a small stickiness
    /// layer: if the previously-resolved wid is still in the suitable
    /// set, keep it; only flip when it leaves the set.
    public func frontWindowIDs() -> [CGWindowID] {
        guard let list = collectSuitableWindowIDs() else { return [] }
        return list
    }

    /// Convenience: just the front-most suitable window. Equivalent to
    /// JB's `get_front_window` and used as a fallback when no previous
    /// focus is set.
    public func frontWindowID() -> CGWindowID? {
        frontWindowIDs().first
    }

    private func collectSuitableWindowIDs() -> [CGWindowID]? {
        guard let getFrontProcess = symbols.getFrontProcess,
              let getCIDForPSN = symbols.getConnectionIDForPSN,
              let copyWindows = symbols.copyWindowsWithOptionsAndTags,
              let queryWindows = symbols.windowQueryWindows,
              let queryCopy = symbols.windowQueryResultCopyWindows,
              let advance = symbols.windowIteratorAdvance,
              let getWID = symbols.windowIteratorGetWindowID
        else { return nil }
        guard let activeSpace = activeSpaceID() else { return nil }

        var psn = CSPSN(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard getFrontProcess(&psn) == 0 else { return nil }
        var targetCID: CGSConnectionID = 0
        guard getCIDForPSN(connectionID, &psn, &targetCID) == .success else { return nil }

        // Build CFArray containing one CFNumber holding the active space ID.
        var spaceValue = activeSpace
        guard let spaceNumber = CFNumberCreate(nil, .sInt64Type, &spaceValue) else { return nil }
        let spaceArray: CFArray = withExtendedLifetime(spaceNumber) {
            var values: [Unmanaged<CFNumber>?] = [Unmanaged.passUnretained(spaceNumber)]
            return values.withUnsafeMutableBufferPointer { buf in
                let raw = UnsafeMutableRawPointer(buf.baseAddress!).assumingMemoryBound(to: UnsafeRawPointer?.self)
                return CFArrayCreate(nil, raw, 1, &CFTypeArrayCallBacksHolder.callbacks)!
            }
        }

        var setTags: UInt64 = 1
        var clearTags: UInt64 = 0
        guard let unmanagedWindowList = copyWindows(
            connectionID,
            UInt32(bitPattern: Int32(targetCID)),
            spaceArray,
            0x2,
            &setTags,
            &clearTags
        ) else { return nil }
        let windowList = unmanagedWindowList.takeRetainedValue()
        let count = CFArrayGetCount(windowList)
        guard count > 0 else { return nil }

        guard let unmanagedQuery = queryWindows(connectionID, windowList, 0x0) else { return nil }
        let query = unmanagedQuery.takeRetainedValue()
        guard let unmanagedIter = queryCopy(query) else { return nil }
        let iterator = unmanagedIter.takeRetainedValue()

        var ids: [CGWindowID] = []
        while advance(iterator) {
            if suitable(iterator: iterator) {
                ids.append(getWID(iterator))
            }
        }
        return ids
    }
}

/// `kCFTypeArrayCallBacks` is a `let` global; `CFArrayCreate` wants an
/// inout pointer. Wrap it in a mutable holder so we can take its address
/// without reaching into the immutable global.
private enum CFTypeArrayCallBacksHolder {
    nonisolated(unsafe) static var callbacks: CFArrayCallBacks = kCFTypeArrayCallBacks
}
