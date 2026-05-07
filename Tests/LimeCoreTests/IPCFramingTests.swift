import XCTest
@testable import LimeCore

final class IPCFramingTests: XCTestCase {
    func testSplitsOnNewline() throws {
        var f = IPCFramer()
        try f.append(Data("hello\nworld\n".utf8))
        XCTAssertEqual(f.nextFrame(), Data("hello".utf8))
        XCTAssertEqual(f.nextFrame(), Data("world".utf8))
        XCTAssertNil(f.nextFrame())
    }

    func testWaitsForNewline() throws {
        var f = IPCFramer()
        try f.append(Data("partial".utf8))
        XCTAssertNil(f.nextFrame())
        try f.append(Data(" message\n".utf8))
        XCTAssertEqual(f.nextFrame(), Data("partial message".utf8))
    }

    func testRejectsOversizedFrameWithoutNewline() {
        var f = IPCFramer(maxFrameBytes: 16)
        XCTAssertThrowsError(try f.append(Data(repeating: 0x41, count: 32))) { err in
            XCTAssertEqual(err as? IPCFramer.Error, .frameTooLarge(limit: 16))
        }
    }

    func testEmptyLineIsAValidFrame() throws {
        var f = IPCFramer()
        try f.append(Data("\n".utf8))
        XCTAssertEqual(f.nextFrame(), Data())
    }
}
