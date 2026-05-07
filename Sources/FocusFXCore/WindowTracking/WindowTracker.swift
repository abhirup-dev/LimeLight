import AppKit
import Foundation
import os

/// Off-main window registry.
/// - Owns a `[WindowID: WindowState]` cache guarded by `os_unfair_lock`.
/// - Updates run on a serial `dev.focusfx.tracker` queue (`userInitiated`).
/// - Bridges (`WindowServerBridge`, `AXBridge`) are injectable so tests can stub them.
///
/// Scope (focusfx-10.1):
///   - Startup enumeration via WindowServerBridge.
///   - Focus tracking via NSWorkspace.didActivateApplication + AX.
///   - Coarse refresh hook (`refresh()`) for callers; SLS streaming is a follow-up.
public final class WindowTracker: @unchecked Sendable {
    public typealias FocusChangeHandler = @Sendable (WindowID?) -> Void

    private let trackerQueue = DispatchQueue(label: "dev.focusfx.tracker", qos: .userInitiated)
    private let server: WindowServerBridge
    private let ax: AXBridge

    private var cache: [WindowID: WindowState] = [:]
    private var cacheLock = os_unfair_lock()
    private var focusedWindowID: WindowID?
    private var focusHandlers: [FocusChangeHandler] = []
    private var workspaceObserver: NSObjectProtocol?

    public init(server: WindowServerBridge = CGWindowListBridge(), ax: AXBridge = RealAXBridge()) {
        self.server = server
        self.ax = ax
    }

    deinit { stop() }

    // MARK: - lifecycle

    public func start() {
        trackerQueue.async { [weak self] in
            self?.performInitialEnumeration()
        }
        installWorkspaceObservers()
    }

    public func stop() {
        if let token = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            workspaceObserver = nil
        }
    }

    /// Re-enumerate windows. Cheap enough to call periodically in v0; SLS
    /// streaming will replace this.
    public func refresh() {
        trackerQueue.async { [weak self] in
            self?.performInitialEnumeration()
        }
    }

    // MARK: - public read API

    public var snapshot: [WindowState] {
        os_unfair_lock_lock(&cacheLock)
        defer { os_unfair_lock_unlock(&cacheLock) }
        return Array(cache.values)
    }

    public var currentFocusedWindowID: WindowID? {
        os_unfair_lock_lock(&cacheLock)
        defer { os_unfair_lock_unlock(&cacheLock) }
        return focusedWindowID
    }

    public var currentFocusedWindow: WindowState? {
        os_unfair_lock_lock(&cacheLock)
        defer { os_unfair_lock_unlock(&cacheLock) }
        guard let id = focusedWindowID else { return nil }
        return cache[id]
    }

    public var accessibility: AccessibilityStatus { ax.status }

    /// Subscribe to focus-change notifications. Handler runs on the tracker queue.
    public func onFocusChange(_ handler: @escaping FocusChangeHandler) {
        trackerQueue.async { [weak self] in
            self?.focusHandlers.append(handler)
        }
    }

    // MARK: - tracker-queue work

    private func performInitialEnumeration() {
        dispatchPrecondition(condition: .onQueue(trackerQueue))
        let started = DispatchTime.now()
        var windows = server.enumerateOnScreenWindows()
        // Backfill bundle identifier from AX/NSRunningApplication when missing.
        for i in windows.indices where windows[i].bundleIdentifier == nil {
            windows[i].bundleIdentifier = ax.bundleIdentifier(for: windows[i].ownerPID)
            if windows[i].appName == nil {
                windows[i].appName = ax.appName(for: windows[i].ownerPID)
            }
        }

        var newCache: [WindowID: WindowState] = [:]
        newCache.reserveCapacity(windows.count)
        for w in windows { newCache[w.windowID] = w }

        os_unfair_lock_lock(&cacheLock)
        cache = newCache
        os_unfair_lock_unlock(&cacheLock)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        Log.tracker.info("enumerated \(windows.count, privacy: .public) windows in \(elapsedMs, format: .fixed(precision: 2))ms")

        // Re-resolve focus after a fresh enum.
        recomputeFocus()
    }

    private func recomputeFocus() {
        dispatchPrecondition(condition: .onQueue(trackerQueue))
        guard let focused = ax.focusedWindow() else {
            updateFocus(nil)
            return
        }
        // AX returns (pid, title). Find a window in cache matching pid + title (or just pid).
        os_unfair_lock_lock(&cacheLock)
        let candidates = cache.values.filter { $0.ownerPID == focused.pid }
        os_unfair_lock_unlock(&cacheLock)

        let chosen: WindowState?
        if let title = focused.title, !title.isEmpty {
            chosen = candidates.first { $0.title == title } ?? candidates.first
        } else {
            chosen = candidates.first
        }
        updateFocus(chosen?.windowID)
    }

    private func updateFocus(_ wid: WindowID?) {
        dispatchPrecondition(condition: .onQueue(trackerQueue))
        os_unfair_lock_lock(&cacheLock)
        let changed = focusedWindowID != wid
        focusedWindowID = wid
        os_unfair_lock_unlock(&cacheLock)
        if changed {
            for h in focusHandlers { h(wid) }
        }
    }

    // MARK: - NSWorkspace observers

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObserver = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil // delivered on a background thread; we hop to trackerQueue
        ) { [weak self] _ in
            guard let self else { return }
            self.trackerQueue.async {
                // App focus change -> refresh enumeration so cache reflects new window order.
                self.performInitialEnumeration()
            }
        }
    }
}
