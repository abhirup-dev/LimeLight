import Foundation

/// Identity returned by the daemon over IPC and surfaced by `limelight status`.
public struct DaemonInfo: Codable, Sendable, Equatable {
    public let version: String
    public let pid: Int32
    public let bundleIdentifier: String
    public let socketPath: String
    public let configPath: String
    public let startedAt: Date

    public init(
        version: String,
        pid: Int32,
        bundleIdentifier: String,
        socketPath: String,
        configPath: String,
        startedAt: Date
    ) {
        self.version = version
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.socketPath = socketPath
        self.configPath = configPath
        self.startedAt = startedAt
    }
}

public struct VersionInfo: Codable, Sendable, Equatable {
    public let version: String
    public let buildConfig: String

    public init(version: String, buildConfig: String) {
        self.version = version
        self.buildConfig = buildConfig
    }

    public static let current: VersionInfo = {
        #if DEBUG
        return VersionInfo(version: Lime.version, buildConfig: "debug")
        #else
        return VersionInfo(version: Lime.version, buildConfig: "release")
        #endif
    }()
}

extension Lime {
    /// Resolves a path relative to the user's home directory.
    public static func userPath(_ relative: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(relative)
    }

    public static var resolvedSocketPath: String { userPath(socketRelativePath) }

    /// Honours `$XDG_CONFIG_HOME` when set (so users sharing dotfile configs
    /// across machines pick up the right location), else `~/.config/limelight/`.
    public static var resolvedConfigPath: String {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("limelight/config.jsonc")
        }
        return userPath(configRelativePath)
    }

    public static var resolvedSchemaPath: String {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("limelight/config.schema.json")
        }
        return userPath(schemaRelativePath)
    }
}
