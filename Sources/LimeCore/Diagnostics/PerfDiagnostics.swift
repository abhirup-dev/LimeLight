import Foundation

/// Cheap, cached snapshot of "is the daemon healthy" surfaced through
/// `limelight perf` (focusfx-30.1). Each field reflects state already kept
/// in-memory by some subsystem — the collector only reads, never enumerates
/// windows or replays SLS queries. Values that depend on a private API
/// being available carry an explicit `available` boolean rather than a
/// silent zero so users can tell "feature off" from "feature broken".
public struct PerfDiagnostics: Sendable, Equatable {
    public struct Daemon: Sendable, Equatable {
        public let version: String
        public let pid: Int32
        public let bundleIdentifier: String
        public let uptimeSeconds: Double
        public init(version: String, pid: Int32, bundleIdentifier: String, uptimeSeconds: Double) {
            self.version = version; self.pid = pid; self.bundleIdentifier = bundleIdentifier; self.uptimeSeconds = uptimeSeconds
        }
    }

    public struct Accessibility: Sendable, Equatable {
        /// Mirrors `AccessibilityStatus` raw string: granted|denied|undetermined.
        public let status: String
        public init(status: String) { self.status = status }
    }

    public struct SkyLight: Sendable, Equatable {
        /// True iff the streaming bridge could resolve `SLSMainConnectionID`
        /// and the event-streaming entry points. False on hosts where
        /// private symbols couldn't be dlsym'd.
        public let streamingAvailable: Bool
        /// True iff `SLSCopyWindowsWithOptionsAndTags` + iterator vended a
        /// connection ID; false means we degrade to AX-only focus.
        public let frontWindowResolutionAvailable: Bool
        public init(streamingAvailable: Bool, frontWindowResolutionAvailable: Bool) {
            self.streamingAvailable = streamingAvailable
            self.frontWindowResolutionAvailable = frontWindowResolutionAvailable
        }
    }

    public struct Socket: Sendable, Equatable {
        public let path: String
        public init(path: String) { self.path = path }
    }

    public struct Config: Sendable, Equatable {
        public let path: String
        /// Number of compile-time diagnostics on the active snapshot
        /// (bad regex, unknown enum value, etc.). 0 means clean.
        public let diagnosticsCount: Int
        public let bordersEnabled: Bool
        public let ruleCount: Int
        public init(path: String, diagnosticsCount: Int, bordersEnabled: Bool, ruleCount: Int) {
            self.path = path; self.diagnosticsCount = diagnosticsCount
            self.bordersEnabled = bordersEnabled; self.ruleCount = ruleCount
        }
    }

    public struct Render: Sendable, Equatable {
        public let bordersEngineEnabled: Bool
        /// Engine-side desired-set count — the number of borders the engine
        /// believes should currently be on screen. The renderer almost
        /// always matches; transient reconcile gaps are visible through
        /// `borders.desired` if needed.
        public let desiredBorderCount: Int
        public init(bordersEngineEnabled: Bool, desiredBorderCount: Int) {
            self.bordersEngineEnabled = bordersEngineEnabled
            self.desiredBorderCount = desiredBorderCount
        }
    }

    public struct Tracker: Sendable, Equatable {
        public let trackedWindowCount: Int
        public let focusedWindowID: UInt32?
        public init(trackedWindowCount: Int, focusedWindowID: UInt32?) {
            self.trackedWindowCount = trackedWindowCount; self.focusedWindowID = focusedWindowID
        }
    }

    public struct MainThread: Sendable, Equatable {
        public let totalBudgetCalls: UInt64
        public let slowBudgetCalls: UInt64
        public let maxObservedMs: Double
        public let slowestTaskAtIso: String?
        public init(totalBudgetCalls: UInt64, slowBudgetCalls: UInt64, maxObservedMs: Double, slowestTaskAtIso: String?) {
            self.totalBudgetCalls = totalBudgetCalls; self.slowBudgetCalls = slowBudgetCalls
            self.maxObservedMs = maxObservedMs; self.slowestTaskAtIso = slowestTaskAtIso
        }
    }

    public let collectedAtIso: String
    public let daemon: Daemon
    public let accessibility: Accessibility
    public let skylight: SkyLight
    public let socket: Socket
    public let config: Config
    public let render: Render
    public let tracker: Tracker
    public let mainThread: MainThread
    /// Stable diagnostic codes surfaced when a subsystem is degraded
    /// (focusfx-30.2). Codes are part of the wire contract — never
    /// renamed silently. Current vocabulary:
    ///   - "ax_denied"            : AX permission missing (focus is AX-resolved)
    ///   - "ax_undetermined"      : user hasn't responded to TCC prompt
    ///   - "sls_streaming_off"    : SLS event-stream symbols unavailable
    ///   - "sls_resolver_off"     : SLSCopyWindowsWithOptionsAndTags unavailable
    ///   - "config_invalid"       : last parsed config produced diagnostics
    ///   - "borders_disabled"     : engine globally off (config or runtime)
    public let warnings: [String]

    public init(
        collectedAtIso: String,
        daemon: Daemon,
        accessibility: Accessibility,
        skylight: SkyLight,
        socket: Socket,
        config: Config,
        render: Render,
        tracker: Tracker,
        mainThread: MainThread
    ) {
        self.collectedAtIso = collectedAtIso
        self.daemon = daemon
        self.accessibility = accessibility
        self.skylight = skylight
        self.socket = socket
        self.config = config
        self.render = render
        self.tracker = tracker
        self.mainThread = mainThread
        var w: [String] = []
        switch accessibility.status {
        case "denied":       w.append("ax_denied")
        case "undetermined": w.append("ax_undetermined")
        default: break
        }
        if !skylight.streamingAvailable { w.append("sls_streaming_off") }
        if !skylight.frontWindowResolutionAvailable { w.append("sls_resolver_off") }
        if config.diagnosticsCount > 0 { w.append("config_invalid") }
        if !render.bordersEngineEnabled { w.append("borders_disabled") }
        self.warnings = w
    }

    /// JSON-serializable dictionary suitable for `IPCResponse.success(result:)`.
    public func toIPCDictionary() -> [String: AnyCodable] {
        [
            "collectedAt": AnyCodable(collectedAtIso),
            "daemon": AnyCodable([
                "version": AnyCodable(daemon.version),
                "pid": AnyCodable(Int(daemon.pid)),
                "bundleIdentifier": AnyCodable(daemon.bundleIdentifier),
                "uptimeSeconds": AnyCodable(daemon.uptimeSeconds),
            ] as [String: AnyCodable]),
            "accessibility": AnyCodable([
                "status": AnyCodable(accessibility.status),
            ] as [String: AnyCodable]),
            "skylight": AnyCodable([
                "streamingAvailable": AnyCodable(skylight.streamingAvailable),
                "frontWindowResolutionAvailable": AnyCodable(skylight.frontWindowResolutionAvailable),
            ] as [String: AnyCodable]),
            "socket": AnyCodable([
                "path": AnyCodable(socket.path),
            ] as [String: AnyCodable]),
            "config": AnyCodable([
                "path": AnyCodable(config.path),
                "diagnosticsCount": AnyCodable(config.diagnosticsCount),
                "bordersEnabled": AnyCodable(config.bordersEnabled),
                "ruleCount": AnyCodable(config.ruleCount),
            ] as [String: AnyCodable]),
            "render": AnyCodable([
                "bordersEngineEnabled": AnyCodable(render.bordersEngineEnabled),
                "desiredBorderCount": AnyCodable(render.desiredBorderCount),
            ] as [String: AnyCodable]),
            "tracker": AnyCodable([
                "trackedWindowCount": AnyCodable(tracker.trackedWindowCount),
                "focusedWindowID": AnyCodable(tracker.focusedWindowID.map { Int($0) } ?? NSNull()),
            ] as [String: AnyCodable]),
            "mainThread": AnyCodable([
                "totalBudgetCalls": AnyCodable(Int(mainThread.totalBudgetCalls)),
                "slowBudgetCalls": AnyCodable(Int(mainThread.slowBudgetCalls)),
                "maxObservedMs": AnyCodable(mainThread.maxObservedMs),
                "slowestTaskAt": AnyCodable(mainThread.slowestTaskAtIso ?? NSNull()),
            ] as [String: AnyCodable]),
            "warnings": AnyCodable(warnings.map { AnyCodable($0) }),
        ]
    }
}
