import Foundation
import os

/// Loads, validates, and serves an immutable snapshot of the JSONC config.
/// All parsing/regex work runs off the main thread; consumers read the current
/// snapshot via `currentSnapshot` under a single `os_unfair_lock` (~10 ns).
public final class ConfigStore: @unchecked Sendable {
    public struct LoadResult: Sendable {
        public let snapshot: ConfigSnapshot
        public let replacedActive: Bool
        public let parseError: String?
    }

    public let path: String
    private let parseQueue = DispatchQueue(label: "dev.focusfx.config", qos: .userInitiated)
    private var snapshot: ConfigSnapshot
    private var lock = os_unfair_lock()

    public init(path: String, initial: ConfigSnapshot = .default) {
        self.path = path
        self.snapshot = initial
    }

    /// Lock-protected read. Cheap and main-thread safe.
    public var currentSnapshot: ConfigSnapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return snapshot
    }

    /// Synchronous parse-and-publish; off-main only. Used directly by tests
    /// and by `loadAsync`. Invalid input keeps the previously active snapshot.
    @discardableResult
    public func loadSync() -> LoadResult {
        dispatchPrecondition(condition: .notOnQueue(.main))

        let raw: String
        do {
            raw = try String(contentsOfFile: path, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            Log.config.notice("config not found at \(self.path, privacy: .public) — using defaults")
            let defaults = ConfigSnapshot.default
            publish(defaults)
            return LoadResult(snapshot: defaults, replacedActive: true, parseError: nil)
        } catch {
            Log.config.error("config read failed: \(error.localizedDescription, privacy: .public)")
            return LoadResult(snapshot: currentSnapshot, replacedActive: false, parseError: error.localizedDescription)
        }
        return parse(raw: raw)
    }

    public func loadAsync(completion: @escaping @Sendable (LoadResult) -> Void) {
        parseQueue.async {
            let result = self.loadSync()
            completion(result)
        }
    }

    /// Parses arbitrary JSONC text and publishes if valid. Exposed for tests
    /// and for future "validate without writing" CLI flows.
    @discardableResult
    public func parse(raw: String) -> LoadResult {
        dispatchPrecondition(condition: .notOnQueue(.main))

        let sanitized: String
        do {
            sanitized = try JSONCSanitizer.sanitize(raw)
        } catch {
            return LoadResult(snapshot: currentSnapshot, replacedActive: false, parseError: "JSONC sanitize failed: \(error)")
        }

        let decoded: RawConfig
        do {
            decoded = try IPCCoding.makeDecoder().decode(RawConfig.self, from: Data(sanitized.utf8))
        } catch {
            return LoadResult(snapshot: currentSnapshot, replacedActive: false, parseError: "JSON decode failed: \(error.localizedDescription)")
        }

        let compiled = ConfigCompiler.compile(decoded)
        publish(compiled)
        return LoadResult(snapshot: compiled, replacedActive: true, parseError: nil)
    }

    private func publish(_ next: ConfigSnapshot) {
        os_unfair_lock_lock(&lock)
        snapshot = next
        os_unfair_lock_unlock(&lock)
        let warnings = next.diagnostics.filter { $0.severity == .warning }
        if !warnings.isEmpty {
            Log.config.warning("config compiled with \(warnings.count, privacy: .public) warning(s)")
        }
    }
}
