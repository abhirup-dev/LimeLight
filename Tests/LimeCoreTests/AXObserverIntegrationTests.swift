import XCTest
import CoreGraphics
import Foundation
import os
@testable import LimeCore

/// Integration tests for focusfx-1hr: WindowTracker re-enumerates when its
/// AXWindowObserverManager fires `onChange`, and bursts of events collapse
/// into a single re-enumeration via the debouncer.
final class AXObserverIntegrationTests: XCTestCase {
    func testAXObserverChangeTriggersReEnumeration() {
        let server = MutableServerBridge(initial: [
            WindowState(windowID: 1, ownerPID: 100, appName: "Warp",
                        title: "old", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        ])
        let observers = StubAXObserverManager()
        let tracker = WindowTracker(
            server: server,
            ax: StubAXBridgeForObs(),
            axObservers: observers
        )
        tracker.start()
        _ = waitForCount(tracker, 1)

        // Simulate AeroSpace teleporting the window.
        server.set([
            WindowState(windowID: 1, ownerPID: 100, appName: "Warp",
                        title: "old", frame: CGRect(x: -9999, y: 0, width: 100, height: 100))
        ])

        // No NSWorkspace activation — without the AX path, the cache stays stale.
        // Now fire an AX move event.
        observers.fire()

        let after = waitForFrame(tracker, windowID: 1, expectedX: -9999)
        XCTAssertEqual(after?.frame.origin.x, -9999, "AX onChange must trigger a re-enumeration")
    }

    func testBurstOfAXEventsCollapsesToOneEnumeration() {
        let server = CountingServerBridge(initial: [
            WindowState(windowID: 1, ownerPID: 100, appName: "Warp",
                        title: "t", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        ])
        let observers = StubAXObserverManager()
        let tracker = WindowTracker(
            server: server,
            ax: StubAXBridgeForObs(),
            axObservers: observers
        )
        tracker.start()
        _ = waitForCount(tracker, 1)
        let baseline = server.callCount

        // Fire ten AX events well within the 16ms debounce window.
        for _ in 0..<10 { observers.fire() }

        // Wait for the debounce to fire + a margin.
        Thread.sleep(forTimeInterval: 0.1)
        let delta = server.callCount - baseline
        XCTAssertEqual(delta, 1, "ten AX events in <16ms should collapse to ONE re-enumeration, got \(delta)")
    }

    func testStopReleasesAXObservers() {
        let observers = StubAXObserverManager()
        let tracker = WindowTracker(
            server: MutableServerBridge(initial: []),
            ax: StubAXBridgeForObs(),
            axObservers: observers
        )
        tracker.start()
        XCTAssertTrue(observers.started)
        tracker.stop()
        XCTAssertFalse(observers.started, "stop() must call axObservers.stop()")
    }

    // MARK: - helpers

    private func waitForCount(_ t: WindowTracker, _ n: Int, timeout: TimeInterval = 2) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if t.snapshot.count == n { return n }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return t.snapshot.count
    }

    private func waitForFrame(_ t: WindowTracker, windowID: WindowID, expectedX: CGFloat,
                              timeout: TimeInterval = 2) -> WindowState? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let w = t.snapshot.first(where: { $0.windowID == windowID }),
               w.frame.origin.x == expectedX {
                return w
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return t.snapshot.first(where: { $0.windowID == windowID })
    }
}

// MARK: - test doubles

/// AXWindowObserverManager that surfaces a test-controlled trigger.
private final class StubAXObserverManager: AXWindowObserverManager, @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var queue: DispatchQueue?
    private var handler: (@Sendable () -> Void)?
    private(set) var started = false

    func start(deliveryQueue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        self.queue = deliveryQueue
        self.handler = onChange
        self.started = true
    }

    func stop() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        self.queue = nil
        self.handler = nil
        self.started = false
    }

    /// Simulate an AX move/resize/etc. — what the real manager would
    /// dispatch from its callback.
    func fire() {
        os_unfair_lock_lock(&lock)
        let q = queue, h = handler
        os_unfair_lock_unlock(&lock)
        guard let q, let h else { return }
        q.async { h() }
    }
}

/// Minimal bridge that we can mutate between calls.
private final class MutableServerBridge: WindowServerBridge, @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var windows: [WindowState]
    var isStreaming: Bool { false }
    init(initial: [WindowState]) { self.windows = initial }
    func enumerateOnScreenWindows() -> [WindowState] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return windows
    }
    func set(_ w: [WindowState]) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        self.windows = w
    }
}

/// Same as above but counts how many times enumerate was called.
private final class CountingServerBridge: WindowServerBridge, @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var windows: [WindowState]
    private var _callCount = 0
    var isStreaming: Bool { false }
    init(initial: [WindowState]) { self.windows = initial }
    var callCount: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return _callCount
    }
    func enumerateOnScreenWindows() -> [WindowState] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        _callCount += 1
        return windows
    }
}

private final class StubAXBridgeForObs: AXBridge, @unchecked Sendable {
    var status: AccessibilityStatus { .granted }
    func focusedWindow() -> (pid: Int32, title: String?)? { nil }
    func bundleIdentifier(for pid: Int32) -> String? { nil }
    func appName(for pid: Int32) -> String? { nil }
}
