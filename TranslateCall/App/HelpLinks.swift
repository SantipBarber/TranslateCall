import Foundation

/// Help destinations opened from the app (REQ-U-01).
enum HelpLinks {
    /// The usage guide on the repository's main branch.
    static let usageGuide: URL = {
        guard let url = URL(string: "https://github.com/SantipBarber/TranslateCall/blob/main/docs/usage-guide.md")
        else { preconditionFailure("Invalid usage guide URL") }
        return url
    }()
}
