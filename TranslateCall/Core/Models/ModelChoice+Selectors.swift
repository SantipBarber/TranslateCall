import Combine
import Foundation

// MARK: - Automatic mode in the selectors (M9 UI core REQ-UI-21…23, design §3.3)

/// The one shared implementation of the automatic flag for both selectors (P5).
protocol AutomaticModeSelector: ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    var defaults: UserDefaults { get }
}

extension AutomaticModeSelector {
    /// Automatic (catalog) or manual (`preferredEngine`, today's behaviour). Shared by both selectors.
    var isAutomatic: Bool { ModelChoice.isAutomatic(in: defaults) }

    /// `true` = back to automatic ("Automatic (recommended)"); `setPreferredEngine` sets `false`.
    func setAutomatic(_ automatic: Bool) {
        objectWillChange.send()
        ModelChoice.setAutomatic(automatic, in: defaults)
    }
}

extension STTEngineSelector: AutomaticModeSelector {
    var availability: ModelAvailability {
        ModelAvailability(parakeetCached: cacheProbe.parakeet(), whisperCached: cacheProbe.whisper())
    }

    func automaticService(for locale: Locale, direction: TranscriptDirection) -> any SpeechRecognizerService {
        switch ModelChoice.stt(for: locale, direction: direction, catalog: catalog, availability: availability) {
        case .parakeet: parakeetFactory(locale)
        case .whisper: whisperFactory(locale)
        case .appleSpeech: appleSpeechFactory(locale)
        }
    }
}

extension TTSEngineSelector: AutomaticModeSelector {
    /// The voice clone counts as ready when its model is on disk, "Use my voice" is on and a profile
    /// is active (P19, D-6); the preloader loads it ahead of Start.
    var availability: ModelAvailability {
        let voiceCloneReady = voiceCloningEnabled && activeVoiceProfileId != nil && cacheProbe.voiceClone()
        return ModelAvailability(kokoroCached: cacheProbe.kokoro(), voiceCloneReady: voiceCloneReady)
    }

    /// The system voice path keeps today's Edge fallback, which needs prior consent (REQ-UI-22).
    func automaticPrimary(for locale: Locale, direction: TranscriptDirection) -> any UtteranceSynthesizer {
        switch ModelChoice.tts(for: locale, direction: direction, catalog: catalog, availability: availability) {
        case .voiceClone:
            if let profileId = activeVoiceProfileId, let store = profileStore {
                return voiceCloneFactory(profileId, store)
            }
            return systemOrEdgePrimary(for: locale)
        case .kokoro:
            let voiceID = defaults.string(forKey: KokoroConfiguration.voiceDefaultsKey) ?? ""
            return kokoroFactory(KokoroConfiguration(voiceIdentifier: voiceID))
        case .avSpeech, .edgeTTS:
            return systemOrEdgePrimary(for: locale)
        }
    }
}
