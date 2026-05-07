import AppKit
import Foundation
import FocusFXCore

final class DaemonAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let startedAt = Date()
    private let router = IPCRouter()
    private var ipcServer: IPCServer?
    private let configStore = ConfigStore(path: FocusFX.resolvedConfigPath)

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
        Log.core.info("FocusFX daemon ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.core.notice("FocusFX daemon terminating")
        ipcServer?.stop()
    }

    private func registerCommands() {
        let cachedInfo = info()
        router.register("status") { req in
            // Cached snapshot — no main-thread fan-out, no full window rescan.
            do {
                let payload = try IPCCoding.makeEncoder().encode(cachedInfo)
                let any = try IPCCoding.makeDecoder().decode(AnyCodable.self, from: payload)
                return IPCResponse.success(id: req.id, result: any)
            } catch {
                return IPCResponse.failure(id: req.id, code: "encode_failed", message: "\(error)")
            }
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
        // diagnostics WITHOUT publishing if invalid. Used by `focusfx config validate`.
        router.register("config.validate") { req in
            // Reuse the daemon's store path; future args could supply alternative text.
            let result = store.loadSync()
            return Self.encodeReloadResponse(id: req.id, result: result, validateOnly: true)
        }

        router.register("config.path") { req in
            IPCResponse.success(id: req.id, result: AnyCodable(store.path))
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
        let server = IPCServer(socketPath: FocusFX.resolvedSocketPath, router: router)
        do {
            try server.start()
            self.ipcServer = server
        } catch {
            FileHandle.standardError.write(Data("FocusFX: \(error)\n".utf8))
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
            button.toolTip = "FocusFX \(FocusFX.version)"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "FocusFX \(FocusFX.version)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit FocusFX", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        self.statusItem = item
    }

    @objc private func reloadConfig() {
        Log.core.info("reload requested from menu — config reload lands in focusfx-5")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func info() -> DaemonInfo {
        DaemonInfo(
            version: FocusFX.version,
            pid: getpid(),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.focusfx.daemon",
            socketPath: FocusFX.resolvedSocketPath,
            configPath: FocusFX.resolvedConfigPath,
            startedAt: startedAt
        )
    }
}
