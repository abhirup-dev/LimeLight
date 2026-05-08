import XCTest
import CoreGraphics
@testable import LimeCore

final class BorderEngineLogicTests: XCTestCase {
    // MARK: - Y-flip math

    func testCocoaFrameFlipFromCGForPrimaryDisplay() {
        // 1080-tall primary display. CG y=0 = top; Cocoa y=0 = bottom.
        let cg = CGRect(x: 100, y: 50, width: 800, height: 600)
        let cocoa = BorderEngineLogic.cocoaFrame(from: cg, primaryDisplayHeight: 1080)
        XCTAssertEqual(cocoa.origin.x, 100)
        XCTAssertEqual(cocoa.origin.y, 1080 - 50 - 600) // 430
        XCTAssertEqual(cocoa.size.width, 800)
        XCTAssertEqual(cocoa.size.height, 600)
    }

    func testCocoaFrameFlipNearTopOfScreen() {
        // A window that's near the top in CG (small y) ends up near the top in Cocoa
        // (large y, since Cocoa y grows up).
        let cg = CGRect(x: 0, y: 0, width: 200, height: 100)
        let cocoa = BorderEngineLogic.cocoaFrame(from: cg, primaryDisplayHeight: 900)
        XCTAssertEqual(cocoa.origin.y, 800) // 900 - 0 - 100
    }

    func testCocoaFrameFlipNearBottomOfScreen() {
        // A window near the bottom in CG (large y) ends up near the bottom in Cocoa
        // (small y).
        let cg = CGRect(x: 0, y: 800, width: 200, height: 100)
        let cocoa = BorderEngineLogic.cocoaFrame(from: cg, primaryDisplayHeight: 900)
        XCTAssertEqual(cocoa.origin.y, 0)
    }

    func testCocoaFrameSecondaryDisplayToTheRight() {
        // Multi-display: CG and Cocoa both share their y-origin from the primary
        // display, so the formula doesn't change for a window on a display to the
        // right (different x, same y reference). Cocoa flip still uses primary height.
        let cg = CGRect(x: 1920, y: 100, width: 600, height: 400) // window at x=1920
        let cocoa = BorderEngineLogic.cocoaFrame(from: cg, primaryDisplayHeight: 1080)
        XCTAssertEqual(cocoa.origin.x, 1920)
        XCTAssertEqual(cocoa.origin.y, 1080 - 100 - 400) // 580
    }

    // MARK: - desiredBorders

    private func makeSnapshot(rules: [Rule] = [], excludes: [WindowMatch] = []) -> ConfigSnapshot {
        ConfigSnapshot(
            performance: .default,
            borders: .default,
            defaultEffect: .default,
            popup: .default,
            idleReturn: .default,
            rules: rules,
            exclude: excludes,
            diagnostics: []
        )
    }

    private func w(_ id: WindowID, pid: Int32 = 100, app: String = "Warp", title: String = "t",
                   frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
                   onScreen: Bool = true) -> WindowState {
        WindowState(windowID: id, ownerPID: pid, appName: app, title: title, frame: frame, isOnScreen: onScreen)
    }

    func testDesiredBordersFocusedIsActiveOthersAreInactive() {
        let inputs = BorderEngineLogic.Inputs(
            windows: [1: w(1), 2: w(2, app: "Finder", frame: CGRect(x: 1000, y: 0, width: 800, height: 600))],
            focusedWindowID: 1,
            snapshot: makeSnapshot(),
            primaryDisplayHeight: 1080
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[.window(1)]?.isActive == true)
        XCTAssertTrue(result[.window(2)]?.isActive == false)
        XCTAssertEqual(result[.window(1)]?.color, BordersConfig.default.active)
        XCTAssertEqual(result[.window(2)]?.color, BordersConfig.default.inactive)
    }

    func testDesiredBordersBorderEnabledFalseProducesEmpty() {
        var snap = makeSnapshot()
        snap = ConfigSnapshot(
            performance: snap.performance,
            borders: BordersConfig(
                enabled: false, style: .round, order: .below, width: 5, hidpi: false,
                active: snap.borders.active, inactive: snap.borders.inactive,
                background: snap.borders.background
            ),
            defaultEffect: snap.defaultEffect, popup: snap.popup,
            idleReturn: snap.idleReturn, rules: [], exclude: [], diagnostics: []
        )
        let inputs = BorderEngineLogic.Inputs(
            windows: [1: w(1)], focusedWindowID: 1, snapshot: snap, primaryDisplayHeight: 1080
        )
        XCTAssertTrue(BorderEngineLogic.desiredBorders(inputs).isEmpty)
    }

    func testDesiredBordersExcludesOffScreenAndZeroSized() {
        let inputs = BorderEngineLogic.Inputs(
            windows: [
                1: w(1),
                2: w(2, onScreen: false),
                3: w(3, frame: CGRect(x: 0, y: 0, width: 0, height: 0)),
            ],
            focusedWindowID: 1,
            snapshot: makeSnapshot(),
            primaryDisplayHeight: 1080
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertEqual(Set(result.keys), Set([.window(1)]))
    }

    func testDesiredBordersHonorsExcludeList() {
        let exclude = [
            WindowMatch(appName: "System Settings", bundleIdentifier: nil, windowTitleExact: nil,
                        windowTitleContains: nil, windowTitleRegex: nil, windowID: nil, aerospaceWorkspace: nil)
        ]
        let inputs = BorderEngineLogic.Inputs(
            windows: [
                1: w(1),
                2: w(2, app: "System Settings"),
            ],
            focusedWindowID: 1,
            snapshot: makeSnapshot(excludes: exclude),
            primaryDisplayHeight: 1080
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertEqual(Set(result.keys), Set([.window(1)]))
    }

    func testDesiredBordersAppliesRuleOverrideWidthAndColor() {
        let glow = ColorSpec.glow(.init(r: 0, g: 0.8, b: 1, a: 1))
        let rule = Rule(
            name: "warp",
            match: WindowMatch(appName: "Warp", bundleIdentifier: nil, windowTitleExact: nil,
                               windowTitleContains: nil, windowTitleRegex: nil, windowID: nil, aerospaceWorkspace: nil),
            borderOverrides: Rule.BorderOverrides(active: glow, inactive: nil, width: 9.0, style: nil),
            effect: nil
        )
        let inputs = BorderEngineLogic.Inputs(
            windows: [1: w(1, app: "Warp")],
            focusedWindowID: 1,
            snapshot: makeSnapshot(rules: [rule]),
            primaryDisplayHeight: 1080
        )
        let spec = BorderEngineLogic.desiredBorders(inputs)[.window(1)]
        XCTAssertEqual(spec?.width, 9.0)
        XCTAssertEqual(spec?.color, glow)
    }

    // MARK: - hybrid per-monitor

    private func display(_ id: CGDirectDisplayID, cg: CGRect, isFullscreen: Bool = false) -> DisplayInfo {
        DisplayInfo(id: id, cgFrame: cg, cocoaVisibleFrame: cg, isFullscreen: isFullscreen)
    }

    func testWindowsOnUnfocusedMonitorRenderInactive() {
        // focusfx-fa3: Two displays side-by-side; focused window on display 1,
        // idle window on display 2. The unfocused-display window must still
        // get a border (inactive color). Earlier behavior dropped it entirely.
        // The screen-wide stripe is still gone (removed in focusfx-ogp).
        let d1 = display(1, cg: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let d2 = display(2, cg: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        let focused = w(1, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        let idle = w(2, frame: CGRect(x: 2100, y: 100, width: 800, height: 600))
        let inputs = BorderEngineLogic.Inputs(
            orderedWindows: [focused, idle],
            focusedWindowID: 1,
            snapshot: makeSnapshot(),
            primaryDisplayHeight: 1080,
            displays: [d1, d2]
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertEqual(result[.window(1)]?.isActive, true, "focused window is active")
        XCTAssertEqual(result[.window(2)]?.isActive, false, "unfocused-display window is inactive")
        XCTAssertNil(result[.screen(1)])
        XCTAssertNil(result[.screen(2)])
    }

    func testThreeDisplaysTwoWindowsEachFocusOnEachDisplay() {
        // focusfx-fa3 acceptance: three displays, two windows each, sweep the
        // focus across all six. The focused window must always be the only
        // active border; the other five must always render inactive — never
        // missing.
        let d1 = display(1, cg: CGRect(x: 0,    y: 0, width: 1920, height: 1080))
        let d2 = display(2, cg: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        let d3 = display(3, cg: CGRect(x: 3840, y: 0, width: 1920, height: 1080))
        let windows = [
            w(11, frame: CGRect(x:    0, y: 0, width: 960, height: 1080)),
            w(12, frame: CGRect(x:  960, y: 0, width: 960, height: 1080)),
            w(21, frame: CGRect(x: 1920, y: 0, width: 960, height: 1080)),
            w(22, frame: CGRect(x: 2880, y: 0, width: 960, height: 1080)),
            w(31, frame: CGRect(x: 3840, y: 0, width: 960, height: 1080)),
            w(32, frame: CGRect(x: 4800, y: 0, width: 960, height: 1080)),
        ]
        let allIDs: Set<WindowID> = [11, 12, 21, 22, 31, 32]
        for focusID in allIDs {
            let inputs = BorderEngineLogic.Inputs(
                orderedWindows: windows,
                focusedWindowID: focusID,
                snapshot: makeSnapshot(),
                primaryDisplayHeight: 1080,
                displays: [d1, d2, d3]
            )
            let result = BorderEngineLogic.desiredBorders(inputs)
            for id in allIDs {
                guard let spec = result[.window(id)] else {
                    XCTFail("focus=\(focusID): window \(id) missing border (focusfx-fa3 regression)")
                    continue
                }
                XCTAssertEqual(spec.isActive, id == focusID,
                    "focus=\(focusID): window \(id) active=\(spec.isActive)")
            }
            XCTAssertNil(result[.screen(1)])
            XCTAssertNil(result[.screen(2)])
            XCTAssertNil(result[.screen(3)])
        }
    }

    func testHybridFocusedMonitorTilesAllGetBorders() {
        // Focused monitor has two AeroSpace tiles. Both should be bordered.
        let d1 = display(1, cg: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let left = w(1, frame: CGRect(x: 0, y: 0, width: 960, height: 1080))
        let right = w(2, frame: CGRect(x: 960, y: 0, width: 960, height: 1080))
        let inputs = BorderEngineLogic.Inputs(
            orderedWindows: [left, right],
            focusedWindowID: 1,
            snapshot: makeSnapshot(),
            primaryDisplayHeight: 1080,
            displays: [d1]
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertTrue(result[.window(1)]?.isActive == true)
        XCTAssertTrue(result[.window(2)]?.isActive == false)
        XCTAssertNil(result[.screen(1)])
    }

    func testHybridFullscreenMonitorSuppressesScreenBorder() {
        let d1 = display(1, cg: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let d2 = display(2, cg: CGRect(x: 1920, y: 0, width: 1920, height: 1080), isFullscreen: true)
        let focused = w(1, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        let inputs = BorderEngineLogic.Inputs(
            orderedWindows: [focused],
            focusedWindowID: 1,
            snapshot: makeSnapshot(),
            primaryDisplayHeight: 1080,
            displays: [d1, d2]
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertNil(result[.screen(2)], "fullscreen monitor must not get a screen border")
    }

    func testOcclusionStackedWindowsOnlyTopBorders() {
        // Three Slack windows stacked on the same monitor. orderedWindows is
        // CGWindowList front-to-back — the front (id=1) covers the others.
        let d1 = display(1, cg: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let top = w(1, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        let mid = w(2, frame: CGRect(x: 110, y: 110, width: 800, height: 600))
        let bot = w(3, frame: CGRect(x: 120, y: 120, width: 800, height: 600))
        let inputs = BorderEngineLogic.Inputs(
            orderedWindows: [top, mid, bot],
            focusedWindowID: 1,
            snapshot: makeSnapshot(),
            primaryDisplayHeight: 1080,
            displays: [d1]
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertNotNil(result[.window(1)])
        XCTAssertNil(result[.window(2)], "mid window is covered by top — no border")
        XCTAssertNil(result[.window(3)], "bottom window is covered — no border")
    }

    func testOcclusionAdjacentTilesBothBorder() {
        // AeroSpace-style: two side-by-side tiles share an edge but don't
        // overlap. Both must keep their borders.
        let d1 = display(1, cg: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let left = w(1, frame: CGRect(x: 0, y: 0, width: 960, height: 1080))
        let right = w(2, frame: CGRect(x: 960, y: 0, width: 960, height: 1080))
        let inputs = BorderEngineLogic.Inputs(
            orderedWindows: [left, right],
            focusedWindowID: 1,
            snapshot: makeSnapshot(),
            primaryDisplayHeight: 1080,
            displays: [d1]
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertNotNil(result[.window(1)])
        XCTAssertNotNil(result[.window(2)])
    }

    /// focusfx-ogp: BorderEngineLogic trusts `focusedWindowID` (resolved
    /// upstream via SLS in WindowTracker). Same-frame siblings drop out
    /// via occlusion. The SLS resolver picks the visually-front surface;
    /// this test just confirms the engine renders it as active.
    func testBorderEngineTrustsResolvedFocusedWindowID() {
        let d1 = display(1, cg: CGRect(x: -500, y: 0, width: 3000, height: 2000))
        let front = w(33251, pid: 74351, app: "Arc",
                      frame: CGRect(x: -411, y: 1123, width: 2550, height: 1429))
        let mid = w(17013, pid: 74351, app: "Arc",
                    frame: CGRect(x: -411, y: 1123, width: 2400, height: 1429))
        let back = w(33605, pid: 74351, app: "Arc",
                     frame: CGRect(x: -261, y: 1123, width: 2400, height: 1429))
        let inputs = BorderEngineLogic.Inputs(
            orderedWindows: [front, mid, back],
            focusedWindowID: 33251,
            snapshot: makeSnapshot(),
            primaryDisplayHeight: 2000,
            displays: [d1]
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertEqual(result[.window(33251)]?.isActive, true)
        XCTAssertNil(result[.window(17013)], "occlusion drops the same-frame sibling")
        XCTAssertNil(result[.window(33605)], "occlusion drops the overlapping sibling")
    }

    /// focusfx-ogp regression: SLS picks one wid as front, but
    /// `orderedWindows` (CG z-order) has a *different* same-pid sibling
    /// at index 0. Without the active-wid-seeding fix in
    /// `desiredBorders`, the occlusion walk would accept the CG-front
    /// sibling first (rendering it as inactive, since it != focused)
    /// and drop the SLS-chosen window via overlap occlusion. Result: no
    /// bright border visible, faded inactive on the wrong sibling.
    /// With the fix, the focused wid is moved to position 0 of the
    /// iteration order so it always wins the occlusion contest.
    func testActiveWindowSeededFirstWhenSLSAndCGZOrderDisagree() {
        let d1 = display(1, cg: CGRect(x: -500, y: 0, width: 3000, height: 2000))
        // CG z-order has 17013 at index 0 (i.e. CG thinks it's the
        // visually-front Arc surface). SLS, however, returns 33251 as
        // the suitable front-of-pid.
        let zFront = w(17013, pid: 74351, app: "Arc",
                       frame: CGRect(x: -411, y: 1123, width: 2400, height: 1429))
        let slsFront = w(33251, pid: 74351, app: "Arc",
                         frame: CGRect(x: -411, y: 1123, width: 2550, height: 1429))
        let inputs = BorderEngineLogic.Inputs(
            orderedWindows: [zFront, slsFront],
            focusedWindowID: 33251, // SLS truth
            snapshot: makeSnapshot(),
            primaryDisplayHeight: 2000,
            displays: [d1]
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertEqual(result[.window(33251)]?.isActive, true,
                       "SLS-chosen focused wid must keep its active border even if CG z-order would otherwise put a sibling first")
        XCTAssertNil(result[.window(17013)],
                     "the CG-z-order sibling is occluded by the active wid, gets no border")
    }

    /// AeroSpace tile: cycling between same-pid Slack tiles must keep the
    /// AX-focused tile active, because tiles don't overlap so the
    /// front-most-of-pid resolution narrows to whichever tile AeroSpace
    /// raised in CG z-order (which IS the focused one).
    func testTiledSamePidFocusFollowsAerospaceRaise() {
        let d1 = display(1, cg: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        // Two Slack windows tiled side-by-side. AeroSpace raised the right
        // one in z-order (front=2), AX agrees.
        let raised = w(2, pid: 200, app: "Slack",
                       frame: CGRect(x: 960, y: 0, width: 960, height: 1080))
        let other = w(1, pid: 200, app: "Slack",
                      frame: CGRect(x: 0, y: 0, width: 960, height: 1080))
        let inputs = BorderEngineLogic.Inputs(
            orderedWindows: [raised, other],
            focusedWindowID: 2,
            snapshot: makeSnapshot(),
            primaryDisplayHeight: 1080,
            displays: [d1]
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        XCTAssertEqual(result[.window(2)]?.isActive, true)
        XCTAssertEqual(result[.window(1)]?.isActive, false)
    }

    func testHybridNoFocusEmitsNoScreenBorders() {
        let d1 = display(1, cg: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let d2 = display(2, cg: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        let onA = w(1, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        let onB = w(2, frame: CGRect(x: 2100, y: 100, width: 800, height: 600))
        let inputs = BorderEngineLogic.Inputs(
            orderedWindows: [onA, onB],
            focusedWindowID: nil,
            snapshot: makeSnapshot(),
            primaryDisplayHeight: 1080,
            displays: [d1, d2]
        )
        let result = BorderEngineLogic.desiredBorders(inputs)
        // No focus → fall back to per-window borders on both displays, no screen borders.
        XCTAssertNotNil(result[.window(1)])
        XCTAssertNotNil(result[.window(2)])
        XCTAssertFalse(result[.window(1)]!.isActive)
        XCTAssertFalse(result[.window(2)]!.isActive)
        XCTAssertNil(result[.screen(1)])
        XCTAssertNil(result[.screen(2)])
    }

    // MARK: - diff

    private func spec(_ id: WindowID, frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) -> BorderSpec {
        BorderSpec(id: .window(id), frame: frame, width: 5, style: .round,
                   color: BordersConfig.default.active, isActive: true)
    }

    func testDiffEmptyToNonEmptyIsAllCreate() {
        let next: [BorderID: BorderSpec] = [.window(1): spec(1), .window(2): spec(2)]
        let d = BorderEngineLogic.diff(prev: [:], next: next)
        XCTAssertEqual(d.toCreate.count, 2)
        XCTAssertTrue(d.toUpdate.isEmpty)
        XCTAssertTrue(d.toDestroy.isEmpty)
    }

    func testDiffNonEmptyToEmptyIsAllDestroy() {
        let prev: [BorderID: BorderSpec] = [.window(1): spec(1), .window(2): spec(2)]
        let d = BorderEngineLogic.diff(prev: prev, next: [:])
        XCTAssertEqual(d.toDestroy, [.window(1), .window(2)])
        XCTAssertTrue(d.toCreate.isEmpty)
        XCTAssertTrue(d.toUpdate.isEmpty)
    }

    func testDiffSameSpecsIsNoop() {
        let s = spec(1)
        let d = BorderEngineLogic.diff(prev: [.window(1): s], next: [.window(1): s])
        XCTAssertTrue(d.toCreate.isEmpty)
        XCTAssertTrue(d.toUpdate.isEmpty)
        XCTAssertTrue(d.toDestroy.isEmpty)
    }

    func testDiffChangedSpecGoesIntoUpdate() {
        let prev = spec(1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let next = spec(1, frame: CGRect(x: 50, y: 50, width: 100, height: 100))
        let d = BorderEngineLogic.diff(prev: [.window(1): prev], next: [.window(1): next])
        XCTAssertEqual(d.toUpdate.count, 1)
        XCTAssertTrue(d.toCreate.isEmpty)
        XCTAssertTrue(d.toDestroy.isEmpty)
    }

    func testDiffMixedScenario() {
        let prev: [BorderID: BorderSpec] = [
            .window(1): spec(1, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            .window(2): spec(2),
        ]
        let next: [BorderID: BorderSpec] = [
            .window(1): spec(1, frame: CGRect(x: 10, y: 10, width: 100, height: 100)),
            .window(3): spec(3),
        ]
        let d = BorderEngineLogic.diff(prev: prev, next: next)
        XCTAssertEqual(d.toUpdate.map(\.id), [.window(1)])
        XCTAssertEqual(d.toCreate.map(\.id), [.window(3)])
        XCTAssertEqual(d.toDestroy, [.window(2)])
    }
}
