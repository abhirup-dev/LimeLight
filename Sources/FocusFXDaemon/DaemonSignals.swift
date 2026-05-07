import Foundation

enum DaemonSignals {
    /// Installs SIGINT/SIGTERM handlers that invoke `handler` on a background queue.
    /// Uses GCD signal sources rather than `signal()` so the run loop is not interrupted.
    static func install(_ handler: @escaping () -> Void) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            src.setEventHandler(handler: handler)
            src.resume()
            sources.append(src)
        }
    }

    private static var sources: [DispatchSourceSignal] = []
}
