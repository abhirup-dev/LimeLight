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
///
/// # RealtimeFastHook
///
/// The above pipeline is *correct* but not fast enough for a user
/// hammering AeroSpace hotkeys to cycle through stacked same-app windows
/// (e.g. workspace 7 with many Slacks). A standard refresh round-trip
/// is ≥30 ms because it serializes through:
///
///     AX event  →  6 ms refresh debounce  →  CG enum (~5 ms)  →
///                  16 ms coalescer tick   →  recompute & paint
///
/// At a 50–100 ms hotkey cadence that reads as visible lag — the colour
/// stays on the previously-focused window.
///
/// `RealtimeFastHook` is the side-channel that fixes this:
///
///   1. `AXWindowObserverManager.setOnFocusChange` registers a second
///      handler that fires *only* on `kAXFocusedWindowChanged` /
///      `kAXApplicationActivated` notifications. These come from the
///      same AX event stream but skip the debounce.
///   2. `WindowTracker.fastPathFocusUpdate` re-resolves focus from AX
///      against the *existing* cache. No CG enum. Cache may be slightly
///      stale (z-order, frame), but the only thing that needs to change
///      to flip border colours is `focusedWindowID`, so this is fine.
///   3. The focus-change subscriber (BorderEngine, wired in the daemon)
///      runs `recompute()` directly — bypassing the
///      `WindowEventCoalescer` 16 ms tick.
///
/// End-to-end the fast path lands a colour swap in roughly 5–10 ms.
/// The full enumeration path still runs in parallel (debounced) and
/// reconciles z-order / frame / lifecycle in the background.
///
/// **Invariant:** RealtimeFastHook never *removes* or *creates* a
/// border. Those decisions need accurate cache state and stay on the
/// debounced path. The fast path only updates which window in the
/// existing cache is "active". Worst case for a stale cache: we briefly
/// flip the wrong window's colour for ≤6 ms until the debounced enum
/// lands, then it self-corrects.
public final class WindowTracker: @unchecked Sendable {
    public typealias FocusChangeHandler = @Sendable (WindowID?) -> Void

    private let trackerQueue = DispatchQueue(label: "dev.abhirup.lime.tracker", qos: .userInitiated)
    private let server: WindowServerBridge
    private let ax: AXBridge
    private let axObservers: AXWindowObserverManager

    private var cache: [WindowID: WindowState] = [:]
    /// Window IDs in CGWindowList z-order (front-to-back). Maintained
    /// alongside `cache` so consumers can walk the stack in order without
    /// re-querying CG. The dict above is for O(1) ID → state lookup; this
    /// list is for ordered traversal (occlusion filtering in
    /// BorderEngineLogic depends on z-order being preserved).
    private var orderedIDs: [WindowID] = []
    private var cacheLock = os_unfair_lock()
    private var focusedWindowID: WindowID?
    private var focusHandlers: [FocusChangeHandler] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Coalesces a burst of refresh requests (e.g. AX move flurry during
    /// AeroSpace teleport) into one enumeration per ~6ms. Lower than the
    /// 16ms-per-frame budget so rapid hotkey cycling between same-app
    /// windows doesn't stall behind a frame's worth of debounce.
    private var refreshPending = false
    /// Set if any AX events arrived while a refresh was pending — ensures we
    /// run a follow-up enum after the first one settles, since AeroSpace /
    /// WindowServer state can lag the AX focus event by a few ms.
    private var refreshTrailing = false
    private let refreshDebounceMs: Int = 6
    private let refreshTrailingMs: Int = 30

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
        // Fast-path: focus events bypass the enumeration debounce. We just
        // re-resolve focus from AX and emit a focus-change tick into the
        // coalescer so the renderer flips colours within a frame even when
        // the window cache and CGWindowList z-order haven't caught up yet.
        axObservers.setOnFocusChange { [weak self] in
            self?.fastPathFocusUpdate()
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
    ///   - Further calls during the window: marked as a "trailing" need so
    ///     the timer schedules a follow-up enum `refreshTrailingMs` later.
    ///     This catches the case where AeroSpace / WindowServer hasn't
    ///     finished propagating the new z-order by the time the first
    ///     enum runs.
    ///   - When the timer fires: enumerate, then if trailing was requested
    ///     schedule one more enum to capture the post-propagation state.
    ///
    /// Tuned to 6ms (well under the 16ms frame budget) so consecutive
    /// hotkey presses at 50–100ms cadence don't get the second event
    /// silently absorbed by the first event's debounce window — see the
    /// RealtimeFastHook docblock on `fastPathFocusUpdate`.
    private func scheduleDebouncedRefresh() {
        trackerQueue.async { [weak self] in
            guard let self else { return }
            if self.refreshPending {
                self.refreshTrailing = true
                return
            }
            self.refreshPending = true
            self.trackerQueue.asyncAfter(deadline: .now() + .milliseconds(self.refreshDebounceMs)) { [weak self] in
                guard let self else { return }
                self.refreshPending = false
                self.performInitialEnumeration()
                if self.refreshTrailing {
                    self.refreshTrailing = false
                    self.trackerQueue.asyncAfter(deadline: .now() + .milliseconds(self.refreshTrailingMs)) { [weak self] in
                        self?.performInitialEnumeration()
                    }
                }
            }
        }
    }

    /// **RealtimeFastHook.** Fires synchronously off an AX
    /// `kAXFocusedWindowChanged` (or app-activated) event, bypassing the
    /// enumeration debounce so the *focused window ID* updates within a
    /// frame regardless of how busy the cache-rebuild path is.
    ///
    /// Why this exists: when the user cycles through stacked same-app
    /// windows via AeroSpace hotkeys, the things that actually need to
    /// change in the renderer are just the active/inactive border colours
    /// on two windows. Re-enumerating CGWindowList, diffing the cache,
    /// running the coalescer tick, and recomputing every border spec is
    /// pure overhead for that case — and the user perceives the lag.
    /// The fast path:
    ///   1. Reads the system-focused (pid, title) from AX directly.
    ///   2. Looks up the matching window in the existing cache.
    ///   3. Updates `focusedWindowID` and pushes a `.focusChanged` event
    ///      into the coalescer for both the previous and new focused
    ///      windows. The BorderEngine recompute then flips colours
    ///      without waiting for the next enumeration to land.
    ///
    /// The full enumeration path still runs in parallel via the
    /// debounced `scheduleDebouncedRefresh` triggered by the same AX
    /// event — z-order, frame, and lifecycle changes are picked up
    /// there. The fast path is purely an *optimistic* focus update
    /// against the current cache.
    ///
    /// Failure modes (degrade gracefully, never lie):
    ///   - AX cannot resolve focus (AX denied, app dead): leave focus as
    ///     it was; the next enum will reconcile.
    ///   - The focused window isn't in our cache yet (just created):
    ///     skip; the next enum will install both the cache entry and
    ///     resolve focus to it.
    ///   - Multiple cache entries match the AX (pid, title) tuple:
    ///     prefer the one whose CG z-order is highest (i.e. the front
    ///     one), since AeroSpace typically raises the focused window.
    private func fastPathFocusUpdate() {
        trackerQueue.async { [weak self] in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.trackerQueue))
            self.recomputeFocus()
        }
    }

    // MARK: - public read API

    public var snapshot: [WindowState] {
        os_unfair_lock_lock(&cacheLock)
        defer { os_unfair_lock_unlock(&cacheLock) }
        return Array(cache.values)
    }

    /// Snapshot in CGWindowList z-order (front-to-back). Front element is
    /// the topmost on-screen window. Used by BorderEngineLogic to apply the
    /// occlusion filter ("if any higher window overlaps, skip").
    public var orderedSnapshot: [WindowState] {
        os_unfair_lock_lock(&cacheLock)
        defer { os_unfair_lock_unlock(&cacheLock) }
        return orderedIDs.compactMap { cache[$0] }
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
        var newOrder: [WindowID] = []
        newOrder.reserveCapacity(windows.count)
        for w in windows {
            if newCache[w.windowID] == nil { newOrder.append(w.windowID) }
            newCache[w.windowID] = w
        }

        os_unfair_lock_lock(&cacheLock)
        let oldCache = cache
        cache = newCache
        orderedIDs = newOrder
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

    /// Resolve focus from AX. Used by both the debounced enum path and the
    /// RealtimeFastHook (`fastPathFocusUpdate`).
    ///
    /// Tie-break order when AX (pid, title) matches multiple cache entries:
    ///   1. Exact title match.
    ///   2. Front-most CG z-order among the title matches (AeroSpace
    ///      raises the newly-focused window so the front one is the
    ///      correct answer in nearly every case).
    ///   3. Front-most CG z-order among ALL windows of the pid (when title
    ///      didn't disambiguate, e.g. several Slack windows whose CGWindow
    ///      titles happen to be empty or identical).
    private func recomputeFocus() {
        dispatchPrecondition(condition: .onQueue(trackerQueue))
        guard let focused = ax.focusedWindow() else {
            updateFocus(nil)
            return
        }

        os_unfair_lock_lock(&cacheLock)
        let pidCandidates = cache.values.filter { $0.ownerPID == focused.pid }
        let order = orderedIDs
        os_unfair_lock_unlock(&cacheLock)

        // z-order rank: smaller index = closer to front.
        let zRank: (WindowID) -> Int = { wid in
            order.firstIndex(of: wid) ?? Int.max
        }

        let chosen: WindowState?
        if let title = focused.title, !title.isEmpty {
            let titleMatches = pidCandidates.filter { $0.title == title }
            if let frontMatch = titleMatches.min(by: { zRank($0.windowID) < zRank($1.windowID) }) {
                chosen = frontMatch
            } else {
                chosen = pidCandidates.min(by: { zRank($0.windowID) < zRank($1.windowID) })
            }
        } else {
            chosen = pidCandidates.min(by: { zRank($0.windowID) < zRank($1.windowID) })
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
