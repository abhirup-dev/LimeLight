import XCTest
@testable import LimeCore

final class RuleResolverTests: XCTestCase {
    private func compile(_ raw: String) -> ConfigSnapshot {
        var captured: ConfigSnapshot!
        let exp = expectation(description: "compile")
        DispatchQueue.global(qos: .userInitiated).async {
            let store = ConfigStore(path: "/dev/null")
            captured = store.parse(raw: raw).snapshot
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        return captured
    }

    // MARK: - match field coverage

    func testMatchByAppName() {
        let s = compile(#"{ "rules": [ { "name": "warp", "match": { "appName": "Warp" } } ] }"#)
        XCTAssertNotNil(RuleResolver.firstMatchingRule(.init(appName: "Warp"), snapshot: s))
        XCTAssertNil(RuleResolver.firstMatchingRule(.init(appName: "Other"), snapshot: s))
    }

    func testMatchByBundleIdentifier() {
        let s = compile(#"{ "rules": [ { "match": { "bundleIdentifier": "dev.warp.Warp" } } ] }"#)
        XCTAssertNotNil(RuleResolver.firstMatchingRule(.init(bundleIdentifier: "dev.warp.Warp"), snapshot: s))
        XCTAssertNil(RuleResolver.firstMatchingRule(.init(bundleIdentifier: "com.apple.dt.Xcode"), snapshot: s))
    }

    func testMatchByExactWindowTitle() {
        let s = compile(#"{ "rules": [ { "match": { "windowTitle": "Activity Monitor" } } ] }"#)
        XCTAssertNotNil(RuleResolver.firstMatchingRule(.init(windowTitle: "Activity Monitor"), snapshot: s))
        XCTAssertNil(RuleResolver.firstMatchingRule(.init(windowTitle: "Activity Monitor – CPU"), snapshot: s))
    }

    func testMatchByWindowTitleContains() {
        let s = compile(#"{ "rules": [ { "match": { "windowTitleContains": "GitHub" } } ] }"#)
        XCTAssertNotNil(RuleResolver.firstMatchingRule(.init(windowTitle: "PR — anthropics/foo on GitHub"), snapshot: s))
        XCTAssertNil(RuleResolver.firstMatchingRule(.init(windowTitle: "no match here"), snapshot: s))
    }

    func testMatchByWindowTitleRegex() {
        let s = compile(#"{ "rules": [ { "match": { "windowTitleRegex": ".*GitHub.*|.*docs.*" } } ] }"#)
        XCTAssertNotNil(RuleResolver.firstMatchingRule(.init(windowTitle: "API docs"), snapshot: s))
        XCTAssertNotNil(RuleResolver.firstMatchingRule(.init(windowTitle: "PR on GitHub"), snapshot: s))
        XCTAssertNil(RuleResolver.firstMatchingRule(.init(windowTitle: "unrelated"), snapshot: s))
    }

    func testMatchByWindowID() {
        let s = compile(#"{ "rules": [ { "match": { "windowID": 4242 } } ] }"#)
        XCTAssertNotNil(RuleResolver.firstMatchingRule(.init(windowID: 4242), snapshot: s))
        XCTAssertNil(RuleResolver.firstMatchingRule(.init(windowID: 4243), snapshot: s))
    }

    func testMatchByAerospaceWorkspace() {
        let s = compile(#"{ "rules": [ { "match": { "aerospaceWorkspace": "1" } } ] }"#)
        XCTAssertNotNil(RuleResolver.firstMatchingRule(.init(aerospaceWorkspace: "1"), snapshot: s))
        XCTAssertNil(RuleResolver.firstMatchingRule(.init(aerospaceWorkspace: "2"), snapshot: s))
    }

    func testMatchAllFieldsAreANDed() {
        let s = compile(#"""
        { "rules": [ { "match": { "appName": "Warp", "windowTitleContains": "ssh" } } ] }
        """#)
        XCTAssertNotNil(RuleResolver.firstMatchingRule(.init(appName: "Warp", windowTitle: "ssh box"), snapshot: s))
        XCTAssertNil(RuleResolver.firstMatchingRule(.init(appName: "Warp", windowTitle: "local"), snapshot: s))
        XCTAssertNil(RuleResolver.firstMatchingRule(.init(appName: "Other", windowTitle: "ssh"), snapshot: s))
    }

    // MARK: - precedence

    func testPrecedenceCLIOverridesRuleOverridesGlobal() {
        let s = compile(#"""
        {
          "effects": { "default": { "name": "global", "color": "#000000", "durationMs": 100 } },
          "rules": [
            { "match": { "appName": "Warp" },
              "effect": { "name": "ruled", "color": "#ff0000", "durationMs": 200 } }
          ]
        }
        """#)

        // Defaults: no match → global
        let xs = RuleResolver.resolveEffect(for: .init(appName: "Other"), snapshot: s)
        XCTAssertEqual(xs.name, "global")

        // Match: rule overrides global
        let yr = RuleResolver.resolveEffect(for: .init(appName: "Warp"), snapshot: s)
        XCTAssertEqual(yr.name, "ruled")
        XCTAssertEqual(yr.durationMs, 200)

        // CLI override: highest precedence
        let zc = RuleResolver.resolveEffect(
            for: .init(appName: "Warp"),
            snapshot: s,
            overrides: EffectOverrides(name: "cli", durationMs: 99)
        )
        XCTAssertEqual(zc.name, "cli")
        XCTAssertEqual(zc.durationMs, 99)
    }

    func testFirstMatchingRuleWinsInSourceOrder() {
        let s = compile(#"""
        {
          "rules": [
            { "name": "first",  "match": { "appName": "Warp" } },
            { "name": "second", "match": { "appName": "Warp" } }
          ]
        }
        """#)
        XCTAssertEqual(RuleResolver.firstMatchingRule(.init(appName: "Warp"), snapshot: s)?.name, "first")
    }

    func testBordersOverridePatchesGlobal() {
        let s = compile(#"""
        {
          "borders": { "width": 5.0, "active": { "color": "0xff111111" } },
          "rules": [
            { "match": { "appName": "Warp" },
              "borders": { "width": 6.0, "active": { "color": "glow(0xffff0000)" } } }
          ]
        }
        """#)
        let g = RuleResolver.resolveBorders(for: .init(appName: "Other"), snapshot: s)
        XCTAssertEqual(g.width, 5.0)
        let m = RuleResolver.resolveBorders(for: .init(appName: "Warp"), snapshot: s)
        XCTAssertEqual(m.width, 6.0)
        guard case .glow = m.active else { return XCTFail("expected glow override") }
    }

    func testExcludeListBlocksWindow() {
        let s = compile(#"""
        { "exclude": [ { "appName": "System Settings" }, { "windowTitleRegex": "^Picture in Picture$" } ] }
        """#)
        XCTAssertTrue(RuleResolver.isExcluded(.init(appName: "System Settings"), snapshot: s))
        XCTAssertTrue(RuleResolver.isExcluded(.init(windowTitle: "Picture in Picture"), snapshot: s))
        XCTAssertFalse(RuleResolver.isExcluded(.init(windowTitle: "Picture in Picture - Live"), snapshot: s))
        XCTAssertFalse(RuleResolver.isExcluded(.init(appName: "Finder"), snapshot: s))
    }

    func testEmptyMatchFromBadRegexDoesNotMatchEverything() {
        let s = compile(#"""
        { "rules": [ { "name": "broken", "match": { "windowTitleRegex": "(unclosed" } } ] }
        """#)
        XCTAssertEqual(s.rules.count, 1)
        // The compiled match is empty (regex was rejected). matches() must return false for everyone.
        XCTAssertNil(RuleResolver.firstMatchingRule(.init(windowTitle: "anything"), snapshot: s))
        XCTAssertNil(RuleResolver.firstMatchingRule(.init(appName: "anything"), snapshot: s))
    }
}
