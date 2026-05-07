import Foundation

/// Decode-only DTOs that match PLAN.md verbatim. Compilation into the runtime
/// `ConfigSnapshot` (typed colors, compiled regexes) happens in ConfigCompiler.
public struct RawConfig: Codable, Sendable {
    public var performance: RawPerformance?
    public var borders: RawBorders?
    public var effects: RawEffects?
    public var popup: RawPopup?
    public var idleReturn: RawIdleReturn?
    public var rules: [RawRule]?
    public var exclude: [RawMatch]?
}

public struct RawPerformance: Codable, Sendable {
    public var eventCoalesceMs: Int?
    public var maxMainThreadTaskMs: Int?
    public var idleCpuTargetPercent: Double?
    public var enablePerfLogging: Bool?
}

public struct RawBorders: Codable, Sendable {
    public var enabled: Bool?
    public var style: String?       // round | square | uniform
    public var order: String?       // above | below
    public var width: Double?
    public var hidpi: Bool?
    public var active: RawBorderColor?
    public var inactive: RawBorderColor?
    public var background: RawBorderBackground?
}

public struct RawBorderColor: Codable, Sendable {
    public var color: String?
}

public struct RawBorderBackground: Codable, Sendable {
    public var enabled: Bool?
    public var color: String?
}

public struct RawEffects: Codable, Sendable {
    public var `default`: RawEffect?
}

public struct RawEffect: Codable, Sendable {
    public var name: String?
    public var color: String?
    public var durationMs: Int?
}

public struct RawPopup: Codable, Sendable {
    public var enabled: Bool?
    public var placement: String?   // topRight | topLeft | bottomRight | bottomLeft | center
    public var durationMs: Int?
    public var showAppIcon: Bool?
    public var showWindowTitle: Bool?
}

public struct RawIdleReturn: Codable, Sendable {
    public var enabled: Bool?
    public var thresholdSeconds: Int?
    public var popup: RawIdlePopup?
    public var effect: String?
}

public struct RawIdlePopup: Codable, Sendable {
    public var title: String?
    public var message: String?
}

public struct RawRule: Codable, Sendable {
    public var name: String?
    public var match: RawMatch?
    public var borders: RawRuleBorders?
    public var effect: RawEffect?
}

public struct RawRuleBorders: Codable, Sendable {
    public var active: RawBorderColor?
    public var inactive: RawBorderColor?
    public var width: Double?
    public var style: String?
}

public struct RawMatch: Codable, Sendable {
    public var appName: String?
    public var bundleIdentifier: String?
    public var windowTitle: String?
    public var windowTitleContains: String?
    public var windowTitleRegex: String?
    public var windowID: UInt32?
    public var aerospaceWorkspace: String?
}
