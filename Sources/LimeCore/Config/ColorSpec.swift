import Foundation

/// Parsed border color spec, JankyBorders-compatible:
///   solid:    "0xffe1e3e4"   or "#e1e3e4"
///   glow:     "glow(0xffff0000)"
///   gradient: "gradient(top_left=0xff..., bottom_right=0xff...)"
///             "gradient(top_right=0xff..., bottom_left=0xff...)"
public enum ColorSpec: Sendable, Equatable {
    public struct RGBA: Sendable, Equatable, Hashable {
        public let r: Double
        public let g: Double
        public let b: Double
        public let a: Double
        public init(r: Double, g: Double, b: Double, a: Double) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
    }

    public enum GradientAxis: String, Sendable, Equatable {
        case topLeftToBottomRight
        case topRightToBottomLeft
    }

    case solid(RGBA)
    case glow(RGBA)
    case gradient(axis: GradientAxis, start: RGBA, end: RGBA)

    public enum ParseError: Error, Equatable {
        case empty
        case malformedHex(String)
        case unknownFunction(String)
        case missingComponent(String)
    }

    public static func parse(_ raw: String) throws -> ColorSpec {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { throw ParseError.empty }

        // Function form: glow(...) or gradient(...)
        if let openIdx = s.firstIndex(of: "("), s.last == ")" {
            let head = String(s[s.startIndex..<openIdx]).lowercased()
            let body = String(s[s.index(after: openIdx)..<s.index(before: s.endIndex)])
            switch head {
            case "glow":
                return .glow(try parseHex(body.trimmingCharacters(in: .whitespaces)))
            case "gradient":
                return try parseGradient(body)
            default:
                throw ParseError.unknownFunction(head)
            }
        }

        return .solid(try parseHex(s))
    }

    private static func parseGradient(_ body: String) throws -> ColorSpec {
        var entries: [String: RGBA] = [:]
        for part in body.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { throw ParseError.missingComponent(String(part)) }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let val = kv[1].trimmingCharacters(in: .whitespaces)
            entries[key] = try parseHex(val)
        }
        if let tl = entries["top_left"], let br = entries["bottom_right"] {
            return .gradient(axis: .topLeftToBottomRight, start: tl, end: br)
        }
        if let tr = entries["top_right"], let bl = entries["bottom_left"] {
            return .gradient(axis: .topRightToBottomLeft, start: tr, end: bl)
        }
        throw ParseError.missingComponent("gradient requires top_left+bottom_right or top_right+bottom_left")
    }

    /// Accepts `0xRRGGBB`, `0xAARRGGBB`, `#RRGGBB`, `#AARRGGBB`.
    /// Hex without alpha defaults to fully opaque.
    public static func parseHex(_ raw: String) throws -> RGBA {
        var s = raw.lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ParseError.malformedHex(raw)
        }
        let value: UInt32
        switch s.count {
        case 6:
            guard let v = UInt32(s, radix: 16) else { throw ParseError.malformedHex(raw) }
            value = 0xff00_0000 | v
        case 8:
            guard let v = UInt32(s, radix: 16) else { throw ParseError.malformedHex(raw) }
            value = v
        default:
            throw ParseError.malformedHex(raw)
        }
        let a = Double((value >> 24) & 0xff) / 255.0
        let r = Double((value >> 16) & 0xff) / 255.0
        let g = Double((value >> 8) & 0xff) / 255.0
        let b = Double(value & 0xff) / 255.0
        return RGBA(r: r, g: g, b: b, a: a)
    }
}
