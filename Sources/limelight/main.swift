import Darwin
import Foundation
import LimeCore

// Don't die from SIGPIPE if a socket peer closes mid-write — surface a normal error instead.
signal(SIGPIPE, SIG_IGN)

let argv = Array(CommandLine.arguments.dropFirst())

func usage() {
    FileHandle.standardError.write(Data("""
    limelight \(Lime.version)

    Usage:
      limelight daemon open
      limelight daemon quit
      limelight status [--json]
      limelight --help | --version

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
    print("limelight \(Lime.version)")
    print("")
    print("Top-level commands:")
    print("  daemon open                Launch LimeLight.app.")
    print("  daemon quit                Ask the running daemon to terminate.")
    print("  status [--json]            Print daemon status (cached, no rescan).")
    print("  config path                Print the config file path.")
    print("  config validate            Validate the config and print diagnostics.")
    print("  reload                     Re-read config from disk and apply if valid.")
    print("  windows [--json]           List cached windows.")
    print("  current-window [--json]    Print the focused window.")
    print("  borders <subcommand>       Runtime border controls (enable/disable/redraw-all/reset).")
    print("  perf [--json]              Cached diagnostics dump (daemon, AX, SkyLight, render).")
    print("  trigger [--effect=NAME]    Enqueue a transient effect on the focused window.")
    print("  popup --title=T --message=M  Show a transient banner.")
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
    print("limelight \(Lime.version)")
    exit(0)
}

let command = argv[0]
let rest = Array(argv.dropFirst())

switch command {
case "daemon":
    DaemonCommand.run(rest)
case "status":
    StatusCommand.run(rest)
case "config":
    ConfigCommand.run(rest)
case "reload":
    ReloadCommand.run(rest)
case "windows":
    WindowsCommand.run(rest)
case "current-window":
    CurrentWindowCommand.run(rest)
case "borders":
    BordersCommand.run(rest)
case "perf":
    PerfCommand.run(rest)
case "trigger":
    TriggerCommand.run(rest)
case "popup":
    PopupCommand.run(rest)
default:
    FileHandle.standardError.write(Data("limelight: command '\(command)' not implemented yet\n".utf8))
    exit(2)
}
