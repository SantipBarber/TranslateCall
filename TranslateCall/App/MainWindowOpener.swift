import AppKit

/// What the opener needs to know about a window; `NSWindow` conforms, tests use fakes.
@MainActor
protocol MainWindowCandidate: AnyObject {
    var canBecomeMain: Bool { get }
    var isVisible: Bool { get }
    var isMiniaturized: Bool { get }
    func raise()
}

extension NSWindow: MainWindowCandidate {
    func raise() {
        if isMiniaturized { deminiaturize(nil) }
        makeKeyAndOrderFront(nil)
    }
}

/// Raises the main window, or asks SwiftUI to open it when none is on screen (F8.5.4 D-2).
/// The always-visible, borderless `TranslationHostWindow` makes AppKit think the app still has a
/// window, so neither the Dock click nor the menu bar would reopen a closed main window by themselves.
/// SwiftUI's `openWindow` only exists inside a view: `TranslateCallApp` hands it over at launch.
@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()
    static let windowID = "main"

    /// Opens a new main window; set once the first main window appears.
    var openWindow: (() -> Void)?

    /// Raises the first visible (or Dock-minimised) main-capable window, else requests a new one. Returns what it did.
    /// A hidden app (Cmd-H) has every window ordered out, so it is unhidden first: otherwise the lookup would
    /// miss the main window and a data-less `WindowGroup` would open a duplicate.
    @discardableResult
    func show(in windows: [any MainWindowCandidate], appIsHidden: Bool = false, unhide: () -> Void = {}) -> Outcome {
        if appIsHidden { unhide() }
        if let window = windows.first(where: { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }) {
            window.raise()
            return .raised
        }
        openWindow?()
        return .openRequested
    }

    enum Outcome: Equatable {
        case raised
        case openRequested
    }
}

/// Keeps the app alive with no main window (the call runs from the menu bar) and brings the
/// main window back on a Dock click.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // `flag` is always true: the translation host is a visible window. Look for a main-capable one.
        sender.showMainWindow()
        return false
    }
}
