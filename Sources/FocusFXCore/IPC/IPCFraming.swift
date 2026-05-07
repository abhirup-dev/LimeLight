import Foundation

/// Newline-delimited framing buffer. Append bytes as they arrive on the socket;
/// drain whole `\n`-terminated frames out the other end. Bounded so a malformed
/// peer cannot grow the buffer without limit.
public struct IPCFramer {
    public enum Error: Swift.Error, Equatable {
        case frameTooLarge(limit: Int)
    }

    public static let defaultMaxFrameBytes = 1 << 20 // 1 MiB

    public let maxFrameBytes: Int
    private var buffer = Data()

    public init(maxFrameBytes: Int = IPCFramer.defaultMaxFrameBytes) {
        self.maxFrameBytes = maxFrameBytes
    }

    public mutating func append(_ bytes: Data) throws {
        buffer.append(bytes)
        if buffer.count > maxFrameBytes,
           // Fail only if there isn't already a complete frame inside the
           // oversized buffer — caller still wants to drain valid frames first.
           buffer.firstIndex(of: 0x0A) == nil {
            buffer.removeAll(keepingCapacity: false)
            throw Error.frameTooLarge(limit: maxFrameBytes)
        }
    }

    /// Pulls one full line (without the trailing `\n`) if available.
    public mutating func nextFrame() -> Data? {
        guard let nl = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = buffer.subdata(in: buffer.startIndex..<nl)
        buffer.removeSubrange(buffer.startIndex...nl)
        return line
    }

    public var pendingByteCount: Int { buffer.count }
}
