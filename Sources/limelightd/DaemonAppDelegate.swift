import AppKit
import Foundation
import LimeCore

final class DaemonAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let startedAt = Date()
    private let router = IPCRouter()
    private var ipcServer: IPCServer?
    private let configStore = ConfigStore(path: Lime.resolvedConfigPath)
    private lazy var windowTracker = WindowTracker(coalesceMs: 16) { [weak self] batch in
        self?.borderEngine?.handleCoalescedBatch(batch)
    }
    private var borderEngine: BorderEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainThreadBudget("daemon.didFinishLaunching") {
            installStatusItem()
        }
        // Initial config load runs off-main; we keep the built-in defaults until it returns.
        configStore.loadAsync { result in
            if let err = result.parseError {
                Log.config.error("initial config load failed: \(err, privacy: .public)")
            }
        }
        registerCommands()
        startIPCServer()
        promptAccessibilityIfNeeded()
        startBorderEngine()
        windowTracker.start()
        windowTracker.onFocusChange { wid in
            Log.tracker.debug("focus changed -> \(wid.map { "\($0)" } ?? "nil", privacy: .public)")
        }
        Log.core.info("LimeLight daemon ready")
    }

    private func startBorderEngine() {
        let engine = BorderEngine(tracker: windowTracker, configStore: configStore)
        self.borderEngine = engine
        // Initial paint after the first window enumeration finishes —
        // schedule slightly behind the tracker startup tick.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [weak engine] in
            engine?.recompute()
        }
    }

    /// First-launch: nudge macOS to show the Accessibility prompt for this binary.
    /// On subsequent launches with permission already granted, this is a cheap no-op.
    /// Runs off-main; the system's TCC dialog is its own UI process.
    private func promptAccessibilityIfNeeded() {
        DispatchQueue.global(qos: .userInitiated).async {
            let bridge = RealAXBridge()
            if bridge.status == .denied {
                _ = bridge.requestPermission()
                Log.core.notice("Accessibility prompt presented; restart LimeLight after granting.")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.core.notice("LimeLight daemon terminating")
        ipcServer?.stop()
    }

    private func registerCommands() {
        let cachedInfo = info()
        let tracker = windowTracker
        router.register("status") { req in
            // Cached snapshot — no main-thread fan-out, no full window rescan.
            do {
                let info = try IPCCoding.makeEncoder().encode(cachedInfo)
                guard var dict = try JSONSerialization.jsonObject(with: info) as? [String: Any] else {
                    return IPCResponse.failure(id: req.id, code: "encode_failed", message: "unexpected status shape")
                }
                dict["accessibility"] = tracker.accessibility.rawValue
                dict["windowCount"] = tracker.snapshot.count
                let merged = try JSONSerialization.data(withJSONObject: dict, options: [])
                let any = try IPCCoding.makeDecoder().decode(AnyCodable.self, from: merged)
                return IPCResponse.success(id: req.id, result: any)
            } catch {
                return IPCResponse.failure(id: req.id, code: "encode_failed", message: "\(error)")
            }
        }

        router.register("windows.snapshot") { req in
            let windows = tracker.snapshot.sorted { $0.windowID < $1.windowID }
            let entries: [AnyCodable] = windows.map { w in
                AnyCodable([
                    "windowID": AnyCodable(Int(w.windowID)),
                    "ownerPID": AnyCodable(Int(w.ownerPID)),
                    "appName": AnyCodable(w.appName ?? NSNull()),
                    "bundleIdentifier": AnyCodable(w.bundleIdentifier ?? NSNull()),
                    "title": AnyCodable(w.title ?? NSNull()),
                    "frame": AnyCodable([
                        "x": AnyCodable(Double(w.frame.origin.x)),
                        "y": AnyCodable(Double(w.frame.origin.y)),
                        "width": AnyCodable(Double(w.frame.size.width)),
                        "height": AnyCodable(Double(w.frame.size.height)),
                    ] as [String: AnyCodable]),
                    "isOnScreen": AnyCodable(w.isOnScreen),
                ] as [String: AnyCodable])
            }
            return IPCResponse.success(id: req.id, result: AnyCodable([
                "count": AnyCodable(entries.count),
                "windows": AnyCodable(entries),
                "focusedWindowID": AnyCodable(tracker.currentFocusedWindowID.map { Int($0) } ?? NSNull()),
            ] as [String: AnyCodable]))
        }

        router.register("current-window") { req in
            guard let w = tracker.currentFocusedWindow else {
                return IPCResponse.success(id: req.id, result: AnyCodable(NSNull()))
            }
            return IPCResponse.success(id: req.id, result: AnyCodable([
                "windowID": AnyCodable(Int(w.windowID)),
                "ownerPID": AnyCodable(Int(w.ownerPID)),
                "appName": AnyCodable(w.appName ?? NSNull()),
                "title": AnyCodable(w.title ?? NSNull()),
            ] as [String: AnyCodable]))
        }
        router.register("ping") { req in
            IPCResponse.success(id: req.id, result: AnyCodable("pong"))
        }
        router.register("quit") { req in
            DispatchQueue.main.async {
                Log.core.notice("quit requested via IPC")
                NSApp.terminate(nil)
            }
            return IPCResponse.success(id: req.id, result: AnyCodable("terminating"))
        }

        // `reload`: re-read the config file off-main and publish if valid.
        // Synchronous from the IPC worker's perspective so the response carries the outcome.
        let store = configStore
        router.register("reload") { req in
            let result = store.loadSync()
            return Self.encodeReloadResponse(id: req.id, result: result)
        }

        // `config.validate`: parse the file (or text supplied via args.text) and report
        // diagnostics WITHOUT publishing if invalid. Used by `limelight config validate`.
        router.register("config.validate") { req in
            // Reuse the daemon's store path; future args could supply alternative text.
            let result = store.loadSync()
            return Self.encodeReloadResponse(id: req.id, result: result, validateOnly: true)
        }

        router.register("config.path") { req in
            IPCResponse.success(id: req.id, result: AnyCodable(store.path))
        }

        // Border runtime overrides (focusfx-14.3). The shim binary forwards
        // JankyBorders args here as `borders.style`. CLI subcommands route to
        // the boolean / redraw helpers.
        router.register("borders.style") { [weak self] req in
            guard let engine = self?.borderEngine else {
                return IPCResponse.failure(id: req.id, code: "engine_unavailable", message: "border engine not started")
            }
            let args = req.args ?? [:]
            do {
                let parsed = try BordersStyleRequestDecoder.decode(from: args)
                engine.applyStyleRequest(parsed)
                return IPCResponse.success(id: req.id, result: AnyCodable([
                    "applied": AnyCodable(true),
                    "perWindow": AnyCodable(parsed.applyTo != nil),
                ] as [String: AnyCodable]))
            } catch {
                return IPCResponse.failure(id: req.id, code: "bad_args", message: "\(error)")
            }
        }
        router.register("borders.enable") { [weak self] req in
            guard let engine = self?.borderEngine else {
                return IPCResponse.failure(id: req.id, code: "engine_unavailable", message: "border engine not started")
            }
            engine.setEnabled(true)
            return IPCResponse.success(id: req.id, result: AnyCodable("enabled"))
        }
        router.register("borders.disable") { [weak self] req in
            guard let engine = self?.borderEngine else {
                return IPCResponse.failure(id: req.id, code: "engine_unavailable", message: "border engine not started")
            }
            engine.setEnabled(false)
            return IPCResponse.success(id: req.id, result: AnyCodable("disabled"))
        }
        router.register("borders.redrawAll") { [weak self] req in
            guard let engine = self?.borderEngine else {
                return IPCResponse.failure(id: req.id, code: "engine_unavailable", message: "border engine not started")
            }
            engine.redrawAll()
            return IPCResponse.success(id: req.id, result: AnyCodable("redrawing"))
        }
        router.register("borders.clearOverrides") { [weak self] req in
            guard let engine = self?.borderEngine else {
                return IPCResponse.failure(id: req.id, code: "engine_unavailable", message: "border engine not started")
            }
            engine.clearOverrides()
            return IPCResponse.success(id: req.id, result: AnyCodable("cleared"))
        }
    }

    private static func encodeReloadResponse(
        id: String,
        result: ConfigStore.LoadResult,
        validateOnly: Bool = false
    ) -> IPCResponse {
        let payload: [String: AnyCodable] = [
            "ok": AnyCodable(result.parseError == nil),
            "applied": AnyCodable(!validateOnly && result.replacedActive),
            "diagnostics": AnyCodable(result.snapshot.diagnostics.map { d -> AnyCodable in
                AnyCodable([
                    "severity": AnyCodable(d.severity.rawValue),
                    "path": AnyCodable(d.path),
                    "message": AnyCodable(d.message),
                ] as [String: AnyCodable])
            }),
            "parseError": AnyCodable(result.parseError ?? NSNull()),
        ]
        return IPCResponse.success(id: id, result: AnyCodable(payload))
    }

    private func startIPCServer() {
        let server = IPCServer(socketPath: Lime.resolvedSocketPath, router: router)
        do {
            try server.start()
            self.ipcServer = server
        } catch {
            FileHandle.standardError.write(Data("LimeLight: \(error)\n".utf8))
            Log.core.fault("IPC server failed to start: \(String(describing: error), privacy: .public)")
            // Singleton daemon contract: refuse to keep running without a control plane.
            NSApp.terminate(nil)
            exit(1)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "✦"
            button.toolTip = "LimeLight \(Lime.version)"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "LimeLight \(Lime.version)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LimeLight", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        self.statusItem = item
    }

    @objc private func reloadConfig() {
        Log.core.info("reload requested from menu — config reload lands in the planned phase")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func info() -> DaemonInfo {
        DaemonInfo(
            version: Lime.version,
            pid: getpid(),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.abhirup.lime",
            socketPath: Lime.resolvedSocketPath,
            configPath: Lime.resolvedConfigPath,
            startedAt: startedAt
        )
    }
}
