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
        public let primaryDisplayHeight: CGFloat
        public let aerospaceWorkspace: String?

        public init(
            windows: [WindowID: WindowState],
            focusedWindowID: WindowID?,
            snapshot: ConfigSnapshot,
            primaryDisplayHeight: CGFloat,
            aerospaceWorkspace: String? = nil
        ) {
            self.windows = windows
            self.focusedWindowID = focusedWindowID
            self.snapshot = snapshot
            self.primaryDisplayHeight = primaryDisplayHeight
            self.aerospaceWorkspace = aerospaceWorkspace
        }
    }

    /// Produces the desired set of border specs, keyed by window ID for cheap diffing.
    public static func desiredBorders(_ inputs: Inputs) -> [WindowID: BorderSpec] {
        let g = inputs.snapshot.borders
        guard g.enabled else { return [:] }

        var result: [WindowID: BorderSpec] = [:]
        result.reserveCapacity(inputs.windows.count)

        for (wid, w) in inputs.windows {
            // Skip off-screen, zero-frame, or excluded windows.
            guard w.isOnScreen else { continue }
            guard w.frame.width > 0, w.frame.height > 0 else { continue }

            let attrs = w.attributes(aerospaceWorkspace: inputs.aerospaceWorkspace)
            if RuleResolver.isExcluded(attrs, snapshot: inputs.snapshot) { continue }

            // Resolve effective borders (rule overrides patch global).
            let effective = RuleResolver.resolveBorders(for: attrs, snapshot: inputs.snapshot)
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
