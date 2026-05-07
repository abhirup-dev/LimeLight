import XCTest
@testable import FocusFXCore

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
