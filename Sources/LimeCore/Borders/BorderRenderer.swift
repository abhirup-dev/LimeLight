import AppKit
import Foundation

/// Owns one borderless overlay `NSWindow` per tracked target. Applies
/// renderer-actionable diffs computed by `BorderEngineLogic` on the main
/// thread. Glow / gradient / background fill are explicitly NOT implemented
/// in v0 — see follow-up `focusfx-kxs`. Solid color (round / square /
/// uniform) only.
@MainActor
public final class BorderRenderer {
    private var windows: [WindowID: BorderWindow] = [:]

    public init() {}

    /// Apply a diff. Must run on the main queue.
    public func apply(_ diff: BorderEngineLogic.Diff) {
        mainThreadBudget("borders.apply") {
            for spec in diff.toCreate {
                let w = BorderWindow(spec: spec)
                windows[spec.windowID] = w
                w.show()
            }
            for spec in diff.toUpdate {
                windows[spec.windowID]?.update(spec: spec)
            }
            for wid in diff.toDestroy {
                if let w = windows.removeValue(forKey: wid) {
                    w.hide()
                }
            }
        }
    }

    /// Tear down everything (config reload / shutdown).
    public func tearDown() {
        for w in windows.values { w.hide() }
        windows.removeAll()
    }

    public var liveWindowCount: Int { windows.count }
}

/// Single borderless overlay window backed by a CALayer with `borderColor`,
/// `borderWidth`, and `cornerRadius`. No `CADisplayLink` / no `Timer` /
/// no animation — purely event-driven from coalescer ticks.
@MainActor
private final class BorderWindow {
    private let window: NSWindow
    private let borderLayer: CALayer
    private var currentSpec: BorderSpec

    init(spec: BorderSpec) {
        self.currentSpec = spec

        let w = NSWindow(
            contentRect: spec.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // .canJoinAllSpaces is wrong for true per-Space attachment, but fine
        // for v0 — borders show on all Spaces. Per-Space membership is part
        // of focusfx-b13 (SLS streaming) where Space IDs become available.
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: spec.frame.size))
        content.wantsLayer = true
        w.contentView = content

        let layer = CALayer()
        layer.frame = content.bounds
        layer.backgroundColor = NSColor.clear.cgColor
        content.layer?.addSublayer(layer)

        self.window = w
        self.borderLayer = layer

        applyColor(spec.color)
        applyShape(width: spec.width, style: spec.style, frameSize: spec.frame.size)
    }

    func show() {
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    func update(spec: BorderSpec) {
        // Disable implicit CA animations — the coalescer is our event source,
        // we don't want layer property changes to spawn their own draw loops.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if spec.frame != currentSpec.frame {
            window.setFrame(spec.frame, display: false, animate: false)
            if let view = window.contentView {
                view.frame = NSRect(origin: .zero, size: spec.frame.size)
                borderLayer.frame = view.bounds
            }
        }
        if spec.color != currentSpec.color {
            applyColor(spec.color)
        }
        if spec.width != currentSpec.width || spec.style != currentSpec.style
            || spec.frame.size != currentSpec.frame.size {
            applyShape(width: spec.width, style: spec.style, frameSize: spec.frame.size)
        }
        currentSpec = spec
    }

    private func applyColor(_ spec: ColorSpec) {
        // v0: solid only. glow / gradient land in focusfx-kxs.
        let rgba: ColorSpec.RGBA
        switch spec {
        case .solid(let v): rgba = v
        case .glow(let v): rgba = v       // fallback to solid for v0
        case .gradient(_, let start, _): rgba = start
        }
        borderLayer.borderColor = CGColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }

    private func applyShape(width: Double, style: BordersConfig.Style, frameSize: CGSize) {
        borderLayer.borderWidth = CGFloat(width)
        borderLayer.cornerRadius = {
            switch style {
            case .round:
                return min(12, min(frameSize.width, frameSize.height) / 2)
            case .square:
                return 0
            case .uniform:
                // PLAN.md treats uniform as square-with-rounded-corners-disabled for now.
                return 0
            }
        }()
        // Inset the layer by half-width so the stroke sits centered on the window edge.
        let inset = CGFloat(width) / 2
        borderLayer.frame = CGRect(
            x: inset, y: inset,
            width: max(0, frameSize.width - 2 * inset),
            height: max(0, frameSize.height - 2 * inset)
        )
    }
}
