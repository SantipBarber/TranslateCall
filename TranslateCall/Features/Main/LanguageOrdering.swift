import Foundation

/// The language pickers' order (REQ-UI-06): Español, English, Deutsch first, then the rest by
/// display name. `priority` is empty when none of them is supported.
nonisolated enum LanguageOrdering {
    static let priorityCodes = ["es", "en", "de"]

    static func ordered(_ supported: [Locale.Language], displayName: (Locale.Language) -> String)
        -> (priority: [Locale.Language], others: [Locale.Language]) {
        let priority = priorityCodes.compactMap { code in
            supported.first { $0.languageCode?.identifier == code }
        }
        let others = supported.filter { !priority.contains($0) }
            .sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
        return (priority, others)
    }
}
