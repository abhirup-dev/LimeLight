import XCTest
@testable import FocusFXCore

/// Verifies the CLI's "daemon never hangs" guarantee at the IPC layer:
/// connecting to a missing socket returns `connectFailed` quickly, not a hang.
final class IPCClientUnreachableTests: XCTestCase {
    func testConnectFailsImmediatelyWhenNoDaemon() {
        let path = "/tmp/ffx-missing-\(UUID().uuidString.prefix(6)).sock"
        let client = IPCClient(socketPath: path, defaultTimeout: 0.5)
        let started = Date()
        XCTAssertThrowsError(try client.call(IPCRequest(command: "status"))) { err in
            guard case IPCClient.CallError.connectFailed = err else {
                return XCTFail("expected connectFailed, got \(err)")
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.2, "missing-socket connect took \(elapsed)s — should fail immediately")
    }
}
