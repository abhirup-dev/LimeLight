import XCTest
import CoreGraphics
@testable import LimeCore

final class BorderRuntimeOverridesTests: XCTestCase {
    private func snap(rules: [Rule] = [], excludes: [WindowMatch] = []) -> ConfigSnapshot {
        ConfigSnapshot(
            performance: .default, borders: .default, defaultEffect: .default,
            popup: .default, idleReturn: .default,
            rules: rules, exclude: excludes, diagnostics: []
        )
    }

    private func win(_ id: WindowID, app: String = "Warp",
                     frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)) -> WindowState {
        WindowState(windowID: id, ownerPID: 100, appName: app, title: "t", frame: frame, isOnScreen: true)
    }

    // MARK: - apply / merge semantics

    func testApplyWithoutApplyToMergesIntoGlobal() {
        var ov = BorderRuntimeOverrides.empty
        var req = BordersStyleRequest()
        req.width = 7; req.style = .square
        ov.apply(req)
        XCTAssertEqual(ov.global.width, 7)
        XCTAssertEqual(ov.global.style, .square)
        XCTAssertTrue(ov.perWindow.isEmpty)
    }

    func testApplyWithApplyToLandsAsPerWindowAndStripsTarget() {
        var ov = BorderRuntimeOverrides.empty
        var req = BordersStyleRequest()
        req.width = 9; req.applyTo = 42
        ov.apply(req)
        XCTAssertEqual(ov.global.width, nil, "global must not absorb the per-window write")
        XCTAssertEqual(ov.perWindow[42]?.width, 9)
        XCTAssertNil(ov.perWindow[42]?.applyTo, "applyTo is consumed by the routing")
    }

    func testRepeatedApplyMergesFieldByField() {
        var ov = BorderRuntimeOverrides.empty
        var a = BordersStyleRequest(); a.width = 4
        var b = BordersStyleRequest(); b.style = .uniform
        ov.apply(a); ov.apply(b)
        XCTAssertEqual(ov.global.width, 4)
        XCTAssertEqual(ov.global.style, .uniform)
    }

    // MARK: - desiredBorders precedence

    func testGlobalOverrideWidthWinsOverConfig() {
        var ov = BorderRuntimeOverrides.empty
        var r = BordersStyleRequest(); r.width = 11
        ov.apply(r)

        let inputs = BorderEngineLogic.Inputs(
            windows: [1: win(1)], focusedWindowID: 1,
            snapshot: snap(), overrides: ov, primaryDisplayHeight: 1080
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertEqual(result[1]?.width, 11)
    }

    func testGlobalOverrideEnabledFalseProducesEmpty() {
        var ov = BorderRuntimeOverrides.empty
        ov.global.enabled = false
        let inputs = BorderEngineLogic.Inputs(
            windows: [1: win(1)], focusedWindowID: 1,
            snapshot: snap(), overrides: ov, primaryDisplayHeight: 1080
        )
        XCTAssertTrue(BorderEngineLogic.desiredBorders(inputs).isEmpty)
    }

    func testPerWindowOverrideOnlyAffectsTarget() {
        var ov = BorderRuntimeOverrides.empty
        var perW = BordersStyleRequest(); perW.width = 13
        ov.perWindow[1] = perW

        let inputs = BorderEngineLogic.Inputs(
            windows: [1: win(1), 2: win(2)],
            focusedWindowID: 1,
            snapshot: snap(), overrides: ov, primaryDisplayHeight: 1080
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertEqual(result[1]?.width, 13, "target window picks up the per-window override")
        XCTAssertEqual(result[2]?.width, BordersConfig.default.width, "non-target stays at config default")
    }

    func testRulePrecedence_ruleOverridesGlobalRuntime_perWindowOverridesRule() {
        let glow = ColorSpec.glow(.init(r: 0, g: 1, b: 0, a: 1))
        let ruleOverride = ColorSpec.solid(.init(r: 1, g: 0, b: 0, a: 1))
        let perWindowOverride = ColorSpec.solid(.init(r: 0, g: 0, b: 1, a: 1))

        let rule = Rule(
            name: "warp",
            match: WindowMatch(appName: "Warp", bundleIdentifier: nil, windowTitleExact: nil,
                               windowTitleContains: nil, windowTitleRegex: nil, windowID: nil, aerospaceWorkspace: nil),
            borderOverrides: Rule.BorderOverrides(active: ruleOverride, inactive: nil, width: 8, style: nil),
            effect: nil
        )

        var ov = BorderRuntimeOverrides.empty
        ov.global.active = glow      // global runtime override
        ov.global.width = 4
        ov.perWindow[1] = {
            var r = BordersStyleRequest()
            r.active = perWindowOverride
            return r
        }()

        let inputs = BorderEngineLogic.Inputs(
            windows: [1: win(1, app: "Warp"), 2: win(2, app: "Warp")],
            focusedWindowID: 1,
            snapshot: snap(rules: [rule]),
            overrides: ov, primaryDisplayHeight: 1080
        )
        let result = BorderEngineLogic.desiredBorders(inputs)

        // Window 1 (focused): per-window > rule > global runtime.
        XCTAssertEqual(result[1]?.color, perWindowOverride)
        // Window 1's width: rule (8), since the per-window override didn't set width
        XCTAssertEqual(result[1]?.width, 8)

        // Window 2 (unfocused, no per-window): rule wins for color (rule specifies `active`
        // override only, so inactive falls through to global runtime — but global runtime
        // didn't set inactive → config default).
        XCTAssertEqual(result[2]?.color, BordersConfig.default.inactive)
        XCTAssertEqual(result[2]?.width, 8)
    }

    // MARK: - shim filters

    func testBlacklistDropsApp() {
        var ov = BorderRuntimeOverrides.empty
        ov.global.blacklist = ["Finder"]
        let inputs = BorderEngineLogic.Inputs(
            windows: [1: win(1, app: "Warp"), 2: win(2, app: "Finder")],
            focusedWindowID: 1,
            snapshot: snap(), overrides: ov, primaryDisplayHeight: 1080
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertEqual(Set(result.keys), Set([1]))
    }

    func testWhitelistKeepsOnlyListed() {
        var ov = BorderRuntimeOverrides.empty
        ov.global.whitelist = ["Warp"]
        let inputs = BorderEngineLogic.Inputs(
            windows: [1: win(1, app: "Warp"), 2: win(2, app: "Finder")],
            focusedWindowID: 1,
            snapshot: snap(), overrides: ov, primaryDisplayHeight: 1080
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertEqual(Set(result.keys), Set([1]))
    }

    // MARK: - decoder roundtrip

    func testDecoderRoundtripMatchesParser() throws {
        let parsed = BordersStyleArgs.parse([
            "active_color=glow(0xffff0000)",
            "inactive_color=0xff494d64",
            "background_color=0x80112233",
            "width=4.5", "style=square", "order=above",
            "hidpi=on", "ax_focus=off", "blacklist=A,B",
            "whitelist=C", "apply-to=42",
        ]).request

        let dict = parsed.ipcArgs
        let decoded = try BordersStyleRequestDecoder.decode(from: dict)
        XCTAssertEqual(decoded, parsed)
    }
}
