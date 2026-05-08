import AppKit
import Foundation
import LimeCore

final class DaemonAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let startedAt = Date()
    private let router = IPCRouter()
    private var ipcServer: IPCServer?
    private let configStore = ConfigStore(path: Lime.resolvedConfigPath)
    /// Window tracker server bridge. Default to the SLS streaming bridge —
    /// it wraps a `CGWindowListBridge` for enumeration and layers SLS
    /// events on top via dlopen+dlsym (focusfx-b13). If private symbols are
    /// missing on this OS, `start()` is a no-op and the tracker keeps
    /// using AX + NSWorkspace observers as the public-API fallback.
    private let windowServerBridge: WindowServerBridge = StreamingSkyLightBridge()
    private lazy var windowTracker = WindowTracker(server: windowServerBridge, coalesceMs: 16) { [weak self] batch in
        self?.borderEngine?.handleCoalescedBatch(batch)
    }
    private var borderEngine: BorderEngine?
    @MainActor private let effectEngine = EffectEngine()
    @MainActor private let popupEngine = PopupEngine()

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
        // RealtimeFastHook: focus changes drive a recompute directly without
        // waiting for the WindowEventCoalescer's 16ms tick. Cycling between
        // same-app windows then flips border colours within ~10ms instead of
        // the 30–50ms baseline of the debounced enumeration path.
        windowTracker.onFocusChange { [weak self] wid in
            Log.tracker.debug("focus changed -> \(wid.map { "\($0)" } ?? "nil", privacy: .public)")
            self?.borderEngine?.recompute()
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
        // Crash-safe shutdown order (focusfx-30.2):
        //   1. Stop IPC first so no new commands land mid-shutdown.
        //   2. Tear down border overlay NSWindows synchronously on main —
        //      otherwise a rapid relaunch race-leaks them onto the next
        //      session's screen.
        //   3. Stop the WindowTracker (cancels SLS streaming + AX observers).
        // ConfigStore is value-typed and needs no teardown.
        ipcServer?.stop()
        borderEngine?.tearDown()
        effectEngine.tearDown()
        popupEngine.tearDown()
        windowTracker.stop()
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
                    "isAXOwned": AnyCodable(w.isAXOwned ?? NSNull()),
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

        // `config.validate`: parse the configured file and report diagnostics
        // WITHOUT publishing — even on success. Used by `limelight config
        // validate` so a CLI dry-run never swaps the live snapshot
        // (focusfx-7ew).
        router.register("config.validate") { req in
            let result = store.validateFile()
            return Self.encodeReloadResponse(id: req.id, result: result, validateOnly: true)
        }

        router.register("config.path") { req in
            IPCResponse.success(id: req.id, result: AnyCodable(store.path))
        }

        // `trigger`: enqueue a transient effect (focusfx-18.2). Args:
        //   effect:        string (cometRing|neon|shockwave|line)
        //   target:        "focused" (default) | int (windowID) — currently
        //                  always resolved to focused; explicit-id support
        //                  follows once we have a stable wid round-trip.
        //   color:         "0xrrggbbaa" (optional, falls back to config default)
        //   durationMs:    int (optional, defaults to config default)
        //   aerospaceWorkspace: string (optional, propagated for rule context)
        // Returns synchronously: { accepted: bool, code: string }.
        router.register("trigger") { [weak self] req in
            guard let self else { return IPCResponse.failure(id: req.id, code: "engine_unavailable", message: "no engine") }
            let args = req.args ?? [:]
            let effectName = (args["effect"]?.value as? String) ?? self.configStore.currentSnapshot.defaultEffect.name
            let durationMs = (args["durationMs"]?.value as? Int) ?? self.configStore.currentSnapshot.defaultEffect.durationMs
            let colorStr = args["color"]?.value as? String
            let parsedColor: LimeCore.ColorSpec.RGBA
            if let s = colorStr, case let .solid(rgba) = (try? LimeCore.ColorSpec.parse(s)) ?? .solid(.init(r: 0, g: 0, b: 0, a: 0)) {
                parsedColor = rgba
            } else {
                parsedColor = self.configStore.currentSnapshot.defaultEffect.color
            }
            // Resolve target frame from focused window unless caller pinned a wid.
            var targetFrame: CGRect? = nil
            if let wid = args["target"]?.value as? Int, let state = tracker.snapshot.first(where: { Int($0.windowID) == wid }) {
                targetFrame = state.frame
            } else if let focused = tracker.currentFocusedWindow {
                targetFrame = focused.frame
            }
            guard let frame = targetFrame else {
                return IPCResponse.failure(id: req.id, code: "no_target", message: "no focused window to attach effect to")
            }
            let primaryHeight = NSScreen.main?.frame.height ?? 0
            let cocoa = BorderEngineLogic.cocoaFrame(from: frame, primaryDisplayHeight: primaryHeight)
            let trig = EffectTrigger(
                effect: effectName,
                frame: frame,
                cocoaFrame: cocoa,
                color: parsedColor,
                durationMs: durationMs
            )
            // Hop to main for the actual render — IPC worker returns immediately.
            let semaphore = DispatchSemaphore(value: 0)
            var outcome: EffectAccepted = .unknownEffect
            DispatchQueue.main.async { [effectEngine] in
                outcome = effectEngine.trigger(trig)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 0.05) // sub-frame budget
            switch outcome {
            case .accepted:
                return IPCResponse.success(id: req.id, result: AnyCodable([
                    "accepted": AnyCodable(true), "code": AnyCodable("ok"),
                ] as [String: AnyCodable]))
            case .effectNotImplemented:
                return IPCResponse.failure(id: req.id, code: "effect_not_implemented", message: "renderer for '\(effectName)' is not yet wired")
            case .unknownEffect:
                return IPCResponse.failure(id: req.id, code: "unknown_effect", message: "unknown effect '\(effectName)'")
            case .noTarget:
                return IPCResponse.failure(id: req.id, code: "no_target", message: "target frame is empty")
            }
        }

        // `popup`: show a transient banner (focusfx-22.1). Args:
        //   title, message: strings
        //   placement:      "topRight" (default) | "topLeft" | "bottomRight"
        //                   | "bottomLeft" | "center"
        //   durationMs:     int (defaults to config.popup.durationMs)
        router.register("popup") { [weak self] req in
            guard let self else { return IPCResponse.failure(id: req.id, code: "engine_unavailable", message: "no engine") }
            let args = req.args ?? [:]
            let cfg = self.configStore.currentSnapshot.popup
            let title = (args["title"]?.value as? String) ?? "LimeLight"
            let message = (args["message"]?.value as? String) ?? ""
            let placement = (args["placement"]?.value as? String) ?? cfg.placement.rawValue
            let durationMs = (args["durationMs"]?.value as? Int) ?? cfg.durationMs
            let pop = PopupRequest(title: title, message: message, placement: placement, durationMs: durationMs)
            DispatchQueue.main.async { [popupEngine] in
                _ = popupEngine.show(pop)
            }
            return IPCResponse.success(id: req.id, result: AnyCodable([
                "accepted": AnyCodable(true),
            ] as [String: AnyCodable]))
        }

        // `perf`: cached, cheap diagnostics dump (focusfx-30.1). Reads only
        // already-published state — no window rescan, no SLS round-trip,
        // no main-thread hop. Use as a quick health probe before
        // escalating to Instruments.
        let bridge = windowServerBridge
        let startedAt = startedAt
        router.register("perf") { [weak self] req in
            let snapshot = store.currentSnapshot
            let mainThread = MainThreadBudgetMetrics.snapshot()
            let renderEnabled = self?.borderEngine?.currentOverrides().global.enabled ?? snapshot.borders.enabled
            let desiredCount = self?.borderEngine?.currentDesired().count ?? 0
            let iso = ISO8601DateFormatter()
            let diagnostics = PerfDiagnostics(
                collectedAtIso: iso.string(from: Date()),
                daemon: PerfDiagnostics.Daemon(
                    version: Lime.version,
                    pid: getpid(),
                    bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.abhirup.LimeLight",
                    uptimeSeconds: Date().timeIntervalSince(startedAt)
                ),
                accessibility: PerfDiagnostics.Accessibility(
                    status: tracker.accessibility.rawValue
                ),
                skylight: PerfDiagnostics.SkyLight(
                    streamingAvailable: (bridge as? StreamingSkyLightBridge)?.isStreaming ?? false,
                    frontWindowResolutionAvailable: SkyLightSymbols.resolveFromSkyLight().canResolveFrontWindow
                ),
                socket: PerfDiagnostics.Socket(path: Lime.resolvedSocketPath),
                config: PerfDiagnostics.Config(
                    path: store.path,
                    diagnosticsCount: snapshot.diagnostics.count,
                    bordersEnabled: snapshot.borders.enabled,
                    ruleCount: snapshot.rules.count
                ),
                render: PerfDiagnostics.Render(
                    bordersEngineEnabled: renderEnabled,
                    desiredBorderCount: desiredCount
                ),
                tracker: PerfDiagnostics.Tracker(
                    trackedWindowCount: tracker.snapshot.count,
                    focusedWindowID: tracker.currentFocusedWindowID
                ),
                mainThread: PerfDiagnostics.MainThread(
                    totalBudgetCalls: mainThread.totalCalls,
                    slowBudgetCalls: mainThread.slowCalls,
                    maxObservedMs: mainThread.maxElapsedMs,
                    slowestTaskAtIso: mainThread.slowestTaskAt.map { iso.string(from: $0) }
                )
            )
            return IPCResponse.success(id: req.id, result: AnyCodable(diagnostics.toIPCDictionary()))
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
        router.register("borders.desired") { [weak self] req in
            guard let engine = self?.borderEngine else {
                return IPCResponse.failure(id: req.id, code: "engine_unavailable", message: "border engine not started")
            }
            let desired = engine.currentDesired()
            let entries: [AnyCodable] = desired.values.map { spec in
                let kind: String
                let key: String
                switch spec.id {
                case .window(let w): kind = "window"; key = "\(w)"
                case .screen(let s): kind = "screen"; key = "\(s)"
                }
                return AnyCodable([
                    "kind": AnyCodable(kind),
                    "id": AnyCodable(key),
                    "isActive": AnyCodable(spec.isActive),
                    "frame": AnyCodable([
                        "x": AnyCodable(Double(spec.frame.origin.x)),
                        "y": AnyCodable(Double(spec.frame.origin.y)),
                        "width": AnyCodable(Double(spec.frame.size.width)),
                        "height": AnyCodable(Double(spec.frame.size.height)),
                    ] as [String: AnyCodable]),
                    "width": AnyCodable(spec.width),
                ] as [String: AnyCodable])
            }
            return IPCResponse.success(id: req.id, result: AnyCodable([
                "count": AnyCodable(entries.count),
                "borders": AnyCodable(entries),
            ] as [String: AnyCodable]))
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
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.abhirup.LimeLight",
            socketPath: Lime.resolvedSocketPath,
            configPath: Lime.resolvedConfigPath,
            startedAt: startedAt
        )
    }
}
