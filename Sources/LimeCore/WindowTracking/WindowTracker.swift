import AppKit
import Foundation
import os

/// Off-main window registry.
/// - Owns a `[WindowID: WindowState]` cache guarded by `os_unfair_lock`.
/// - Updates run on a serial `dev.abhirup.lime.tracker` queue (`userInitiated`).
/// - Bridges (`WindowServerBridge`, `AXBridge`, `AXWindowObserverManager`)
///   are injectable so tests can stub them.
///
/// Refresh triggers (in order of importance for catching staleness):
///   1. AXWindowObserverManager — push events on move / resize / minimize /
///      restore / window-created / window-destroyed for every observed app.
///      Fires on AeroSpace's hideInCorner frame teleports, which is the
///      only signal we have for AeroSpace workspace switches when the
///      frontmost app does not change. Debounced via
///      `scheduleDebouncedRefresh()` to absorb the burst that AeroSpace
///      fires when teleporting every window in a workspace at once.
///   2. NSWorkspace.activeSpaceDidChangeNotification — fires on Mission
///      Control / Stage Manager Space switches even when no app changes.
///   3. NSWorkspace.didActivateApplicationNotification — frontmost-app
///      changes; covers focus-driven cache refresh.
///   4. Explicit `refresh()` calls by external callers (rare).
///
/// Together these eliminate the staleness that was the root cause of
/// focusfx-l4i (phantom borders after AeroSpace workspace switch). SLS
/// streaming (focusfx-b13) will eventually subsume #1 and add native
/// Space-membership filtering, but #2 stays as a public-API fallback.
public final class WindowTracker: @unchecked Sendable {
    public typealias FocusChangeHandler = @Sendable (WindowID?) -> Void

    private let trackerQueue = DispatchQueue(label: "dev.abhirup.lime.tracker", qos: .userInitiated)
    private let server: WindowServerBridge
    private let ax: AXBridge
    private let axObservers: AXWindowObserverManager

    private var cache: [WindowID: WindowState] = [:]
    private var cacheLock = os_unfair_lock()
    private var focusedWindowID: WindowID?
    private var focusHandlers: [FocusChangeHandler] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Coalesces a burst of refresh requests (e.g. AX move flurry during
    /// AeroSpace teleport) into one enumeration per ~16ms.
    private var refreshPending = false
    private let refreshDebounceMs: Int = 16

    /// Per-window event coalescer. BorderEngine / EffectEngine subscribe via
    /// the consumer-supplied handler at init time. The tracker bumps generations
    /// here so async redraw work can stale-check before applying.
    public let coalescer: WindowEventCoalescer

    public init(
        server: WindowServerBridge = CGWindowListBridge(),
        ax: AXBridge = RealAXBridge(),
        axObservers: AXWindowObserverManager = RealAXWindowObserverManager(),
        coalesceMs: Int = 16,
        onCoalesced: @escaping WindowEventCoalescer.Handler = { _ in }
    ) {
        self.server = server
        self.ax = ax
        self.axObservers = axObservers
        self.coalescer = WindowEventCoalescer(coalesceMs: coalesceMs, handler: onCoalesced)
    }

    /// Snapshot the generation for `windowID`. Async work captures this at
    /// dispatch time and re-checks before applying its output.
    public func generation(for windowID: WindowID) -> WindowGeneration {
        coalescer.currentGeneration(for: windowID)
    }

    deinit { stop() }

    // MARK: - lifecycle

    public func start() {
        trackerQueue.async { [weak self] in
            self?.performInitialEnumeration()
        }
        installWorkspaceObservers()
        axObservers.start(deliveryQueue: trackerQueue) { [weak self] in
            self?.scheduleDebouncedRefresh()
        }
    }

    public func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers { nc.removeObserver(token) }
        workspaceObservers.removeAll()
        axObservers.stop()
    }

    /// Re-enumerate windows. Cheap enough to call periodically in v0; SLS
    /// streaming will replace this.
    public func refresh() {
        trackerQueue.async { [weak self] in
            self?.performInitialEnumeration()
        }
    }

    /// AXWindowObserverManager fires one notification per window per change.
    /// AeroSpace teleporting four windows in a workspace produces four
    /// move events (or eight, with resize). We don't want four
    /// re-enumerations 3ms apart; we want one a tick later, after the
    /// burst has settled. The debouncer:
    ///   - First call: sets `refreshPending = true` and schedules an
    ///     enumeration `refreshDebounceMs` in the future.
    ///   - Further calls during the window: skipped (early return).
    ///   - When the timer fires: enumerate, clear the flag.
    /// 16ms matches the engine's coalescer tick — same end-to-end latency
    /// the renderer would see for a frame change on a focused window.
    private func scheduleDebouncedRefresh() {
        trackerQueue.async { [weak self] in
            guard let self else { return }
            if self.refreshPending { return }
            self.refreshPending = true
            self.trackerQueue.asyncAfter(deadline: .now() + .milliseconds(self.refreshDebounceMs)) { [weak self] in
                guard let self else { return }
                self.refreshPending = false
                self.performInitialEnumeration()
            }
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
        let oldCache = cache
        cache = newCache
        os_unfair_lock_unlock(&cacheLock)

        diffAndCoalesce(old: oldCache, new: newCache)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        Log.tracker.info("enumerated \(windows.count, privacy: .public) windows in \(elapsedMs, format: .fixed(precision: 2))ms")

        // Re-resolve focus after a fresh enum.
        recomputeFocus()
    }

    /// Compares two cache snapshots and pushes per-window events into the
    /// coalescer so consumers (BorderEngine, EffectEngine) get one batch tick
    /// per `coalesceMs` instead of N events per enumeration burst.
    private func diffAndCoalesce(old: [WindowID: WindowState], new: [WindowID: WindowState]) {
        dispatchPrecondition(condition: .onQueue(trackerQueue))

        for (wid, n) in new {
            if let o = old[wid] {
                if o.frame != n.frame {
                    coalescer.enqueue(wid, change: .frameChanged)
                }
                if o.isOnScreen != n.isOnScreen {
                    coalescer.enqueue(wid, change: .visibilityChanged)
                }
            } else {
                coalescer.enqueue(wid, change: .created)
            }
        }
        for wid in old.keys where new[wid] == nil {
            coalescer.enqueue(wid, change: .destroyed)
        }
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
        let previous = focusedWindowID
        let changed = previous != wid
        focusedWindowID = wid
        os_unfair_lock_unlock(&cacheLock)
        if changed {
            // Feed both the old and new focused windows through the coalescer
            // so the border/effect engines redraw both (one losing focus,
            // one gaining it) in the same coalescing tick.
            if let previous { coalescer.enqueue(previous, change: .focusChanged) }
            if let wid { coalescer.enqueue(wid, change: .focusChanged) }
            for h in focusHandlers { h(wid) }
        }
    }

    // MARK: - NSWorkspace observers

    /// NSWorkspace observers — refresh path (3) and (2) from the class
    /// header. Both refresh immediately (no debounce) because they fire at
    /// most once per user action, not in bursts; debouncing them would
    /// just add latency to the visible response.
    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        // (3) Frontmost-app activation. Firing path predates the AeroSpace
        // bug fix; kept because the activation also gives us a chance to
        // resolve focus immediately even if no AX move has fired yet.
        let activate = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.trackerQueue.async { self?.performInitialEnumeration() }
        }

        // (2) Mission Control / Stage Manager Space switches. Public API
        // equivalent of the SLS space-change event (1401). Critical for
        // catching native-Spaces changes today without depending on
        // private APIs (focusfx-b13).
        let space = nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.trackerQueue.async { self?.performInitialEnumeration() }
        }

        workspaceObservers = [activate, space]
    }
}
