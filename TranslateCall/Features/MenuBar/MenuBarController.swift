import AppKit
import Combine
import SwiftUI

/// Controls the menu bar status item and its popover.
///
/// Must be `NSObject` subclass so `@objc` selectors work for `NSMenuItem` targets.
/// Created once at app launch by `TranslateCallApp` and kept alive for the session.
@MainActor
final class MenuBarController: NSObject {

    // MARK: - Private storage

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellable: AnyCancellable?
    private let viewModel: AudioViewModel
    private let session: CallSessionModel
    private let setup: MainSetupModel
    private let panel: StatusPanelController

    // MARK: - Init

    init(viewModel: AudioViewModel, session: CallSessionModel, setup: MainSetupModel, panel: StatusPanelController) {
        self.viewModel = viewModel
        self.session = session
        self.setup = setup
        self.panel = panel
        super.init()
        setupStatusItem()
        observeState()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }

        button.image = Self.icon(dot: .none)
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self

        let pop = NSPopover()
        pop.behavior = .transient
        let host = NSHostingController(
            rootView: MenuBarPopoverView(session: session, setup: setup, viewModel: viewModel, panel: panel)
        )
        host.sizingOptions = .preferredContentSize
        pop.contentViewController = host
        popover = pop
    }

    // MARK: - Actions

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false   // isEnabled below is authoritative

        let toggleTitle = viewModel.isCapturing ? "Stop Translation" : "Start Translation"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleCapture), keyEquivalent: "")
        // start() in flight or the call app opening (no cancel path): no Stop/Start until it settles.
        toggleItem.isEnabled = !viewModel.isStarting && session.phase != .launching
        menu.addItem(toggleItem)
        let running = session.phase == .running
        let pauseItem = NSMenuItem(title: session.isPaused ? "Resume" : "Pause",
                                   action: #selector(togglePause), keyEquivalent: "")
        pauseItem.isEnabled = running
        menu.addItem(pauseItem)
        let skipItem = NSMenuItem(title: "Skip My Next Sentence", action: #selector(skipNextSentence),
                                  keyEquivalent: "")
        skipItem.isEnabled = running
        menu.addItem(skipItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Main Window", action: #selector(openMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit TranslateCall",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        for item in menu.items { item.target = self }

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func toggleCapture() {
        guard !viewModel.isStarting, session.phase != .launching else { return }
        if session.phase == .running {
            Task { await session.stop() }
        } else {
            MenuBarStart.start(setup: setup, viewModel: viewModel)
        }
    }

    @objc private func togglePause() {
        Task { await session.togglePause() }
    }

    @objc private func skipNextSentence() {
        session.skipNextSentence()
    }

    @objc private func openSettings() {
        SettingsOpener.shared.open(tab: .general)
    }

    @objc private func openMainWindow() {
        NSApp.showMainWindow()
    }

    // MARK: - State observation

    private func observeState() {
        cancellable = session.$phase
            .combineLatest(session.$title)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, title in
                self?.updateIcon(dot: MenuBarDot.derive(phase: phase, title: title))
            }
    }

    /// Menu bar symbol for a state (F8.5.3 REQ-H-13).
    nonisolated static func iconName(state: ConversationState, isCapturing: Bool) -> String {
        guard isCapturing else { return "mic.slash" }
        switch state {
        case .listening:  return "mic"
        case .speaking:   return "waveform"
        case .micPaused:  return "mic.slash.circle"
        }
    }

    private func updateIcon(dot: MenuBarDot) {
        statusItem?.button?.image = Self.icon(dot: dot)
    }

    /// The status item's image: the template glyph at 15 pt; with a dot, an 18×18 drawing with a 6 pt
    /// filled circle at the bottom-right (REQ-UI-61). The dotted image is not a template, so the glyph is
    /// tinted with the label colour at draw time to follow the menu bar's appearance.
    static func icon(dot: MenuBarDot) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let symbol = NSImage(systemSymbolName: MenuBarDot.symbolName, accessibilityDescription: "TranslateCall")?
            .withSymbolConfiguration(config) ?? NSImage()
        let color: NSColor
        switch dot {
        case .none:
            symbol.isTemplate = true
            return symbol
        case .green: color = .systemGreen
        case .orange: color = .systemOrange
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let size = symbol.size
            let glyph = NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                               width: size.width, height: size.height)
            symbol.draw(in: glyph)
            NSColor.labelColor.set()
            glyph.fill(using: .sourceAtop)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: 0, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "TranslateCall"
        return image
    }
}

extension NSApplication {
    /// Raises the visible main-capable window, or opens one if the user closed it. The off-screen
    /// `TranslationHostWindow` is borderless and cannot become main, so it is never picked (F8.5.4 D-2).
    func showMainWindow() {
        activate(ignoringOtherApps: true)
        MainWindowOpener.shared.show(in: windows, appIsHidden: isHidden, unhide: { unhide(nil) })
    }
}
