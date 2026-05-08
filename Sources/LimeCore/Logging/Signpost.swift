import Foundation
import OSLog

/// Lightweight wrapper around `OSSignposter` for measuring critical paths.
/// Used by later subsystems to flag main-thread tasks above the configured threshold.
public enum Signposts {
    public static let core = OSSignposter(subsystem: Log.subsystem, category: "core")
    public static let ipc = OSSignposter(subsystem: Log.subsystem, category: "ipc")
    public static let config = OSSignposter(subsystem: Log.subsystem, category: "config")
    public static let tracker = OSSignposter(subsystem: Log.subsystem, category: "tracker")
    public static let borders = OSSignposter(subsystem: Log.subsystem, category: "borders")
    public static let render = OSSignposter(subsystem: Log.subsystem, category: "render")
}

/// Measures a synchronous main-thread block and logs a warning when its duration
/// exceeds `thresholdMs`. The default threshold mirrors `performance.maxMainThreadTaskMs`.
@discardableResult
public func mainThreadBudget<T>(
    _ name: StaticString,
    thresholdMs: Double = 8.0,
    file: StaticString = #fileID,
    line: UInt = #line,
    _ body: () throws -> T
) rethrows -> T {
    let start = DispatchTime.now()
    let result = try body()
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    MainThreadBudgetMetrics.record(elapsedMs: elapsedMs, thresholdMs: thresholdMs)
    if elapsedMs > thresholdMs {
        Log.perf.warning("main-thread task \(name, privacy: .public) took \(elapsedMs, format: .fixed(precision: 2))ms (>\(thresholdMs, format: .fixed(precision: 1))ms) at \(file, privacy: .public):\(line)")
    }
    return result
}

/// Process-wide counters for `mainThreadBudget` calls. Surfaced through
/// `limelight perf` (focusfx-30.1) so users can see how often we breached
/// the budget without grepping `log stream`. Read-only API; tests reset
/// via `_resetForTesting()`.
public enum MainThreadBudgetMetrics {
    private static let queue = DispatchQueue(label: "dev.abhirup.lime.perf.budget")
    private static var totalCalls: UInt64 = 0
    private static var slowCalls: UInt64 = 0
    private static var maxElapsedMs: Double = 0
    private static var slowestTaskAt: Date?

    public struct Snapshot: Sendable, Equatable {
        public let totalCalls: UInt64
        public let slowCalls: UInt64
        public let maxElapsedMs: Double
        public let slowestTaskAt: Date?
    }

    public static func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(
                totalCalls: totalCalls,
                slowCalls: slowCalls,
                maxElapsedMs: maxElapsedMs,
                slowestTaskAt: slowestTaskAt
            )
        }
    }

    static func record(elapsedMs: Double, thresholdMs: Double) {
        queue.sync {
            totalCalls &+= 1
            if elapsedMs > thresholdMs { slowCalls &+= 1 }
            if elapsedMs > maxElapsedMs {
                maxElapsedMs = elapsedMs
                slowestTaskAt = Date()
            }
        }
    }

    public static func _resetForTesting() {
        queue.sync {
            totalCalls = 0
            slowCalls = 0
            maxElapsedMs = 0
            slowestTaskAt = nil
        }
    }
}
