import AVFoundation

// MARK: - SynthesisConfiguration

struct SynthesisConfiguration: Sendable {
    /// Speech rate. Matches AVSpeechUtteranceDefaultSpeechRate = 0.5
    var rate: Float = 0.5
    /// Pitch multiplier (0.5 – 2.0). Default: 1.0 (unchanged).
    var pitchMultiplier: Float = 1.0
    /// Volume (0.0 – 1.0). Default: 1.0.
    var volume: Float = 1.0

    nonisolated static let `default` = SynthesisConfiguration()
}

// MARK: - STSError

enum STSError: LocalizedError, Equatable {
    case voiceUnavailable(Locale)
    case engineStartFailed(Error)
    case deviceRoutingFailed

    var errorDescription: String? {
        switch self {
        case .voiceUnavailable(let locale):
            return "No voice installed for locale: \(locale.identifier)"
        case .engineStartFailed(let error):
            return "Audio engine failed to start: \(error.localizedDescription)"
        case .deviceRoutingFailed:
            return "Failed to route audio to the specified output device."
        }
    }

    static func == (lhs: STSError, rhs: STSError) -> Bool {
        switch (lhs, rhs) {
        case (.voiceUnavailable(let lhs), .voiceUnavailable(let rhs)): return lhs == rhs
        case (.engineStartFailed, .engineStartFailed): return true
        case (.deviceRoutingFailed, .deviceRoutingFailed): return true
        default: return false
        }
    }
}

// MARK: - SynthesisService

protocol SynthesisService: Actor {
    /// Emits `true` when speaking, `false` when idle.
    nonisolated var isSpeakingStream: AsyncStream<Bool> { get }

    /// Synthesize and play text in the given locale. Queued if already speaking.
    func speak(text: String, locale: Locale) async

    /// Immediately stop current utterance and clear queue.
    func stopSpeaking() async

    /// Stop synthesis, clear queue, stop audio engine.
    func deactivate() async
}
