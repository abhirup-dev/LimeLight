import AppKit
import Foundation
import FocusFXCore

final class DaemonAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let startedAt = Date()
    private let router = IPCRouter()
    private var ipcServer: IPCServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainThreadBudget("daemon.didFinishLaunching") {
            installStatusItem()
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
