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
    if elapsedMs > thresholdMs {
        Log.perf.warning("main-thread task \(name, privacy: .public) took \(elapsedMs, format: .fixed(precision: 2))ms (>\(thresholdMs, format: .fixed(precision: 1))ms) at \(file, privacy: .public):\(line)")
    }
    return result
}
