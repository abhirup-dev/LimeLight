import AppKit
import Foundation
import LimeCore

let args = CommandLine.arguments.dropFirst()

if args.contains("--version") {
    print("limelightd \(Lime.version)")
    exit(0)
}

if args.contains("--help") || args.contains("-h") {
    print("""
    limelightd \(Lime.version)

    The LimeLight background daemon. Normally launched as the LimeLight.app
    bundle (LSUIElement), it can also be run directly for development.

    Usage:
      limelightd              Run the daemon (foreground).
      limelightd --version    Print version and exit.
      limelightd --help       Print this help and exit.
    """)
    exit(0)
}

let app = NSApplication.shared
let delegate = DaemonAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Reinforces LSUIElement for direct-launch.

DaemonSignals.install {
    DispatchQueue.main.async {
        Log.core.notice("LimeLight daemon: termination signal received")
        NSApp.terminate(nil)
    }
}

Log.core.notice("LimeLight daemon \(Lime.version, privacy: .public) starting (pid=\(getpid()))")
app.run()
