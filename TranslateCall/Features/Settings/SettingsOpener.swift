import AppKit

/// The Settings tabs (REQ-UI-70). `advancedLegacy` is replaced by feature 2.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case advancedLegacy
    var id: String { rawValue }
}

/// Opens Settings on a given tab from anywhere, AppKit contexts included (status item, NSPanel).
/// SwiftUI's `openSettings` only exists inside a view: the setup window hands it over, the same
/// pattern as `MainWindowOpener` (design §7.3).
@MainActor
final class SettingsOpener {
    static let shared = SettingsOpener()
    /// `@AppStorage` key of the selected tab, read by `SettingsView`.
    static let tabKey = "ui.settings.tab"

    /// SwiftUI's `openSettings`; set once the first setup window appears.
    var openSettings: (() -> Void)?
    private let defaults: UserDefaults
    private let activate: () -> Void

    init(defaults: UserDefaults = .standard, activate: @escaping () -> Void = { NSApp.activate() }) {
        self.defaults = defaults
        self.activate = activate
    }

    /// Selects `tab`, brings the app forward and opens (or raises) the Settings window.
    @discardableResult
    func open(tab: SettingsTab) -> Bool {
        defaults.set(tab.rawValue, forKey: Self.tabKey)
        activate()
        guard let openSettings else { return false }
        openSettings()
        return true
    }
}
