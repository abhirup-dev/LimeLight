import XCTest
@testable import LimeCore

final class PopupEngineTests: XCTestCase {
    func testTearDownIsIdempotent() async {
        await MainActor.run {
            let engine = PopupEngine()
            engine.tearDown()
            engine.tearDown()
            XCTAssertEqual(engine.activeCount, 0)
        }
    }
}
