import Foundation

/// IPC encoding for `BordersStyleRequest`. Stable on-the-wire keys so the
/// daemon-side handler (focusfx-14.3) can decode without churn.
public extension BordersStyleRequest {
    var ipcArgs: [String: AnyCodable] {
        var dict: [String: AnyCodable] = [:]
        if let v = enabled { dict["enabled"] = AnyCodable(v) }
        if let v = active { dict["active"] = AnyCodable(Self.encodeColor(v)) }
        if let v = inactive { dict["inactive"] = AnyCodable(Self.encodeColor(v)) }
        if let v = background { dict["background"] = AnyCodable(Self.encodeColor(v)) }
        if let v = backgroundEnabled { dict["backgroundEnabled"] = AnyCodable(v) }
        if let v = width { dict["width"] = AnyCodable(v) }
        if let v = style { dict["style"] = AnyCodable(v.rawValue) }
        if let v = order { dict["order"] = AnyCodable(v.rawValue) }
        if let v = hidpi { dict["hidpi"] = AnyCodable(v) }
        if let v = blacklist { dict["blacklist"] = AnyCodable(v.map { AnyCodable($0) }) }
        if let v = whitelist { dict["whitelist"] = AnyCodable(v.map { AnyCodable($0) }) }
        if let v = axFocus { dict["axFocus"] = AnyCodable(v) }
        if let v = applyTo { dict["applyTo"] = AnyCodable(v) }
        return dict
    }

    private static func encodeColor(_ c: ColorSpec) -> [String: AnyCodable] {
        switch c {
        case .solid(let rgba):
            return ["kind": AnyCodable("solid"), "rgba": AnyCodable(rgbaDict(rgba))]
        case .glow(let rgba):
            return ["kind": AnyCodable("glow"), "rgba": AnyCodable(rgbaDict(rgba))]
        case .gradient(let axis, let start, let end):
            return [
                "kind": AnyCodable("gradient"),
                "axis": AnyCodable(axis.rawValue),
                "start": AnyCodable(rgbaDict(start)),
                "end": AnyCodable(rgbaDict(end)),
            ]
        }
    }

    private static func rgbaDict(_ rgba: ColorSpec.RGBA) -> [String: AnyCodable] {
        ["r": AnyCodable(rgba.r), "g": AnyCodable(rgba.g),
         "b": AnyCodable(rgba.b), "a": AnyCodable(rgba.a)]
    }
}
