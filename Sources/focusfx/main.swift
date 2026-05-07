import Darwin
import Foundation
import FocusFXCore

// Don't die from SIGPIPE if a socket peer closes mid-write — surface a normal error instead.
signal(SIGPIPE, SIG_IGN)

let argv = Array(CommandLine.arguments.dropFirst())

func usage() {
    FileHandle.standardError.write(Data("""
    focusfx \(FocusFX.version)

    Usage:
      focusfx daemon open
      focusfx daemon quit
      focusfx status [--json]
      focusfx --help | --version

    Implemented commands return exit codes:
      0  success
      1  usage / argument error
      2  command not implemented yet
      3  daemon unreachable
      4  daemon returned error envelope
      5  timeout
    \n
    """.utf8))
}

func runHelp() -> Never {
    print("focusfx \(FocusFX.version)")
    print("")
    print("Top-level commands:")
    print("  daemon open                Launch FocusFX.app.")
    print("  daemon quit                Ask the running daemon to terminate.")
    print("  status [--json]            Print daemon status (cached, no rescan).")
    print("  --help, -h                 Show this help.")
    print("  --version, -v              Print version.")
    exit(0)
}

if argv.isEmpty {
    usage()
    exit(1)
}

if argv == ["--help"] || argv == ["-h"] {
    runHelp()
}

if argv == ["--version"] || argv == ["-v"] {
    print("focusfx \(FocusFX.version)")
    exit(0)
}

let command = argv[0]
let rest = Array(argv.dropFirst())

switch command {
case "daemon":
    DaemonCommand.run(rest)
case "status":
    StatusCommand.run(rest)
default:
    FileHandle.standardError.write(Data("focusfx: command '\(command)' not implemented yet (focusfx-5.3+)\n".utf8))
    exit(2)
}
