import AppKit
import SwiftUI

/// Keeps both call-time translation bridges alive for the app's lifetime in an off-screen window,
/// so translation does not depend on the main window being open (F8.5.4 D-2, REQ-TR-30/31).
/// Borderless windows never become key or main; this one is also hidden from the Window menu.
@MainActor
final class TranslationHostWindow {
    let window: NSWindow

    init(outgoing: TranslationBridgeModel, incoming: TranslationBridgeModel) {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.canHide = false        // Cmd-H must not order it out: .translationTask needs a visible host
        window.isRestorable = false   // never part of window restoration
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = NSHostingView(rootView: HStack(spacing: 0) {
            TranslationBridge(model: outgoing)
            TranslationBridge(model: incoming)
        })
        window.orderBack(nil)
        self.window = window
    }

    /// Tests only: the app keeps its host window until it quits.
    func close() {
        window.close()
    }
}
