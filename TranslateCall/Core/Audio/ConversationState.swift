// MARK: - ConversationState

/// What the conversation is doing, for the status badge and the menu bar icon (F8.5.3 REQ-H-13).
/// Replaces the half-duplex state machine: nothing is suppressed any more, the mic is only paused
/// by `MicEchoGate` in speakers mode.
nonisolated enum ConversationState: Equatable, Sendable {
    /// No translation is playing.
    case listening
    /// A translation is playing (either direction); both directions keep listening.
    case speaking
    /// Speakers mode: the mic is muted while the remote side's translation plays.
    case micPaused

    static func derive(micPaused: Bool, outgoingSpeaking: Bool, incomingSpeaking: Bool) -> ConversationState {
        if micPaused { return .micPaused }
        if outgoingSpeaking || incomingSpeaking { return .speaking }
        return .listening
    }
}
