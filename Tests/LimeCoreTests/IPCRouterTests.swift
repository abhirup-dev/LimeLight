import XCTest
@testable import LimeCore

final class IPCRouterTests: XCTestCase {
    func testDispatchesRegisteredCommand() {
        let r = IPCRouter()
        r.register("ping") { req in IPCResponse.success(id: req.id, result: AnyCodable("pong")) }
        let resp = r.dispatch(IPCRequest(id: "1", command: "ping"))
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.result?.value as? String, "pong")
    }

    func testUnknownCommandReturnsStableError() {
        let r = IPCRouter()
        let resp = r.dispatch(IPCRequest(id: "x", command: "nope"))
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, "unknown_command")
        XCTAssertEqual(resp.id, "x")
    }
}
