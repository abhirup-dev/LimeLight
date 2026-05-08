import XCTest
@testable import LimeCore

final class PerfDiagnosticsTests: XCTestCase {
    func testIPCDictionaryRoundTripsCleanJSON() throws {
        let d = PerfDiagnostics(
            collectedAtIso: "2026-05-08T07:00:00Z",
            daemon: .init(version: "0.1.0", pid: 1234, bundleIdentifier: "dev.abhirup.LimeLight", uptimeSeconds: 12.5),
            accessibility: .init(status: "granted"),
            skylight: .init(streamingAvailable: true, frontWindowResolutionAvailable: true),
            socket: .init(path: "/tmp/limelight.sock"),
            config: .init(path: "/tmp/cfg.jsonc", diagnosticsCount: 0, bordersEnabled: true, ruleCount: 3),
            render: .init(bordersEngineEnabled: true, desiredBorderCount: 5),
            tracker: .init(trackedWindowCount: 17, focusedWindowID: 42),
            mainThread: .init(totalBudgetCalls: 100, slowBudgetCalls: 2, maxObservedMs: 12.7, slowestTaskAtIso: "2026-05-08T06:59:00Z")
        )
        let dict = d.toIPCDictionary()
        let data = try IPCCoding.makeEncoder().encode(AnyCodable(dict))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["collectedAt"] as? String, "2026-05-08T07:00:00Z")
        XCTAssertEqual((json["daemon"] as? [String: Any])?["pid"] as? Int, 1234)
        XCTAssertEqual((json["accessibility"] as? [String: Any])?["status"] as? String, "granted")
        XCTAssertEqual((json["render"] as? [String: Any])?["desiredBorderCount"] as? Int, 5)
        XCTAssertEqual((json["tracker"] as? [String: Any])?["focusedWindowID"] as? Int, 42)
        XCTAssertEqual((json["mainThread"] as? [String: Any])?["slowBudgetCalls"] as? Int, 2)
    }

    // focusfx-30.1: surfaces "feature off" vs "feature broken" — when the
    // SLS resolver is unavailable, frontWindowResolutionAvailable=false and
    // streamingAvailable=false; granted-AX still reports normally.
    func testReportsBrokenSkylightCleanly() throws {
        let d = PerfDiagnostics(
            collectedAtIso: "2026-05-08T07:00:00Z",
            daemon: .init(version: "0.1.0", pid: 1, bundleIdentifier: "x", uptimeSeconds: 0),
            accessibility: .init(status: "granted"),
            skylight: .init(streamingAvailable: false, frontWindowResolutionAvailable: false),
            socket: .init(path: "/tmp/x"),
            config: .init(path: "/tmp/x", diagnosticsCount: 0, bordersEnabled: true, ruleCount: 0),
            render: .init(bordersEngineEnabled: true, desiredBorderCount: 0),
            tracker: .init(trackedWindowCount: 0, focusedWindowID: nil),
            mainThread: .init(totalBudgetCalls: 0, slowBudgetCalls: 0, maxObservedMs: 0, slowestTaskAtIso: nil)
        )
        let dict = d.toIPCDictionary()
        let data = try IPCCoding.makeEncoder().encode(AnyCodable(dict))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sky = try XCTUnwrap(json["skylight"] as? [String: Any])
        XCTAssertEqual(sky["streamingAvailable"] as? Bool, false)
        XCTAssertEqual(sky["frontWindowResolutionAvailable"] as? Bool, false)
        let tracker = try XCTUnwrap(json["tracker"] as? [String: Any])
        XCTAssertNil(tracker["focusedWindowID"] as? Int, "nil focus serializes to JSON null, not 0")
    }

    // focusfx-30.2: stable diagnostic codes appear in the warnings array
    // when subsystems are degraded. The codes are part of the wire
    // contract — tests pin the exact strings.
    func testDegradedStateProducesStableWarningCodes() {
        let d = PerfDiagnostics(
            collectedAtIso: "2026-05-08T07:00:00Z",
            daemon: .init(version: "x", pid: 1, bundleIdentifier: "x", uptimeSeconds: 0),
            accessibility: .init(status: "denied"),
            skylight: .init(streamingAvailable: false, frontWindowResolutionAvailable: false),
            socket: .init(path: "/tmp/x"),
            config: .init(path: "/tmp/x", diagnosticsCount: 2, bordersEnabled: false, ruleCount: 0),
            render: .init(bordersEngineEnabled: false, desiredBorderCount: 0),
            tracker: .init(trackedWindowCount: 0, focusedWindowID: nil),
            mainThread: .init(totalBudgetCalls: 0, slowBudgetCalls: 0, maxObservedMs: 0, slowestTaskAtIso: nil)
        )
        XCTAssertEqual(Set(d.warnings), [
            "ax_denied", "sls_streaming_off", "sls_resolver_off",
            "config_invalid", "borders_disabled",
        ])
    }

    func testHealthyStateHasNoWarnings() {
        let d = PerfDiagnostics(
            collectedAtIso: "x",
            daemon: .init(version: "x", pid: 1, bundleIdentifier: "x", uptimeSeconds: 0),
            accessibility: .init(status: "granted"),
            skylight: .init(streamingAvailable: true, frontWindowResolutionAvailable: true),
            socket: .init(path: "/tmp/x"),
            config: .init(path: "/tmp/x", diagnosticsCount: 0, bordersEnabled: true, ruleCount: 1),
            render: .init(bordersEngineEnabled: true, desiredBorderCount: 1),
            tracker: .init(trackedWindowCount: 1, focusedWindowID: 1),
            mainThread: .init(totalBudgetCalls: 0, slowBudgetCalls: 0, maxObservedMs: 0, slowestTaskAtIso: nil)
        )
        XCTAssertEqual(d.warnings, [])
    }

    func testMainThreadBudgetMetricsCount() {
        MainThreadBudgetMetrics._resetForTesting()
        // Force-thread-budget calls — fast body to stay under threshold.
        for _ in 0..<5 { mainThreadBudget("test.fast") {} }
        let snap = MainThreadBudgetMetrics.snapshot()
        XCTAssertEqual(snap.totalCalls, 5)
        XCTAssertEqual(snap.slowCalls, 0)
    }
}
