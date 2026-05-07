import XCTest
@testable import LimeCore

final class WindowEventCoalescerTests: XCTestCase {
    func testBurstCollapsesToSingleUpdatePerWindow() {
        let exp = expectation(description: "batch delivered")
        let captured = Locked<[CoalescedUpdate]>([])
        let coalescer = WindowEventCoalescer(coalesceMs: 10) { batch in
            captured.set(batch)
            exp.fulfill()
        }
        for _ in 0..<200 {
            coalescer.enqueue(42, change: .frameChanged)
        }
        wait(for: [exp], timeout: 1)

        let batch = captured.value
        XCTAssertEqual(batch.count, 1, "burst of 200 frame changes for one window must coalesce to one update")
        XCTAssertEqual(batch.first?.windowID, 42)
        XCTAssertEqual(batch.first?.change, .frameChanged)
        // Generation bumped 200 times.
        XCTAssertEqual(coalescer.currentGeneration(for: 42), 200)
    }

    func testMultipleWindowsBatchedTogether() {
        let exp = expectation(description: "batch delivered")
        let captured = Locked<[CoalescedUpdate]>([])
        let coalescer = WindowEventCoalescer(coalesceMs: 10) { batch in
            captured.set(batch)
            exp.fulfill()
        }
        coalescer.enqueue(1, change: .frameChanged)
        coalescer.enqueue(2, change: .focusChanged)
        coalescer.enqueue(3, change: .created)
        wait(for: [exp], timeout: 1)

        let batch = captured.value
        XCTAssertEqual(batch.count, 3)
        XCTAssertEqual(batch.map(\.windowID), [1, 2, 3])
    }

    func testDestroyedAlwaysWins() {
        XCTAssertEqual(WindowEventCoalescer.merge(existing: .frameChanged, next: .destroyed), .destroyed)
        XCTAssertEqual(WindowEventCoalescer.merge(existing: .destroyed, next: .frameChanged), .destroyed)
        XCTAssertEqual(WindowEventCoalescer.merge(existing: .created, next: .destroyed), .destroyed)
    }

    func testCreatedStaysCreatedThroughLaterChanges() {
        XCTAssertEqual(WindowEventCoalescer.merge(existing: .created, next: .frameChanged), .created)
        XCTAssertEqual(WindowEventCoalescer.merge(existing: .created, next: .focusChanged), .created)
    }

    func testFocusChangeDoesNotBumpGeneration() {
        let coalescer = WindowEventCoalescer(coalesceMs: 5) { _ in }
        coalescer.enqueue(7, change: .focusChanged)
        coalescer.enqueue(7, change: .focusChanged)
        XCTAssertEqual(coalescer.currentGeneration(for: 7), 0)
    }

    func testFrameChangeBumpsGeneration() {
        let coalescer = WindowEventCoalescer(coalesceMs: 5) { _ in }
        XCTAssertEqual(coalescer.currentGeneration(for: 9), 0)
        coalescer.enqueue(9, change: .frameChanged)
        XCTAssertEqual(coalescer.currentGeneration(for: 9), 1)
        coalescer.enqueue(9, change: .frameChanged)
        XCTAssertEqual(coalescer.currentGeneration(for: 9), 2)
    }

    func testStaleGenerationGuardRejectsOldWork() {
        // Async border-render simulation. The consumer captures generation N at
        // dispatch time; a newer change makes it N+1; the consumer's apply()
        // checks the snapshot and discards.
        let coalescer = WindowEventCoalescer(coalesceMs: 5) { _ in }
        coalescer.enqueue(11, change: .frameChanged)
        let captured = coalescer.currentGeneration(for: 11)
        XCTAssertEqual(captured, 1)
        // Newer event arrives.
        coalescer.enqueue(11, change: .frameChanged)
        XCTAssertEqual(coalescer.currentGeneration(for: 11), 2)
        // Consumer would do: if currentGeneration(for: 11) != captured { drop }
        XCTAssertNotEqual(coalescer.currentGeneration(for: 11), captured)
    }

    func testQueueBoundedByDistinctWindowsNotBurstLength() {
        let coalescer = WindowEventCoalescer(coalesceMs: 50) { _ in }
        // 10,000 events for 5 windows -> pendingCount stays at 5.
        for i in 0..<10_000 {
            coalescer.enqueue(WindowID(i % 5), change: .frameChanged)
        }
        XCTAssertEqual(coalescer.pendingCount, 5)
    }

    func testFlushNowDrainsPending() {
        let exp = expectation(description: "flushed")
        let captured = Locked<[CoalescedUpdate]>([])
        let coalescer = WindowEventCoalescer(coalesceMs: 10_000) { b in
            captured.set(b)
            exp.fulfill()
        }
        coalescer.enqueue(1, change: .frameChanged)
        coalescer.enqueue(2, change: .created)
        coalescer.flushNow()
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(captured.value.count, 2)
    }

    func testSingleScheduledTickPerCoalesceWindow() {
        // A burst of enqueues should result in exactly one delivery, not N.
        let deliveries = Locked<Int>(0)
        let exp = expectation(description: "one tick")
        let coalescer = WindowEventCoalescer(coalesceMs: 20) { _ in
            deliveries.mutate { $0 += 1 }
            exp.fulfill()
        }
        for _ in 0..<500 {
            coalescer.enqueue(1, change: .frameChanged)
        }
        wait(for: [exp], timeout: 1)
        // Wait one more coalesce window to ensure no second delivery.
        let waitExp = expectation(description: "no extra tick")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) { waitExp.fulfill() }
        wait(for: [waitExp], timeout: 1)
        XCTAssertEqual(deliveries.value, 1)
    }
}

/// Minimal lock-protected box used by tests to record async output.
final class Locked<T>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "locked")
    private var _value: T
    init(_ initial: T) { self._value = initial }
    var value: T { queue.sync { _value } }
    func set(_ v: T) { queue.sync { _value = v } }
    func mutate(_ f: (inout T) -> Void) { queue.sync { f(&_value) } }
}
