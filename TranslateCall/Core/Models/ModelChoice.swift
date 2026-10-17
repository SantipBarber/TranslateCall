import Foundation

// MARK: - ModelAvailability

/// What is usable on this Mac right now (D-6: "ready" = downloaded on disk). The voice clone is
/// ready when its model is on disk, "Use my voice" is on and a voice profile is active (P19).
struct ModelAvailability: Equatable {
    var parakeetCached = false
    var whisperCached = false
    var kokoroCached = false
    var voiceCloneReady = false
}

// MARK: - ModelChoice

/// Automatic engine choice (REQ-UI-21/22/24, design §3.2): the first catalog engine that supports
/// the locale and is ready; otherwise Apple Speech / the system voice. A pure function.
enum ModelChoice {
    /// Shared by both selectors: automatic (default `true`) or the engines picked by hand (REQ-UI-23).
    static let automaticKey = "tlk.models.automatic"

    static func isAutomatic(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: automaticKey) as? Bool ?? true
    }

    static func setAutomatic(_ automatic: Bool, in defaults: UserDefaults) {
        defaults.set(automatic, forKey: automaticKey)
    }

    /// Parakeet serves the outgoing direction only, as today (one shared ASR model).
    static func stt(for locale: Locale, direction: TranscriptDirection,
                    catalog: ModelCatalog, availability: ModelAvailability) -> STTEngine {
        catalog.sttEngines(for: locale).first { engine in
            engine.supports(locale: locale) && isReady(engine, availability)
                && !(engine == .parakeet && direction == .incoming)
        } ?? .appleSpeech
    }

    static func tts(for locale: Locale, direction: TranscriptDirection,
                    catalog: ModelCatalog, availability: ModelAvailability) -> TTSEngine {
        catalog.ttsEngines(for: locale, direction: direction).first { engine in
            engine.supports(locale: locale) && isReady(engine, availability)
        } ?? .avSpeech
    }

    private static func isReady(_ engine: STTEngine, _ availability: ModelAvailability) -> Bool {
        switch engine {
        case .appleSpeech: true
        case .parakeet: availability.parakeetCached
        case .whisper: availability.whisperCached
        }
    }

    /// Kokoro is never chosen while the voice clone is ready: only one MLX TTS model at a time (§3.3).
    private static func isReady(_ engine: TTSEngine, _ availability: ModelAvailability) -> Bool {
        switch engine {
        case .avSpeech: true
        case .kokoro: availability.kokoroCached && !availability.voiceCloneReady
        case .voiceClone: availability.voiceCloneReady
        case .edgeTTS: false
        }
    }
}
