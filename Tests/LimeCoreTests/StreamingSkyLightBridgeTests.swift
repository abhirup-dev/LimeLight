import XCTest
@testable import LimeCore

/// focusfx-b13: streaming bridge boundary tests. We can't exercise the
/// real SLS callback in a unit test (no WindowServer attached), but we can
/// verify the graceful-degradation gate and the trampoline-decode path
/// via the test hook on the bridge.
final class StreamingSkyLightBridgeTests: XCTestCase {
    /// Empty symbols (no dlsym hits) must NOT register anything: start()
    /// returns false, isStreaming stays false, and enumerate still works
    /// via the wrapped public-API bridge.
    func testGracefulDegradationWhenSymbolsMissing() {
        let inner = StubBridge(initial: [
            WindowState(windowID: 42, ownerPID: 1, appName: "X",
                        title: "t", frame: .zero)
        ])
        let bridge = StreamingSkyLightBridge(wrapping: inner, symbols: SkyLightSymbols())
        XCTAssertFalse(bridge.isStreaming)

        let q = DispatchQueue(label: "test.degrade")
        let started = bridge.start(dispatchQueue: q) { _ in
            XCTFail("handler must not fire when symbols are unavailable")
        }
        XCTAssertFalse(started)
        XCTAssertFalse(bridge.isStreaming)
        XCTAssertEqual(bridge.enumerateOnScreenWindows().count, 1)
    }

    /// `_testFireEvent` simulates a callback as if SLS had delivered it.
    /// Without a real `start()`, the bridge has no handler installed, so
    /// the fire is a silent no-op (which is also the correct behaviour
    /// for events arriving after stop()). This guards the no-handler
    /// branch from regressing into a crash.
    func testFireEventIsNoOpWithoutInstalledHandler() {
        let bridge = StreamingSkyLightBridge(
            wrapping: StubBridge(initial: []),
            symbols: SkyLightSymbols()
        )
        bridge._testFireEvent(.windowMove)
    }

    /// Real-world resolution: at least the connection-ID symbol should be
    /// resolvable on a stock macOS 14. This is the smoke test for the
    /// dlopen path. Skipped if we're somehow running where SkyLight isn't
    /// available so CI on non-mac targets doesn't false-fail.
    func testRealResolutionOnHostHasConnectionID() throws {
        let resolved = SkyLightSymbols.resolveFromSkyLight()
        guard resolved.mainConnectionID != nil else {
            throw XCTSkip("SkyLight not resolvable in this environment")
        }
        XCTAssertNotNil(resolved.registerNotifyProc, "if mainConnectionID resolves, registerNotifyProc usually does too")
        XCTAssertTrue(resolved.canStream)
    }
}

private final class StubBridge: WindowServerBridge, @unchecked Sendable {
    private let windows: [WindowState]
    var isStreaming: Bool { false }
    init(initial: [WindowState]) { self.windows = initial }
    func enumerateOnScreenWindows() -> [WindowState] { windows }
}
