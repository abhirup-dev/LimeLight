import XCTest
@testable import LimeCore

final class ConfigStoreTests: XCTestCase {
    private static let planSampleConfig = """
    {
      "performance": {
        "eventCoalesceMs": 16,
        "maxMainThreadTaskMs": 8,
        "idleCpuTargetPercent": 1.0,
        "enablePerfLogging": true
      },

      "borders": {
        "enabled": true,
        "style": "round",
        "order": "below",
        "width": 5.0,
        "hidpi": false,
        "active": { "color": "0xffe1e3e4" },
        "inactive": { "color": "0xff494d64" },
        "background": {
          "enabled": false,
          "color": "0x00000000"
        }
      },

      "effects": {
        "default": {
          "name": "cometRing",
          "color": "#00D1FF",
          "durationMs": 500
        }
      },

      "popup": {
        "enabled": true,
        "placement": "topRight",
        "durationMs": 2200,
        "showAppIcon": true,
        "showWindowTitle": true
      },

      "idleReturn": {
        "enabled": true,
        "thresholdSeconds": 300,
        "popup": {
          "title": "Welcome back",
          "message": "Idle for {idleMinutes}m"
        },
        "effect": "cometRing"
      },

      "rules": [
        {
          "name": "Warp windows",
          "match": { "appName": "Warp" },
          "borders": {
            "active": { "color": "glow(0xff00d1ff)" },
            "inactive": { "color": "0x88494d64" },
            "width": 6.0
          },
          "effect": {
            "name": "cometRing",
            "color": "#00D1FF"
          }
        },
        {
          "name": "Browser docs",
          "match": {
            "windowTitleRegex": ".*GitHub.*|.*docs.*"
          },
          "effect": {
            "name": "neon",
            "color": "#FFD166"
          }
        }
      ],

      "exclude": [
        { "appName": "System Settings" },
        { "windowTitleRegex": "^Picture in Picture$" }
      ]
    }
    """

    private func makeStore() -> ConfigStore {
        ConfigStore(path: "/nonexistent/intentionally")
    }

    func testParsesPlanSampleConfig() {
        let store = makeStore()
        let result = parseOffMain(store: store, raw: Self.planSampleConfig)
        XCTAssertTrue(result.replacedActive)
        XCTAssertNil(result.parseError)
        let snap = result.snapshot
        XCTAssertEqual(snap.performance.eventCoalesceMs, 16)
        XCTAssertEqual(snap.borders.style, .round)
        XCTAssertEqual(snap.borders.width, 5.0)
        XCTAssertEqual(snap.popup.placement, .topRight)
        XCTAssertEqual(snap.idleReturn.thresholdSeconds, 300)
        XCTAssertEqual(snap.rules.count, 2)
        XCTAssertEqual(snap.rules[0].name, "Warp windows")
        XCTAssertEqual(snap.rules[0].match.appName, "Warp")
        if case .glow = snap.rules[0].borderOverrides?.active {} else { XCTFail("expected glow override") }
        XCTAssertNotNil(snap.rules[1].match.windowTitleRegex)
        XCTAssertEqual(snap.exclude.count, 2)
        XCTAssertTrue(snap.diagnostics.isEmpty, "expected no diagnostics for the canonical sample")
    }

    func testJSONCCommentsAndTrailingCommasAccepted() {
        let store = makeStore()
        let raw = """
        {
          // top-level comment
          "borders": {
            "width": 4.0, /* inline */
            "active": { "color": "#ffffff" }, // trailing comma below
          },
        }
        """
        let result = parseOffMain(store: store, raw: raw)
        XCTAssertTrue(result.replacedActive)
        XCTAssertEqual(result.snapshot.borders.width, 4.0)
    }

    func testInvalidJSONKeepsPreviousSnapshot() {
        let store = makeStore()
        // Establish a known-good snapshot first.
        let ok = parseOffMain(store: store, raw: Self.planSampleConfig)
        XCTAssertTrue(ok.replacedActive)
        let prevWidth = ok.snapshot.borders.width

        let bad = parseOffMain(store: store, raw: "{ this is not json")
        XCTAssertFalse(bad.replacedActive)
        XCTAssertNotNil(bad.parseError)
        XCTAssertEqual(store.currentSnapshot.borders.width, prevWidth)
    }

    func testBadRegexIsolatesRule() {
        let store = makeStore()
        let raw = """
        {
          "rules": [
            { "name": "good", "match": { "appName": "Warp" } },
            { "name": "bad",  "match": { "windowTitleRegex": "(unclosed" } },
            { "name": "later","match": { "appName": "Cursor" } }
          ]
        }
        """
        let result = parseOffMain(store: store, raw: raw)
        XCTAssertTrue(result.replacedActive)
        let snap = result.snapshot
        XCTAssertEqual(snap.rules.count, 3, "bad rule must not nuke siblings")
        XCTAssertEqual(snap.rules[0].name, "good")
        XCTAssertEqual(snap.rules[2].name, "later")
        XCTAssertTrue(snap.rules[1].match.isEmpty, "bad regex should disable the rule, not erase it")
        XCTAssertTrue(snap.diagnostics.contains { $0.path == "rules[1].match.windowTitleRegex" })
    }

    func testMissingFileReturnsDefaults() {
        let store = ConfigStore(path: "/nonexistent/definitely/missing/\(UUID()).jsonc")
        let result = loadOffMain(store: store)
        XCTAssertTrue(result.replacedActive)
        XCTAssertNil(result.parseError)
        XCTAssertEqual(result.snapshot.borders.style, BordersConfig.default.style)
    }

    func testFiveHundredRulesParseQuickly() {
        var ruleBlocks: [String] = []
        ruleBlocks.reserveCapacity(500)
        for i in 0..<500 {
            ruleBlocks.append("""
            { "name": "r\(i)", "match": { "windowTitleRegex": "(?i)pattern-\(i).*[abc]+$" } }
            """)
        }
        let raw = """
        {
          "rules": [
            \(ruleBlocks.joined(separator: ",\n"))
          ]
        }
        """
        let store = makeStore()
        let started = Date()
        let result = parseOffMain(store: store, raw: raw)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(result.replacedActive)
        XCTAssertEqual(result.snapshot.rules.count, 500)
        XCTAssertLessThan(elapsed, 0.250, "parsing 500 rules took \(elapsed)s")
    }

    func testSnapshotIsImmutableAcrossThreads() {
        let store = makeStore()
        _ = parseOffMain(store: store, raw: Self.planSampleConfig)
        let s1 = store.currentSnapshot
        _ = parseOffMain(store: store, raw: """
        { "borders": { "width": 9.0 } }
        """)
        // The snapshot we already pulled out is immutable — still has the old width.
        XCTAssertEqual(s1.borders.width, 5.0)
        XCTAssertEqual(store.currentSnapshot.borders.width, 9.0)
    }

    // focusfx-7ew: `validate` must NEVER swap the live snapshot, even when the
    // candidate parses cleanly. Earlier the daemon's `config.validate` IPC
    // routed through `loadSync()` and published the parsed config — running a
    // CLI dry-run against a different valid file would silently replace the
    // active config. Pin the non-publishing path here.
    func testValidateDoesNotPublishEvenOnSuccess() {
        let store = makeStore()
        // Establish a known-good live snapshot.
        let baseline = parseOffMain(store: store, raw: Self.planSampleConfig)
        XCTAssertTrue(baseline.replacedActive)
        XCTAssertEqual(store.currentSnapshot.borders.width, 5.0)

        // Validate a *different* but valid candidate that would shift width.
        let candidate = """
        { "borders": { "width": 42.0 } }
        """
        let result = validateOffMain(store: store, raw: candidate)
        XCTAssertNil(result.parseError, "candidate should parse cleanly")
        XCTAssertFalse(result.replacedActive, "validate must not flip replacedActive")
        XCTAssertEqual(result.snapshot.borders.width, 42.0, "diagnostics-bearing snapshot should reflect candidate")

        // The live snapshot must be untouched.
        XCTAssertEqual(store.currentSnapshot.borders.width, 5.0, "validate leaked into live snapshot")
    }

    func testValidateReportsErrorsWithoutTouchingSnapshot() {
        let store = makeStore()
        _ = parseOffMain(store: store, raw: Self.planSampleConfig)
        let liveBefore = store.currentSnapshot.borders.width

        let result = validateOffMain(store: store, raw: "{ broken")
        XCTAssertNotNil(result.parseError)
        XCTAssertFalse(result.replacedActive)
        XCTAssertEqual(store.currentSnapshot.borders.width, liveBefore)
    }

    // MARK: - off-main helpers

    private func parseOffMain(store: ConfigStore, raw: String) -> ConfigStore.LoadResult {
        var captured: ConfigStore.LoadResult!
        let exp = expectation(description: "parse")
        DispatchQueue.global(qos: .userInitiated).async {
            captured = store.parse(raw: raw)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        return captured
    }

    private func validateOffMain(store: ConfigStore, raw: String) -> ConfigStore.LoadResult {
        var captured: ConfigStore.LoadResult!
        let exp = expectation(description: "validate")
        DispatchQueue.global(qos: .userInitiated).async {
            captured = store.validate(raw: raw)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        return captured
    }

    private func loadOffMain(store: ConfigStore) -> ConfigStore.LoadResult {
        var captured: ConfigStore.LoadResult!
        let exp = expectation(description: "load")
        DispatchQueue.global(qos: .userInitiated).async {
            captured = store.loadSync()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        return captured
    }
}
