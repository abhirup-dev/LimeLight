import Foundation
import LimeCore

/// `limelight popup --title=T --message=M [--placement=topRight]
///                  [--duration-ms=N]` (focusfx-22.1). Transient banner.
enum PopupCommand {
    static func run(_ args: [String]) {
        var ipcArgs: [String: AnyCodable] = [:]
        for a in args {
            guard a.hasPrefix("--"), let eq = a.firstIndex(of: "=") else { continue }
            let key = String(a[a.index(a.startIndex, offsetBy: 2)..<eq])
            let value = String(a[a.index(after: eq)..<a.endIndex])
            switch key {
            case "title":       ipcArgs["title"] = AnyCodable(value)
            case "message":     ipcArgs["message"] = AnyCodable(value)
            case "placement":   ipcArgs["placement"] = AnyCodable(value)
            case "duration-ms":
                if let n = Int(value) { ipcArgs["durationMs"] = AnyCodable(n) }
            default:
                FileHandle.standardError.write(Data("limelight popup: ignoring unknown --\(key)\n".utf8))
            }
        }
        _ = CLIClient.requireOK(CLIClient.call("popup", args: ipcArgs))
        print("ok")
        exit(0)
    }
}
