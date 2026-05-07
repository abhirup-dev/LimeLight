import CSkyLight
import Darwin
import Foundation

/// SLS event class IDs we care about. Verified against JankyBorders/src/events.c
/// — these are stable across recent macOS releases but are NOT public API,
/// which is why every symbol below is dlsym'd rather than linked.
public enum SLSEventClass: UInt32, CaseIterable {
    case windowMove        = 806
    case windowResize      = 807
    case windowReorder     = 808
    case windowHide        = 815
    case windowUnhide      = 816
    case windowCreate      = 1325
    case windowDestroy     = 1326
    case spaceChange       = 1401
    case frontAppChange    = 1508
}

/// Resolved private-API symbol set. Every field is optional — a missing
/// symbol does NOT crash the daemon. Two capability gates:
///   - `canStream`: SLS event subscription works (events drive refresh).
///   - `canResolveFrontWindow`: full JankyBorders-style front-window query
///     works (active-window picker uses SLS instead of AX).
/// Either may be true independently; missing capabilities fall through to
/// the public-API path (CGWindowList enum + AX focus).
public struct SkyLightSymbols: Sendable {
    // Event subscription
    public let mainConnectionID: SLSMainConnectionIDFn?
    public let registerNotifyProc: SLSRegisterNotifyProcFn?

    // Front-window resolution (SLS connection-filtered enum, JB pattern)
    public let getFrontProcess: SLPSGetFrontProcessFn?
    public let getConnectionIDForPSN: SLSGetConnectionIDForPSNFn?
    public let copyWindowsWithOptionsAndTags: SLSCopyWindowsWithOptionsAndTagsFn?
    public let windowQueryWindows: SLSWindowQueryWindowsFn?
    public let windowQueryResultCopyWindows: SLSWindowQueryResultCopyWindowsFn?
    public let windowIteratorGetCount: SLSWindowIteratorGetCountFn?
    public let windowIteratorAdvance: SLSWindowIteratorAdvanceFn?
    public let windowIteratorGetParentID: SLSWindowIteratorGetParentIDFn?
    public let windowIteratorGetWindowID: SLSWindowIteratorGetWindowIDFn?
    public let windowIteratorGetTags: SLSWindowIteratorGetTagsFn?
    public let windowIteratorGetAttributes: SLSWindowIteratorGetAttributesFn?

    // Active space resolution
    public let copyManagedDisplays: SLSCopyManagedDisplaysFn?
    public let copyActiveMenuBarDisplayIdentifier: SLSCopyActiveMenuBarDisplayIdentifierFn?
    public let managedDisplayGetCurrentSpace: SLSManagedDisplayGetCurrentSpaceFn?

    // Defensive accelerators (not on V1 critical path)
    public let getWindowBounds: SLSGetWindowBoundsFn?
    public let getWindowOwner: SLSGetWindowOwnerFn?
    public let connectionGetPID: SLSConnectionGetPIDFn?

    public init(
        mainConnectionID: SLSMainConnectionIDFn? = nil,
        registerNotifyProc: SLSRegisterNotifyProcFn? = nil,
        getFrontProcess: SLPSGetFrontProcessFn? = nil,
        getConnectionIDForPSN: SLSGetConnectionIDForPSNFn? = nil,
        copyWindowsWithOptionsAndTags: SLSCopyWindowsWithOptionsAndTagsFn? = nil,
        windowQueryWindows: SLSWindowQueryWindowsFn? = nil,
        windowQueryResultCopyWindows: SLSWindowQueryResultCopyWindowsFn? = nil,
        windowIteratorGetCount: SLSWindowIteratorGetCountFn? = nil,
        windowIteratorAdvance: SLSWindowIteratorAdvanceFn? = nil,
        windowIteratorGetParentID: SLSWindowIteratorGetParentIDFn? = nil,
        windowIteratorGetWindowID: SLSWindowIteratorGetWindowIDFn? = nil,
        windowIteratorGetTags: SLSWindowIteratorGetTagsFn? = nil,
        windowIteratorGetAttributes: SLSWindowIteratorGetAttributesFn? = nil,
        copyManagedDisplays: SLSCopyManagedDisplaysFn? = nil,
        copyActiveMenuBarDisplayIdentifier: SLSCopyActiveMenuBarDisplayIdentifierFn? = nil,
        managedDisplayGetCurrentSpace: SLSManagedDisplayGetCurrentSpaceFn? = nil,
        getWindowBounds: SLSGetWindowBoundsFn? = nil,
        getWindowOwner: SLSGetWindowOwnerFn? = nil,
        connectionGetPID: SLSConnectionGetPIDFn? = nil
    ) {
        self.mainConnectionID = mainConnectionID
        self.registerNotifyProc = registerNotifyProc
        self.getFrontProcess = getFrontProcess
        self.getConnectionIDForPSN = getConnectionIDForPSN
        self.copyWindowsWithOptionsAndTags = copyWindowsWithOptionsAndTags
        self.windowQueryWindows = windowQueryWindows
        self.windowQueryResultCopyWindows = windowQueryResultCopyWindows
        self.windowIteratorGetCount = windowIteratorGetCount
        self.windowIteratorAdvance = windowIteratorAdvance
        self.windowIteratorGetParentID = windowIteratorGetParentID
        self.windowIteratorGetWindowID = windowIteratorGetWindowID
        self.windowIteratorGetTags = windowIteratorGetTags
        self.windowIteratorGetAttributes = windowIteratorGetAttributes
        self.copyManagedDisplays = copyManagedDisplays
        self.copyActiveMenuBarDisplayIdentifier = copyActiveMenuBarDisplayIdentifier
        self.managedDisplayGetCurrentSpace = managedDisplayGetCurrentSpace
        self.getWindowBounds = getWindowBounds
        self.getWindowOwner = getWindowOwner
        self.connectionGetPID = connectionGetPID
    }

    /// True iff event subscription works.
    public var canStream: Bool {
        mainConnectionID != nil && registerNotifyProc != nil
    }

    /// True iff the JB-style front-window resolver has every symbol it
    /// needs. If false, callers fall through to AX-based focus.
    public var canResolveFrontWindow: Bool {
        mainConnectionID != nil
            && getFrontProcess != nil
            && getConnectionIDForPSN != nil
            && copyWindowsWithOptionsAndTags != nil
            && windowQueryWindows != nil
            && windowQueryResultCopyWindows != nil
            && windowIteratorAdvance != nil
            && windowIteratorGetParentID != nil
            && windowIteratorGetWindowID != nil
            && windowIteratorGetTags != nil
            && windowIteratorGetAttributes != nil
            && copyManagedDisplays != nil
            && copyActiveMenuBarDisplayIdentifier != nil
            && managedDisplayGetCurrentSpace != nil
    }

    /// Attempt to dlopen SkyLight and resolve every known symbol.
    public static func resolveFromSkyLight() -> SkyLightSymbols {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            return SkyLightSymbols()
        }
        // We deliberately do NOT dlclose: symbols are referenced for the
        // process lifetime; closing would invalidate every resolved pointer.
        func sym<T>(_ name: String, as _: T.Type) -> T? {
            guard let raw = dlsym(handle, name) else { return nil }
            return unsafeBitCast(raw, to: T.self)
        }
        return SkyLightSymbols(
            mainConnectionID:                   sym("SLSMainConnectionID",                   as: SLSMainConnectionIDFn.self),
            registerNotifyProc:                 sym("SLSRegisterNotifyProc",                 as: SLSRegisterNotifyProcFn.self),
            getFrontProcess:                    sym("_SLPSGetFrontProcess",                  as: SLPSGetFrontProcessFn.self),
            getConnectionIDForPSN:              sym("SLSGetConnectionIDForPSN",              as: SLSGetConnectionIDForPSNFn.self),
            copyWindowsWithOptionsAndTags:      sym("SLSCopyWindowsWithOptionsAndTags",      as: SLSCopyWindowsWithOptionsAndTagsFn.self),
            windowQueryWindows:                 sym("SLSWindowQueryWindows",                 as: SLSWindowQueryWindowsFn.self),
            windowQueryResultCopyWindows:       sym("SLSWindowQueryResultCopyWindows",       as: SLSWindowQueryResultCopyWindowsFn.self),
            windowIteratorGetCount:             sym("SLSWindowIteratorGetCount",             as: SLSWindowIteratorGetCountFn.self),
            windowIteratorAdvance:              sym("SLSWindowIteratorAdvance",              as: SLSWindowIteratorAdvanceFn.self),
            windowIteratorGetParentID:          sym("SLSWindowIteratorGetParentID",          as: SLSWindowIteratorGetParentIDFn.self),
            windowIteratorGetWindowID:          sym("SLSWindowIteratorGetWindowID",          as: SLSWindowIteratorGetWindowIDFn.self),
            windowIteratorGetTags:              sym("SLSWindowIteratorGetTags",              as: SLSWindowIteratorGetTagsFn.self),
            windowIteratorGetAttributes:        sym("SLSWindowIteratorGetAttributes",        as: SLSWindowIteratorGetAttributesFn.self),
            copyManagedDisplays:                sym("SLSCopyManagedDisplays",                as: SLSCopyManagedDisplaysFn.self),
            copyActiveMenuBarDisplayIdentifier: sym("SLSCopyActiveMenuBarDisplayIdentifier", as: SLSCopyActiveMenuBarDisplayIdentifierFn.self),
            managedDisplayGetCurrentSpace:      sym("SLSManagedDisplayGetCurrentSpace",      as: SLSManagedDisplayGetCurrentSpaceFn.self),
            getWindowBounds:                    sym("SLSGetWindowBounds",                    as: SLSGetWindowBoundsFn.self),
            getWindowOwner:                     sym("SLSGetWindowOwner",                     as: SLSGetWindowOwnerFn.self),
            connectionGetPID:                   sym("SLSConnectionGetPID",                   as: SLSConnectionGetPIDFn.self)
        )
    }
}
