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
    }

    deinit {
        if let token = screenParamsObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Apply a runtime override (from `borders.style` IPC). Triggers a recompute.
    public func applyStyleRequest(_ req: BordersStyleRequest) {
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
            displays: geom.displays
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
        DispatchQueue.main.async { [renderer] in
            renderer.apply(diff)
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
    /// our queue.
    private func installScreenParamsObserver() {
        let nc = NotificationCenter.default
        screenParamsObserver = nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.recompute()
        }
    }

    /// Reads `NSScreen.screens` on main and synthesizes the per-display info
    /// the engine needs. Must be safe to call off-main; we hop synchronously
    /// when needed because the recompute path is short.
    ///
    /// Fullscreen detection is heuristic: a display whose CG bounds are
    /// covered by some window's frame (within 1pt). Stage Manager and
    /// PiP-style overlays may fool this — see follow-up beads.
    private struct ScreenGeometry {
        let primaryHeight: CGFloat
        let displays: [DisplayInfo]
    }

    private func mainScreenGeometry() -> ScreenGeometry {
        if Thread.isMainThread {
            return readScreenGeometryOnMain()
        }
        var result = ScreenGeometry(primaryHeight: 0, displays: [])
        DispatchQueue.main.sync {
            result = self.readScreenGeometryOnMain()
        }
        return result
    }

    private func readScreenGeometryOnMain() -> ScreenGeometry {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0

        // Snapshot CGWindowList frames once for the fullscreen heuristic so we
        // don't re-enumerate per display.
        let windowFrames: [CGRect] = tracker.orderedSnapshot
            .filter { $0.isOnScreen && $0.frame.width > 0 && $0.frame.height > 0 }
            .map { $0.frame }

        var displays: [DisplayInfo] = []
        displays.reserveCapacity(screens.count)
        for screen in screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let id = num.uint32Value as CGDirectDisplayID
            let cg = CGDisplayBounds(id)
            let isFullscreen = windowFrames.contains { f in
                abs(f.origin.x - cg.origin.x) < 1
                    && abs(f.origin.y - cg.origin.y) < 1
                    && abs(f.size.width - cg.size.width) < 1
                    && abs(f.size.height - cg.size.height) < 1
            }
            displays.append(DisplayInfo(
                id: id,
                cgFrame: cg,
                cocoaVisibleFrame: screen.visibleFrame,
                isFullscreen: isFullscreen
            ))
        }
        return ScreenGeometry(primaryHeight: primaryHeight, displays: displays)
    }
}
