import AppKit
import ApplicationServices
import Foundation

/// Per-pid AXObserver registry. Push-based source of "the window state
/// has likely changed" events so the WindowTracker cache stays fresh
/// without polling. Solves focusfx-l4i (phantom borders after AeroSpace
/// workspace switches): without these observers, the only refresh trigger
/// was NSWorkspace.didActivateApplicationNotification, which never fires
/// when AeroSpace teleports a frame within the same frontmost app.
///
/// Why AX (and not just CGWindowList polling):
///   - CGWindowList itself has no notification mechanism. We'd have to
///     poll on a timer; a 100–250ms timer either burns idle CPU or shows
///     visible staleness during fast workspace switches. PLAN.md targets
///     idle CPU < 1%, so polling is off the table.
///   - AX events are push and free at idle. They fire whenever an app's
///     own window state changes — including AeroSpace's frame teleports,
///     because AeroSpace moves windows by setting their AX position.
///
/// Why we use a single coarse "something changed" callback instead of
/// per-window targeted updates:
///   - CGWindowList re-enumeration is microseconds. The existing diff +
///     coalesce path in WindowTracker is tuned to absorb bursts.
///   - AX → CGWindowID resolution is itself an AX-heavy main-thread
///     operation; doing it per event would be costlier than just
///     re-enumerating everything.
///   - Simpler invariant: "any AX event from any observed app means
///     re-enumerate." Easier to reason about and fewer code paths.
///
/// Threading model:
///   - `AXObserverGetRunLoopSource(observer)` is added to the main run
///     loop. AX callbacks therefore fire on the main thread.
///   - The C callback resolves the manager via the unretained refcon
///     pointer and immediately hops to the caller-supplied delivery queue
///     (typically WindowTracker.trackerQueue). Main-thread is freed
///     instantly; we never run cache work there.
///
/// Lifecycle:
///   - `start()` snapshots running apps and attaches observers, then
///     listens to NSWorkspace launch/terminate notifications to keep the
///     pid → observer map in sync as apps come and go.
///   - On `kAXWindowCreatedNotification`, the manager attaches the
///     window-level observers to the new element so its first move/resize
///     also fires (otherwise we'd only see the create and nothing else).
///   - The daemon's own pid is skipped — observing our own status item
///     would just create noise.
public protocol AXWindowObserverManager: AnyObject, Sendable {
    /// Begin observing every running app and stay subscribed across launches
    /// and terminations. The handler fires on `deliveryQueue` whenever any
    /// observed event indicates the window state may have changed.
    func start(deliveryQueue: DispatchQueue, onChange: @escaping @Sendable () -> Void)

    /// Stop observing and release every AXObserver.
    func stop()
}

/// No-op manager used in tests + when the AX bridge is unavailable.
public final class NoopAXWindowObserverManager: AXWindowObserverManager, @unchecked Sendable {
    public init() {}
    public func start(deliveryQueue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {}
    public func stop() {}
}

public final class RealAXWindowObserverManager: AXWindowObserverManager, @unchecked Sendable {
    private let installQueue = DispatchQueue(label: "dev.abhirup.lime.ax-observers", qos: .userInitiated)
    private var perApp: [pid_t: AXObserver] = [:]
    private var deliveryQueue: DispatchQueue?
    private var onChange: (@Sendable () -> Void)?
    private var launchObs: NSObjectProtocol?
    private var terminateObs: NSObjectProtocol?

    /// Notifications observed on each *application* element.
    ///
    /// - WindowCreated: catches new windows. The handler attaches the
    ///   window-level notifications to the new element so its first
    ///   move/resize will fire normally.
    /// - FocusedWindowChanged: in-app focus shifts (e.g. moving between
    ///   tabs/panes the host treats as separate windows). Covers cases
    ///   `didActivateApplication` misses because the app didn't change.
    /// - ApplicationActivated/Deactivated: redundant with NSWorkspace
    ///   activation but cheap, and serves as a backstop if the
    ///   NSWorkspace observer ever drops a notification.
    private static let appLevelNotifications: [String] = [
        kAXWindowCreatedNotification as String,
        kAXFocusedWindowChangedNotification as String,
        kAXApplicationActivatedNotification as String,
        kAXApplicationDeactivatedNotification as String,
    ]

    /// Notifications observed on each *window* element.
    ///
    /// - Moved/Resized: cover the AeroSpace teleport path (hideInCorner
    ///   moves frames to ±W off the monitor). Without these, a workspace
    ///   switch silently strands stale frames in our cache. This is the
    ///   primary fix for focusfx-l4i.
    /// - Miniaturized/Deminiaturized: minimize/restore changes
    ///   kCGWindowIsOnscreen but emits no other event, so without these
    ///   we'd keep a border around an invisible (minimized) window.
    /// - UIElementDestroyed: fires when the underlying window is closed
    ///   from inside the app without the app terminating. The next
    ///   enumeration drops the window from cache; we trigger that
    ///   enumeration here.
    private static let windowLevelNotifications: [String] = [
        kAXWindowMovedNotification as String,
        kAXWindowResizedNotification as String,
        kAXWindowMiniaturizedNotification as String,
        kAXWindowDeminiaturizedNotification as String,
        kAXUIElementDestroyedNotification as String,
    ]

    public init() {}

    public func start(deliveryQueue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.deliveryQueue = deliveryQueue
        self.onChange = onChange

        // Hook NSWorkspace lifecycle so we attach to apps as they launch and
        // detach when they terminate. Both fire on a background NSWorkspace
        // queue; we hop to our serial install queue.
        let nc = NSWorkspace.shared.notificationCenter
        launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.installQueue.async { self?.attach(pid: app.processIdentifier) }
        }
        terminateObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.installQueue.async { self?.detach(pid: app.processIdentifier) }
        }

        // Initial sweep: attach to everything currently running.
        installQueue.async { [weak self] in
            for app in NSWorkspace.shared.runningApplications {
                self?.attach(pid: app.processIdentifier)
            }
        }
    }

    public func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        if let t = launchObs { nc.removeObserver(t); launchObs = nil }
        if let t = terminateObs { nc.removeObserver(t); terminateObs = nil }
        installQueue.async { [weak self] in
            self?.perApp.removeAll()
            self?.onChange = nil
        }
    }

    // MARK: - per-app attach/detach

    /// Create an AXObserver for `pid` and register every notification we
    /// care about. Silently no-ops for apps whose AX surface refuses
    /// observation — system services, our own pid, apps without AX support.
    /// Idempotent: a second attach for the same pid is a no-op.
    ///
    /// Order matters here:
    ///   1. AXObserverCreate — make the observer object.
    ///   2. App-level subscriptions — these include WindowCreated, so any
    ///      window that comes into existence between step 3 and step 4
    ///      will still get its window-level subscriptions added in
    ///      `handle()`.
    ///   3. Iterate existing AX windows and subscribe per-window.
    ///   4. Attach the observer's run-loop source to main, so callbacks
    ///      start firing.
    private func attach(pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(installQueue))
        guard pid > 0, perApp[pid] == nil else { return }
        if pid == getpid() { return }

        var observerOpt: AXObserver?
        let createRC = AXObserverCreate(pid, RealAXWindowObserverManager.callback, &observerOpt)
        guard createRC == .success, let observer = observerOpt else { return }

        let app = AXUIElementCreateApplication(pid)
        // Unretained: we own the observer for the same lifetime as `self`,
        // and the observer holds the refcon. No retain cycle, no use-after-
        // free as long as `stop()` runs before deinit (it does — Tracker.stop
        // calls our stop()).
        let context = Unmanaged.passUnretained(self).toOpaque()

        for n in Self.appLevelNotifications {
            // .notificationUnsupported / .invalidUIElement are normal here
            // (system processes, login window, etc.). Silently ignore.
            _ = AXObserverAddNotification(observer, app, n as CFString, context)
        }

        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AXUIElement] {
            for w in windows {
                Self.subscribeWindow(observer: observer, element: w, context: context)
            }
        }

        // Attach the run-loop source LAST. Once attached, callbacks fire on
        // main; doing this before subscriptions would risk a callback firing
        // for an unrelated subscription before we've registered ours.
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        perApp[pid] = observer
    }

    private func detach(pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(installQueue))
        guard let observer = perApp.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        // Releasing observer happens implicitly when the dictionary entry
        // drops the last reference.
    }

    private static func subscribeWindow(observer: AXObserver, element: AXUIElement, context: UnsafeMutableRawPointer) {
        for n in Self.windowLevelNotifications {
            _ = AXObserverAddNotification(observer, element, n as CFString, context)
        }
    }

    // MARK: - AX callback (C-compatible)

    /// AXObserver C callback (must be a free function or a static — captures
    /// would prevent a `@convention(c)` cast). Runs on whichever run loop the
    /// observer's source was attached to (main, in our case).
    /// `refcon` is the unretained `RealAXWindowObserverManager` pointer.
    private static let callback: AXObserverCallback = { observer, element, notification, refcon in
        guard let refcon else { return }
        let manager = Unmanaged<RealAXWindowObserverManager>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        manager.handle(observer: observer, element: element, notification: notification as String)
    }

    /// Dispatch a notification: if it's a window-created event, lazily
    /// attach the per-window subscriptions to the new element so we don't
    /// miss its first move/resize. Then fan out to the subscriber via the
    /// delivery queue.
    private func handle(observer: AXObserver, element: AXUIElement, notification: String) {
        if notification == kAXWindowCreatedNotification as String {
            let context = Unmanaged.passUnretained(self).toOpaque()
            Self.subscribeWindow(observer: observer, element: element, context: context)
        }

        // Every notification we registered for is by construction relevant
        // to border state — no per-event filtering needed here. The
        // WindowTracker debounces a burst into a single re-enumeration.
        if let queue = deliveryQueue, let cb = onChange {
            queue.async { cb() }
        }
    }
}
