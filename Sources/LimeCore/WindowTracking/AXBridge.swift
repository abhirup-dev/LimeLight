import AppKit
import ApplicationServices
import Foundation

/// Adapter for Accessibility (AX) — focused-window per app, focus change
/// observers, and bundle-identifier metadata.
public protocol AXBridge: AnyObject, Sendable {
    var status: AccessibilityStatus { get }
    /// Returns the (pid, axWindowID) of the currently focused window, if any.
    /// `axWindowID` is best-effort — AX does not expose CGWindowID directly.
    func focusedWindow() -> (pid: Int32, title: String?)?
    /// Bundle identifier for a running PID, if known.
    func bundleIdentifier(for pid: Int32) -> String?
    /// App name for a running PID, if known (used as a fallback when CGWindowList lacks it).
    func appName(for pid: Int32) -> String?
}

public final class RealAXBridge: AXBridge, @unchecked Sendable {
    public init() {}

    public var status: AccessibilityStatus {
        // Pass `nil` so we don't trigger a TCC prompt during status checks; the
        // first prompt will come from a real attribute call elsewhere if needed.
        let trusted = AXIsProcessTrustedWithOptions(nil)
        return trusted ? .granted : .denied
    }

    /// Forces the TCC prompt by passing `kAXTrustedCheckOptionPrompt: true`.
    /// Call this once at startup if the daemon wants to nudge the user.
    public func requestPermission() -> AccessibilityStatus {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts) ? .granted : .denied
    }

    public func focusedWindow() -> (pid: Int32, title: String?)? {
        guard status == .granted else { return nil }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontmost.processIdentifier
        let app = AXUIElementCreateApplication(pid)

        var focused: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused)
        guard rc == .success, let element = focused else { return (pid, nil) }
        let axWindow = element as! AXUIElement

        var titleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)
        return (pid, titleValue as? String)
    }

    public func bundleIdentifier(for pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    public func appName(for pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
