import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Adapter for Accessibility (AX) — focused-window per app, focus change
/// observers, and bundle-identifier metadata.
public protocol AXBridge: AnyObject, Sendable {
    var status: AccessibilityStatus { get }
    /// Returns the focused window's pid, AX title, and (when resolvable) the
    /// matching `CGWindowID`. The CGWindowID comes from the
    /// `_AXUIElementGetWindow` private SPI that every major macOS window
    /// manager (yabai, AeroSpace, Hammerspoon, Rectangle) uses; we resolve it
    /// via `dlsym` so absence degrades gracefully back to the title path.
    func focusedWindow() -> (pid: Int32, title: String?, cgWindowID: CGWindowID?)?
    /// Bundle identifier for a running PID, if known.
    func bundleIdentifier(for pid: Int32) -> String?
    /// App name for a running PID, if known (used as a fallback when CGWindowList lacks it).
    func appName(for pid: Int32) -> String?

    /// CGWindowIDs that the app itself reports via `kAXWindowsAttribute`.
    /// CGWindowList sees implementation-detail sub-windows (toolbar / panel
    /// / chrome NSWindows) that the app does NOT consider user-facing; those
    /// are absent from this list. Used to filter borders to "real" windows
    /// only — see `WindowState.isAXOwned`. Returns `nil` if AX is denied or
    /// the query fails, in which case callers must NOT drop windows (we
    /// degrade to the unfiltered cache to avoid losing borders on a
    /// transient AX hiccup).
    func axWindowIDs(for pid: Int32) -> Set<CGWindowID>?
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

    public func focusedWindow() -> (pid: Int32, title: String?, cgWindowID: CGWindowID?)? {
        guard status == .granted else { return nil }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontmost.processIdentifier
        let app = AXUIElementCreateApplication(pid)

        var focused: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused)
        guard rc == .success, let element = focused else { return (pid, nil, nil) }
        let axWindow = element as! AXUIElement

        var titleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)

        let cgWindowID: CGWindowID? = Self.cgWindowID(for: axWindow)
        return (pid, titleValue as? String, cgWindowID)
    }

    /// Maps an AX element to the CGWindowID that CGWindowList uses, via the
    /// private `_AXUIElementGetWindow(_:_:)` SPI. The symbol has shipped in
    /// every macOS release since 10.0 and is what every credible window
    /// manager (yabai, AeroSpace, Hammerspoon, Rectangle, Magnet…) uses to
    /// bridge AX and CG. Resolved via `dlsym` so a future removal degrades
    /// to the title/z-order tie-break path in `WindowTracker.recomputeFocus`
    /// rather than crashing.
    ///
    /// Why we need this: empty CGWindow titles for app-spawned auxiliary
    /// windows (e.g. main Arc vs. Little Arc, multiple Slack DMs) leave the
    /// title-based match ambiguous, and z-order tie-break can pick the
    /// wrong window when the OS hasn't raised the new focused window yet.
    /// CGWindowID is a unique stable identifier — exact match every time.
    private static let _axGetWindow: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
        // RTLD_DEFAULT searches all loaded images; the AX framework provides
        // the symbol when ApplicationServices is linked.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(sym, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
    }()

    private static func cgWindowID(for element: AXUIElement) -> CGWindowID? {
        guard let fn = _axGetWindow else { return nil }
        var wid: CGWindowID = 0
        let rc = fn(element, &wid)
        guard rc == .success, wid != 0 else { return nil }
        return wid
    }

    public func bundleIdentifier(for pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    public func appName(for pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    public func axWindowIDs(for pid: Int32) -> Set<CGWindowID>? {
        guard status == .granted, pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue)
        guard rc == .success, let windows = windowsValue as? [AXUIElement] else { return nil }

        var ids: Set<CGWindowID> = []
        ids.reserveCapacity(windows.count)
        for w in windows {
            if let wid = Self.cgWindowID(for: w) {
                ids.insert(wid)
            }
        }
        return ids
    }
}
