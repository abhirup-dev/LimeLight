import Foundation

public struct ConfigSnapshot: Sendable {
    public let performance: PerformanceConfig
    public let borders: BordersConfig
    public let defaultEffect: EffectConfig
    public let popup: PopupConfig
    public let idleReturn: IdleReturnConfig
    public let rules: [Rule]
    public let exclude: [WindowMatch]

    /// Diagnostics gathered during compile. Always present, may be empty.
    public let diagnostics: [ConfigDiagnostic]

    public static let `default` = ConfigSnapshot(
        performance: .default,
        borders: .default,
        defaultEffect: .default,
        popup: .default,
        idleReturn: .default,
        rules: [],
        exclude: [],
        diagnostics: []
    )
}

public struct PerformanceConfig: Sendable, Equatable {
    public let eventCoalesceMs: Int
    public let maxMainThreadTaskMs: Int
    public let idleCpuTargetPercent: Double
    public let enablePerfLogging: Bool

    public static let `default` = PerformanceConfig(
        eventCoalesceMs: 16,
        maxMainThreadTaskMs: 8,
        idleCpuTargetPercent: 1.0,
        enablePerfLogging: true
    )
}

public struct BordersConfig: Sendable, Equatable {
    public enum Style: String, Sendable, Equatable { case round, square, uniform }
    public enum Order: String, Sendable, Equatable { case above, below }

    public let enabled: Bool
    public let style: Style
    public let order: Order
    public let width: Double
    public let hidpi: Bool
    public let active: ColorSpec
    public let inactive: ColorSpec
    public let background: BackgroundConfig

    public struct BackgroundConfig: Sendable, Equatable {
        public let enabled: Bool
        public let color: ColorSpec
    }

    public static let `default` = BordersConfig(
        enabled: true,
        style: .round,
        order: .below,
        width: 5.0,
        hidpi: false,
        active: .solid(.init(r: 225/255.0, g: 227/255.0, b: 228/255.0, a: 1.0)),
        inactive: .solid(.init(r: 73/255.0, g: 77/255.0, b: 100/255.0, a: 1.0)),
        background: .init(enabled: false, color: .solid(.init(r: 0, g: 0, b: 0, a: 0)))
    )
}

public struct EffectConfig: Sendable, Equatable {
    public let name: String
    public let color: ColorSpec.RGBA
    public let durationMs: Int

    public static let `default` = EffectConfig(
        name: "cometRing",
        color: .init(r: 0, g: 209/255.0, b: 255/255.0, a: 1.0),
        durationMs: 500
    )
}

public struct PopupConfig: Sendable, Equatable {
    public enum Placement: String, Sendable, Equatable {
        case topRight, topLeft, bottomRight, bottomLeft, center
    }

    public let enabled: Bool
    public let placement: Placement
    public let durationMs: Int
    public let showAppIcon: Bool
    public let showWindowTitle: Bool

    public static let `default` = PopupConfig(
        enabled: true,
        placement: .topRight,
        durationMs: 2200,
        showAppIcon: true,
        showWindowTitle: true
    )
}

public struct IdleReturnConfig: Sendable, Equatable {
    public let enabled: Bool
    public let thresholdSeconds: Int
    public let popupTitle: String
    public let popupMessage: String
    public let effectName: String

    public static let `default` = IdleReturnConfig(
        enabled: true,
        thresholdSeconds: 300,
        popupTitle: "Welcome back",
        popupMessage: "Idle for {idleMinutes}m",
        effectName: "cometRing"
    )
}

public struct Rule: Sendable {
    public let name: String?
    public let match: WindowMatch
    public let borderOverrides: BorderOverrides?
    public let effect: EffectConfig?

    public struct BorderOverrides: Sendable {
        public let active: ColorSpec?
        public let inactive: ColorSpec?
        public let width: Double?
        public let style: BordersConfig.Style?
    }
}

/// Pre-compiled match. Strings are stored verbatim; the regex (if any) is compiled once.
public struct WindowMatch: Sendable {
    public let appName: String?
    public let bundleIdentifier: String?
    public let windowTitleExact: String?
    public let windowTitleContains: String?
    public let windowTitleRegex: NSRegularExpression?
    public let windowID: UInt32?
    public let aerospaceWorkspace: String?

    public var isEmpty: Bool {
        appName == nil && bundleIdentifier == nil && windowTitleExact == nil
            && windowTitleContains == nil && windowTitleRegex == nil
            && windowID == nil && aerospaceWorkspace == nil
    }
}
