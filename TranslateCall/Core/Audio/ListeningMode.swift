// MARK: - ListeningMode

/// How the user hears the translated voice (F8.5.3 D-2). Persisted by `ConversationSettings`.
nonisolated enum ListeningMode: String, Sendable, CaseIterable {
    /// The mic cannot hear the translation: nothing is ever muted (default, recommended).
    case headphones
    /// The mic hears the remote side's translation: `MicEchoGate` mutes it while it plays.
    case speakers
}
