import Foundation

/// Strips `// line` and `/* block */` comments and trailing commas from a
/// JSONC byte stream so the result can be fed to `JSONSerialization`.
/// Implemented as a small state machine rather than regex so URLs and
/// other comment-like substrings inside JSON strings are left intact.
public enum JSONCSanitizer {
    public enum SanitizeError: Error, Equatable {
        case unterminatedString(byteOffset: Int)
        case unterminatedBlockComment(byteOffset: Int)
    }

    public static func sanitize(_ source: String) throws -> String {
        let bytes = Array(source.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)

        enum State { case normal, inString, inLineComment, inBlockComment }
        var state: State = .normal
        var stringStart = 0
        var blockStart = 0
        var escapeNext = false
        var i = 0

        while i < bytes.count {
            let b = bytes[i]
            switch state {
            case .normal:
                // Comment starts.
                if b == UInt8(ascii: "/"), i + 1 < bytes.count {
                    let next = bytes[i + 1]
                    if next == UInt8(ascii: "/") { state = .inLineComment; i += 2; continue }
                    if next == UInt8(ascii: "*") { state = .inBlockComment; blockStart = i; i += 2; continue }
                }
                // Trailing comma: a `,` followed (after whitespace/comments) by `]` or `}`.
                if b == UInt8(ascii: ",") {
                    if isFollowedByCloser(bytes: bytes, after: i) {
                        i += 1
                        continue // drop comma
                    }
                }
                if b == UInt8(ascii: "\"") { state = .inString; stringStart = i }
                out.append(b)
                i += 1

            case .inString:
                out.append(b)
                if escapeNext {
                    escapeNext = false
                } else if b == UInt8(ascii: "\\") {
                    escapeNext = true
                } else if b == UInt8(ascii: "\"") {
                    state = .normal
                }
                i += 1

            case .inLineComment:
                if b == 0x0A || b == 0x0D {
                    state = .normal
                    out.append(b) // preserve line breaks so error offsets stay sensible
                }
                i += 1

            case .inBlockComment:
                if b == UInt8(ascii: "*"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "/") {
                    state = .normal
                    i += 2
                    continue
                }
                // Preserve newlines inside block comments so line numbers don't shift.
                if b == 0x0A { out.append(b) }
                i += 1
            }
        }

        switch state {
        case .normal: break
        case .inString: throw SanitizeError.unterminatedString(byteOffset: stringStart)
        case .inLineComment: break // EOF terminates a line comment cleanly
        case .inBlockComment: throw SanitizeError.unterminatedBlockComment(byteOffset: blockStart)
        }

        return String(decoding: out, as: UTF8.self)
    }

    /// Looks past whitespace and comments after position `i` (which points at `,`)
    /// to see whether the next non-trivia byte is `]` or `}`.
    private static func isFollowedByCloser(bytes: [UInt8], after i: Int) -> Bool {
        var j = i + 1
        while j < bytes.count {
            let c = bytes[j]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { j += 1; continue }
            if c == UInt8(ascii: "/"), j + 1 < bytes.count {
                let n = bytes[j + 1]
                if n == UInt8(ascii: "/") {
                    j += 2
                    while j < bytes.count, bytes[j] != 0x0A, bytes[j] != 0x0D { j += 1 }
                    continue
                }
                if n == UInt8(ascii: "*") {
                    j += 2
                    while j + 1 < bytes.count, !(bytes[j] == UInt8(ascii: "*") && bytes[j + 1] == UInt8(ascii: "/")) {
                        j += 1
                    }
                    j += 2
                    continue
                }
            }
            return c == UInt8(ascii: "]") || c == UInt8(ascii: "}")
        }
        return false
    }
}
