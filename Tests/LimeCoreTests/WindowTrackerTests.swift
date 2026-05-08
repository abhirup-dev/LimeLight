import XCTest
import CoreGraphics
import Foundation
import os
@testable import LimeCore

final class WindowTrackerTests: XCTestCase {
    func testStartupEnumerationPopulatesCache() {
        let server = StubServerBridge(initial: [
            WindowState(windowID: 1, ownerPID: 100, appName: "Warp", title: "ssh"),
            WindowState(windowID: 2, ownerPID: 200, appName: "Finder", title: "Downloads"),
        ])
        let ax = StubAXBridge()
        let tracker = WindowTracker(server: server, ax: ax, axObservers: NoopAXWindowObserverManager())
        tracker.start()

        let snap = waitForSnapshot(tracker, expectedCount: 2)
        XCTAssertEqual(snap.count, 2)
        XCTAssertTrue(snap.contains { $0.windowID == 1 && $0.appName == "Warp" })
    }

    func testRefreshReplacesCache() {
        let server = StubServerBridge(initial: [
            WindowState(windowID: 1, ownerPID: 100, appName: "Warp", title: "old"),
        ])
        let tracker = WindowTracker(server: server, ax: StubAXBridge(), axObservers: NoopAXWindowObserverManager())
        tracker.start()
        _ = waitForSnapshot(tracker, expectedCount: 1)

        server.set([
            WindowState(windowID: 1, ownerPID: 100, appName: "Warp", title: "new"),
            WindowState(windowID: 5, ownerPID: 300, appName: "Cursor", title: "main.swift"),
        ])
        tracker.refresh()
        let snap = waitForSnapshot(tracker, expectedCount: 2)
        XCTAssertEqual(snap.count, 2)
        XCTAssertTrue(snap.contains { $0.windowID == 5 && $0.appName == "Cursor" })
        XCTAssertEqual(snap.first { $0.windowID == 1 }?.title, "new")
    }

    func testFocusResolvedFromAXBridge() {
        let server = StubServerBridge(initial: [
            WindowState(windowID: 10, ownerPID: 100, appName: "Warp", title: "alpha"),
            WindowState(windowID: 11, ownerPID: 100, appName: "Warp", title: "beta"),
            WindowState(windowID: 20, ownerPID: 200, appName: "Finder", title: "Downloads"),
        ])
        let ax = StubAXBridge(focusedPID: 100, focusedTitle: "beta", status: .granted)
        let tracker = WindowTracker(server: server, ax: ax, axObservers: NoopAXWindowObserverManager())
        tracker.start()
        _ = waitForSnapshot(tracker, expectedCount: 3)

        let focusedID = waitForFocus(tracker, expected: 11)
        XCTAssertEqual(focusedID, 11)
        XCTAssertEqual(tracker.currentFocusedWindow?.title, "beta")
    }

    func testNoFocusWhenAXDenied() {
        let server = StubServerBridge(initial: [
            WindowState(windowID: 1, ownerPID: 100, appName: "Warp"),
        ])
        let ax = StubAXBridge(status: .denied)
        let tracker = WindowTracker(server: server, ax: ax, axObservers: NoopAXWindowObserverManager())
        tracker.start()
        _ = waitForSnapshot(tracker, expectedCount: 1)
        // Allow the focus pass to finish.
        let exp = expectation(description: "drain")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertNil(tracker.currentFocusedWindowID)
        XCTAssertEqual(tracker.accessibility, .denied)
    }

    func testBundleIdentifierBackfilledFromAX() {
        let server = StubServerBridge(initial: [
            WindowState(windowID: 1, ownerPID: 100, appName: "Warp", bundleIdentifier: nil),
        ])
        let ax = StubAXBridge(bundleIDsByPID: [100: "dev.warp.Warp"])
        let tracker = WindowTracker(server: server, ax: ax, axObservers: NoopAXWindowObserverManager())
        tracker.start()
        let snap = waitForSnapshot(tracker, expectedCount: 1)
        XCTAssertEqual(snap.first?.bundleIdentifier, "dev.warp.Warp")
    }

    // focusfx-sf2: setUseAXFocusOnly is the JankyBorders `ax_focus=on`
    // escape hatch. Toggling it must (a) be idempotent, (b) keep the AX
    // resolution path working — this proves the SLS-bypass branch in
    // recomputeFocus actually runs the AX fallback.
    func testAXFocusOnlyTogglePreservesAXResolution() {
        let server = StubServerBridge(initial: [
            WindowState(windowID: 7, ownerPID: 100, appName: "Warp", title: "alpha"),
        ])
        let ax = StubAXBridge(focusedPID: 100, focusedTitle: "alpha", status: .granted)
        // Pass slsActiveWindow=nil so we know the SLS branch is unreachable
        // and any focus we observe is from the AX fallback regardless of
        // useAXFocusOnly's value.
        let tracker = WindowTracker(server: server, ax: ax, axObservers: NoopAXWindowObserverManager(), slsActiveWindow: nil)
        tracker.start()
        _ = waitForSnapshot(tracker, expectedCount: 1)
        XCTAssertEqual(waitForFocus(tracker, expected: 7), 7)

        tracker.setUseAXFocusOnly(true)
        XCTAssertEqual(waitForFocus(tracker, expected: 7), 7, "ax_focus=on must not break AX resolution")
        tracker.setUseAXFocusOnly(true) // idempotent
        XCTAssertEqual(tracker.currentFocusedWindowID, 7)
        tracker.setUseAXFocusOnly(false)
        XCTAssertEqual(waitForFocus(tracker, expected: 7), 7, "ax_focus=off must not break AX resolution")
    }

    // MARK: - helpers

    private func waitForSnapshot(_ tracker: WindowTracker, expectedCount: Int, timeout: TimeInterval = 2) -> [WindowState] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snap = tracker.snapshot
            if snap.count == expectedCount { return snap }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return tracker.snapshot
    }

    private func waitForFocus(_ tracker: WindowTracker, expected: WindowID, timeout: TimeInterval = 2) -> WindowID? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if tracker.currentFocusedWindowID == expected { return expected }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return tracker.currentFocusedWindowID
    }
}

// MARK: - stubs

private final class StubServerBridge: WindowServerBridge, @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var windows: [WindowState]
    var isStreaming: Bool { false }

    init(initial: [WindowState]) { self.windows = initial }

    func enumerateOnScreenWindows() -> [WindowState] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return windows
    }

    func set(_ windows: [WindowState]) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        self.windows = windows
    }
}

private final class StubAXBridge: AXBridge, @unchecked Sendable {
    let focusedPID: Int32?
    let focusedTitle: String?
    let _status: AccessibilityStatus
    let bundleIDsByPID: [Int32: String]

    init(
        focusedPID: Int32? = nil,
        focusedTitle: String? = nil,
        status: AccessibilityStatus = .granted,
        bundleIDsByPID: [Int32: String] = [:]
    ) {
        self.focusedPID = focusedPID
        self.focusedTitle = focusedTitle
        self._status = status
        self.bundleIDsByPID = bundleIDsByPID
    }

    var status: AccessibilityStatus { _status }

    func focusedWindow() -> (pid: Int32, title: String?, cgWindowID: CGWindowID?)? {
        guard _status == .granted, let pid = focusedPID else { return nil }
        return (pid, focusedTitle, nil)
    }

    func bundleIdentifier(for pid: Int32) -> String? { bundleIDsByPID[pid] }
    func appName(for pid: Int32) -> String? { nil }
    func axWindowIDs(for pid: Int32) -> Set<CGWindowID>? { nil }
}
