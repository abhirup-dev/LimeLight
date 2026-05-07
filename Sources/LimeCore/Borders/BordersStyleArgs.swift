import Foundation

/// Typed result of parsing a JankyBorders-compatible argv list.
///
/// All fields are optional: a missing flag means "leave this dimension untouched"
/// when the daemon applies the override. Unsupported flags produce diagnostics
/// rather than fatal errors so that AeroSpace startup commands containing extras
/// keep the shim usable.
public struct BordersStyleRequest: Sendable, Equatable {
    public var enabled: Bool?
    public var active: ColorSpec?
    public var inactive: ColorSpec?
    public var background: ColorSpec?
    public var backgroundEnabled: Bool?
    public var width: Double?
    public var style: BordersConfig.Style?
    public var order: BordersConfig.Order?
    public var hidpi: Bool?
    public var blacklist: [String]?
    public var whitelist: [String]?
    public var axFocus: Bool?
    public var applyTo: Int?

    public init() {}
}

public enum BordersStyleArgs {
    public struct ParseOutcome: Sendable, Equatable {
        public var request: BordersStyleRequest
        public var errors: [String]
        public var warnings: [String]
        public var hasFatalErrors: Bool { !errors.isEmpty }
    }

    /// Parse a JankyBorders-style token list. Tokens are `key=value` pairs;
    /// a leading bare `borders` subcommand (the JB binary name when invoked
    /// from a CLI) is tolerated.
    public static func parse(_ tokens: [String]) -> ParseOutcome {
        var req = BordersStyleRequest()
        var errors: [String] = []
        var warnings: [String] = []

        for raw in tokens {
            // Tolerate a stray "borders" or "--" token.
            if raw == "borders" || raw == "--" { continue }
            if raw.isEmpty { continue }

            guard let eq = raw.firstIndex(of: "=") else {
                errors.append("missing '=' in token: \(raw)")
                continue
            }
            let key = String(raw[raw.startIndex..<eq]).lowercased()
            let value = String(raw[raw.index(after: eq)..<raw.endIndex])

            do {
                try apply(key: key, value: value, into: &req, warnings: &warnings)
            } catch let e as ParseFailure {
                errors.append(e.message)
            } catch {
                errors.append("\(key): \(error)")
            }
        }

        return ParseOutcome(request: req, errors: errors, warnings: warnings)
    }

    private struct ParseFailure: Error { let message: String }

    private static func apply(
        key: String,
        value: String,
        into req: inout BordersStyleRequest,
        warnings: inout [String]
    ) throws {
        switch key {
        case "active_color":
            req.active = try parseColor(key: key, value: value)
        case "inactive_color":
            req.inactive = try parseColor(key: key, value: value)
        case "background_color":
            let c = try parseColor(key: key, value: value)
            req.background = c
            // JankyBorders treats any non-zero alpha as enabling the fill.
            if case .solid(let rgba) = c, rgba.a == 0 {
                req.backgroundEnabled = false
            } else {
                req.backgroundEnabled = true
            }
        case "width":
            guard let d = Double(value) else {
                throw ParseFailure(message: "width must be a number, got '\(value)'")
            }
            req.width = d
        case "style":
            guard let s = BordersConfig.Style(rawValue: value.lowercased()) else {
                throw ParseFailure(message: "style must be round|square|uniform, got '\(value)'")
            }
            req.style = s
        case "order":
            guard let o = BordersConfig.Order(rawValue: value.lowercased()) else {
                throw ParseFailure(message: "order must be above|below, got '\(value)'")
            }
            req.order = o
        case "hidpi":
            req.hidpi = try parseBool(key: key, value: value)
        case "ax_focus":
            req.axFocus = try parseBool(key: key, value: value)
        case "blacklist":
            req.blacklist = splitList(value)
        case "whitelist":
            req.whitelist = splitList(value)
        case "apply-to", "apply_to":
            guard let n = Int(value) else {
                throw ParseFailure(message: "apply-to must be an integer, got '\(value)'")
            }
            req.applyTo = n
        default:
            warnings.append("unsupported option: \(key)")
        }
    }

    private static func parseColor(key: String, value: String) throws -> ColorSpec {
        do {
            return try ColorSpec.parse(value)
        } catch {
            throw ParseFailure(message: "\(key): cannot parse color '\(value)' (\(error))")
        }
    }

    private static func parseBool(key: String, value: String) throws -> Bool {
        switch value.lowercased() {
        case "on", "true", "yes", "1": return true
        case "off", "false", "no", "0": return false
        default:
            throw ParseFailure(message: "\(key): expected on|off, got '\(value)'")
        }
    }

    private static func splitList(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
