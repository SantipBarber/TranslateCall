import Foundation

/// Recognizes the user's mic picking up the other side's translation from the speakers, by its
/// words, whatever the listening mode (M9 scenario-tests: the Task 18 Q6 loop). `MicEchoGate` mutes
/// the mic in speakers mode; this catches what gets through: the wrong mode, an undetected speaker, a
/// tail longer than the gate's.
///
/// An outgoing sentence is an echo when most of its words were in a translation played in the last
/// `window`: `threshold` of them, or only `playingThreshold` when it arrives while their translation
/// plays or within `playingTail` after (recognition garbles an echo; the timing gives it away).
/// Short sentences are never echoes: "sí, claro" must always get through.
nonisolated struct SelfEchoGuard: Sendable {
    /// From the moment a translation is sent to the speakers: its playback, plus recognition.
    static let window: Duration = .seconds(20)
    static let minimumWords = 5
    /// Share of the sentence's distinct words found in one played translation. Echoes measured in the
    /// scenarios score 0.9 and more; quoting the other side back ("¿has dicho que…?") stays below 0.8.
    static let threshold = 0.8
    /// A garbled echo measured in the scenarios scored 0.75.
    static let playingThreshold = 0.6
    /// Recognition of an echo ends about 1 s after the playback that caused it.
    static let playingTail: Duration = .seconds(2)

    private var played: [(at: ContinuousClock.Instant, words: Set<String>)] = []
    private var isPlaying = false
    private var stoppedAt: ContinuousClock.Instant?

    /// Their translation started or stopped playing.
    mutating func playing(_ speaking: Bool, at instant: ContinuousClock.Instant) {
        if !speaking, isPlaying { stoppedAt = instant }
        isPlaying = speaking
    }

    /// A translation of theirs is about to play on the user's output.
    mutating func played(_ text: String, at instant: ContinuousClock.Instant) {
        played.removeAll { $0.at + Self.window < instant }
        let words = Self.words(text)
        if !words.isEmpty { played.append((instant, words)) }
    }

    func isEcho(_ text: String, at instant: ContinuousClock.Instant) -> Bool {
        let words = Self.words(text)
        guard words.count >= Self.minimumWords else { return false }
        let duringPlayback = isPlaying || stoppedAt.map { instant <= $0 + Self.playingTail } ?? false
        let threshold = duringPlayback ? Self.playingThreshold : Self.threshold
        return played.contains { entry in
            entry.at + Self.window >= instant
                && Double(words.intersection(entry.words).count) / Double(words.count) >= threshold
        }
    }

    mutating func reset() {
        played.removeAll()
        isPlaying = false
        stoppedAt = nil
    }

    /// Lowercased, without accents or punctuation: recognition drifts on both.
    static func words(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Set(folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
}
