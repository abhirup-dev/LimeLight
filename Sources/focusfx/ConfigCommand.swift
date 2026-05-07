import Foundation
import FocusFXCore

enum ConfigCommand {
    static func run(_ args: [String]) {
        guard let sub = args.first else {
            FileHandle.standardError.write(Data("focusfx config: missing subcommand (path|validate)\n".utf8))
            exit(1)
        }
        switch sub {
        case "path":
            // Local-only — no IPC needed.
            print(FocusFX.resolvedConfigPath)
        case "validate":
            runValidate()
        default:
            FileHandle.standardError.write(Data("focusfx config: unknown subcommand '\(sub)'\n".utf8))
            exit(1)
        }
    }

    private static func runValidate() {
        let resp = CLIClient.requireOK(CLIClient.call("config.validate"))
        printDiagnostics(resp)
        guard let payload = resp.result?.value as? [String: AnyCodable] else { return }
        let parseError = (payload["parseError"]?.value as? String)
        if let parseError {
            FileHandle.standardError.write(Data("config invalid: \(parseError)\n".utf8))
            exit(4)
        }
        let count = (payload["diagnostics"]?.value as? [AnyCodable])?.count ?? 0
        if count == 0 {
            print("config: ok")
        } else {
            print("config: ok with \(count) warning(s)")
        }
    }

    static func printDiagnostics(_ resp: IPCResponse) {
        guard let payload = resp.result?.value as? [String: AnyCodable] else { return }
        guard let diags = payload["diagnostics"]?.value as? [AnyCodable] else { return }
        for d in diags {
            guard let entry = d.value as? [String: AnyCodable] else { continue }
            let severity = (entry["severity"]?.value as? String) ?? "warning"
            let path = (entry["path"]?.value as? String) ?? "?"
            let message = (entry["message"]?.value as? String) ?? ""
            let stream: FileHandle = severity == "error" ? .standardError : .standardOutput
            stream.write(Data("[\(severity)] \(path): \(message)\n".utf8))
        }
    }
}

enum ReloadCommand {
    static func run(_ args: [String]) {
        _ = args
        let resp = CLIClient.requireOK(CLIClient.call("reload"))
        ConfigCommand.printDiagnostics(resp)
        guard let payload = resp.result?.value as? [String: AnyCodable] else {
            print("reload: ok")
            return
        }
        let parseError = payload["parseError"]?.value as? String
        if let parseError {
            FileHandle.standardError.write(Data(
                "reload failed: \(parseError) — previous config kept.\n".utf8))
            exit(4)
        }
        let applied = (payload["applied"]?.value as? Bool) ?? false
        print(applied ? "reload: applied" : "reload: no change")
    }
}
