import Foundation

/// Which way a sentence travels: `outgoing` = the user → the call, `incoming` = the call → the user.
nonisolated enum TranscriptDirection: Sendable, Equatable {
    case outgoing, incoming
}

/// One sentence of the session transcript (REQ-UI-44, design §4.1).
nonisolated struct TranscriptEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let direction: TranscriptDirection
    let original: String
    /// nil while translating, or when the sentence was skipped.
    var translation: String?
    /// Translation failed: shown dimmed with a note.
    var skipped = false
    let date: Date
    /// From `LatencyProvider` when available.
    var latency: Duration?

    init(direction: TranscriptDirection, original: String, date: Date = .now) {
        id = UUID()
        self.direction = direction
        self.original = original
        self.date = date
    }

    /// Kept at most (REQ-UI-44).
    static let limit = 200
}
