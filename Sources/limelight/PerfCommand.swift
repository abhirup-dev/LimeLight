import Foundation
import LimeCore

/// `limelight perf [--json]` (focusfx-30.1). Cheap diagnostics dump —
/// reads cached daemon state, never enumerates windows.
enum PerfCommand {
    static func run(_ args: [String]) {
        let json = args.contains("--json")
        let resp = CLIClient.requireOK(CLIClient.call("perf"))
        guard let result = resp.result,
              let data = try? IPCCoding.makeEncoder().encode(result),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            print("(no result)")
            exit(0)
        }
        if json {
            let pretty = try? JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
            if let pretty {
                FileHandle.standardOutput.write(pretty)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            exit(0)
        }
        printHuman(dict)
        exit(0)
    }

    private static func printHuman(_ d: [String: Any]) {
        let daemon = d["daemon"] as? [String: Any] ?? [:]
        let ax = d["accessibility"] as? [String: Any] ?? [:]
        let sky = d["skylight"] as? [String: Any] ?? [:]
        let cfg = d["config"] as? [String: Any] ?? [:]
        let render = d["render"] as? [String: Any] ?? [:]
        let tracker = d["tracker"] as? [String: Any] ?? [:]
        let mt = d["mainThread"] as? [String: Any] ?? [:]
        let socket = d["socket"] as? [String: Any] ?? [:]

        print("LimeLight \(daemon["version"] ?? "?")  pid=\(daemon["pid"] ?? "?")  uptime=\(formatSeconds(daemon["uptimeSeconds"]))")
        print("  socket:        \(socket["path"] ?? "?")")
        print("  accessibility: \(ax["status"] ?? "?")")
        let streaming = (sky["streamingAvailable"] as? Bool) == true ? "yes" : "no"
        let resolver = (sky["frontWindowResolutionAvailable"] as? Bool) == true ? "yes" : "no"
        print("  skylight:      streaming=\(streaming) frontWindowResolution=\(resolver)")
        print("  config:        \(cfg["path"] ?? "?")")
        print("                 rules=\(cfg["ruleCount"] ?? 0) diagnostics=\(cfg["diagnosticsCount"] ?? 0) bordersEnabled=\(cfg["bordersEnabled"] ?? false)")
        print("  tracker:       trackedWindows=\(tracker["trackedWindowCount"] ?? 0) focused=\(tracker["focusedWindowID"] ?? "nil")")
        print("  render:        bordersOn=\(render["bordersEngineEnabled"] ?? false) desired=\(render["desiredBorderCount"] ?? 0)")
        let total = mt["totalBudgetCalls"] as? Int ?? 0
        let slow = mt["slowBudgetCalls"] as? Int ?? 0
        let max = mt["maxObservedMs"] as? Double ?? 0
        print("  mainThread:    calls=\(total) slow=\(slow) maxMs=\(String(format: "%.2f", max))")
        if let warnings = d["warnings"] as? [String], !warnings.isEmpty {
            print("  warnings:      \(warnings.joined(separator: ", "))")
        }
    }

    private static func formatSeconds(_ v: Any?) -> String {
        let s = (v as? Double) ?? Double(v as? Int ?? 0)
        if s < 60 { return String(format: "%.0fs", s) }
        if s < 3600 { return String(format: "%.0fm%.0fs", floor(s / 60), s.truncatingRemainder(dividingBy: 60)) }
        return String(format: "%.1fh", s / 3600)
    }
}
