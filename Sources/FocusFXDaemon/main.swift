import AppKit
import Foundation
import FocusFXCore

let args = CommandLine.arguments.dropFirst()

if args.contains("--version") {
    print("FocusFXDaemon \(FocusFX.version)")
    exit(0)
}

if args.contains("--help") || args.contains("-h") {
    print("""
    FocusFXDaemon \(FocusFX.version)

    The FocusFX background daemon. Normally launched as the FocusFX.app
    bundle (LSUIElement), it can also be run directly for development.

    Usage:
      FocusFXDaemon              Run the daemon (foreground).
      FocusFXDaemon --version    Print version and exit.
      FocusFXDaemon --help       Print this help and exit.
    """)
    exit(0)
}

let app = NSApplication.shared
let delegate = DaemonAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Reinforces LSUIElement for direct-launch.

DaemonSignals.install {
    DispatchQueue.main.async {
        Log.core.notice("FocusFX daemon: termination signal received")
        NSApp.terminate(nil)
    }
}

Log.core.notice("FocusFX daemon \(FocusFX.version, privacy: .public) starting (pid=\(getpid()))")
app.run()
