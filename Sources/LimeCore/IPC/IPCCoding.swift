import Foundation

/// Shared JSON encoder/decoder configuration for the IPC wire format.
/// Dates are encoded as ISO8601 so the wire stays inspectable with `jq`.
public enum IPCCoding {
    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = []
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
