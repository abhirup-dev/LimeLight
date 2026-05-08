import AppKit
import Foundation

/// Wires WindowTracker (cache + coalescer) → BorderEngineLogic → BorderRenderer.
/// Owned by the daemon. Lives entirely off-main except for the renderer hop
/// and the on-main NSScreen reads.
public final class BorderEngine: @unchecked Sendable {
    private let tracker: WindowTracker
    private let configStore: ConfigStore
    @MainActor private let renderer = BorderRenderer()
    private let queue = DispatchQueue(label: "dev.abhirup.lime.borders", qos: .userInitiated)
    private var lastDesired: [BorderID: BorderSpec] = [:]
    private var overrides: BorderRuntimeOverrides = .empty
    private var screenParamsObserver: NSObjectProtocol?

    /// The display containing the focused window the last time we APPLIED a
    /// recompute. Compared against the next compute's focused display to
    /// trigger the 75ms monitor-swap debounce — see `recomputeOnQueue`.
    private var lastAppliedFocusedDisplay: CGDirectDisplayID?
    /// Pending swap apply — cancelled if focus moves again before the timer
    /// fires, so cmd-tab spamming through monitors doesn't backlog draws.
    private var pendingSwap: DispatchWorkItem?
    private let monitorSwapDebounceMs: Int = 75

    public init(tracker: WindowTracker, configStore: ConfigStore) {
        self.tracker = tracker
        self.configStore = configStore
        installScreenParamsObserver()
        refreshScreenCache()
    }

    deinit {
        if let token = screenParamsObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Apply a runtime override (from `borders.style` IPC). Triggers a recompute.
    /// `axFocus` is forwarded out-of-band to the WindowTracker so the focus
    /// resolver flips between SLS-primary and AX-only mode without waiting
    /// for the next coalesced batch (focusfx-sf2).
    public func applyStyleRequest(_ req: BordersStyleRequest) {
        if let axFocus = req.axFocus {
            tracker.setUseAXFocusOnly(axFocus)
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.overrides.apply(req)
            self.recomputeOnQueue()
        }
    }

    /// Force borders globally on/off without touching other override fields.
    public func setEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.overrides.global.enabled = enabled
            self.recomputeOnQueue()
        }
    }

    /// Drop all in-memory overrides and recompute from snapshot.
    public func clearOverrides() {
        queue.async { [weak self] in
            guard let self else { return }
            self.overrides.clearAll()
            self.recomputeOnQueue()
        }
    }

    /// Force-redraw every border: clears the diff baseline so every desired
    /// spec is re-emitted as create/update.
    public func redrawAll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastDesired = [:]
            DispatchQueue.main.async { [renderer] in renderer.tearDown() }
            self.recomputeOnQueue()
        }
    }

    public func currentOverrides() -> BorderRuntimeOverrides {
        queue.sync { overrides }
    }

    /// Diagnostic: returns the set of borders the engine currently has
    /// applied (i.e. `lastDesired`). Useful for `limelight borders.desired`
    /// to understand why a particular window has/lacks a border without
    /// guessing from CGWindowList.
    public func currentDesired() -> [BorderID: BorderSpec] {
        queue.sync { lastDesired }
    }

    /// The daemon connects this to the WindowTracker coalescer on startup.
    public func handleCoalescedBatch(_ updates: [CoalescedUpdate]) {
        queue.async { [weak self] in self?.recomputeOnQueue() }
    }

    /// Force a full recompute (config reload / startup / topology change).
    public func recompute() {
        queue.async { [weak self] in self?.recomputeOnQueue() }
    }

    private func recomputeOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        let snapshot = configStore.currentSnapshot
        let ordered = tracker.orderedSnapshot
        let geom = mainScreenGeometry()

        let inputs = BorderEngineLogic.Inputs(
            orderedWindows: ordered,
            focusedWindowID: tracker.currentFocusedWindowID,
            snapshot: snapshot,
            overrides: overrides,
            primaryDisplayHeight: geom.primaryHeight,
            displays: geom.staticDisplays
        )
        let next = BorderEngineLogic.desiredBorders(inputs)
        let nextFocusedDisplay = focusedDisplayID(for: inputs)

        // Debounce monitor swaps (caveat #4 from advisor): when the focused
        // display changes we hold the apply for `monitorSwapDebounceMs` so a
        // burst of focus events through several monitors doesn't flash a
        // screen border on every intermediate display. Window-only changes
        // on the same monitor apply immediately. A pending swap is cancelled
        // if focus moves again before the timer fires.
        let isMonitorSwap = nextFocusedDisplay != lastAppliedFocusedDisplay
        if isMonitorSwap, lastAppliedFocusedDisplay != nil || nextFocusedDisplay != nil {
            pendingSwap?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.applyOnQueue(next: next, focusedDisplay: nextFocusedDisplay)
            }
            pendingSwap = work
            queue.asyncAfter(deadline: .now() + .milliseconds(monitorSwapDebounceMs), execute: work)
            return
        }

        pendingSwap?.cancel()
        pendingSwap = nil
        applyOnQueue(next: next, focusedDisplay: nextFocusedDisplay)
    }

    private func applyOnQueue(next: [BorderID: BorderSpec], focusedDisplay: CGDirectDisplayID?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let diff = BorderEngineLogic.diff(prev: lastDesired, next: next)
        lastDesired = next
        lastAppliedFocusedDisplay = focusedDisplay

        if diff.toCreate.isEmpty, diff.toUpdate.isEmpty, diff.toDestroy.isEmpty {
            return
        }
        Log.borders.debug("apply +\(diff.toCreate.count) ~\(diff.toUpdate.count) -\(diff.toDestroy.count)")
        let expected = Set(next.keys)
        DispatchQueue.main.async { [renderer] in
            renderer.apply(diff, expected: expected)
        }
    }

    private func focusedDisplayID(for inputs: BorderEngineLogic.Inputs) -> CGDirectDisplayID? {
        guard !inputs.displays.isEmpty,
              let fid = inputs.focusedWindowID,
              let fw = inputs.orderedWindows.first(where: { $0.windowID == fid })
        else { return nil }
        let center = CGPoint(x: fw.frame.midX, y: fw.frame.midY)
        return inputs.displays.first { $0.cgFrame.contains(center) }?.id
    }

    public func tearDown() {
        DispatchQueue.main.async { [renderer] in
            renderer.tearDown()
        }
        queue.async { [weak self] in
            self?.lastDesired = [:]
            self?.lastAppliedFocusedDisplay = nil
            self?.pendingSwap?.cancel()
            self?.pendingSwap = nil
        }
    }

    /// Re-read NSScreen on screen reconfiguration (plug/unplug, resolution
    /// change, dock toggle). Public-API listener — `didChangeScreenParameters`
    /// is dispatched off the runloop, so we just bounce a recompute through
    /// our queue. Also refreshes the cached static screen info so we never
    /// have to hit main on a hot path.
    private func installScreenParamsObserver() {
        let nc = NotificationCenter.default
        screenParamsObserver = nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refreshScreenCache()
            self?.recompute()
        }
    }

    /// Per-display geometry cached off `NSScreen.screens`. Refreshed once at
    /// startup and on `didChangeScreenParameters`. Lives on the borders
    /// queue (or the main thread during init) — never read off main during
    /// a recompute, which means `recomputeOnQueue` no longer takes a
    /// `DispatchQueue.main.sync`. That sync was directly responsible for
    /// 10–100 ms stalls on focus changes when main was busy (Arc rendering,
    /// CALayer commits, etc.) and was the dominant tail-latency source.
    private struct ScreenGeometry {
        let primaryHeight: CGFloat
        /// Static per-display geometry. The `isFullscreen` flag is filled
        /// in dynamically per recompute against the current window cache —
        /// a fullscreen window appearing/disappearing must NOT wait for a
        /// screen-params change to update.
        let staticDisplays: [DisplayInfo]
    }

    /// Cached static geometry. Read on the borders queue (or main during
    /// init); written only by `refreshScreenCache`.
    private var screenCache = ScreenGeometry(primaryHeight: 0, staticDisplays: [])

    /// Reads `NSScreen.screens` and writes the cache. Hops to main when off
    /// main (initial init is on main, screen-params hop will go through the
    /// notification's queue).
    private func refreshScreenCache() {
        if Thread.isMainThread {
            screenCache = readScreenGeometryOnMain()
        } else {
            DispatchQueue.main.sync {
                self.screenCache = self.readScreenGeometryOnMain()
            }
        }
    }

    /// Builds the final `ScreenGeometry` for one recompute: cached static
    /// info + per-call fullscreen detection against the current cache.
    /// Pure / no main-hop. Cheap.
    private func mainScreenGeometry() -> ScreenGeometry {
        let cached = screenCache
        let windowFrames: [CGRect] = tracker.orderedSnapshot
            .filter { $0.isOnScreen && $0.frame.width > 0 && $0.frame.height > 0 }
            .map { $0.frame }
        let displays: [DisplayInfo] = cached.staticDisplays.map { d in
            let isFullscreen = windowFrames.contains { f in
                abs(f.origin.x - d.cgFrame.origin.x) < 1
                    && abs(f.origin.y - d.cgFrame.origin.y) < 1
                    && abs(f.size.width - d.cgFrame.size.width) < 1
                    && abs(f.size.height - d.cgFrame.size.height) < 1
            }
            return DisplayInfo(
                id: d.id,
                cgFrame: d.cgFrame,
                cocoaVisibleFrame: d.cocoaVisibleFrame,
                isFullscreen: isFullscreen
            )
        }
        return ScreenGeometry(primaryHeight: cached.primaryHeight, staticDisplays: displays)
    }

    /// On-main read used to refresh the cache. The fullscreen flag is set
    /// to `false` here — it's recomputed dynamically by `mainScreenGeometry`.
    private func readScreenGeometryOnMain() -> ScreenGeometry {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0

        var displays: [DisplayInfo] = []
        displays.reserveCapacity(screens.count)
        for screen in screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let id = num.uint32Value as CGDirectDisplayID
            let cg = CGDisplayBounds(id)
            displays.append(DisplayInfo(
                id: id,
                cgFrame: cg,
                cocoaVisibleFrame: screen.visibleFrame,
                isFullscreen: false
            ))
        }
        return ScreenGeometry(primaryHeight: primaryHeight, staticDisplays: displays)
    }
}
