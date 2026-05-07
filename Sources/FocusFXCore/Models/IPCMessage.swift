import Foundation

public struct IPCRequest: Codable, Sendable {
    public let id: String
    public let command: String
    public let args: [String: AnyCodable]?

    public init(id: String = UUID().uuidString, command: String, args: [String: AnyCodable]? = nil) {
        self.id = id
        self.command = command
        self.args = args
    }
}

public struct IPCResponse: Codable, Sendable {
    public let id: String
    public let ok: Bool
    public let result: AnyCodable?
    public let error: IPCError?

    public init(id: String, ok: Bool, result: AnyCodable? = nil, error: IPCError? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func success(id: String, result: AnyCodable? = nil) -> IPCResponse {
        IPCResponse(id: id, ok: true, result: result, error: nil)
    }

    public static func failure(id: String, code: String, message: String) -> IPCResponse {
        IPCResponse(id: id, ok: false, result: nil, error: IPCError(code: code, message: message))
    }
}

public struct IPCError: Codable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Type-erased Codable wrapper for heterogeneous JSON payloads.
public struct AnyCodable: Codable, Sendable {
    public let value: Sendable

    public init(_ value: Sendable) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.value = NSNull()
        } else if let b = try? c.decode(Bool.self) {
            self.value = b
        } else if let i = try? c.decode(Int64.self) {
            self.value = i
        } else if let d = try? c.decode(Double.self) {
            self.value = d
        } else if let s = try? c.decode(String.self) {
            self.value = s
        } else if let arr = try? c.decode([AnyCodable].self) {
            self.value = arr
        } else if let dict = try? c.decode([String: AnyCodable].self) {
            self.value = dict
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let i as Int64: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let arr as [AnyCodable]: try c.encode(arr)
        case let dict as [String: AnyCodable]: try c.encode(dict)
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported value")
            )
        }
    }
}
