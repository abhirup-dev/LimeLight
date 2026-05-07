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

    public init(
        windowID: WindowID,
        ownerPID: Int32,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        title: String? = nil,
        frame: CGRect = .zero,
        isOnScreen: Bool = true,
        spaceID: UInt64? = nil
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.spaceID = spaceID
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
