import XCTest
@testable import LimeCore

final class LimeCoreTests: XCTestCase {
    func testVersionPresent() {
        XCTAssertFalse(Lime.version.isEmpty)
    }

    func testIPCRequestRoundTrip() throws {
        let req = IPCRequest(id: "abc", command: "status", args: nil)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        XCTAssertEqual(decoded.id, "abc")
        XCTAssertEqual(decoded.command, "status")
    }

    func testIPCResponseSuccessRoundTrip() throws {
        let resp = IPCResponse.success(id: "abc")
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
        XCTAssertTrue(decoded.ok)
        XCTAssertNil(decoded.error)
    }

    func testIPCResponseFailureRoundTrip() throws {
        let resp = IPCResponse.failure(id: "abc", code: "not_authorized", message: "nope")
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error?.code, "not_authorized")
    }

    func testVersionInfoRoundTrip() throws {
        let info = VersionInfo(version: "1.2.3", buildConfig: "release")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(VersionInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    func testDaemonInfoRoundTrip() throws {
        let info = DaemonInfo(
            version: "1.0",
            pid: 4242,
            bundleIdentifier: "dev.abhirup.lime",
            socketPath: "/tmp/x.sock",
            configPath: "/tmp/x.jsonc",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let data = try enc.encode(info)
        let decoded = try dec.decode(DaemonInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    func testResolvedPathsExpandHome() {
        XCTAssertTrue(Lime.resolvedSocketPath.hasSuffix("limelight.sock"))
        XCTAssertTrue(Lime.resolvedConfigPath.hasSuffix("config.jsonc"))
        XCTAssertFalse(Lime.resolvedConfigPath.contains("~"))
    }

    func testMainThreadBudgetPassesThrough() {
        let v = mainThreadBudget("test", thresholdMs: 1_000) { 7 + 35 }
        XCTAssertEqual(v, 42)
    }
}
