import Foundation

// MARK: - ModelAvailability

/// What is usable on this Mac right now (D-6: "ready" = downloaded on disk). The voice clone is
/// ready when its model is on disk, "Use my voice" is on and a voice profile is active (P19).
struct ModelAvailability: Equatable {
    var parakeetCached = false
    var whisperCached = false
    var kokoroCached = false
    var voiceCloneReady = false
    var cloud = CloudSnapshot()

    /// Parakeet, Whisper and Kokoro cached; no voice clone; no cloud.
    static let allOnDisk = ModelAvailability(parakeetCached: true, whisperCached: true, kokoroCached: true)
}

// MARK: - ModelChoice

/// Engine resolution (M9 UI settings REQ-ST-02…04): the pair's choice when it is usable, otherwise the
/// first catalog engine that serves the language and is ready, otherwise Apple Speech / the system voice.
/// The voice clone wins outgoing whatever the choice. Pure functions.
enum ModelChoice {
    // MARK: Resolution

    static func stt(for locale: Locale, direction: TranscriptDirection, pairChoice: STTEngine? = nil,
                    catalog: ModelCatalog, availability: ModelAvailability) -> STTEngine {
        if let pairChoice, isUsable(pairChoice, for: locale, direction: direction, availability: availability) {
            return pairChoice
        }
        return catalog.sttEngines(for: locale).first {
            isUsable($0, for: locale, direction: direction, availability: availability)
        } ?? .appleSpeech
    }

    static func tts(for locale: Locale, direction: TranscriptDirection, pairChoice: TTSEngine? = nil,
                    catalog: ModelCatalog, availability: ModelAvailability) -> TTSEngine {
        let listed = catalog.ttsEngines(for: locale, direction: direction)
        if listed.contains(.voiceClone),
           isUsable(.voiceClone, for: locale, direction: direction, availability: availability) {
            return .voiceClone
        }
        if let pairChoice, isUsable(pairChoice, for: locale, direction: direction, availability: availability) {
            return pairChoice
        }
        return listed.first {
            isUsable($0, for: locale, direction: direction, availability: availability)
        } ?? .avSpeech
    }

    // MARK: Serving and readiness

    /// Language and direction only; the disk is not consulted.
    static func serves(_ engine: STTEngine, locale: Locale, direction: TranscriptDirection) -> Bool {
        // Parakeet serves the outgoing direction only (one shared ASR model).
        engine.supports(locale: locale) && !(engine == .parakeet && direction == .incoming)
    }

    static func serves(_ engine: TTSEngine, locale: Locale, direction: TranscriptDirection) -> Bool {
        engine.supports(locale: locale) && !(engine == .voiceClone && direction == .incoming)
    }

    static func isUsable(_ engine: STTEngine, for locale: Locale, direction: TranscriptDirection,
                         availability: ModelAvailability) -> Bool {
        serves(engine, locale: locale, direction: direction) && isReady(engine, availability)
    }

    static func isUsable(_ engine: TTSEngine, for locale: Locale, direction: TranscriptDirection,
                         availability: ModelAvailability) -> Bool {
        serves(engine, locale: locale, direction: direction) && isReady(engine, availability)
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
        case .edgeTTS: availability.cloud.permits(.edgeTTS)
        }
    }
}
