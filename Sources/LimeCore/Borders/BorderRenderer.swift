import AppKit
import Foundation

/// Owns one borderless overlay `NSWindow` per tracked target. Applies
/// renderer-actionable diffs computed by `BorderEngineLogic` on the main
/// thread.
///
/// Style support (focusfx-kxs):
///   - solid    : plain `CALayer.borderColor` stroke.
///   - glow     : same stroke + outer `shadow*` halo. Window frame is
///                expanded outward so the halo isn't clipped.
///   - gradient : `CAGradientLayer` masked by a `CAShapeLayer` rounded-rect
///                stroke, so the gradient is visible only along the stroke.
///
/// `BordersConfig.background.enabled` is intentionally a no-op here —
/// painting a fill *under* a real app window needs SLSReorderWindow,
/// tracked in focusfx-007 (blocked on focusfx-b13).
@MainActor
public final class BorderRenderer {
    private var windows: [BorderID: BorderWindow] = [:]

    public init() {}

    /// Apply a diff. Must run on the main queue. `expected` is the full
    /// set of `BorderID`s the engine currently considers desired —
    /// passed alongside the diff so the renderer can reconcile and
    /// destroy any NSWindow whose ID has fallen out of the desired set
    /// (focusfx-ogp: under rapid focus churn we observed orphan border
    /// windows surviving past the destroy diff).
    public func apply(_ diff: BorderEngineLogic.Diff, expected: Set<BorderID>) {
        mainThreadBudget("borders.apply") {
            for spec in diff.toCreate {
                // Destroy any pre-existing window for the same BorderID
                // before creating a new one. Defensive: under rapid focus
                // churn (Arc multi-surface) we've seen the create path
                // collide with a not-yet-destroyed predecessor, leaking
                // an NSWindow that the engine no longer wants.
                if let prev = windows.removeValue(forKey: spec.id) {
                    prev.hide()
                }
                let w = BorderWindow(spec: spec)
                windows[spec.id] = w
                w.show()
            }
            for spec in diff.toUpdate {
                windows[spec.id]?.update(spec: spec)
            }
            for id in diff.toDestroy {
                if let w = windows.removeValue(forKey: id) {
                    w.hide()
                }
            }
            // Reconcile sweep: drop any NSWindow the engine no longer
            // considers desired. Catches the failure mode where a
            // border survives because its destroy diff was missed
            // (out-of-order apply, dropped event, etc.). Logs at fault
            // level so any occurrence shows up in `log stream`.
            for id in windows.keys where !expected.contains(id) {
                if let w = windows.removeValue(forKey: id) {
                    w.hide()
                    Log.borders.fault("renderer reconcile: destroyed orphan border \(String(describing: id), privacy: .public)")
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

/// Single borderless overlay window. Layer composition depends on the spec:
///   - solid / glow : one `CALayer` does the stroke; glow adds outer shadow.
///   - gradient     : a `CAGradientLayer` covers the bounds, masked by a
///                    `CAShapeLayer` whose stroked path is the rounded
///                    rectangle border. The mask makes the gradient appear
///                    only along the stroke.
///
/// The window is sized to `spec.frame` for solid/gradient, but for glow it
/// is inset outward by `glowOuterInset` so the shadow halo isn't clipped
/// at the edges of the overlay window. We always re-evaluate the layer
/// stack on a style/colour change rather than animating between modes.
@MainActor
private final class BorderWindow {
    private let window: NSWindow
    /// Stroke layer for solid / glow; nil while in gradient mode.
    private var strokeLayer: CALayer?
    /// Gradient layer for gradient mode; nil otherwise.
    private var gradientLayer: CAGradientLayer?
    /// Mask for gradient mode that turns the filled gradient into a stroke.
    private var gradientMask: CAShapeLayer?
    private var currentSpec: BorderSpec

    init(spec: BorderSpec) {
        self.currentSpec = spec

        let outerFrame = Self.outerFrame(for: spec)
        let w = NSWindow(
            contentRect: outerFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        // sharingType=.none hides this window from CGWindowListCopyWindowInfo,
        // so the next enumeration tick won't re-border our own borders.
        w.sharingType = .none
        w.level = Self.windowLevel(for: spec)
        // Per-Space attachment: `.moveToActiveSpace` keeps the border on
        // the user's current Space rather than ghosting onto every Space
        // (`.canJoinAllSpaces`, the v0 default). The engine recomputes on
        // SLS spaceChange events anyway, so a fresh border is emitted for
        // the new Space's focused window almost immediately (focusfx-sf2).
        w.collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: outerFrame.size))
        content.wantsLayer = true
        content.layer?.masksToBounds = false
        Self.applyHidpi(spec, to: content)
        w.contentView = content

        self.window = w
        rebuildLayers(for: spec, in: content)
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

        let prev = currentSpec
        let modeChanged = colorMode(prev.color) != colorMode(spec.color)
        let frameChanged = spec.frame != prev.frame
        let glowChanged = (prev.color.isGlow || spec.color.isGlow) && prev.color != spec.color

        if prev.order != spec.order {
            window.level = Self.windowLevel(for: spec)
        }
        if prev.hidpi != spec.hidpi, let view = window.contentView {
            Self.applyHidpi(spec, to: view)
        }

        if modeChanged || (glowChanged && frameChanged == false) {
            // Outer-frame size depends on whether glow halo padding is needed,
            // so we may need to resize even when spec.frame is unchanged.
            window.setFrame(Self.outerFrame(for: spec), display: false, animate: false)
            if let view = window.contentView {
                view.frame = NSRect(origin: .zero, size: window.frame.size)
            }
            if let view = window.contentView {
                rebuildLayers(for: spec, in: view)
            }
            currentSpec = spec
            return
        }

        if frameChanged {
            window.setFrame(Self.outerFrame(for: spec), display: false, animate: false)
            if let view = window.contentView {
                view.frame = NSRect(origin: .zero, size: window.frame.size)
            }
        }
        if frameChanged
            || spec.width != prev.width
            || spec.style != prev.style
            || spec.color != prev.color {
            applyStyle(for: spec)
        }
        currentSpec = spec
    }

    // MARK: - layer composition

    private func rebuildLayers(for spec: BorderSpec, in content: NSView) {
        content.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        strokeLayer = nil
        gradientLayer = nil
        gradientMask = nil

        switch spec.color {
        case .solid, .glow:
            let layer = CALayer()
            layer.masksToBounds = false
            content.layer?.addSublayer(layer)
            strokeLayer = layer
        case .gradient:
            let mask = CAShapeLayer()
            mask.fillColor = NSColor.clear.cgColor
            mask.strokeColor = NSColor.white.cgColor
            let grad = CAGradientLayer()
            grad.mask = mask
            content.layer?.addSublayer(grad)
            gradientLayer = grad
            gradientMask = mask
        }
        applyStyle(for: spec)
    }

    private func applyStyle(for spec: BorderSpec) {
        let outerSize = Self.outerFrame(for: spec).size
        let halo = Self.glowHaloRadius(for: spec)
        let inner = CGRect(
            x: halo, y: halo,
            width: max(0, outerSize.width - 2 * halo),
            height: max(0, outerSize.height - 2 * halo)
        )
        let cornerRadius = Self.cornerRadius(style: spec.style, frameSize: spec.frame.size)
        let halfWidth = CGFloat(spec.width) / 2

        switch spec.color {
        case .solid(let rgba):
            guard let layer = strokeLayer else { return }
            layer.frame = inner.insetBy(dx: halfWidth, dy: halfWidth)
            layer.borderWidth = CGFloat(spec.width)
            layer.borderColor = Self.cgColor(rgba)
            layer.cornerRadius = cornerRadius
            layer.shadowOpacity = 0
            layer.shadowRadius = 0

        case .glow(let rgba):
            guard let layer = strokeLayer else { return }
            layer.frame = inner.insetBy(dx: halfWidth, dy: halfWidth)
            layer.borderWidth = CGFloat(spec.width)
            layer.borderColor = Self.cgColor(rgba)
            layer.cornerRadius = cornerRadius
            layer.shadowColor = Self.cgColor(rgba)
            layer.shadowOffset = .zero
            layer.shadowRadius = halo
            layer.shadowOpacity = Float(rgba.a)

        case .gradient(let axis, let start, let end):
            guard let grad = gradientLayer, let mask = gradientMask else { return }
            grad.frame = inner
            grad.colors = [Self.cgColor(start), Self.cgColor(end)]
            switch axis {
            case .topLeftToBottomRight:
                grad.startPoint = CGPoint(x: 0, y: 1)
                grad.endPoint = CGPoint(x: 1, y: 0)
            case .topRightToBottomLeft:
                grad.startPoint = CGPoint(x: 1, y: 1)
                grad.endPoint = CGPoint(x: 0, y: 0)
            }
            // Stroke path inset by half-width so the line sits centered on
            // the rounded rectangle's edge — same as the solid case.
            let strokeRect = CGRect(origin: .zero, size: inner.size).insetBy(dx: halfWidth, dy: halfWidth)
            mask.frame = grad.bounds
            mask.path = CGPath(
                roundedRect: strokeRect,
                cornerWidth: max(0, cornerRadius - halfWidth),
                cornerHeight: max(0, cornerRadius - halfWidth),
                transform: nil
            )
            mask.lineWidth = CGFloat(spec.width)
        }
    }

    // MARK: - geometry helpers

    /// `glow` needs the overlay window slightly larger than the target frame
    /// so the shadow halo isn't clipped at the window edge. The amount is
    /// proportional to stroke width but capped — large halos waste GPU time
    /// and look like a fog rather than a frame.
    private static func glowHaloRadius(for spec: BorderSpec) -> CGFloat {
        guard case .glow = spec.color else { return 0 }
        return min(CGFloat(spec.width) * 2, 18)
    }

    private static func outerFrame(for spec: BorderSpec) -> CGRect {
        let halo = glowHaloRadius(for: spec)
        return spec.frame.insetBy(dx: -halo, dy: -halo)
    }

    /// Map JankyBorders `order=above|below` onto an NSWindow level.
    /// `above`: status bar + 1, the original v0 placement (border floats
    /// over OS chrome too — important for fullscreen Spaces).
    /// `below`: status bar - 1, so the menu bar still covers the overlay.
    /// Both sit above all normal app windows so the stroke stays visible.
    private static func windowLevel(for spec: BorderSpec) -> NSWindow.Level {
        let base = NSWindow.Level.statusBar.rawValue
        switch spec.order {
        case .above: return NSWindow.Level(rawValue: base + 1)
        case .below: return NSWindow.Level(rawValue: base - 1)
        }
    }

    /// `hidpi=on` renders the overlay's content layer at the screen's
    /// native backing-scale (sharp on retina). `hidpi=off` pins it to 1x:
    /// strokes look softer but the GPU draws fewer pixels — JankyBorders
    /// exposes this knob for users on battery-constrained machines.
    private static func applyHidpi(_ spec: BorderSpec, to view: NSView) {
        guard let layer = view.layer else { return }
        let backing: CGFloat = spec.hidpi
            ? (view.window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
            : 1.0
        layer.contentsScale = backing
        for sub in layer.sublayers ?? [] {
            sub.contentsScale = backing
        }
    }

    private static func cornerRadius(style: BordersConfig.Style, frameSize: CGSize) -> CGFloat {
        switch style {
        case .round:
            return min(12, min(frameSize.width, frameSize.height) / 2)
        case .square, .uniform:
            return 0
        }
    }

    private static func cgColor(_ rgba: ColorSpec.RGBA) -> CGColor {
        CGColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }

    private func colorMode(_ c: ColorSpec) -> Int {
        switch c {
        case .solid: return 0
        case .glow: return 1
        case .gradient: return 2
        }
    }
}

private extension ColorSpec {
    var isGlow: Bool { if case .glow = self { return true } else { return false } }
}
