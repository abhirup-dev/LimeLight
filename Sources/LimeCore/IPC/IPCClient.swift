import Darwin
import Foundation

/// One-shot Unix-socket client. Connects, writes a single NDJSON request,
/// reads a single NDJSON response, closes. Honors a per-call timeout.
public final class IPCClient {
    public enum CallError: Error, CustomStringConvertible {
        case socketCreateFailed(errno: Int32)
        case pathTooLong(path: String)
        case connectFailed(path: String, errno: Int32)
        case timeout(seconds: Double)
        case readFailed(errno: Int32)
        case writeFailed(errno: Int32)
        case peerClosed
        case decodeFailed(Error)
        case server(IPCError)

        public var description: String {
            switch self {
            case .socketCreateFailed(let e): return "socket(): \(String(cString: strerror(e)))"
            case .pathTooLong(let p): return "path too long: \(p)"
            case .connectFailed(let p, let e): return "connect(\(p)): \(String(cString: strerror(e)))"
            case .timeout(let s): return "timed out after \(s)s"
            case .readFailed(let e): return "read: \(String(cString: strerror(e)))"
            case .writeFailed(let e): return "write: \(String(cString: strerror(e)))"
            case .peerClosed: return "daemon closed connection before sending a response"
            case .decodeFailed(let err): return "decode failed: \(err)"
            case .server(let err): return "\(err.code): \(err.message)"
            }
        }
    }

    public let socketPath: String
    public let defaultTimeout: TimeInterval

    public init(socketPath: String, defaultTimeout: TimeInterval = 1.5) {
        self.socketPath = socketPath
        self.defaultTimeout = defaultTimeout
    }

    /// Sends `request` and returns the decoded response. Throws `CallError.server`
    /// when the daemon returns an error envelope.
    public func call(_ request: IPCRequest, timeout: TimeInterval? = nil) throws -> IPCResponse {
        let to = timeout ?? defaultTimeout
        let fd = try connect(timeout: to)
        defer { close(fd) }

        try setRecvSendTimeout(fd: fd, seconds: to)

        var data = try IPCCoding.makeEncoder().encode(request)
        data.append(0x0A)
        try writeAll(fd: fd, data: data, timeout: to)

        let line = try readUntilNewline(fd: fd, timeout: to)
        do {
            return try IPCCoding.makeDecoder().decode(IPCResponse.self, from: line)
        } catch {
            throw CallError.decodeFailed(error)
        }
    }

    // MARK: - low level

    private func connect(timeout: TimeInterval) throws -> Int32 {
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < IPCServer.sunPathLimit else {
            throw CallError.pathTooLong(path: socketPath)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw CallError.socketCreateFailed(errno: errno) }

        // Don't kill the process with SIGPIPE if the peer closes mid-write.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            let p = dst.baseAddress!.assumingMemoryBound(to: CChar.self)
            for (i, b) in pathBytes.enumerated() { p[i] = CChar(bitPattern: b) }
            p[pathBytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if rc != 0 {
            let e = errno
            close(fd)
            throw CallError.connectFailed(path: socketPath, errno: e)
        }
        _ = timeout // SO_RCVTIMEO/SO_SNDTIMEO are set by the caller
        return fd
    }

    private func setRecvSendTimeout(fd: Int32, seconds: TimeInterval) throws {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        let len = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, len)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, len)
    }

    private func writeAll(fd: Int32, data: Data, timeout: TimeInterval) throws {
        var remaining = data
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { buf -> Int in
                Darwin.write(fd, buf.baseAddress, buf.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw CallError.timeout(seconds: timeout) }
                throw CallError.writeFailed(errno: errno)
            }
            if n == 0 { throw CallError.peerClosed }
            remaining.removeFirst(n)
        }
    }

    private func readUntilNewline(fd: Int32, timeout: TimeInterval) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { buf -> Int in
                Darwin.read(fd, buf.baseAddress, buf.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw CallError.timeout(seconds: timeout) }
                throw CallError.readFailed(errno: errno)
            }
            if n == 0 {
                if buffer.isEmpty { throw CallError.peerClosed }
                return buffer
            }
            buffer.append(Data(bytes: chunk, count: n))
            if let nl = buffer.firstIndex(of: 0x0A) {
                return buffer.subdata(in: buffer.startIndex..<nl)
            }
            if buffer.count > IPCFramer.defaultMaxFrameBytes { throw CallError.peerClosed }
        }
    }
}
