import Foundation
import FocusFXCore

enum WindowsCommand {
    static func run(_ args: [String]) {
        let json = args.contains("--json")
        let resp = CLIClient.requireOK(CLIClient.call("windows.snapshot"))
        guard let result = resp.result else {
            print(json ? "{}" : "(no windows)")
            return
        }
        if json {
            renderJSON(result)
            return
        }
        renderTable(result)
    }

    private static func renderJSON(_ result: AnyCodable) {
        let encoder = IPCCoding.makeEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? encoder.encode(result) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static func renderTable(_ result: AnyCodable) {
        let encoder = IPCCoding.makeEncoder()
        guard let data = try? encoder.encode(result),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("(unparseable result)")
            return
        }
        let count = (raw["count"] as? Int) ?? 0
        let focused = (raw["focusedWindowID"] as? Int).map(String.init) ?? "(none)"
        let entries = raw["windows"] as? [[String: Any]] ?? []
        print("\(count) window(s) — focused=\(focused)")
        print(row("wid", "pid", "app", "title"))
        for w in entries {
            let wid = (w["windowID"] as? Int).map(String.init) ?? "?"
            let pid = (w["ownerPID"] as? Int).map(String.init) ?? "?"
            let app = truncated((w["appName"] as? String) ?? "—", to: 22)
            let title = (w["title"] as? String) ?? "—"
            print(row(wid, pid, app, title))
        }
    }

    private static func row(_ wid: String, _ pid: String, _ app: String, _ title: String) -> String {
        let widCol = pad(wid, width: 8, rightAlign: true)
        let pidCol = pad(pid, width: 6, rightAlign: true)
        let appCol = pad(app, width: 22, rightAlign: false)
        return "\(widCol)  \(pidCol)  \(appCol)  \(title)"
    }

    private static func pad(_ s: String, width: Int, rightAlign: Bool) -> String {
        if s.count >= width { return s }
        let padding = String(repeating: " ", count: width - s.count)
        return rightAlign ? padding + s : s + padding
    }

    private static func truncated(_ s: String, to n: Int) -> String {
        guard s.count > n else { return s }
        return String(s.prefix(n - 1)) + "…"
    }
}

/// AnyCodable decodes JSON integers as Int64; CLI helpers want Int. Centralize the cast.
func anyInt(_ a: AnyCodable?) -> Int? {
    if let i = a?.value as? Int { return i }
    if let i = a?.value as? Int64 { return Int(i) }
    if let i = a?.value as? Int32 { return Int(i) }
    return nil
}

enum CurrentWindowCommand {
    static func run(_ args: [String]) {
        let json = args.contains("--json")
        let resp = CLIClient.requireOK(CLIClient.call("current-window"))
        guard let result = resp.result, !(result.value is NSNull) else {
            print(json ? "null" : "(no focused window)")
            return
        }
        if json {
            let encoder = IPCCoding.makeEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            if let data = try? encoder.encode(result) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            return
        }
        guard let w = result.value as? [String: AnyCodable] else {
            print("(unparseable result)")
            return
        }
        let wid = anyInt(w["windowID"]).map(String.init) ?? "?"
        let app = (w["appName"]?.value as? String) ?? "—"
        let title = (w["title"]?.value as? String) ?? "—"
        print("wid=\(wid) app=\(app) title=\(title)")
    }
}
