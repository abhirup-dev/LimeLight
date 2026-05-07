import Foundation
import FocusFXCore

enum DaemonCommand {
    static func run(_ args: [String]) {
        guard let sub = args.first else {
            FileHandle.standardError.write(Data("focusfx daemon: missing subcommand (open|quit)\n".utf8))
            exit(1)
        }
        switch sub {
        case "open": runOpen()
        case "quit": runQuit()
        default:
            FileHandle.standardError.write(Data("focusfx daemon: unknown subcommand '\(sub)'\n".utf8))
            exit(1)
        }
    }

    private static func runOpen() {
        if isDaemonAlive() {
            print("FocusFX daemon already running.")
            exit(0)
        }

        guard let appPath = locateAppBundle() else {
            FileHandle.standardError.write(Data("""
            focusfx: could not find FocusFX.app.
            Set FOCUSFX_APP_PATH or install the bundle to /Applications/FocusFX.app.
            \n
            """.utf8))
            exit(3)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-ga", appPath]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            FileHandle.standardError.write(Data("focusfx: failed to launch \(appPath): \(error)\n".utf8))
            exit(3)
        }

        // Wait briefly for the socket to appear so the next CLI call sees a live daemon.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if isDaemonAlive() {
                print("FocusFX daemon started.")
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        FileHandle.standardError.write(Data("focusfx: launched \(appPath) but socket did not appear within 2s\n".utf8))
        exit(3)
    }

    private static func runQuit() {
        let resp = CLIClient.requireOK(CLIClient.call("quit", timeout: 1.0))
        _ = resp
        print("FocusFX daemon: quit requested.")
    }

    // MARK: - helpers

    private static func isDaemonAlive() -> Bool {
        let client = IPCClient(socketPath: FocusFX.resolvedSocketPath, defaultTimeout: 0.25)
        do {
            _ = try client.call(IPCRequest(command: "ping"), timeout: 0.25)
            return true
        } catch {
            return false
        }
    }

    private static func locateAppBundle() -> String? {
        if let env = ProcessInfo.processInfo.environment["FOCUSFX_APP_PATH"], !env.isEmpty {
            if FileManager.default.fileExists(atPath: env) { return env }
        }
        // Next to the CLI binary (dev: .build/debug/focusfx → .build/FocusFX.app).
        let cliPath = CommandLine.arguments[0]
        let cliDir = (cliPath as NSString).deletingLastPathComponent
        let candidates = [
            (cliDir as NSString).appendingPathComponent("../FocusFX.app"),
            (cliDir as NSString).appendingPathComponent("FocusFX.app"),
            "/Applications/FocusFX.app",
            ((NSHomeDirectory() as NSString).appendingPathComponent("Applications/FocusFX.app")),
        ]
        for path in candidates {
            let resolved = (path as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: resolved) { return resolved }
        }
        return nil
    }
}
