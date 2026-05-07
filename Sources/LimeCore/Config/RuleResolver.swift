import Foundation

/// Attributes available for matching a window against rules.
public struct WindowAttributes: Sendable, Equatable {
    public let appName: String?
    public let bundleIdentifier: String?
    public let windowTitle: String?
    public let windowID: UInt32?
    public let aerospaceWorkspace: String?

    public init(
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        windowID: UInt32? = nil,
        aerospaceWorkspace: String? = nil
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.aerospaceWorkspace = aerospaceWorkspace
    }
}

/// Per-CLI-call overrides. Highest precedence (PLAN.md: CLI args > rule > global > defaults).
public struct EffectOverrides: Sendable, Equatable {
    public let name: String?
    public let color: ColorSpec.RGBA?
    public let durationMs: Int?

    public init(name: String? = nil, color: ColorSpec.RGBA? = nil, durationMs: Int? = nil) {
        self.name = name
        self.color = color
        self.durationMs = durationMs
    }

    public static let none = EffectOverrides()
}

/// Pure functions over an immutable `ConfigSnapshot`.
public enum RuleResolver {
    /// Returns true if the window matches the given match clause. An empty
    /// match (no fields set) matches nothing — bad-regex isolation relies on this.
    public static func matches(_ attrs: WindowAttributes, _ m: WindowMatch) -> Bool {
        if m.isEmpty { return false }

        if let want = m.appName, attrs.appName != want { return false }
        if let want = m.bundleIdentifier, attrs.bundleIdentifier != want { return false }
        if let want = m.windowTitleExact, attrs.windowTitle != want { return false }
        if let want = m.windowTitleContains {
            guard let title = attrs.windowTitle, title.contains(want) else { return false }
        }
        if let regex = m.windowTitleRegex {
            guard let title = attrs.windowTitle else { return false }
            let ns = title as NSString
            let range = NSRange(location: 0, length: ns.length)
            if regex.firstMatch(in: title, options: [], range: range) == nil { return false }
        }
        if let want = m.windowID, attrs.windowID != want { return false }
        if let want = m.aerospaceWorkspace, attrs.aerospaceWorkspace != want { return false }
        return true
    }

    public static func isExcluded(_ attrs: WindowAttributes, snapshot: ConfigSnapshot) -> Bool {
        snapshot.exclude.contains { matches(attrs, $0) }
    }

    /// First-matching rule in source order, or nil.
    public static func firstMatchingRule(_ attrs: WindowAttributes, snapshot: ConfigSnapshot) -> Rule? {
        snapshot.rules.first { matches(attrs, $0.match) }
    }

    /// Effect resolution: CLI overrides > matching rule > snapshot.defaultEffect.
    public static func resolveEffect(
        for attrs: WindowAttributes,
        snapshot: ConfigSnapshot,
        overrides: EffectOverrides = .none
    ) -> EffectConfig {
        let rule = firstMatchingRule(attrs, snapshot: snapshot)
        let base = rule?.effect ?? snapshot.defaultEffect
        return EffectConfig(
            name: overrides.name ?? base.name,
            color: overrides.color ?? base.color,
            durationMs: overrides.durationMs ?? base.durationMs
        )
    }

    /// Border resolution for a target window: rule overrides patch the global borders config.
    public static func resolveBorders(
        for attrs: WindowAttributes,
        snapshot: ConfigSnapshot
    ) -> BordersConfig {
        let g = snapshot.borders
        guard let rule = firstMatchingRule(attrs, snapshot: snapshot),
              let o = rule.borderOverrides else {
            return g
        }
        return BordersConfig(
            enabled: g.enabled,
            style: o.style ?? g.style,
            order: g.order,
            width: o.width ?? g.width,
            hidpi: g.hidpi,
            active: o.active ?? g.active,
            inactive: o.inactive ?? g.inactive,
            background: g.background
        )
    }
}
