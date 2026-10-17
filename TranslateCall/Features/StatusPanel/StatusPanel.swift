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
}

// MARK: - PanelHostingView

/// The panel's SwiftUI host. The panel never becomes key, so its buttons must act on the first
/// click without activating the app (design §7.2).
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - StatusPanelController

/// Shows, hides, expands and resizes the panel (the "panel presenter"); owned by `UIServices`
/// (design §7.2). Views observe `isExpanded`.
@MainActor
final class StatusPanelController: ObservableObject {
    let panel: StatusPanel
    /// Compact (direction rows) or expanded (transcript, REQ-UI-44).
    @Published private(set) var isExpanded = false

    /// - Parameters:
    ///   - autosaveName: remembers the position across launches; nil in tests.
    ///   - screenFrame: the main screen's visible frame (injected for tests).
    ///   - content: builds the panel's content; it receives the controller (to observe `isExpanded`).
    init(size: NSSize, autosaveName: String? = "StatusPanel",
         screenFrame: () -> NSRect? = { NSScreen.main?.visibleFrame },
         content: (StatusPanelController) -> NSView) {
        panel = StatusPanel(contentRect: NSRect(origin: .zero, size: size))
        let restored = autosaveName.map { panel.setFrameUsingName($0) } ?? false
        if let autosaveName { panel.setFrameAutosaveName(autosaveName) }
        if !restored, let visible = screenFrame() {
            panel.setFrameOrigin(StatusPanel.defaultOrigin(size: size, visibleFrame: visible))
        }
        panel.contentView = Self.background(around: content(self))
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the panel without activating the app or taking focus.
    func show() { panel.orderFrontRegardless() }

    func hide() { panel.orderOut(nil) }

    /// The expand button: compact ↔ expanded.
    func toggleExpanded() { isExpanded.toggle() }

    /// Compact ↔ expanded, anchored at the top edge.
    func resize(to size: NSSize) {
        panel.setFrame(StatusPanel.resized(panel.frame, to: size), display: true, animate: false)
    }

    /// A material background with a 12 pt corner radius, `content` filling it (design §7.2).
    private static func background(around content: NSView) -> NSVisualEffectView {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        content.frame = background.bounds
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        return background
    }
}
