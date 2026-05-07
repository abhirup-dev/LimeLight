import XCTest
@testable import LimeCore

final class ColorSpecTests: XCTestCase {
    func testSolidWith0xAARRGGBB() throws {
        let c = try ColorSpec.parse("0xffe1e3e4")
        guard case let .solid(rgba) = c else { return XCTFail("expected solid") }
        XCTAssertEqual(rgba.a, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgba.r, 225/255.0, accuracy: 0.001)
    }

    func testSolidWithHash6() throws {
        let c = try ColorSpec.parse("#00D1FF")
        guard case let .solid(rgba) = c else { return XCTFail("expected solid") }
        XCTAssertEqual(rgba.a, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgba.b, 1.0, accuracy: 0.001)
    }

    func testGlow() throws {
        let c = try ColorSpec.parse("glow(0xffff0000)")
        guard case let .glow(rgba) = c else { return XCTFail("expected glow") }
        XCTAssertEqual(rgba.r, 1.0, accuracy: 0.001)
    }

    func testGradientTopLeftBottomRight() throws {
        let c = try ColorSpec.parse("gradient(top_left=0xffff0000, bottom_right=0xff0000ff)")
        guard case let .gradient(axis, _, _) = c else { return XCTFail("expected gradient") }
        XCTAssertEqual(axis, .topLeftToBottomRight)
    }

    func testGradientTopRightBottomLeft() throws {
        let c = try ColorSpec.parse("gradient(top_right=0xff00ff00, bottom_left=0xff0000ff)")
        guard case let .gradient(axis, _, _) = c else { return XCTFail("expected gradient") }
        XCTAssertEqual(axis, .topRightToBottomLeft)
    }

    func testRejectsMalformedHex() {
        XCTAssertThrowsError(try ColorSpec.parse("0xZZZ"))
        XCTAssertThrowsError(try ColorSpec.parse("not-a-color"))
    }

    func testRejectsUnknownFunction() {
        XCTAssertThrowsError(try ColorSpec.parse("rainbow(0xff0000ff)"))
    }
}
