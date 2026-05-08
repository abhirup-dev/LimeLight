import XCTest
@testable import LimeCore

final class EffectEngineTests: XCTestCase {
    // focusfx-18.2: an unknown effect name returns a stable diagnostic
    // rather than the daemon hanging. Pinning the EffectAccepted vocabulary
    // keeps the IPC error code → CLI exit-code mapping stable.
    func testUnknownEffectIsRejected() async {
        await MainActor.run {
            let engine = EffectEngine()
            let trig = EffectTrigger(
                effect: "doesNotExist",
                frame: CGRect(x: 0, y: 0, width: 200, height: 200),
                cocoaFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
                color: .init(r: 1, g: 0, b: 0, a: 1),
                durationMs: 200
            )
            XCTAssertEqual(engine.trigger(trig), .unknownEffect)
            XCTAssertEqual(engine.activeEffectCount, 0)
        }
    }

    // Parser-known but renderer-pending effects (neon/shockwave/line) must
    // surface as `effectNotImplemented` so callers can detect the gap.
    func testKnownEffectWithoutRendererSurfacesNotImplemented() async {
        await MainActor.run {
            let engine = EffectEngine()
            for name in ["neon", "shockwave", "line"] {
                let trig = EffectTrigger(
                    effect: name,
                    frame: CGRect(x: 0, y: 0, width: 200, height: 200),
                    cocoaFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
                    color: .init(r: 1, g: 0, b: 0, a: 1),
                    durationMs: 200
                )
                XCTAssertEqual(engine.trigger(trig), .effectNotImplemented, "\(name) should be parser-known but pending")
            }
        }
    }

    func testEmptyFrameIsRejected() async {
        await MainActor.run {
            let engine = EffectEngine()
            let trig = EffectTrigger(
                effect: "cometRing",
                frame: .zero, cocoaFrame: .zero,
                color: .init(r: 1, g: 0, b: 0, a: 1),
                durationMs: 200
            )
            XCTAssertEqual(engine.trigger(trig), .noTarget)
        }
    }

    func testTearDownIsIdempotent() async {
        await MainActor.run {
            let engine = EffectEngine()
            engine.tearDown()
            engine.tearDown()
            XCTAssertEqual(engine.activeEffectCount, 0)
        }
    }
}
