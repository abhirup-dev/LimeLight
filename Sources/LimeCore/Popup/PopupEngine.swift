import AppKit
import Foundation

/// Resolved popup request. Pure data — no AppKit references.
public struct PopupRequest: Sendable, Equatable {
    public let title: String
    public let message: String
    /// One of `topLeft|topRight|bottomLeft|bottomRight|center`.
    public let placement: String
    public let durationMs: Int

    public init(title: String, message: String, placement: String, durationMs: Int) {
        self.title = title
        self.message = message
        self.placement = placement
        self.durationMs = durationMs
    }
}

/// Transient on-screen popup. Never steals focus and never appears in the
/// CGWindowList enumeration (overlay-window pattern).
///
/// v0 design: a single transient NSWindow stack — placement is computed
/// against the *currently-active* NSScreen's `visibleFrame` so the popup
/// follows the user's monitor focus naturally.
@MainActor
public final class PopupEngine {
    private var activeWindows: [UUID: NSWindow] = [:]

    public init() {}

    @discardableResult
    public func show(_ req: PopupRequest) -> Bool {
        let id = UUID()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
        let size = NSSize(width: 320, height: 88)
        let frame = Self.placementFrame(for: req.placement, on: screen, size: size)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.sharingType = .none
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        w.collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = true

        let titleLabel = NSTextField(labelWithString: req.title)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 12, y: size.height - 28, width: size.width - 24, height: 18)

        let bodyLabel = NSTextField(labelWithString: req.message)
        bodyLabel.font = NSFont.systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.frame = NSRect(x: 12, y: 12, width: size.width - 24, height: size.height - 44)
        bodyLabel.maximumNumberOfLines = 3

        container.addSubview(titleLabel)
        container.addSubview(bodyLabel)
        w.contentView = container

        w.alphaValue = 0
        w.orderFrontRegardless()
        activeWindows[id] = w

        // Fade in (150ms) → hold → fade out (250ms) → orderOut.
        let dur = max(0.4, Double(req.durationMs) / 1000.0)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            w.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                w.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                w.orderOut(nil)
                self?.activeWindows.removeValue(forKey: id)
            })
        }
        return true
    }

    public func tearDown() {
        for w in activeWindows.values { w.orderOut(nil) }
        activeWindows.removeAll()
    }

    public var activeCount: Int { activeWindows.count }

    private static func placementFrame(for placement: String, on screen: NSScreen, size: NSSize) -> NSRect {
        let visible = screen.visibleFrame
        let margin: CGFloat = 16
        switch placement {
        case "topLeft":
            return NSRect(x: visible.minX + margin, y: visible.maxY - size.height - margin, width: size.width, height: size.height)
        case "bottomLeft":
            return NSRect(x: visible.minX + margin, y: visible.minY + margin, width: size.width, height: size.height)
        case "bottomRight":
            return NSRect(x: visible.maxX - size.width - margin, y: visible.minY + margin, width: size.width, height: size.height)
        case "center":
            return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        default: // topRight (also the config default)
            return NSRect(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin, width: size.width, height: size.height)
        }
    }
}
