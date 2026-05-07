import CoreGraphics
import Foundation

/// Adapter for the WindowServer-level view of windows. Hides the choice between
/// public APIs (`CGWindowListCopyWindowInfo`) and private SLS streaming events.
public protocol WindowServerBridge: AnyObject, Sendable {
    /// Full snapshot of currently visible on-screen windows.
    func enumerateOnScreenWindows() -> [WindowState]

    /// True if the bridge is operating with full functionality (e.g. private SLS available).
    var isStreaming: Bool { get }
}

/// Public-API implementation. Always available; never requires permissions.
/// Does NOT stream — callers re-poll for refresh. Streaming SLS events are a
/// later enhancement (see `RealSkyLightStreamingBridge` once SLS subscription is wired).
public final class CGWindowListBridge: WindowServerBridge, @unchecked Sendable {
    public init() {}

    public var isStreaming: Bool { false }

    public func enumerateOnScreenWindows() -> [WindowState] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap(Self.parseEntry)
    }

    static func parseEntry(_ entry: [String: Any]) -> WindowState? {
        guard let wid = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
        guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
        let appName = entry[kCGWindowOwnerName as String] as? String
        let title = entry[kCGWindowName as String] as? String
        let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true

        // Layer 0 = normal application windows. Higher layers are menu bar items,
        // status items, tooltips, popovers, dock — and our own border overlays
        // (statusBar+1). Filtering here prevents the feedback loop where every
        // re-enumeration re-borders our previous borders.
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        if layer != 0 { return nil }

        // Drop fully transparent windows (sharing-state hidden, alpha 0 helpers).
        let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
        if alpha <= 0 { return nil }

        var frame: CGRect = .zero
        if let bounds = entry[kCGWindowBounds as String] as? [String: Any] {
            // CGRectMakeWithDictionaryRepresentation expects a CFDictionary
            CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame)
        }

        return WindowState(
            windowID: wid,
            ownerPID: pid,
            appName: appName,
            bundleIdentifier: nil, // filled in by AXBridge / NSRunningApplication
            title: title,
            frame: frame,
            isOnScreen: isOnScreen,
            spaceID: nil
        )
    }
}
