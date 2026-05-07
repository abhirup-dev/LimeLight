import Foundation

/// Loads, validates, and serves an immutable snapshot of the JSONC config.
/// All parsing/regex work runs off the main thread; window events read the
/// snapshot via `currentSnapshot` without locks on the hot path.
public final class ConfigStore {
    public init() {}
    // Implementation lands in focusfx-5 (control plane) / focusfx-1.2.
}
