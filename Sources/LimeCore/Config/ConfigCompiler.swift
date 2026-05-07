import Foundation

/// Compiles a `RawConfig` (decoded JSON) into a runtime `ConfigSnapshot`,
/// gathering diagnostics. Per-rule failures are isolated: a bad regex disables
/// just that rule rather than nuking the whole config.
public enum ConfigCompiler {
    public static func compile(_ raw: RawConfig) -> ConfigSnapshot {
        var diagnostics: [ConfigDiagnostic] = []

        let performance = compilePerformance(raw.performance)
        let borders = compileBorders(raw.borders, into: &diagnostics)
        let defaultEffect = compileEffect(raw.effects?.default, fallback: .default, path: "effects.default", into: &diagnostics)
        let popup = compilePopup(raw.popup, into: &diagnostics)
        let idleReturn = compileIdleReturn(raw.idleReturn)
        let rules = compileRules(raw.rules, into: &diagnostics)
        let exclude = compileExcludes(raw.exclude, into: &diagnostics)

        return ConfigSnapshot(
            performance: performance,
            borders: borders,
            defaultEffect: defaultEffect,
            popup: popup,
            idleReturn: idleReturn,
            rules: rules,
            exclude: exclude,
            diagnostics: diagnostics
        )
    }

    // MARK: - sections

    private static func compilePerformance(_ raw: RawPerformance?) -> PerformanceConfig {
        let d = PerformanceConfig.default
        return PerformanceConfig(
            eventCoalesceMs: raw?.eventCoalesceMs ?? d.eventCoalesceMs,
            maxMainThreadTaskMs: raw?.maxMainThreadTaskMs ?? d.maxMainThreadTaskMs,
            idleCpuTargetPercent: raw?.idleCpuTargetPercent ?? d.idleCpuTargetPercent,
            enablePerfLogging: raw?.enablePerfLogging ?? d.enablePerfLogging
        )
    }

    private static func compileBorders(_ raw: RawBorders?, into diags: inout [ConfigDiagnostic]) -> BordersConfig {
        let d = BordersConfig.default
        let style: BordersConfig.Style = enumOrWarn(raw?.style, default: d.style, path: "borders.style", diags: &diags)
        let order: BordersConfig.Order = enumOrWarn(raw?.order, default: d.order, path: "borders.order", diags: &diags)
        let active = colorOrWarn(raw?.active?.color, default: d.active, path: "borders.active.color", diags: &diags)
        let inactive = colorOrWarn(raw?.inactive?.color, default: d.inactive, path: "borders.inactive.color", diags: &diags)
        let bgEnabled = raw?.background?.enabled ?? d.background.enabled
        let bgColor = colorOrWarn(raw?.background?.color, default: d.background.color, path: "borders.background.color", diags: &diags)

        return BordersConfig(
            enabled: raw?.enabled ?? d.enabled,
            style: style,
            order: order,
            width: raw?.width ?? d.width,
            hidpi: raw?.hidpi ?? d.hidpi,
            active: active,
            inactive: inactive,
            background: .init(enabled: bgEnabled, color: bgColor)
        )
    }

    private static func compileEffect(
        _ raw: RawEffect?,
        fallback: EffectConfig,
        path: String,
        into diags: inout [ConfigDiagnostic]
    ) -> EffectConfig {
        guard let raw else { return fallback }
        let color: ColorSpec.RGBA
        if let s = raw.color {
            do { color = try ColorSpec.parseHex(s) }
            catch {
                diags.append(.init(severity: .warning, path: "\(path).color", message: "invalid color '\(s)' — using default"))
                color = fallback.color
            }
        } else {
            color = fallback.color
        }
        return EffectConfig(
            name: raw.name ?? fallback.name,
            color: color,
            durationMs: raw.durationMs ?? fallback.durationMs
        )
    }

    private static func compilePopup(_ raw: RawPopup?, into diags: inout [ConfigDiagnostic]) -> PopupConfig {
        let d = PopupConfig.default
        let placement: PopupConfig.Placement = enumOrWarn(raw?.placement, default: d.placement, path: "popup.placement", diags: &diags)
        return PopupConfig(
            enabled: raw?.enabled ?? d.enabled,
            placement: placement,
            durationMs: raw?.durationMs ?? d.durationMs,
            showAppIcon: raw?.showAppIcon ?? d.showAppIcon,
            showWindowTitle: raw?.showWindowTitle ?? d.showWindowTitle
        )
    }

    private static func compileIdleReturn(_ raw: RawIdleReturn?) -> IdleReturnConfig {
        let d = IdleReturnConfig.default
        return IdleReturnConfig(
            enabled: raw?.enabled ?? d.enabled,
            thresholdSeconds: raw?.thresholdSeconds ?? d.thresholdSeconds,
            popupTitle: raw?.popup?.title ?? d.popupTitle,
            popupMessage: raw?.popup?.message ?? d.popupMessage,
            effectName: raw?.effect ?? d.effectName
        )
    }

    private static func compileRules(_ raw: [RawRule]?, into diags: inout [ConfigDiagnostic]) -> [Rule] {
        guard let raw else { return [] }
        var compiled: [Rule] = []
        compiled.reserveCapacity(raw.count)
        for (i, r) in raw.enumerated() {
            let rulePath = "rules[\(i)]"
            guard let rawMatch = r.match else {
                diags.append(.init(severity: .warning, path: rulePath, message: "rule has no 'match' — skipped"))
                continue
            }
            let match: WindowMatch
            do {
                match = try compileMatch(rawMatch, path: "\(rulePath).match")
            } catch let e as MatchError {
                diags.append(.init(severity: .warning, path: e.path, message: e.message))
                // Keep the rule but mark it never-match by emptying the match.
                match = WindowMatch(appName: nil, bundleIdentifier: nil, windowTitleExact: nil,
                                    windowTitleContains: nil, windowTitleRegex: nil,
                                    windowID: nil, aerospaceWorkspace: nil)
            } catch {
                diags.append(.init(severity: .warning, path: "\(rulePath).match", message: "\(error)"))
                continue
            }

            var borderOverrides: Rule.BorderOverrides?
            if let b = r.borders {
                let active = b.active?.color.flatMap { try? ColorSpec.parse($0) }
                let inactive = b.inactive?.color.flatMap { try? ColorSpec.parse($0) }
                let style = b.style.flatMap { BordersConfig.Style(rawValue: $0) }
                if active == nil, let s = b.active?.color {
                    diags.append(.init(severity: .warning, path: "\(rulePath).borders.active.color", message: "invalid color '\(s)'"))
                }
                if inactive == nil, let s = b.inactive?.color {
                    diags.append(.init(severity: .warning, path: "\(rulePath).borders.inactive.color", message: "invalid color '\(s)'"))
                }
                borderOverrides = Rule.BorderOverrides(active: active, inactive: inactive, width: b.width, style: style)
            }

            let effect: EffectConfig? = r.effect.map {
                compileEffect($0, fallback: EffectConfig.default, path: "\(rulePath).effect", into: &diags)
            }

            compiled.append(Rule(name: r.name, match: match, borderOverrides: borderOverrides, effect: effect))
        }
        return compiled
    }

    private static func compileExcludes(_ raw: [RawMatch]?, into diags: inout [ConfigDiagnostic]) -> [WindowMatch] {
        guard let raw else { return [] }
        var compiled: [WindowMatch] = []
        for (i, m) in raw.enumerated() {
            let path = "exclude[\(i)]"
            do {
                compiled.append(try compileMatch(m, path: path))
            } catch let e as MatchError {
                diags.append(.init(severity: .warning, path: e.path, message: e.message))
            } catch {
                diags.append(.init(severity: .warning, path: path, message: "\(error)"))
            }
        }
        return compiled
    }

    // MARK: - match compilation

    private struct MatchError: Error {
        let path: String
        let message: String
    }

    private static func compileMatch(_ m: RawMatch, path: String) throws -> WindowMatch {
        var regex: NSRegularExpression?
        if let pattern = m.windowTitleRegex {
            do {
                regex = try NSRegularExpression(pattern: pattern, options: [])
            } catch {
                throw MatchError(path: "\(path).windowTitleRegex", message: "invalid regex '\(pattern)': \(error.localizedDescription)")
            }
        }
        return WindowMatch(
            appName: m.appName,
            bundleIdentifier: m.bundleIdentifier,
            windowTitleExact: m.windowTitle,
            windowTitleContains: m.windowTitleContains,
            windowTitleRegex: regex,
            windowID: m.windowID,
            aerospaceWorkspace: m.aerospaceWorkspace
        )
    }

    // MARK: - small helpers

    private static func enumOrWarn<E: RawRepresentable>(
        _ raw: String?,
        default: E,
        path: String,
        diags: inout [ConfigDiagnostic]
    ) -> E where E.RawValue == String {
        guard let raw else { return `default` }
        if let v = E(rawValue: raw) { return v }
        diags.append(.init(severity: .warning, path: path, message: "unknown value '\(raw)' — using default"))
        return `default`
    }

    private static func colorOrWarn(
        _ raw: String?,
        default: ColorSpec,
        path: String,
        diags: inout [ConfigDiagnostic]
    ) -> ColorSpec {
        guard let raw else { return `default` }
        do { return try ColorSpec.parse(raw) }
        catch {
            diags.append(.init(severity: .warning, path: path, message: "invalid color '\(raw)' — using default"))
            return `default`
        }
    }
}
