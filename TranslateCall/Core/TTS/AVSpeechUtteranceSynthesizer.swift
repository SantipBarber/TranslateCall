import AVFoundation
import Synchronization

// MARK: - AVSpeechUtteranceSynthesizer

/// System voices through `AVSpeechSynthesizer.write` (F8.5.2 REQ-T-02/03). Buffers are yielded from the
/// write callback in callback order, with no `Task` per buffer. An utterance's stream finishes on the
/// end marker (a zero-length buffer) or on `didFinish`/`didCancel` for that utterance, whichever first.
///
/// `@unchecked Sendable`: `synthesizer` is AVFoundation's and is driven from whichever thread calls
/// `synthesize` (as `AVSpeechService` did before F8.5.2); the per-utterance state lives in `router`.
nonisolated final class AVSpeechUtteranceSynthesizer: UtteranceSynthesizer, @unchecked Sendable {
    let engine: TTSEngine = .avSpeech
    private let config: SynthesisConfiguration
    private let synthesizer = AVSpeechSynthesizer()
    private let router = SpeechCompletionRouter()

    init(config: SynthesisConfiguration = .default) {
        self.config = config
        synthesizer.delegate = router
    }

    func canSpeak(_ locale: Locale) -> Bool {
        Self.bestVoice(for: locale) != nil
    }

    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let (stream, continuation) = UtteranceStream.make()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continuation.finish()   // no audio to produce (REQ-T-03)
            return stream
        }
        guard let voice = Self.bestVoice(for: locale) else {
            continuation.finish(throwing: STSError.voiceUnavailable(locale))
            return stream
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = config.rate
        utterance.pitchMultiplier = config.pitchMultiplier
        utterance.volume = config.volume
        let id = ObjectIdentifier(utterance)
        router.register(id, continuation)
        continuation.onTermination = { [weak self] termination in
            self?.router.remove(id)
            if case .cancelled = termination { self?.synthesizer.stopSpeaking(at: .immediate) }
        }
        synthesizer.write(utterance) { [router] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                router.finish(id)   // end-of-utterance marker
            } else {
                continuation.yield(pcm)
            }
        }
        return stream
    }

    /// Premium, then enhanced, then any voice whose language matches the locale's first two letters.
    static func bestVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        let lang = String(locale.identifier.replacingOccurrences(of: "_", with: "-").prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? voices.first
    }

    /// True if at least one system voice exists for the locale's language code.
    static func hasVoice(for locale: Locale) -> Bool {
        guard let code = locale.language.languageCode?.identifier, !code.isEmpty else { return false }
        return AVSpeechSynthesisVoice.speechVoices().contains { voice in
            (voice.language.components(separatedBy: "-").first ?? "") == code
        }
    }
}

// MARK: - SpeechCompletionRouter

/// Delegate of the shared `AVSpeechSynthesizer`: finishes the stream of the utterance a callback is
/// about, so a late `didCancel` of a stopped utterance can never end the next one.
nonisolated private final class SpeechCompletionRouter: NSObject, AVSpeechSynthesizerDelegate, Sendable {
    typealias Continuation = AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation

    private let pending = Mutex<[ObjectIdentifier: Continuation]>([:])

    func register(_ id: ObjectIdentifier, _ continuation: Continuation) {
        pending.withLock { $0[id] = continuation }
    }

    func remove(_ id: ObjectIdentifier) {
        _ = pending.withLock { $0.removeValue(forKey: id) }
    }

    func finish(_ id: ObjectIdentifier) {
        pending.withLock { $0.removeValue(forKey: id) }?.finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(ObjectIdentifier(utterance))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(ObjectIdentifier(utterance))
    }
}
