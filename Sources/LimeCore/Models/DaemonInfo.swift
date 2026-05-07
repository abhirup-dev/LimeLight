import Foundation

/// Identity returned by the daemon over IPC and surfaced by `focusfx status`.
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
        return VersionInfo(version: FocusFX.version, buildConfig: "debug")
        #else
        return VersionInfo(version: FocusFX.version, buildConfig: "release")
        #endif
    }()
}

extension FocusFX {
    /// Resolves `~/Library/Application Support/FocusFX/...` paths.
    public static func userPath(_ relative: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(relative)
    }

    public static var resolvedSocketPath: String { userPath(socketRelativePath) }
    public static var resolvedConfigPath: String { userPath(configRelativePath) }
    public static var resolvedSchemaPath: String { userPath(schemaRelativePath) }
}
