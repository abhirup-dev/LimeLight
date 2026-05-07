import CSkyLight
import Darwin
import Foundation

/// SLS event class IDs we care about. Verified against JankyBorders/src/events.c
/// — these are stable across recent macOS releases but are NOT public API,
/// which is why every symbol below is dlsym'd rather than linked.
public enum SLSEventClass: UInt32, CaseIterable {
    case windowMove        = 806
    case windowResize      = 807
    case windowReorder     = 808
    case windowHide        = 815
    case windowUnhide      = 816
    case windowCreate      = 1325
    case windowDestroy     = 1326
    case spaceChange       = 1401
    case frontAppChange    = 1508
}

/// Resolved private-API symbol set. Every field is optional — a missing
/// symbol does NOT crash the daemon; instead the streaming bridge declines
/// to install and we keep the public-API `CGWindowListBridge`.
///
/// "Critical" symbols for streaming: `mainConnectionID` and `registerNotifyProc`.
/// Without those there's no streaming. Other fields (bounds/owner/connectionPID)
/// are conveniences for future incremental cache mutation; this pass only
/// uses them defensively.
public struct SkyLightSymbols: Sendable {
    public let mainConnectionID: SLSMainConnectionIDFn?
    public let registerNotifyProc: SLSRegisterNotifyProcFn?
    public let getWindowBounds: SLSGetWindowBoundsFn?
    public let getWindowOwner: SLSGetWindowOwnerFn?
    public let connectionGetPID: SLSConnectionGetPIDFn?

    public init(
        mainConnectionID: SLSMainConnectionIDFn? = nil,
        registerNotifyProc: SLSRegisterNotifyProcFn? = nil,
        getWindowBounds: SLSGetWindowBoundsFn? = nil,
        getWindowOwner: SLSGetWindowOwnerFn? = nil,
        connectionGetPID: SLSConnectionGetPIDFn? = nil
    ) {
        self.mainConnectionID = mainConnectionID
        self.registerNotifyProc = registerNotifyProc
        self.getWindowBounds = getWindowBounds
        self.getWindowOwner = getWindowOwner
        self.connectionGetPID = connectionGetPID
    }

    /// True iff we have the minimum needed to stream: a connection ID and
    /// a notification subscriber. Other fields are optional accelerators.
    public var canStream: Bool {
        mainConnectionID != nil && registerNotifyProc != nil
    }

    /// Attempt to dlopen SkyLight and resolve every known symbol. Returns a
    /// fully-nil struct (i.e. `canStream == false`) if dlopen itself fails —
    /// callers treat that the same as a partial-resolution miss.
    public static func resolveFromSkyLight() -> SkyLightSymbols {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            return SkyLightSymbols()
        }
        // We deliberately do NOT dlclose: the symbols are referenced for the
        // process lifetime, and Apple's framework caches expect long-lived
        // handles. Closing would invalidate every resolved pointer.
        func sym<T>(_ name: String, as _: T.Type) -> T? {
            guard let raw = dlsym(handle, name) else { return nil }
            return unsafeBitCast(raw, to: T.self)
        }
        return SkyLightSymbols(
            mainConnectionID:   sym("SLSMainConnectionID",   as: SLSMainConnectionIDFn.self),
            registerNotifyProc: sym("SLSRegisterNotifyProc", as: SLSRegisterNotifyProcFn.self),
            getWindowBounds:    sym("SLSGetWindowBounds",    as: SLSGetWindowBoundsFn.self),
            getWindowOwner:     sym("SLSGetWindowOwner",     as: SLSGetWindowOwnerFn.self),
            connectionGetPID:   sym("SLSConnectionGetPID",   as: SLSConnectionGetPIDFn.self)
        )
    }
}
