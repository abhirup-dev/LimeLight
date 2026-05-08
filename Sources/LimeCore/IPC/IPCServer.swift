import Darwin
import Dispatch
import Foundation

/// Off-main Unix-socket server speaking newline-delimited JSON.
/// Connection lifecycle is short-lived: a client connects, writes one request
/// terminated by `\n`, reads one response terminated by `\n`, and disconnects.
public final class IPCServer {
    public enum StartError: Error, CustomStringConvertible {
        case socketCreateFailed(errno: Int32)
        case pathTooLong(path: String, limit: Int)
        case bindFailed(path: String, errno: Int32)
        case listenFailed(errno: Int32)
        case alreadyRunning(path: String)

        public var description: String {
            switch self {
            case .socketCreateFailed(let e): return "socket() failed: \(String(cString: strerror(e)))"
            case .pathTooLong(let p, let n): return "Socket path too long for sun_path (\(p.utf8.count) > \(n)): \(p)"
            case .bindFailed(let p, let e): return "bind(\(p)) failed: \(String(cString: strerror(e)))"
            case .listenFailed(let e): return "listen() failed: \(String(cString: strerror(e)))"
            case .alreadyRunning(let p): return "Another LimeLight daemon is already bound to \(p)"
            }
        }
    }

    /// Maximum characters in a Unix domain socket path on macOS (sun_path is 104 bytes).
    public static let sunPathLimit = 104

    /// Per-connection deadlines. Tunable so tests can shorten them.
    public struct Timeouts: Sendable {
        /// Max wait between fd accept and the first readable byte. Protects
        /// against silent clients holding a worker.
        public var firstByteSeconds: Double
        /// Max wall-clock for receiving a full request frame. Protects
        /// against slow-loris drips that never finish.
        public var fullFrameSeconds: Double
        /// Max wait for socket writability when sending the response.
        public var writeSeconds: Double

        public static let `default` = Timeouts(
            firstByteSeconds: 2.0,
            fullFrameSeconds: 5.0,
            writeSeconds: 2.0
        )
    }

    public let socketPath: String
    public let timeouts: Timeouts
    private let router: IPCRouter
    private let acceptQueue = DispatchQueue(label: "dev.abhirup.lime.ipc.accept", qos: .userInitiated)
    private let workQueue = DispatchQueue(label: "dev.abhirup.lime.ipc.work", qos: .userInitiated, attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let started = DispatchSemaphore(value: 0)
    private var isStarted = false

    public init(socketPath: String, router: IPCRouter, timeouts: Timeouts = .default) {
        self.socketPath = socketPath
        self.router = router
        self.timeouts = timeouts
    }

    /// Binds, listens, and starts accepting on a background queue. Returns once
    /// the socket is bound and ready (so callers can advertise the path immediately).
    public func start() throws {
        try ensureParentDirectory()
        try bindAndListen()
        installAcceptSource()
        isStarted = true
        Log.ipc.notice("IPC server listening on \(self.socketPath, privacy: .public)")
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
        Log.ipc.notice("IPC server stopped")
    }

    deinit { stop() }

    // MARK: - bring-up

    private func ensureParentDirectory() throws {
        let parent = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func bindAndListen() throws {
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < IPCServer.sunPathLimit else {
            throw StartError.pathTooLong(path: socketPath, limit: IPCServer.sunPathLimit)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw StartError.socketCreateFailed(errno: errno) }

        // Non-blocking listening socket so accept never stalls a worker.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // Detect "another daemon already running" before unlinking — try connect first.
        if probeExistingDaemon() {
            close(fd)
            throw StartError.alreadyRunning(path: socketPath)
        }
        // Stale socket from a previous crash: remove before bind.
        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            let p = dst.baseAddress!.assumingMemoryBound(to: CChar.self)
            for (i, b) in pathBytes.enumerated() { p[i] = CChar(bitPattern: b) }
            p[pathBytes.count] = 0
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, addrLen) }
        }
        if bindRC != 0 {
            let e = errno
            close(fd)
            throw StartError.bindFailed(path: socketPath, errno: e)
        }

        // Restrict to current user.
        chmod(socketPath, 0o600)

        if Darwin.listen(fd, 16) != 0 {
            let e = errno
            close(fd)
            unlink(socketPath)
            throw StartError.listenFailed(errno: e)
        }

        self.listenFD = fd
    }

    /// Returns true if something is currently accepting on the path.
    private func probeExistingDaemon() -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { if probe >= 0 { close(probe) } }
        guard probe >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < IPCServer.sunPathLimit else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            let p = dst.baseAddress!.assumingMemoryBound(to: CChar.self)
            for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) }
            p[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, len) }
        }
        return rc == 0
    }

    private func installAcceptSource() {
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptOnce() }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.listenFD >= 0 { close(self.listenFD); self.listenFD = -1 }
        }
        src.resume()
        self.acceptSource = src
    }

    private func acceptOnce() {
        while true {
            var remoteAddr = sockaddr()
            var remoteLen = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = Darwin.accept(listenFD, &remoteAddr, &remoteLen)
            if cfd < 0 {
                let e = errno
                if e == EINTR { continue }
                if e == EAGAIN || e == EWOULDBLOCK { return }
                Log.ipc.error("accept failed: \(String(cString: strerror(e)), privacy: .public)")
                return
            }
            // Don't get killed by SIGPIPE if the client closes mid-response.
            var on: Int32 = 1
            _ = setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Keep accepted fd non-blocking. serveConnection drives reads/writes
            // through poll() with deadlines so a silent or slow-loris client
            // can't pin a worker thread (focusfx-lol).
            let cflags = fcntl(cfd, F_GETFL, 0)
            _ = fcntl(cfd, F_SETFL, cflags | O_NONBLOCK)
            workQueue.async { [router, timeouts, weak self] in
                self?.serveConnection(fd: cfd, router: router, timeouts: timeouts)
            }
        }
    }

    // MARK: - per-connection IO

    private func serveConnection(fd: Int32, router: IPCRouter, timeouts: Timeouts) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        defer { close(fd) }

        var framer = IPCFramer()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var frame: Data?
        var hasReceivedAnyByte = false
        let frameDeadline = Date().addingTimeInterval(timeouts.fullFrameSeconds)

        readLoop: while frame == nil {
            // Per-iteration poll deadline: tighter window before we've seen any
            // bytes (silent-client protection); fall back to whatever's left of
            // the full-frame budget after the first byte arrives.
            let now = Date()
            if now >= frameDeadline {
                Log.ipc.notice("ipc connection timed out before full frame received")
                return
            }
            let firstByteRemaining = timeouts.firstByteSeconds // measured per-poll, intentional
            let frameRemaining = frameDeadline.timeIntervalSince(now)
            let pollTimeoutSec = hasReceivedAnyByte
                ? frameRemaining
                : min(firstByteRemaining, frameRemaining)
            switch Self.pollFor(fd: fd, events: Int16(POLLIN), seconds: pollTimeoutSec) {
            case .ready: break
            case .timeout:
                Log.ipc.notice("ipc connection timed out waiting for \(hasReceivedAnyByte ? "frame completion" : "first byte", privacy: .public)")
                return
            case .closed:
                return
            case .error:
                Log.ipc.error("ipc poll(read) failed: \(String(cString: strerror(errno)), privacy: .public)")
                return
            }

            let n = chunk.withUnsafeMutableBufferPointer { buf -> Int in
                Darwin.read(fd, buf.baseAddress, buf.count)
            }
            if n < 0 {
                let e = errno
                if e == EINTR || e == EAGAIN || e == EWOULDBLOCK { continue }
                Log.ipc.error("read failed: \(String(cString: strerror(e)), privacy: .public)")
                return
            }
            if n == 0 { return } // peer closed before sending a full frame
            hasReceivedAnyByte = true
            do {
                try framer.append(Data(bytes: chunk, count: n))
            } catch {
                writeFailure(fd: fd, id: "", code: "frame_too_large", message: "request exceeded 1 MiB", timeouts: timeouts)
                return
            }
            frame = framer.nextFrame()
            if frame != nil { break readLoop }
        }

        guard let frame else { return }

        let response: IPCResponse
        do {
            let req = try IPCCoding.makeDecoder().decode(IPCRequest.self, from: frame)
            response = router.dispatch(req)
        } catch {
            response = IPCResponse.failure(id: "", code: "bad_request", message: "malformed JSON: \(error)")
        }

        writeResponse(fd: fd, response: response, timeouts: timeouts)
    }

    private enum PollOutcome { case ready, timeout, closed, error }

    /// poll(2) wrapper. Returns once `fd` is readable/writable, the timeout
    /// expires, the peer has closed (POLLHUP), or poll() itself errors.
    private static func pollFor(fd: Int32, events: Int16, seconds: Double) -> PollOutcome {
        if seconds <= 0 { return .timeout }
        var pfd = pollfd(fd: fd, events: events, revents: 0)
        let ms = Int32(min(Double(Int32.max), seconds * 1000.0))
        let rc = withUnsafeMutablePointer(to: &pfd) { ptr in
            Darwin.poll(ptr, 1, ms)
        }
        if rc < 0 { return errno == EINTR ? .ready : .error }
        if rc == 0 { return .timeout }
        let r = pfd.revents
        if r & Int16(POLLNVAL | POLLERR) != 0 { return .error }
        if r & Int16(POLLHUP) != 0 && r & events == 0 { return .closed }
        return .ready
    }

    private func writeResponse(fd: Int32, response: IPCResponse, timeouts: Timeouts) {
        do {
            var data = try IPCCoding.makeEncoder().encode(response)
            data.append(0x0A)
            writeAll(fd: fd, data: data, timeouts: timeouts)
        } catch {
            writeFailure(fd: fd, id: response.id, code: "encode_failed", message: "\(error)", timeouts: timeouts)
        }
    }

    private func writeFailure(fd: Int32, id: String, code: String, message: String, timeouts: Timeouts) {
        let resp = IPCResponse.failure(id: id, code: code, message: message)
        if let raw = try? IPCCoding.makeEncoder().encode(resp) {
            var data = raw
            data.append(0x0A)
            writeAll(fd: fd, data: data, timeouts: timeouts)
        }
    }

    private func writeAll(fd: Int32, data: Data, timeouts: Timeouts) {
        var remaining = data
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { buf -> Int in
                Darwin.write(fd, buf.baseAddress, buf.count)
            }
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                if e == EAGAIN || e == EWOULDBLOCK {
                    switch Self.pollFor(fd: fd, events: Int16(POLLOUT), seconds: timeouts.writeSeconds) {
                    case .ready: continue
                    case .timeout:
                        Log.ipc.notice("ipc write timed out — closing slow-reading client")
                        return
                    case .closed, .error:
                        return
                    }
                }
                Log.ipc.error("write failed: \(String(cString: strerror(e)), privacy: .public)")
                return
            }
            if n == 0 { return }
            remaining.removeFirst(n)
        }
    }
}

