import AppKit
import CoreGraphics
import Foundation
import QuartzCore

/// Resolved trigger request. Pure data — no AppKit references.
public struct EffectTrigger: Sendable, Equatable {
    public let effect: String
    public let frame: CGRect
    /// Cocoa-coordinates frame (bottom-left origin) for direct NSWindow use.
    public let cocoaFrame: CGRect
    public let color: ColorSpec.RGBA
    public let durationMs: Int

    public init(effect: String, frame: CGRect, cocoaFrame: CGRect, color: ColorSpec.RGBA, durationMs: Int) {
        self.effect = effect
        self.frame = frame
        self.cocoaFrame = cocoaFrame
        self.color = color
        self.durationMs = durationMs
    }
}

/// Outcome of a trigger request. The IPC handler returns this synchronously
/// (focusfx-18.2 acceptance: "IPC returns accepted/status rather than blocking
/// on render completion") — actual rendering happens on the main queue.
public enum EffectAccepted: Sendable, Equatable {
    case accepted
    case unknownEffect
    case effectNotImplemented
    case noTarget
}

/// Renders transient effects on top of windows. v0 ships **cometRing** as a
/// CALayer-based ring trace; the other JankyBorders-aligned effect names
/// (neon/shockwave/line) parse and route here too but report
/// `effectNotImplemented` until their renderers land — a stable wire
/// contract so CLI/Hammerspoon callers can detect missing visuals without
/// the daemon hanging.
///
/// **Click-through.** Overlay NSWindows set `ignoresMouseEvents = true` and
/// `sharingType = .none` so they never steal focus and never appear in
/// CGWindowList enumeration (which would re-border our own effect).
///
/// **Idle GPU.** When no effect is active, no overlay window exists — there
/// is nothing for Core Animation to draw. The cometRing animation has a
/// finite duration and orderOut runs in the CATransaction completion
/// handler, so the layer stops driving CA commits the frame after the
/// duration ends.
@MainActor
public final class EffectEngine {
    public static let knownEffects: Set<String> = ["neon", "shockwave", "line", "cometRing"]

    private var activeWindows: [UUID: NSWindow] = [:]

    public init() {}

    /// Synchronous accept-or-reject. Spawns the actual render on the main
    /// queue so the IPC worker thread is never blocked on render completion.
    @discardableResult
    public func trigger(_ t: EffectTrigger) -> EffectAccepted {
        guard Self.knownEffects.contains(t.effect) else { return .unknownEffect }
        guard t.cocoaFrame.width > 0, t.cocoaFrame.height > 0 else { return .noTarget }
        switch t.effect {
        case "cometRing":
            spawnCometRing(t)
            return .accepted
        default:
            // neon/shockwave/line: parser-known, renderer pending
            // (focusfx-18.2 follow-up).
            return .effectNotImplemented
        }
    }

    /// Tear down every active overlay window (daemon shutdown / config
    /// reload). Idempotent.
    public func tearDown() {
        for w in activeWindows.values { w.orderOut(nil) }
        activeWindows.removeAll()
    }

    /// Diagnostic: number of currently-rendering effects. 0 means no
    /// overlay window exists and nothing is driving CA commits.
    public var activeEffectCount: Int { activeWindows.count }

    // MARK: - cometRing

    private func spawnCometRing(_ t: EffectTrigger) {
        let id = UUID()
        let window = makeOverlayWindow(frame: t.cocoaFrame)
        activeWindows[id] = window
        guard let view = window.contentView, let layer = view.layer else {
            window.orderOut(nil)
            activeWindows.removeValue(forKey: id)
            return
        }

        let ring = CAShapeLayer()
        ring.frame = CGRect(origin: .zero, size: t.cocoaFrame.size)
        let rect = CGRect(origin: .zero, size: t.cocoaFrame.size).insetBy(dx: 4, dy: 4)
        ring.path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        ring.strokeColor = CGColor(srgbRed: t.color.r, green: t.color.g, blue: t.color.b, alpha: t.color.a)
        ring.fillColor = NSColor.clear.cgColor
        ring.lineWidth = 4
        ring.lineCap = .round
        ring.strokeStart = 0
        ring.strokeEnd = 0
        layer.addSublayer(ring)

        window.orderFrontRegardless()

        let duration = max(0.05, Double(t.durationMs) / 1000.0)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            window.orderOut(nil)
            self.activeWindows.removeValue(forKey: id)
        }
        let trace = CABasicAnimation(keyPath: "strokeEnd")
        trace.fromValue = 0
        trace.toValue = 1
        trace.duration = duration * 0.7
        trace.timingFunction = CAMediaTimingFunction(name: .easeOut)
        trace.fillMode = .forwards
        trace.isRemovedOnCompletion = false

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + duration * 0.7
        fade.duration = duration * 0.3
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false

        ring.add(trace, forKey: "trace")
        ring.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    private func makeOverlayWindow(frame: CGRect) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.sharingType = .none
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        w.collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        w.contentView = view
        return w
    }
}
