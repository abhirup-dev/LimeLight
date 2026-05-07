import AppKit
import Foundation

/// Wires WindowTracker (cache + coalescer) → BorderEngineLogic → BorderRenderer.
/// Owned by the daemon. Lives entirely off-main except for the renderer hop.
public final class BorderEngine: @unchecked Sendable {
    private let tracker: WindowTracker
    private let configStore: ConfigStore
    @MainActor private let renderer = BorderRenderer()
    private let queue = DispatchQueue(label: "dev.abhirup.lime.borders", qos: .userInitiated)
    private var lastDesired: [WindowID: BorderSpec] = [:]
    private var overrides: BorderRuntimeOverrides = .empty

    public init(tracker: WindowTracker, configStore: ConfigStore) {
        self.tracker = tracker
        self.configStore = configStore
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

    /// Force-redraw every window: clears the diff baseline so every desired
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
    /// Each call schedules a single recompute on the borders queue.
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
        let cache = Dictionary(uniqueKeysWithValues: tracker.snapshot.map { ($0.windowID, $0) })
        let primaryHeight = mainScreenHeight()

        let inputs = BorderEngineLogic.Inputs(
            windows: cache,
            focusedWindowID: tracker.currentFocusedWindowID,
            snapshot: snapshot,
            overrides: overrides,
            primaryDisplayHeight: primaryHeight
        )
        let next = BorderEngineLogic.desiredBorders(inputs)
        let diff = BorderEngineLogic.diff(prev: lastDesired, next: next)
        lastDesired = next

        if diff.toCreate.isEmpty, diff.toUpdate.isEmpty, diff.toDestroy.isEmpty {
            return
        }
        Log.borders.debug("apply +\(diff.toCreate.count) ~\(diff.toUpdate.count) -\(diff.toDestroy.count)")
        DispatchQueue.main.async { [renderer] in
            renderer.apply(diff)
        }
    }

    public func tearDown() {
        DispatchQueue.main.async { [renderer] in
            renderer.tearDown()
        }
        lastDesired = [:]
    }

    /// `NSScreen.screens` must be read on main; cache it cheaply.
    private func mainScreenHeight() -> CGFloat {
        if Thread.isMainThread {
            return NSScreen.screens.first?.frame.height ?? 0
        }
        var h: CGFloat = 0
        DispatchQueue.main.sync {
            h = NSScreen.screens.first?.frame.height ?? 0
        }
        return h
    }
}
