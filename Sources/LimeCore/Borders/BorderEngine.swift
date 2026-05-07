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

    public init(tracker: WindowTracker, configStore: ConfigStore) {
        self.tracker = tracker
        self.configStore = configStore
    }

    /// The daemon connects this to the WindowTracker coalescer on startup.
    /// Each call schedules a single recompute on the borders queue.
    public func handleCoalescedBatch(_ updates: [CoalescedUpdate]) {
        queue.async { [weak self] in self?.recompute() }
    }

    /// Force a full recompute (config reload / startup / topology change).
    public func recompute() {
        let snapshot = configStore.currentSnapshot
        let cache = Dictionary(uniqueKeysWithValues: tracker.snapshot.map { ($0.windowID, $0) })
        let primaryHeight = mainScreenHeight()

        let inputs = BorderEngineLogic.Inputs(
            windows: cache,
            focusedWindowID: tracker.currentFocusedWindowID,
            snapshot: snapshot,
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
