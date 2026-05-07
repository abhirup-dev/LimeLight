import CoreGraphics
import Foundation

public typealias WindowID = UInt32

public struct WindowState: Sendable, Equatable {
    public var windowID: WindowID
    public var ownerPID: Int32
    public var appName: String?
    public var bundleIdentifier: String?
    public var title: String?
    public var frame: CGRect
    public var isOnScreen: Bool
    public var spaceID: UInt64?
    /// `true` when the owning app reports this CGWindowID via its
    /// `kAXWindowsAttribute`. Apps like Arc expose multiple CGWindow
    /// entries per visible "window" (chrome / panel / content as separate
    /// NSWindows); the helpers are absent from AX's list. BorderEngineLogic
    /// uses this to skip helpers — without the filter, Arc gets stacked
    /// borders from non-overlapping toolbar / panel sub-windows that the
    /// occlusion walk can't dedupe.
    ///
    /// `nil` means we don't know yet (AX not granted, query failed, or
    /// not yet populated). Callers MUST treat `nil` as "include": never
    /// drop a window because we couldn't confirm AX ownership, otherwise
    /// a transient AX hiccup would lose every border.
    public var isAXOwned: Bool?

    public init(
        windowID: WindowID,
        ownerPID: Int32,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        title: String? = nil,
        frame: CGRect = .zero,
        isOnScreen: Bool = true,
        spaceID: UInt64? = nil,
        isAXOwned: Bool? = nil
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.spaceID = spaceID
        self.isAXOwned = isAXOwned
    }

    public func attributes(aerospaceWorkspace: String? = nil) -> WindowAttributes {
        WindowAttributes(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: title,
            windowID: windowID,
            aerospaceWorkspace: aerospaceWorkspace
        )
    }
}

public enum AccessibilityStatus: String, Sendable, Codable {
    case granted
    case denied
    case unknown
}
