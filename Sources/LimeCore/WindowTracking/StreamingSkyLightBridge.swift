import CSkyLight
import CoreGraphics
import Foundation
import os

/// SLS-event-driven `WindowServerBridge`.
///
/// Design (per advisor on focusfx-b13):
///   * Wraps a `CGWindowListBridge` for `enumerateOnScreenWindows()`. We do
///     NOT swap to `SLSCopyWindowsWithOptionsAndTags` in this pass — that's
///     a second axis of risk (Space-membership semantics differ, ordering
///     differs from CGWindowList z-order which `WindowTracker.orderedIDs`
///     depends on for the occlusion filter).
///   * Layers SLS event subscriptions on top: every event in
///     `SLSEventClass.allCases` is registered through the resolved
///     `SLSRegisterNotifyProc`.
///   * The C callback is `@convention(c)` and cannot capture self. We pass
///     `Unmanaged.passUnretained(self)` as the `userInfo` context, decode
///     it in the trampoline, and immediately hop to the tracker queue. NO
///     work runs on the SLS-callback thread.
///   * "Refresh becomes optional" (b13 acceptance): every received event
///     calls `onEvent` which the WindowTracker wires to its existing
///     `scheduleDebouncedRefresh()`. Incremental cache mutation from the
///     event payload is a follow-up — it would require rewriting the
///     diff/coalesce path and is explicitly out of scope here.
///
/// Graceful degradation: if `symbols.canStream == false`, this initialiser
/// still succeeds, but `start()` is a no-op and `isStreaming` stays false.
/// The wrapper still answers `enumerateOnScreenWindows()` via the public
/// bridge so the daemon never loses its primary update path.
public final class StreamingSkyLightBridge: WindowServerBridge, @unchecked Sendable {
    public typealias EventHandler = @Sendable (SLSEventClass) -> Void

    private let inner: WindowServerBridge
    private let symbols: SkyLightSymbols
    private let deliveryQueue: DispatchQueue
    private let lock = OSAllocatedUnfairLock()
    private var handler: EventHandler?
    private var started = false
    private var connectionID: CGSConnectionID = 0

    public init(
        wrapping inner: WindowServerBridge = CGWindowListBridge(),
        symbols: SkyLightSymbols = .resolveFromSkyLight()
    ) {
        self.inner = inner
        self.symbols = symbols
        self.deliveryQueue = DispatchQueue(label: "dev.abhirup.lime.sls", qos: .userInitiated)
    }

    public var isStreaming: Bool {
        lock.withLock { started }
    }

    public func enumerateOnScreenWindows() -> [WindowState] {
        inner.enumerateOnScreenWindows()
    }

    /// Subscribe to SLS events. `handler` runs on `dispatchQueue`; events
    /// are delivered there one at a time. Returns the queue events will be
    /// delivered on so callers can hop to their own tracker queue from it.
    ///
    /// Called once at WindowTracker startup. Idempotent: a second call
    /// while already streaming is a no-op.
    @discardableResult
    public func start(
        dispatchQueue: DispatchQueue,
        handler: @escaping EventHandler
    ) -> Bool {
        guard symbols.canStream,
              let getCID = symbols.mainConnectionID,
              let register = symbols.registerNotifyProc
        else {
            Log.tracker.notice("SLS streaming unavailable — falling through to public-API refresh path")
            return false
        }

        return lock.withLock {
            if started { return true }

            connectionID = getCID()
            // Wrap the user handler in a queue-hop. The C trampoline calls
            // `invokeHandler`, which calls this closure synchronously; the
            // closure itself bounces to the caller's queue before doing
            // anything real, so the SLS callback thread does no work
            // beyond an opaque-pointer decode + dispatch_async.
            let userHandler = handler
            self.handler = { eventClass in
                dispatchQueue.async {
                    userHandler(eventClass)
                }
            }

            // The trampoline decodes the userInfo back into self. Use
            // passUnretained: the bridge outlives any in-flight callback
            // because `stop()` is the only path that drops it, and stop()
            // is currently a TODO — the bridge lives for the daemon's
            // lifetime. (If we add stop, we must serialise it against
            // pending callbacks.)
            let context = Unmanaged.passUnretained(self).toOpaque()

            var anyRegistered = false
            for evt in SLSEventClass.allCases {
                let err = register(slsTrampoline, evt.rawValue, context)
                if err == .success {
                    anyRegistered = true
                } else {
                    Log.tracker.fault("SLSRegisterNotifyProc failed for event \(evt.rawValue, privacy: .public): \(err.rawValue, privacy: .public)")
                }
            }

            if !anyRegistered {
                Log.tracker.fault("SLS streaming: zero events subscribed; bridge stays in non-streaming mode")
                self.handler = nil
                return false
            }

            started = true
            Log.tracker.info("SLS streaming online (cid=\(self.connectionID, privacy: .public))")
            return true
        }
    }

    /// Test hook: simulate a callback as if it came from SLS. Lets us verify
    /// the trampoline decode + queue-hop + handler invocation without
    /// touching real SLS.
    public func _testFireEvent(_ eventClass: SLSEventClass) {
        invokeHandler(eventClass)
    }

    fileprivate func invokeHandler(_ eventClass: SLSEventClass) {
        let h = lock.withLock { handler }
        h?(eventClass)
    }
}

/// `@convention(c)` trampoline. Cannot capture context; we passed `self`
/// as opaque `userInfo`. Decodes it back, then dispatches synchronously
/// to `invokeHandler`, which itself queue-hops before doing any real work.
/// This keeps the SLS callback thread free of locks / Swift runtime work
/// beyond the bare minimum.
private let slsTrampoline: SLSNotifyProc = { type, _, _, userInfo, _ in
    guard let userInfo,
          let evt = SLSEventClass(rawValue: type)
    else { return }
    let bridge = Unmanaged<StreamingSkyLightBridge>.fromOpaque(userInfo).takeUnretainedValue()
    bridge.invokeHandler(evt)
}
