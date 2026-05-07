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
        case "--help", "-h", "help":
            usage()
            exit(0)
        default:
            FileHandle.standardError.write(Data("limelight borders: unknown subcommand '\(sub)'\n".utf8))
            usage()
            exit(1)
        }
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

        For style/color updates use the JankyBorders-compatible shim:
          borders active_color=0xff... width=5 style=round
        \n
        """.utf8))
    }
}
