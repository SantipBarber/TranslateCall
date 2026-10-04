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

    // MARK: - Init

    init(viewModel: AudioViewModel) {
        self.viewModel = viewModel
        super.init()
        setupStatusItem()
        observeState()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }

        button.image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: "TranslateCall")
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 280, height: 240)
        pop.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(viewModel: viewModel)
        )
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
        toggleItem.isEnabled = !viewModel.isStarting   // start() in flight: no Stop/Start until it settles
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Main Window", action: #selector(openMainWindow), keyEquivalent: ""))
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
        guard !viewModel.isStarting else { return }
        Task { await viewModel.toggleCapture() }
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
    }

    // MARK: - State observation

    private func observeState() {
        cancellable = viewModel.$halfDuplexState
            .combineLatest(viewModel.$isCapturing)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, isCapturing in
                self?.updateIcon(state: state, isCapturing: isCapturing)
            }
    }

    private func updateIcon(state: HalfDuplexState, isCapturing: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if !isCapturing {
            symbol = "mic.slash"
        } else {
            switch state {
            case .speaking, .transitioning: symbol = "waveform"
            case .listening:                symbol = "mic"
            }
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TranslateCall")
        button.image?.isTemplate = true
    }
}
