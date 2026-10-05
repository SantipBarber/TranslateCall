import Foundation

// MARK: - Notice text

extension TTSEvent {
    /// The main window's one-line notice for this event (F8.5.2 REQ-T-41, design §3.7).
    /// `language` names the language the sentence was to be spoken in.
    nonisolated func noticeText(language: String) -> String {
        switch self {
        case .fellBack(let from, .avSpeech):
            return "\(from == .edgeTTS ? "Edge TTS" : from.displayName) unavailable — used system voice"
        case .fellBack(let from, let target):
            return "\(from.displayName) unavailable — used \(target.displayName)"
        case .utteranceSkipped(.noVoice):
            return "No voice for \(language) — sentence skipped"
        case .utteranceSkipped(.timeout), .utteranceSkipped(.primaryFailed):
            return "Speech failed — sentence skipped"
        case .utteranceSkipped(.interrupted):
            return "Speech interrupted — rest of the sentence skipped"
        case .utteranceSkipped(.outputUnavailable):
            return "Audio output unavailable — sentence skipped"
        case .backlog(let pending):
            return "Translation running behind — \(pending) sentences waiting"
        }
    }
}
