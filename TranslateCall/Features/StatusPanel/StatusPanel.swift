import AppKit
import Combine
import SwiftUI

// MARK: - StatusPanel

/// The in-call status panel's window (REQ-UI-41, design §7.2): floating, non-activating, on every
/// Space and over full-screen apps, draggable by its background. It can never become key or main,
/// so it never takes focus or keystrokes from the call app (anti-goal in the brief).
final class StatusPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Top-right of `visibleFrame`, inset by `inset` (the default position).
    static func defaultOrigin(size: NSSize, visibleFrame: NSRect, inset: CGFloat = 16) -> NSPoint {
        NSPoint(x: visibleFrame.maxX - size.width - inset, y: visibleFrame.maxY - size.height - inset)
    }

    /// `frame` resized to `size` keeping its top edge (compact ↔ expanded grows downwards).
    static func resized(_ frame: NSRect, to size: NSSize) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// The frame to restore from a saved top-left: `size` hanging from `topLeft`, moved fully inside the
    /// visible frame it belongs to (the one containing the point, else the first). With no saved point
    /// or no screen, nil (use `defaultOrigin`). Saving the top-left, not the origin, keeps the panel
    /// from drifting down when the app quit while it was expanded.
    static func restoredFrame(topLeft: NSPoint?, size: NSSize, visibleFrames: [NSRect]) -> NSRect? {
        guard let topLeft, let first = visibleFrames.first else { return nil }
        let visible = visibleFrames.first { $0.insetBy(dx: -1, dy: -1).contains(topLeft) } ?? first
        let left = min(max(topLeft.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        let top = min(max(topLeft.y, visible.minY + size.height), visible.maxY)
        return NSRect(x: left, y: top - size.height, width: size.width, height: size.height)
    }
}

// MARK: - PanelHostingView

/// The panel's SwiftUI host. The panel never becomes key, so its buttons must act on the first
/// click without activating the app (design §7.2).
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - StatusPanelController

/// Shows, hides, expands and resizes the panel (the "panel presenter"); owned once by `UIServices`
/// (design §7.2). Views observe `isExpanded`.
///
/// Retain cycle, on purpose: the controller owns the panel, whose hosting view's root view holds the
/// controller as an environment object. Both live as long as the app, so nothing is broken; do not
/// create a second controller per session or per view.
///
/// The panel never becomes key, so its content must not contain a `TextField` or anything that needs
/// keyboard focus (buttons and links only).
@MainActor
final class StatusPanelController: ObservableObject {
    let panel: StatusPanel
    /// Compact (direction rows) or expanded (transcript, REQ-UI-44).
    @Published private(set) var isExpanded = false
    /// Keeps the panel in step with the session; set by `bind(to:defaults:)` (an extension cannot store it).
    var sessionSubscription: AnyCancellable?

    /// - Parameters:
    ///   - autosaveName: remembers the top-left across launches (in `defaults`); nil in tests.
    ///   - visibleFrames: the screens' visible frames, main first (injected for tests).
    ///   - content: builds the panel's content; it receives the controller (to observe `isExpanded`).
    init(size: NSSize, autosaveName: String? = "StatusPanel", defaults: UserDefaults = .standard,
         visibleFrames: () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) },
         content: (StatusPanelController) -> NSView) {
        panel = StatusPanel(contentRect: NSRect(origin: .zero, size: size))
        let frames = visibleFrames()
        let key = autosaveName.map { "\($0).topLeft" }
        let saved = key.flatMap { defaults.string(forKey: $0) }.map(NSPointFromString)
        if let restored = StatusPanel.restoredFrame(topLeft: saved, size: size, visibleFrames: frames) {
            panel.setFrame(restored, display: false)
        } else if let visible = frames.first {
            panel.setFrameOrigin(StatusPanel.defaultOrigin(size: size, visibleFrame: visible))
        }
        panel.contentView = Self.background(around: content(self), size: size)
        if let key {
            // Lives as long as the app, like the controller (see the note above).
            _ = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: panel, queue: .main
            ) { [weak panel] _ in
                guard let panel else { return }
                let frame = panel.frame
                defaults.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: key)
            }
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the panel without activating the app or taking focus.
    func show() {
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func hide() { panel.orderOut(nil) }

    /// The expand button: compact ↔ expanded.
    func toggleExpanded() { isExpanded.toggle() }

    /// Compact ↔ expanded, anchored at the top edge.
    func resize(to size: NSSize) {
        panel.setFrame(StatusPanel.resized(panel.frame, to: size), display: true, animate: false)
        panel.invalidateShadow()
    }

    /// A material background with 12 pt corners, `content` filling it (design §7.2). The corners come
    /// from `maskImage`: a layer corner radius does not clip the behind-window blur.
    private static func background(around content: NSView, size: NSSize) -> NSVisualEffectView {
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = roundedMask(radius: 12)
        content.frame = background.bounds
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        return background
    }

    /// A resizable rounded-rect mask: the corners stay fixed, the middle stretches.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
