import Foundation

/// Runtime overrides on top of `ConfigSnapshot.borders`. Set by the IPC
/// `borders.style` handler (and the `borders` JankyBorders shim that forwards
/// to it). They live in-memory on the daemon — config files on disk are not
/// rewritten — and stay in effect until the next override or daemon restart.
public struct BorderRuntimeOverrides: Sendable, Equatable {
    public var global: BordersStyleRequest
    public var perWindow: [WindowID: BordersStyleRequest]

    public init(
        global: BordersStyleRequest = BordersStyleRequest(),
        perWindow: [WindowID: BordersStyleRequest] = [:]
    ) {
        self.global = global
        self.perWindow = perWindow
    }

    public static let empty = BorderRuntimeOverrides()

    /// Apply a parsed shim/CLI request. If the request carries `applyTo`,
    /// it lands as a per-window override (and is stripped from the global
    /// payload that gets stored). Otherwise it merges into the global
    /// override field-by-field.
    public mutating func apply(_ req: BordersStyleRequest) {
        if let target = req.applyTo, let id = WindowID(exactly: target) {
            var perW = req
            perW.applyTo = nil
            perWindow[id] = perW
        } else {
            mergeIntoGlobal(req)
        }
    }

    public mutating func clearGlobal() { global = BordersStyleRequest() }
    public mutating func clearWindow(_ id: WindowID) { perWindow.removeValue(forKey: id) }
    public mutating func clearAll() {
        global = BordersStyleRequest()
        perWindow = [:]
    }

    private mutating func mergeIntoGlobal(_ r: BordersStyleRequest) {
        if let v = r.enabled { global.enabled = v }
        if let v = r.active { global.active = v }
        if let v = r.inactive { global.inactive = v }
        if let v = r.background { global.background = v }
        if let v = r.backgroundEnabled { global.backgroundEnabled = v }
        if let v = r.width { global.width = v }
        if let v = r.style { global.style = v }
        if let v = r.order { global.order = v }
        if let v = r.hidpi { global.hidpi = v }
        if let v = r.blacklist { global.blacklist = v }
        if let v = r.whitelist { global.whitelist = v }
        if let v = r.axFocus { global.axFocus = v }
    }
}

/// Decodes a `BordersStyleRequest` from the same dictionary shape that
/// `BordersStyleRequest.ipcArgs` produces. Used by the daemon-side handler.
public enum BordersStyleRequestDecoder {
    public enum DecodeError: Error, CustomStringConvertible {
        case badType(field: String, expected: String)
        case badEnum(field: String, value: String)
        case badColor(field: String, reason: String)

        public var description: String {
            switch self {
            case .badType(let f, let e): return "\(f): expected \(e)"
            case .badEnum(let f, let v): return "\(f): unknown value '\(v)'"
            case .badColor(let f, let r): return "\(f): \(r)"
            }
        }
    }

    public static func decode(from args: [String: AnyCodable]) throws -> BordersStyleRequest {
        var req = BordersStyleRequest()
        for (key, wrapped) in args {
            let v = wrapped.value
            switch key {
            case "enabled":
                req.enabled = try requireBool(key, v)
            case "active":
                req.active = try decodeColor(key, v)
            case "inactive":
                req.inactive = try decodeColor(key, v)
            case "background":
                req.background = try decodeColor(key, v)
            case "backgroundEnabled":
                req.backgroundEnabled = try requireBool(key, v)
            case "width":
                req.width = try requireDouble(key, v)
            case "style":
                let s = try requireString(key, v)
                guard let parsed = BordersConfig.Style(rawValue: s) else {
                    throw DecodeError.badEnum(field: key, value: s)
                }
                req.style = parsed
            case "order":
                let s = try requireString(key, v)
                guard let parsed = BordersConfig.Order(rawValue: s) else {
                    throw DecodeError.badEnum(field: key, value: s)
                }
                req.order = parsed
            case "hidpi":
                req.hidpi = try requireBool(key, v)
            case "axFocus":
                req.axFocus = try requireBool(key, v)
            case "blacklist":
                req.blacklist = try requireStringArray(key, v)
            case "whitelist":
                req.whitelist = try requireStringArray(key, v)
            case "applyTo":
                req.applyTo = try requireInt(key, v)
            default:
                continue // forward-compatible: ignore unknowns
            }
        }
        return req
    }

    private static func requireBool(_ key: String, _ v: Any) throws -> Bool {
        guard let b = v as? Bool else { throw DecodeError.badType(field: key, expected: "bool") }
        return b
    }
    private static func requireDouble(_ key: String, _ v: Any) throws -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let i = v as? Int64 { return Double(i) }
        throw DecodeError.badType(field: key, expected: "number")
    }
    private static func requireInt(_ key: String, _ v: Any) throws -> Int {
        if let i = v as? Int { return i }
        if let i = v as? Int64 { return Int(i) }
        if let d = v as? Double { return Int(d) }
        throw DecodeError.badType(field: key, expected: "int")
    }
    private static func requireString(_ key: String, _ v: Any) throws -> String {
        guard let s = v as? String else { throw DecodeError.badType(field: key, expected: "string") }
        return s
    }
    private static func requireStringArray(_ key: String, _ v: Any) throws -> [String] {
        guard let arr = v as? [AnyCodable] else { throw DecodeError.badType(field: key, expected: "string[]") }
        return try arr.map { try requireString(key, $0.value) }
    }

    private static func decodeColor(_ key: String, _ v: Any) throws -> ColorSpec {
        guard let dict = v as? [String: AnyCodable] else {
            throw DecodeError.badColor(field: key, reason: "expected object")
        }
        guard let kindBox = dict["kind"], let kind = kindBox.value as? String else {
            throw DecodeError.badColor(field: key, reason: "missing kind")
        }
        switch kind {
        case "solid":
            return .solid(try decodeRGBA(key, dict["rgba"]?.value))
        case "glow":
            return .glow(try decodeRGBA(key, dict["rgba"]?.value))
        case "gradient":
            guard let axisStr = dict["axis"]?.value as? String,
                  let axis = ColorSpec.GradientAxis(rawValue: axisStr) else {
                throw DecodeError.badColor(field: key, reason: "missing/unknown axis")
            }
            return .gradient(
                axis: axis,
                start: try decodeRGBA(key, dict["start"]?.value),
                end: try decodeRGBA(key, dict["end"]?.value)
            )
        default:
            throw DecodeError.badColor(field: key, reason: "unknown color kind '\(kind)'")
        }
    }

    private static func decodeRGBA(_ key: String, _ v: Any?) throws -> ColorSpec.RGBA {
        guard let dict = v as? [String: AnyCodable] else {
            throw DecodeError.badColor(field: key, reason: "expected rgba object")
        }
        func num(_ k: String) throws -> Double {
            guard let box = dict[k] else { throw DecodeError.badColor(field: key, reason: "missing rgba.\(k)") }
            if let d = box.value as? Double { return d }
            if let i = box.value as? Int { return Double(i) }
            if let i = box.value as? Int64 { return Double(i) }
            throw DecodeError.badColor(field: key, reason: "rgba.\(k) not numeric")
        }
        return ColorSpec.RGBA(r: try num("r"), g: try num("g"), b: try num("b"), a: try num("a"))
    }
}
