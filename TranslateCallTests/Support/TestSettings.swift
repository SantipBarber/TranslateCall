import Foundation
@testable import TranslateCall

extension ConversationSettings {
    /// Settings on a throwaway `UserDefaults` suite: unit tests never read the developer's real domain.
    static func forTesting() -> ConversationSettings {
        ConversationSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
    }
}
