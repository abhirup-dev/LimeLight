import XCTest
@testable import FocusFXCore

final class JSONCSanitizerTests: XCTestCase {
    func testStripsLineComments() throws {
        let s = try JSONCSanitizer.sanitize("""
        {
          "a": 1, // trailing line comment
          "b": 2
        }
        """)
        XCTAssertFalse(s.contains("//"))
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Int]
        XCTAssertEqual(obj?["a"], 1)
        XCTAssertEqual(obj?["b"], 2)
    }

    func testStripsBlockComments() throws {
        let s = try JSONCSanitizer.sanitize("""
        {
          /* hello
             world */
          "a": 1
        }
        """)
        XCTAssertFalse(s.contains("/*"))
        XCTAssertFalse(s.contains("*/"))
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Int]
        XCTAssertEqual(obj?["a"], 1)
    }

    func testPreservesCommentLikeSubstringsInsideStrings() throws {
        let s = try JSONCSanitizer.sanitize("""
        {
          "url": "https://example.com/path",
          "fake": "// not a comment",
          "block": "/* still not */"
        }
        """)
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: String]
        XCTAssertEqual(obj?["url"], "https://example.com/path")
        XCTAssertEqual(obj?["fake"], "// not a comment")
        XCTAssertEqual(obj?["block"], "/* still not */")
    }

    func testStripsTrailingCommas() throws {
        let s = try JSONCSanitizer.sanitize("""
        {
          "a": [1, 2, 3,],
          "b": {"x": 1, "y": 2,},
        }
        """)
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
        XCTAssertEqual((obj?["a"] as? [Int])?.count, 3)
        XCTAssertEqual((obj?["b"] as? [String: Int])?["y"], 2)
    }

    func testTrailingCommaWithCommentBetweenCommaAndCloser() throws {
        let s = try JSONCSanitizer.sanitize("""
        {
          "a": [
            1,
            2, // trailing element
          ]
        }
        """)
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: [Int]]
        XCTAssertEqual(obj?["a"], [1, 2])
    }

    func testRejectsUnterminatedString() {
        XCTAssertThrowsError(try JSONCSanitizer.sanitize("{ \"a\": \"oops "))
    }

    func testRejectsUnterminatedBlockComment() {
        XCTAssertThrowsError(try JSONCSanitizer.sanitize("{ /* never closes "))
    }
}
