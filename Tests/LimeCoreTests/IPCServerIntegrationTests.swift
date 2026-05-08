import XCTest
@testable import LimeCore

final class IPCServerIntegrationTests: XCTestCase {
    private func makeTempSocketPath() -> String {
        // Keep paths short — sun_path on macOS is 104 bytes.
        let name = "ffx-\(UUID().uuidString.prefix(8)).sock"
        return ("/tmp" as NSString).appendingPathComponent(name)
    }

    func testRoundTripStatus() throws {
        let path = makeTempSocketPath()
        defer { unlink(path) }

        let router = IPCRouter()
        router.register("status") { req in
            IPCResponse.success(id: req.id, result: AnyCodable(["alive": AnyCodable(true)]))
        }
        let server = IPCServer(socketPath: path, router: router)
        try server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: path)
        let resp = try client.call(IPCRequest(id: "1", command: "status"))
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.id, "1")
    }

    func testHundredSequentialStatusCalls() throws {
        let path = makeTempSocketPath()
        defer { unlink(path) }

        let router = IPCRouter()
        let counter = Counter()
        router.register("status") { req in
            counter.increment()
            return IPCResponse.success(id: req.id, result: AnyCodable("ok"))
        }
        let server = IPCServer(socketPath: path, router: router)
        try server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: path)
        let started = Date()
        for i in 0..<100 {
            let resp = try client.call(IPCRequest(id: "\(i)", command: "status"))
            XCTAssertTrue(resp.ok, "call #\(i) failed: \(String(describing: resp.error))")
            XCTAssertEqual(resp.id, "\(i)")
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(counter.value, 100)
        // Synchronous main-thread blocking would push this far past 2s.
        // Generous bound; tighten if it ever flakes.
        XCTAssertLessThan(elapsed, 2.0, "100 sequential calls took \(elapsed)s — main thread may be blocked")
    }

    func testUnknownCommandYieldsErrorEnvelope() throws {
        let path = makeTempSocketPath()
        defer { unlink(path) }

        let server = IPCServer(socketPath: path, router: IPCRouter())
        try server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: path)
        let resp = try client.call(IPCRequest(id: "z", command: "doesnotexist"))
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, "unknown_command")
    }

    func testSecondStartFailsIfAlreadyBound() throws {
        let path = makeTempSocketPath()
        defer { unlink(path) }

        let s1 = IPCServer(socketPath: path, router: IPCRouter())
        try s1.start()
        defer { s1.stop() }

        let s2 = IPCServer(socketPath: path, router: IPCRouter())
        XCTAssertThrowsError(try s2.start()) { err in
            guard let startErr = err as? IPCServer.StartError else {
                return XCTFail("unexpected error type: \(err)")
            }
            switch startErr {
            case .alreadyRunning: break
            default: XCTFail("expected .alreadyRunning, got \(startErr)")
            }
        }
    }

    // focusfx-lol: A client that connects and sends nothing must not pin a
    // worker thread forever. With short timeouts the server should hang up on
    // the silent client AND keep serving valid clients in the meantime.
    func testSilentClientIsClosedAndDoesNotBlockOthers() throws {
        let path = makeTempSocketPath()
        defer { unlink(path) }

        let router = IPCRouter()
        router.register("status") { req in
            IPCResponse.success(id: req.id, result: AnyCodable("ok"))
        }
        let timeouts = IPCServer.Timeouts(firstByteSeconds: 0.2, fullFrameSeconds: 0.5, writeSeconds: 0.2)
        let server = IPCServer(socketPath: path, router: router, timeouts: timeouts)
        try server.start()
        defer { server.stop() }

        // Open 8 silent connections — connect, never write.
        var idleFDs: [Int32] = []
        for _ in 0..<8 {
            let cfd = try connectSilently(to: path)
            idleFDs.append(cfd)
        }
        defer { for fd in idleFDs { close(fd) } }

        // While idle clients are still pinned (pre-fix would block here),
        // a real client must get a sub-100ms response.
        let client = IPCClient(socketPath: path)
        let started = Date()
        let resp = try client.call(IPCRequest(id: "live", command: "status"))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(resp.ok)
        XCTAssertLessThan(elapsed, 0.5, "valid client blocked behind silent ones (\(elapsed)s)")

        // After the firstByteSeconds budget, every silent fd must have been
        // closed by the server. Read returns 0 bytes on a closed peer.
        Thread.sleep(forTimeInterval: 0.4)
        for fd in idleFDs {
            var b: UInt8 = 0
            let n = Darwin.read(fd, &b, 1)
            XCTAssertEqual(n, 0, "server did not hang up on silent client (read returned \(n))")
        }
    }

    /// Open a Unix-domain client socket but write nothing.
    private func connectSilently(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            let p = dst.baseAddress!.assumingMemoryBound(to: CChar.self)
            for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) }
            p[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        XCTAssertEqual(rc, 0, "connect: \(String(cString: strerror(errno)))")
        return fd
    }

    func testServerHandlesStaleSocketFromPreviousCrash() throws {
        let path = makeTempSocketPath()
        defer { unlink(path) }

        // Drop a regular file at the socket path to simulate a stale leftover.
        try Data().write(to: URL(fileURLWithPath: path))

        let server = IPCServer(socketPath: path, router: IPCRouter())
        try server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: path)
        let resp = try client.call(IPCRequest(id: "ok", command: "anything"))
        // Unknown command, but we got a real response — proving bind succeeded.
        XCTAssertEqual(resp.id, "ok")
    }
}

/// Thread-safe counter for the 100-call test.
private final class Counter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "counter")
    private var n = 0
    func increment() { queue.sync { n += 1 } }
    var value: Int { queue.sync { n } }
}
