import CoreGraphics
import Foundation

/// What the renderer should draw for a single window. Pure data — no AppKit.
public struct BorderSpec: Sendable, Equatable {
    public let windowID: WindowID
    /// Frame in **Cocoa screen coordinates** (origin bottom-left, y grows up).
    /// The renderer can pass this directly to `NSWindow.setFrame`.
    public let frame: CGRect
    public let width: Double
    public let style: BordersConfig.Style
    public let color: ColorSpec
    public let isActive: Bool
}

/// Pure desired-state computation. Given window cache + focus + config snapshot,
/// returns the set of borders that *should* exist. The renderer diffs this
/// against its current set and executes create/update/destroy on main.
public enum BorderEngineLogic {
    /// Cocoa screen y-axis flip helper. `cgFrame` is in Quartz/Core Graphics
    /// coords (origin top-left of the primary display). `screen` describes
    /// the display whose Cocoa frame defines the target coordinate space.
    ///
    /// Centralized in one place because this is the #1 thing that goes wrong
    /// with overlay windows on multi-display setups.
    public static func cocoaFrame(
        from cgFrame: CGRect,
        primaryDisplayHeight: CGFloat
    ) -> CGRect {
        // CG coords: y measured from top of primary screen, y+H downwards.
        // Cocoa coords: y measured from bottom of primary screen, y+H upwards.
        let cocoaY = primaryDisplayHeight - cgFrame.origin.y - cgFrame.size.height
        return CGRect(
            x: cgFrame.origin.x,
            y: cocoaY,
            width: cgFrame.size.width,
            height: cgFrame.size.height
        )
    }

    /// Inputs assumed already-resolved (focus pid+id, exclusion check) so this
    /// function stays trivially testable.
    public struct Inputs {
        public let windows: [WindowID: WindowState]
        public let focusedWindowID: WindowID?
        public let snapshot: ConfigSnapshot
        public let overrides: BorderRuntimeOverrides
        public let primaryDisplayHeight: CGFloat
        public let aerospaceWorkspace: String?

        public init(
            windows: [WindowID: WindowState],
            focusedWindowID: WindowID?,
            snapshot: ConfigSnapshot,
            overrides: BorderRuntimeOverrides = .empty,
            primaryDisplayHeight: CGFloat,
            aerospaceWorkspace: String? = nil
        ) {
            self.windows = windows
            self.focusedWindowID = focusedWindowID
            self.snapshot = snapshot
            self.overrides = overrides
            self.primaryDisplayHeight = primaryDisplayHeight
            self.aerospaceWorkspace = aerospaceWorkspace
        }
    }

    /// Produces the desired set of border specs, keyed by window ID for cheap diffing.
    public static func desiredBorders(_ inputs: Inputs) -> [WindowID: BorderSpec] {
        // Precedence: per-window override > rule override > global override > config default.
        let effectiveGlobal = applyOverride(inputs.snapshot.borders, inputs.overrides.global)
        guard effectiveGlobal.enabled else { return [:] }

        var result: [WindowID: BorderSpec] = [:]
        result.reserveCapacity(inputs.windows.count)

        for (wid, w) in inputs.windows {
            guard w.isOnScreen else { continue }
            guard w.frame.width > 0, w.frame.height > 0 else { continue }

            let attrs = w.attributes(aerospaceWorkspace: inputs.aerospaceWorkspace)
            if RuleResolver.isExcluded(attrs, snapshot: inputs.snapshot) { continue }
            if !passesShimFilters(attrs: attrs, override: inputs.overrides.global) { continue }

            // Rule overrides patch the (already-overridden) global.
            let afterRule = applyRule(
                effectiveGlobal,
                rule: RuleResolver.firstMatchingRule(attrs, snapshot: inputs.snapshot)
            )
            let effective = applyOverride(afterRule, inputs.overrides.perWindow[wid] ?? BordersStyleRequest())

            let isActive = (wid == inputs.focusedWindowID)
            let cocoa = cocoaFrame(from: w.frame, primaryDisplayHeight: inputs.primaryDisplayHeight)

            result[wid] = BorderSpec(
                windowID: wid,
                frame: cocoa,
                width: effective.width,
                style: effective.style,
                color: isActive ? effective.active : effective.inactive,
                isActive: isActive
            )
        }
        return result
    }

    /// Patches a `BordersConfig` field-by-field from a runtime override request.
    /// Per-field nil means "leave alone".
    public static func applyOverride(_ base: BordersConfig, _ o: BordersStyleRequest) -> BordersConfig {
        BordersConfig(
            enabled: o.enabled ?? base.enabled,
            style: o.style ?? base.style,
            order: o.order ?? base.order,
            width: o.width ?? base.width,
            hidpi: o.hidpi ?? base.hidpi,
            active: o.active ?? base.active,
            inactive: o.inactive ?? base.inactive,
            background: BordersConfig.BackgroundConfig(
                enabled: o.backgroundEnabled ?? base.background.enabled,
                color: o.background ?? base.background.color
            )
        )
    }

    static func applyRule(_ base: BordersConfig, rule: Rule?) -> BordersConfig {
        guard let r = rule, let o = r.borderOverrides else { return base }
        return BordersConfig(
            enabled: base.enabled,
            style: o.style ?? base.style,
            order: base.order,
            width: o.width ?? base.width,
            hidpi: base.hidpi,
            active: o.active ?? base.active,
            inactive: o.inactive ?? base.inactive,
            background: base.background
        )
    }

    /// JankyBorders-style runtime blacklist/whitelist sourced from the global
    /// override (set via `borders blacklist=... whitelist=...`). Empty/nil
    /// means "no filter on this dimension".
    static func passesShimFilters(attrs: WindowAttributes, override: BordersStyleRequest) -> Bool {
        if let bl = override.blacklist, !bl.isEmpty,
           let app = attrs.appName, bl.contains(app) {
            return false
        }
        if let wl = override.whitelist, !wl.isEmpty {
            guard let app = attrs.appName, wl.contains(app) else { return false }
        }
        return true
    }

    /// Diff prev vs next desired-set into renderer-actionable lists.
    public struct Diff: Equatable {
        public let toCreate: [BorderSpec]
        public let toUpdate: [BorderSpec]
        public let toDestroy: [WindowID]
    }

    public static func diff(prev: [WindowID: BorderSpec], next: [WindowID: BorderSpec]) -> Diff {
        var create: [BorderSpec] = []
        var update: [BorderSpec] = []
        var destroy: [WindowID] = []

        for (wid, spec) in next {
            if let prev = prev[wid] {
                if prev != spec { update.append(spec) }
            } else {
                create.append(spec)
            }
        }
        for wid in prev.keys where next[wid] == nil {
            destroy.append(wid)
        }
        // Stable ordering helps tests and reduces apparent thrash in logs.
        create.sort { $0.windowID < $1.windowID }
        update.sort { $0.windowID < $1.windowID }
        destroy.sort()
        return Diff(toCreate: create, toUpdate: update, toDestroy: destroy)
    }
}
