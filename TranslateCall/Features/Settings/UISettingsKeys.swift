import Foundation

/// `@AppStorage` keys of the M9 UI settings (REQ-UI-40, 71).
nonisolated enum UISettingsKeys {
    /// "Show the status panel" (default on).
    static let showStatusPanel = "ui.showStatusPanel"
    /// "Show latency in the panel" (default on; only offered while a latency provider can provide).
    static let showLatency = "ui.showLatency"

    /// Registers both defaults as on, so `bool(forKey:)` and `@AppStorage` agree on a fresh install.
    /// `UIServices` calls it at launch, before any view or the panel reads them (P31).
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [showStatusPanel: true, showLatency: true])
    }
}
