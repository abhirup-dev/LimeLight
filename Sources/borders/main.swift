import Darwin
import Foundation
import LimeCore

// JankyBorders compatibility shim: parses a JB-style argv ("active_color=...
// style=round width=5.0 ...") and forwards it to the LimeLight daemon as a
// `borders.style` IPC call. The daemon-side handler ships in focusfx-14.3 —
// until then, the shim still parses fully and surfaces clear errors locally.

signal(SIGPIPE, SIG_IGN)

let argv = Array(CommandLine.arguments.dropFirst())

func usage() {
    FileHandle.standardError.write(Data("""
    borders \(Lime.version) — JankyBorders-compatible shim

    Usage:
      borders [option=value ...]

    Options:
      active_color=0xAARRGGBB | glow(...) | gradient(top_left=...,bottom_right=...)
      inactive_color=...       background_color=...
      width=5.0                 style=round|square|uniform
      order=above|below         hidpi=on|off
      blacklist=App,App         whitelist=App,App
      ax_focus=on|off           apply-to=N

      --dry-run                 Parse and print the request without touching the daemon.
      --help, -h                Show this help.
      --version, -v             Print version.

    Exit codes:
      0  applied (or --dry-run succeeded)
      1  argument error
      3  daemon unreachable
      4  daemon returned error envelope
    \n
    """.utf8))
}

if argv == ["--help"] || argv == ["-h"] {
    usage()
    exit(0)
}
if argv == ["--version"] || argv == ["-v"] {
    print("borders \(Lime.version)")
    exit(0)
}

var dryRun = false
var tokens: [String] = []
for a in argv {
    if a == "--dry-run" { dryRun = true; continue }
    tokens.append(a)
}

let outcome = BordersStyleArgs.parse(tokens)

for w in outcome.warnings {
    FileHandle.standardError.write(Data("borders: warning: \(w)\n".utf8))
}
if outcome.hasFatalErrors {
    for e in outcome.errors {
        FileHandle.standardError.write(Data("borders: \(e)\n".utf8))
    }
    exit(1)
}

if dryRun {
    let args = outcome.request.ipcArgs
    let json = try JSONSerialization.data(
        withJSONObject: args.mapValues(AnyCodableMirror.unwrap),
        options: [.prettyPrinted, .sortedKeys]
    )
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}

// Forward to the daemon. The handler may not exist yet (focusfx-14.3) — surface
// the error envelope as exit code 4 so the user knows the parse succeeded but
// the daemon couldn't apply it.
let client = IPCClient(socketPath: Lime.resolvedSocketPath, defaultTimeout: 1.5)
let request = IPCRequest(command: "borders.style", args: outcome.request.ipcArgs)

do {
    let resp = try client.call(request)
    if !resp.ok, let e = resp.error {
        FileHandle.standardError.write(Data("borders: \(e.code): \(e.message)\n".utf8))
        exit(4)
    }
    exit(0)
} catch let err as IPCClient.CallError {
    switch err {
    case .connectFailed:
        FileHandle.standardError.write(Data(
            "borders: daemon is not running (no socket at \(Lime.resolvedSocketPath)).\n".utf8
        ))
        exit(3)
    default:
        FileHandle.standardError.write(Data("borders: ipc error: \(err)\n".utf8))
        exit(3)
    }
} catch {
    FileHandle.standardError.write(Data("borders: \(error)\n".utf8))
    exit(3)
}

// Local helper: unwrap AnyCodable trees to raw Foundation types for
// JSONSerialization (only used by --dry-run).
enum AnyCodableMirror {
    static func unwrap(_ v: AnyCodable) -> Any {
        switch v.value {
        case let dict as [String: AnyCodable]: return dict.mapValues(unwrap)
        case let arr as [AnyCodable]: return arr.map(unwrap)
        default: return v.value
        }
    }
}
