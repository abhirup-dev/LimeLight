import Dispatch
import Foundation
import os

/// Per-window monotonic counter; incremented every time a frame-affecting
/// change is observed for that window. Async work that started at generation
/// N must be discarded if `currentGeneration(for:)` has moved past N.
public typealias WindowGeneration = UInt64

/// What changed for a window in this batch. The coalescer keeps the *latest*
/// kind seen during a coalescing window — bursts collapse to one update.
public enum WindowChange: Sendable, Equatable {
    case created
    case destroyed
    case frameChanged
    case focusChanged
    case visibilityChanged
}

public struct CoalescedUpdate: Sendable, Equatable {
    public let windowID: WindowID
    public let change: WindowChange
    public let generation: WindowGeneration
}

/// Off-main coalescer for window events.
///
/// Inputs (`enqueue`) can come from any thread/queue. The coalescer batches
/// them inside a `coalesceWindow` (default 16 ms) and delivers a single batch
/// per coalescing tick to the consumer-supplied handler on a serial dispatch
/// queue. Per-window state collapses to the latest change kind, and queue size
/// is bounded by the number of distinct windows touched in the window — never
/// by burst length.
public final class WindowEventCoalescer: @unchecked Sendable {
    public typealias Handler = @Sendable ([CoalescedUpdate]) -> Void

    public let coalesceWindow: DispatchTimeInterval
    private let queue: DispatchQueue
    private var pending: [WindowID: WindowChange] = [:]
    private var generations: [WindowID: WindowGeneration] = [:]
    private var lock = os_unfair_lock()
    private var scheduled = false
    private let handler: Handler

    public init(
        coalesceMs: Int = 16,
        queue: DispatchQueue = DispatchQueue(label: "dev.abhirup.lime.coalesce", qos: .userInitiated),
        handler: @escaping Handler
    ) {
        self.coalesceWindow = .milliseconds(max(0, coalesceMs))
        self.queue = queue
        self.handler = handler
    }

    /// Record an event. Multiple events for the same window inside one window
    /// collapse to the latest non-superseded change. Generation is bumped only
    /// for frame-affecting changes (created/frameChanged/visibilityChanged) so
    /// pure focus flips don't invalidate in-flight redraw work for that window.
    public func enqueue(_ windowID: WindowID, change: WindowChange) {
        os_unfair_lock_lock(&lock)
        if Self.bumpsGeneration(change) {
            generations[windowID, default: 0] &+= 1
        }
        pending[windowID] = Self.merge(existing: pending[windowID], next: change)
        let needsSchedule = !scheduled
        if needsSchedule { scheduled = true }
        os_unfair_lock_unlock(&lock)

        if needsSchedule {
            queue.asyncAfter(deadline: .now() + coalesceWindow) { [weak self] in
                self?.flush()
            }
        }
    }

    /// Force-flush whatever is pending. Useful for tests.
    public func flushNow() {
        flush()
    }

    public func currentGeneration(for windowID: WindowID) -> WindowGeneration {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return generations[windowID] ?? 0
    }

    public var pendingCount: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return pending.count
    }

    // MARK: - internal

    private func flush() {
        os_unfair_lock_lock(&lock)
        let batch = pending
        let snapshot = generations
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        os_unfair_lock_unlock(&lock)

        guard !batch.isEmpty else { return }

        let updates: [CoalescedUpdate] = batch
            .map { (wid, change) in
                CoalescedUpdate(windowID: wid, change: change, generation: snapshot[wid] ?? 0)
            }
            .sorted { $0.windowID < $1.windowID }
        handler(updates)
    }

    /// `destroyed` always wins. `created` followed by anything stays `created`
    /// (the consumer hasn't seen this window yet — semantics are still "new"
    /// with whatever frame is current). All others collapse to the most recent.
    static func merge(existing: WindowChange?, next: WindowChange) -> WindowChange {
        guard let existing else { return next }
        if existing == .destroyed { return .destroyed }
        if next == .destroyed { return .destroyed }
        if existing == .created { return .created }
        return next
    }

    static func bumpsGeneration(_ change: WindowChange) -> Bool {
        switch change {
        case .frameChanged, .created, .visibilityChanged, .destroyed: return true
        case .focusChanged: return false
        }
    }
}
