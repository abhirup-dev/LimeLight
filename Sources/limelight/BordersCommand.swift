import Foundation
import LimeCore

/// `limelight borders <subcommand>`. Live runtime control of the border engine.
/// Style updates are not exposed here — use the JankyBorders-compatible
/// `borders` shim binary for that.
enum BordersCommand {
    static func run(_ args: [String]) {
        guard let sub = args.first else {
            usage()
            exit(1)
        }
        switch sub {
        case "enable":  send("borders.enable")
        case "disable": send("borders.disable")
        case "redraw-all", "redraw": send("borders.redrawAll")
        case "reset":   send("borders.clearOverrides")
        case "desired": dumpDesired()
        case "--help", "-h", "help":
            usage()
            exit(0)
        default:
            FileHandle.standardError.write(Data("limelight borders: unknown subcommand '\(sub)'\n".utf8))
            usage()
            exit(1)
        }
    }

    /// Diagnostic: dump the borders the engine currently believes should
    /// exist. Reads `borders.desired` IPC and pretty-prints one line per
    /// border so you can confirm in real time which windows are being
    /// targeted, whether they're active/inactive, and the frame the
    /// renderer was handed.
    private static func dumpDesired() {
        // Re-decode the response as raw JSON via JSONSerialization to avoid
        // AnyCodable's Int64-vs-Double ambiguity that bites us when an
        // integer-valued frame component round-trips through encode/decode.
        let resp = CLIClient.requireOK(CLIClient.call("borders.desired"))
        guard let result = resp.result,
              let data = try? IPCCoding.makeEncoder().encode(result),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            print("(no result)")
            exit(0)
        }
        let count = (dict["count"] as? Int) ?? 0
        let borders = (dict["borders"] as? [[String: Any]]) ?? []
        print("desired count=\(count)")
        for b in borders {
            let kind = (b["kind"] as? String) ?? "?"
            let id = (b["id"] as? String) ?? "?"
            let active = (b["isActive"] as? Bool).map { $0 ? "active" : "inactive" } ?? "?"
            let f = b["frame"] as? [String: Any] ?? [:]
            let asDouble: (Any?) -> Double = { v in
                if let d = v as? Double { return d }
                if let i = v as? Int { return Double(i) }
                if let i = v as? Int64 { return Double(i) }
                return 0
            }
            let x = asDouble(f["x"])
            let y = asDouble(f["y"])
            let w = asDouble(f["width"])
            let h = asDouble(f["height"])
            let frameStr = String(format: "(%5.0f,%5.0f %4.0fx%4.0f)", x, y, w, h)
            let kindPad = pad(kind, width: 7)
            let idPad = pad("id=" + id, width: 9)
            let activePad = pad(active, width: 8)
            print("  \(kindPad) \(idPad) \(activePad) frame=\(frameStr)")
        }
        exit(0)
    }

    private static func pad(_ s: String, width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    private static func send(_ command: String) {
        let resp = CLIClient.requireOK(CLIClient.call(command))
        if let s = resp.result?.value as? String {
            print(s)
        } else {
            print("ok")
        }
        exit(0)
    }

    private static func usage() {
        FileHandle.standardError.write(Data("""
        limelight borders <subcommand>

        Subcommands:
          enable       Turn borders on (runtime override).
          disable      Turn borders off (runtime override).
          redraw-all   Tear down and re-create every border window.
          reset        Drop all runtime overrides.
          desired      Diagnostic dump of the current desired-border set.

        For style/color updates use the JankyBorders-compatible shim:
          borders active_color=0xff... width=5 style=round
        \n
        """.utf8))
    }
}
