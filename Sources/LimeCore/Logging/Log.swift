import Foundation
import OSLog

public enum Log {
    public static let subsystem = "dev.abhirup.lime"

    public static let core = Logger(subsystem: subsystem, category: "core")
    public static let ipc = Logger(subsystem: subsystem, category: "ipc")
    public static let config = Logger(subsystem: subsystem, category: "config")
    public static let tracker = Logger(subsystem: subsystem, category: "tracker")
    public static let borders = Logger(subsystem: subsystem, category: "borders")
    public static let effects = Logger(subsystem: subsystem, category: "effects")
    public static let popup = Logger(subsystem: subsystem, category: "popup")
    public static let perf = Logger(subsystem: subsystem, category: "perf")
}
