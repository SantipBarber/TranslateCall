import Foundation

/// Opens (or raises) the setup assistant window. `Window(id: "setup")` has a single instance, so
/// `openWindow` brings an open one to the front (REQ-FR-02). SwiftUI's `openWindow` only exists
/// inside a view: `TranslateCallApp` hands it over when the main window appears, like `MainWindowOpener`.
@MainActor
final class SetupWindowOpener {
    static let shared = SetupWindowOpener()
    static let windowID = "setup"

    var openWindow: (() -> Void)?

    func open() {
        openWindow?()
    }
}
