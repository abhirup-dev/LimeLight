import XCTest
@testable import LimeCore

final class BordersStyleArgsTests: XCTestCase {
    func testParsesPlanMdSampleEndToEnd() {
        let tokens = [
            "borders",                                   // tolerated subcommand
            "active_color=0xffe1e3e4",
            "inactive_color=0xff494d64",
            "background_color=0x00000000",
            "width=5.0",
            "style=round",
            "order=below",
            "hidpi=on",
            "blacklist=Finder,Calendar",
            "whitelist=Warp,Ghostty",
            "ax_focus=off",
            "apply-to=1",
        ]
        let out = BordersStyleArgs.parse(tokens)
        XCTAssertTrue(out.errors.isEmpty, "unexpected errors: \(out.errors)")
        XCTAssertTrue(out.warnings.isEmpty, "unexpected warnings: \(out.warnings)")

        XCTAssertEqual(out.request.width, 5.0)
        XCTAssertEqual(out.request.style, .round)
        XCTAssertEqual(out.request.order, .below)
        XCTAssertEqual(out.request.hidpi, true)
        XCTAssertEqual(out.request.axFocus, false)
        XCTAssertEqual(out.request.applyTo, 1)
        XCTAssertEqual(out.request.blacklist, ["Finder", "Calendar"])
        XCTAssertEqual(out.request.whitelist, ["Warp", "Ghostty"])

        guard case .solid(let active) = out.request.active else {
            return XCTFail("active should parse as solid")
        }
        XCTAssertEqual(active.a, 1.0, accuracy: 0.001)

        // background_color with alpha 0 disables the fill
        XCTAssertEqual(out.request.backgroundEnabled, false)
    }

    func testGlowAndGradientParse() {
        let out = BordersStyleArgs.parse([
            "active_color=glow(0xffff0000)",
            "inactive_color=gradient(top_left=0xffff0000, bottom_right=0xff0000ff)",
        ])
        XCTAssertTrue(out.errors.isEmpty)
        if case .glow = out.request.active {} else { XCTFail("expected glow") }
        if case .gradient(let axis, _, _) = out.request.inactive {
            XCTAssertEqual(axis, .topLeftToBottomRight)
        } else {
            XCTFail("expected gradient")
        }
    }

    func testGradientReverseAxis() {
        let out = BordersStyleArgs.parse([
            "active_color=gradient(top_right=0xffff0000, bottom_left=0xff0000ff)",
        ])
        XCTAssertTrue(out.errors.isEmpty)
        if case .gradient(let axis, _, _) = out.request.active {
            XCTAssertEqual(axis, .topRightToBottomLeft)
        } else {
            XCTFail("expected gradient")
        }
    }

    func testBackgroundWithAlphaEnablesFill() {
        let out = BordersStyleArgs.parse(["background_color=0x80112233"])
        XCTAssertTrue(out.errors.isEmpty)
        XCTAssertEqual(out.request.backgroundEnabled, true)
        XCTAssertNotNil(out.request.background)
    }

    func testUnknownOptionWarnsButDoesNotFail() {
        let out = BordersStyleArgs.parse(["chromatic_aberration=on", "width=3"])
        XCTAssertTrue(out.errors.isEmpty)
        XCTAssertEqual(out.warnings.count, 1)
        XCTAssertTrue(out.warnings[0].contains("chromatic_aberration"))
        XCTAssertEqual(out.request.width, 3)
    }

    func testInvalidStyleProducesStableError() {
        let out = BordersStyleArgs.parse(["style=neon"])
        XCTAssertEqual(out.errors.count, 1)
        XCTAssertTrue(out.errors[0].contains("style"))
        XCTAssertTrue(out.errors[0].contains("round|square|uniform"))
    }

    func testInvalidWidthProducesError() {
        let out = BordersStyleArgs.parse(["width=thick"])
        XCTAssertEqual(out.errors.count, 1)
        XCTAssertTrue(out.errors[0].contains("width"))
    }

    func testMalformedColorProducesError() {
        let out = BordersStyleArgs.parse(["active_color=not-a-color"])
        XCTAssertEqual(out.errors.count, 1)
        XCTAssertTrue(out.errors[0].contains("active_color"))
    }

    func testTokenWithoutEqualsErrors() {
        let out = BordersStyleArgs.parse(["width", "5"])
        XCTAssertEqual(out.errors.count, 2)
    }

    func testBoolAcceptsCommonForms() {
        for v in ["on", "true", "yes", "1"] {
            let out = BordersStyleArgs.parse(["hidpi=\(v)"])
            XCTAssertTrue(out.errors.isEmpty, "\(v) should parse")
            XCTAssertEqual(out.request.hidpi, true, "\(v) should be true")
        }
        for v in ["off", "false", "no", "0"] {
            let out = BordersStyleArgs.parse(["hidpi=\(v)"])
            XCTAssertTrue(out.errors.isEmpty)
            XCTAssertEqual(out.request.hidpi, false, "\(v) should be false")
        }
    }

    func testIPCArgsRoundtrip() throws {
        let out = BordersStyleArgs.parse([
            "active_color=glow(0xffff0000)", "width=4", "style=square",
            "blacklist=A,B",
        ])
        XCTAssertTrue(out.errors.isEmpty)
        let args = out.request.ipcArgs

        let req = IPCRequest(command: "borders.style", args: args)
        let data = try IPCCoding.makeEncoder().encode(req)
        let decoded = try IPCCoding.makeDecoder().decode(IPCRequest.self, from: data)
        XCTAssertEqual(decoded.command, "borders.style")
        XCTAssertNotNil(decoded.args?["active"])
        XCTAssertNotNil(decoded.args?["width"])
        XCTAssertNotNil(decoded.args?["style"])
    }

    func testEmptyArgsYieldEmptyRequest() {
        let out = BordersStyleArgs.parse([])
        XCTAssertTrue(out.errors.isEmpty)
        XCTAssertEqual(out.request, BordersStyleRequest())
    }
}
