import Foundation
import LimeCore

/// `limelight trigger [--effect=NAME] [--color=#rrggbbaa] [--duration-ms=N]
///                    [--target=wid] [--aerospace-workspace=NAME]`
/// (focusfx-18.2). Enqueues a transient effect on the focused (or specified)
/// window. Non-blocking — returns once IPC accepts the request.
enum TriggerCommand {
    static func run(_ args: [String]) {
        var ipcArgs: [String: AnyCodable] = [:]
        for a in args {
            if let eq = a.firstIndex(of: "="),
               a.hasPrefix("--") {
                let key = String(a[a.index(a.startIndex, offsetBy: 2)..<eq])
                let value = String(a[a.index(after: eq)..<a.endIndex])
                switch key {
                case "effect":              ipcArgs["effect"] = AnyCodable(value)
                case "color":               ipcArgs["color"] = AnyCodable(value)
                case "duration-ms":
                    if let n = Int(value) { ipcArgs["durationMs"] = AnyCodable(n) }
                case "target":
                    if let n = Int(value) { ipcArgs["target"] = AnyCodable(n) }
                case "aerospace-workspace":
                    ipcArgs["aerospaceWorkspace"] = AnyCodable(value)
                default:
                    FileHandle.standardError.write(Data("limelight trigger: ignoring unknown --\(key)\n".utf8))
                }
            }
        }
        let resp = CLIClient.requireOK(CLIClient.call("trigger", args: ipcArgs))
        if let dict = resp.result?.value as? [String: AnyCodable],
           let accepted = dict["accepted"]?.value as? Bool {
            print(accepted ? "ok" : "rejected")
        } else {
            print("ok")
        }
        exit(0)
    }
}
