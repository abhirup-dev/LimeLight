import CoreGraphics
import Foundation

/// Identity of a single border the renderer manages. Window borders track
/// their `WindowID`; screen borders (drawn on unfocused monitors in hybrid
/// mode) track the `CGDirectDisplayID` so they survive monitor reorderings.
public enum BorderID: Hashable, Sendable {
    case window(WindowID)
    case screen(CGDirectDisplayID)
}

/// What the renderer should draw for a single border. Pure data — no AppKit.
public struct BorderSpec: Sendable, Equatable {
    public let id: BorderID
    /// Frame in **Cocoa screen coordinates** (origin bottom-left, y grows up).
    /// The renderer can pass this directly to `NSWindow.setFrame`.
    public let frame: CGRect
    public let width: Double
    public let style: BordersConfig.Style
    public let color: ColorSpec
    public let isActive: Bool
}

/// One physical display's geometry, passed into the engine on every recompute.
/// We carry both coordinate systems because window membership is tested in CG
/// (top-left origin, where `WindowState.frame` lives) but the screen-border
/// overlay is positioned in Cocoa (bottom-left origin, where NSWindow lives).
public struct DisplayInfo: Sendable, Equatable {
    public let id: CGDirectDisplayID
    /// Full display rect in CG coords. Used to test window membership and to
    /// detect a fullscreen-Space window covering the whole display.
    public let cgFrame: CGRect
    /// `NSScreen.visibleFrame` — excludes menu bar and dock. The screen border
    /// uses this directly, so it never outlines the menu bar.
    public let cocoaVisibleFrame: CGRect
    /// Best-effort: a window on this display covers `cgFrame` exactly. Used to
    /// suppress the screen-wide border on native-fullscreen Spaces, where any
    /// outline would clip the fullscreen content.
    public let isFullscreen: Bool

    public init(id: CGDirectDisplayID, cgFrame: CGRect, cocoaVisibleFrame: CGRect, isFullscreen: Bool) {
        self.id = id
        self.cgFrame = cgFrame
        self.cocoaVisibleFrame = cocoaVisibleFrame
        self.isFullscreen = isFullscreen
    }
}

/// Pure desired-state computation. Given window cache + focus + config snapshot,
/// returns the set of borders that *should* exist. The renderer diffs this
/// against its current set and executes create/update/destroy on main.
public enum BorderEngineLogic {
    /// Cocoa screen y-axis flip helper. `cgFrame` is in Quartz/Core Graphics
    /// coords (origin top-left of the primary display). Centralized in one
    /// place because this is the #1 thing that goes wrong with overlay
    /// windows on multi-display setups.
    public static func cocoaFrame(
        from cgFrame: CGRect,
        primaryDisplayHeight: CGFloat
    ) -> CGRect {
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
        /// Windows in CGWindowList z-order, front-to-back.
        public let orderedWindows: [WindowState]
        public let focusedWindowID: WindowID?
        public let snapshot: ConfigSnapshot
        public let overrides: BorderRuntimeOverrides
        public let primaryDisplayHeight: CGFloat
        /// Display geometry for the hybrid per-monitor design. Empty disables
        /// the screen-border path entirely (single-display / test fallback).
        public let displays: [DisplayInfo]
        public let aerospaceWorkspace: String?

        public init(
            orderedWindows: [WindowState],
            focusedWindowID: WindowID?,
            snapshot: ConfigSnapshot,
            overrides: BorderRuntimeOverrides = .empty,
            primaryDisplayHeight: CGFloat,
            displays: [DisplayInfo] = [],
            aerospaceWorkspace: String? = nil
        ) {
            self.orderedWindows = orderedWindows
            self.focusedWindowID = focusedWindowID
            self.snapshot = snapshot
            self.overrides = overrides
            self.primaryDisplayHeight = primaryDisplayHeight
            self.displays = displays
            self.aerospaceWorkspace = aerospaceWorkspace
        }

        /// Convenience init for tests / call-sites that don't care about
        /// z-order or per-monitor geometry. Sorts by ID for determinism.
        public init(
            windows: [WindowID: WindowState],
            focusedWindowID: WindowID?,
            snapshot: ConfigSnapshot,
            overrides: BorderRuntimeOverrides = .empty,
            primaryDisplayHeight: CGFloat,
            displays: [DisplayInfo] = [],
            aerospaceWorkspace: String? = nil
        ) {
            self.orderedWindows = windows.values.sorted { $0.windowID < $1.windowID }
            self.focusedWindowID = focusedWindowID
            self.snapshot = snapshot
            self.overrides = overrides
            self.primaryDisplayHeight = primaryDisplayHeight
            self.displays = displays
            self.aerospaceWorkspace = aerospaceWorkspace
        }
    }

    /// Hybrid per-monitor border design.
    ///
    /// **Focused monitor** (the display containing the focused window's
    /// center): emit per-window borders for every visible, non-excluded
    /// window on that monitor. Focused window gets the active color, all
    /// other tiles on the same monitor get inactive. Preserves the
    /// AeroSpace tile UX where every visible tile is bordered.
    ///
    /// **Unfocused monitors**: emit one synthetic screen-wide border at
    /// `cocoaVisibleFrame` (excludes menu bar / dock), keyed by display ID.
    /// Cuts visual noise on the monitors you're not driving without losing
    /// the awareness that something's there.
    ///
    /// **Fullscreen monitors**: skipped — drawing a border around fullscreen
    /// content clips it visually.
    ///
    /// **No focus** (`focusedWindowID == nil`): hide all screen borders;
    /// fall back to per-window borders for everything visible (inactive
    /// color). Avoids a flickering screen border during cmd-tab gaps.
    ///
    /// **No display info** (empty `displays`): skip the screen-border path
    /// entirely; behave like single-display per-window mode. Tests that
    /// don't care about monitor topology hit this branch.
    public static func desiredBorders(_ inputs: Inputs) -> [BorderID: BorderSpec] {
        let effectiveGlobal = applyOverride(inputs.snapshot.borders, inputs.overrides.global)
        guard effectiveGlobal.enabled else { return [:] }

        // Determine the focused display (if any) by locating the focused
        // window's center inside one of the display CG rects.
        let focusedDisplayID: CGDirectDisplayID? = {
            guard !inputs.displays.isEmpty,
                  let fid = inputs.focusedWindowID,
                  let fw = inputs.orderedWindows.first(where: { $0.windowID == fid })
            else { return nil }
            let center = CGPoint(x: fw.frame.midX, y: fw.frame.midY)
            return inputs.displays.first { $0.cgFrame.contains(center) }?.id
        }()

        var result: [BorderID: BorderSpec] = [:]
        result.reserveCapacity(inputs.orderedWindows.count + inputs.displays.count)
        // Frames of windows already accepted, in z-order. The occlusion walk
        // (below) tests against this list so stacked windows produce only one
        // border — the top of the stack. AeroSpace tile layouts still pass
        // because adjacent tiles share an edge but `intersects` is exclusive.
        var acceptedFrames: [CGRect] = []
        acceptedFrames.reserveCapacity(inputs.orderedWindows.count)

        for w in inputs.orderedWindows {
            guard w.isOnScreen, w.frame.width > 0, w.frame.height > 0 else { continue }

            // Display membership: in hybrid mode, only emit per-window borders
            // for windows on the focused display. With no focus, fall back to
            // bordering every visible window on any known display.
            let windowDisplay = inputs.displays.first(where: {
                $0.cgFrame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY))
            })
            if !inputs.displays.isEmpty {
                guard let wd = windowDisplay else { continue }
                if let focused = focusedDisplayID, wd.id != focused { continue }
            }

            let attrs = w.attributes(aerospaceWorkspace: inputs.aerospaceWorkspace)
            if RuleResolver.isExcluded(attrs, snapshot: inputs.snapshot) { continue }
            if !passesShimFilters(attrs: attrs, override: inputs.overrides.global) { continue }

            // Occlusion: front-to-back, any overlap with a higher-z accepted
            // window means this window is not the top of its visual stack.
            // Strict any-overlap (partial cover counts as covered) gives the
            // JankyBorders-style "border only the visible window" behavior
            // even for piles of overlapping Slack-style windows.
            if acceptedFrames.contains(where: { $0.intersects(w.frame) }) { continue }

            let afterRule = applyRule(
                effectiveGlobal,
                rule: RuleResolver.firstMatchingRule(attrs, snapshot: inputs.snapshot)
            )
            let effective = applyOverride(afterRule, inputs.overrides.perWindow[w.windowID] ?? BordersStyleRequest())

            let isActive = (w.windowID == inputs.focusedWindowID)
            let cocoa = cocoaFrame(from: w.frame, primaryDisplayHeight: inputs.primaryDisplayHeight)

            result[.window(w.windowID)] = BorderSpec(
                id: .window(w.windowID),
                frame: cocoa,
                width: effective.width,
                style: effective.style,
                color: isActive ? effective.active : effective.inactive,
                isActive: isActive
            )
            acceptedFrames.append(w.frame)
        }

        // Screen borders: one per non-focused, non-fullscreen display, only
        // when we have a definite focused display. With no focus we'd
        // otherwise draw a grey rectangle on every monitor including the one
        // the user is about to focus into — flickery on cmd-tab.
        if let focused = focusedDisplayID {
            for d in inputs.displays where d.id != focused && !d.isFullscreen {
                result[.screen(d.id)] = BorderSpec(
                    id: .screen(d.id),
                    frame: d.cocoaVisibleFrame,
                    width: effectiveGlobal.width,
                    style: effectiveGlobal.style,
                    color: effectiveGlobal.inactive,
                    isActive: false
                )
            }
        }

        return result
    }

    /// Patches a `BordersConfig` field-by-field from a runtime override request.
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
    /// override (set via `borders blacklist=... whitelist=...`).
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
        public let toDestroy: [BorderID]
    }

    public static func diff(prev: [BorderID: BorderSpec], next: [BorderID: BorderSpec]) -> Diff {
        var create: [BorderSpec] = []
        var update: [BorderSpec] = []
        var destroy: [BorderID] = []

        for (id, spec) in next {
            if let prev = prev[id] {
                if prev != spec { update.append(spec) }
            } else {
                create.append(spec)
            }
        }
        for id in prev.keys where next[id] == nil {
            destroy.append(id)
        }
        // Stable ordering helps tests and reduces apparent thrash in logs.
        create.sort { borderIDOrder($0.id) < borderIDOrder($1.id) }
        update.sort { borderIDOrder($0.id) < borderIDOrder($1.id) }
        destroy.sort { borderIDOrder($0) < borderIDOrder($1) }
        return Diff(toCreate: create, toUpdate: update, toDestroy: destroy)
    }

    /// Sort key: window borders first (by WindowID), then screen borders (by
    /// CGDirectDisplayID). Both spaces are uint32; we offset screens to
    /// avoid collisions at the boundary.
    private static func borderIDOrder(_ id: BorderID) -> UInt64 {
        switch id {
        case .window(let w): return UInt64(w)
        case .screen(let s): return UInt64(UInt32.max) + 1 + UInt64(s)
        }
    }
}
