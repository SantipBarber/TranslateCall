import Combine
import CoreAudio
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSEngineSelector")

// MARK: - TTSEngineSelector

/// Manages TTS engine selection, model availability, and service factory closures.
///
/// `makeOutgoingService` routes to Voice Clone when active, else Kokoro for English,
/// else AVSpeech. `makeIncomingService` always returns AVSpeech.
///
/// Engine priority: Voice Clone > Kokoro > AVSpeech.
@MainActor
final class TTSEngineSelector: ObservableObject {

    // MARK: - Published state

    @Published private(set) var preferredEngine: TTSEngine = .avSpeech
    @Published private(set) var kokoroAvailable: Bool = false
    @Published private(set) var voiceCloneAvailable: Bool = false
    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var isVoiceCloneDownloading: Bool = false
    @Published private(set) var currentTargetLocale: Locale = Locale.current

    /// User toggle — persisted in UserDefaults.
    @Published var voiceCloningEnabled: Bool = false {
        didSet { defaults.set(voiceCloningEnabled, forKey: QwenCloneConfiguration.voiceCloningEnabledKey) }
    }

    /// Active voice profile ID — set by VoiceProfileManager observation.
    @Published var activeVoiceProfileId: UUID?

    /// True when all three conditions are met: enabled + voice clone available + profile selected.
    var voiceCloningActive: Bool {
        voiceCloningEnabled && voiceCloneAvailable && activeVoiceProfileId != nil
    }

    /// True when Edge TTS consent is needed for current locale.
    var needsEdgeTTSConsent: Bool {
        !AVSpeechService.hasVoice(for: currentTargetLocale)
            && !EdgeTTSConsentManager.consentGiven
    }

    /// True when Edge TTS is being used for the current locale.
    var isUsingEdgeTTS: Bool {
        !AVSpeechService.hasVoice(for: currentTargetLocale)
            && EdgeTTSConsentManager.consentGiven
    }

    var usingFallback: Bool {
        preferredEngine == .kokoro && (!kokoroAvailable || !currentTargetLocale.isEnglish)
    }

    // MARK: - UserDefaults

    private let defaults: UserDefaults
    private static let engineKey = "tlk.tts.engine"

    // MARK: - Combine

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Factories (var — injectable for tests)

    var avSpeechFactory: (AudioDeviceID?) throws -> any SynthesisService = { deviceID in
        try AVSpeechService(outputDeviceID: deviceID)
    }
    var kokoroFactory: (AudioDeviceID?, KokoroConfiguration) throws -> any SynthesisService = { deviceID, config in
        try KokoroSpeechService(outputDeviceID: deviceID, configuration: config)
    }
    // swiftlint:disable:next line_length
    var voiceCloneFactory: (AudioDeviceID?, UUID, any VoiceProfileStoring) throws -> any SynthesisService = { deviceID, profileId, store in
        let inferrer = try QwenCloneModelManager.shared.getInferrerSync()
        return try QwenCloneSpeechService(
            outputDeviceID: deviceID,
            activeProfileId: profileId,
            profileStore: store,
            inferrer: inferrer
        )
    }

    // MARK: - Dependencies

    private var profileStore: (any VoiceProfileStoring)?

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.engineKey),
           let engine = TTSEngine(rawValue: raw) {
            preferredEngine = engine
        }
        voiceCloningEnabled = defaults.bool(forKey: QwenCloneConfiguration.voiceCloningEnabledKey)
        observeModelManager()
        observeQwenCloneModelManager()

        // REQ-VC-04: auto-load voice clone model on relaunch if previously enabled
        if voiceCloningEnabled {
            Task {
                do {
                    try await QwenCloneModelManager.shared.ensureReady()
                } catch {
                    logger.info("Voice clone auto-load skipped: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Public API

    func setPreferredEngine(_ engine: TTSEngine) {
        preferredEngine = engine
        defaults.set(engine.rawValue, forKey: Self.engineKey)
    }

    /// Creates the outgoing TTS service for `locale` routed to `deviceID`.
    /// Priority: Voice Clone > Kokoro > AVSpeech > Edge TTS (cloud fallback).
    func makeOutgoingService(
        for locale: Locale, deviceID: AudioDeviceID?
    ) throws -> any SynthesisService {
        currentTargetLocale = locale

        // Priority 1: Voice Clone (10 supported languages)
        if voiceCloningActive,
           QwenCloneConfiguration.supportsLocale(locale),
           let profileId = activeVoiceProfileId,
           let store = profileStore {
            return try voiceCloneFactory(deviceID, profileId, store)
        }

        // Priority 2: Kokoro (English only)
        if preferredEngine == .kokoro, kokoroAvailable, locale.isEnglish {
            let voiceID = defaults.string(forKey: KokoroConfiguration.voiceDefaultsKey) ?? ""
            let config = KokoroConfiguration(voiceIdentifier: voiceID)
            return try kokoroFactory(deviceID, config)
        }

        // Priority 3: AVSpeech (if voice exists)
        if AVSpeechService.hasVoice(for: locale) {
            return try avSpeechFactory(deviceID)
        }

        // Priority 4: Edge TTS (cloud fallback, consent required)
        if EdgeTTSConsentManager.consentGiven,
           let voice = EdgeTTSVoiceCatalog.defaultVoice(for: locale) {
            return try EdgeTTSService(
                outputDeviceID: deviceID, voiceName: voice.shortName
            )
        }

        // Last resort: AVSpeech anyway (will be silent)
        return try avSpeechFactory(deviceID)
    }

    /// Creates the incoming TTS service.
    /// Uses Edge TTS fallback if AVSpeech has no voice and consent is given.
    func makeIncomingService(
        for locale: Locale, deviceID: AudioDeviceID?
    ) throws -> any SynthesisService {
        if AVSpeechService.hasVoice(for: locale) {
            return try avSpeechFactory(deviceID)
        }
        if EdgeTTSConsentManager.consentGiven,
           let voice = EdgeTTSVoiceCatalog.defaultVoice(for: locale) {
            return try EdgeTTSService(
                outputDeviceID: deviceID, voiceName: voice.shortName
            )
        }
        return try avSpeechFactory(deviceID)
    }

    /// Triggers Kokoro model download; sets `isDownloading` while in-flight.
    func downloadKokoroModel() {
        isDownloading = true
        Task { [weak self] in
            _ = try? await KokoroModelManager.shared.ensureReady()
            self?.isDownloading = false
        }
    }

    func unloadKokoroModel() {
        kokoroAvailable = false
        Task { await KokoroModelManager.shared.unload() }
    }

    // MARK: - Voice Cloning API

    /// Enables voice cloning and begins Qwen3-TTS model download if needed.
    /// Unloads Kokoro first (NF-04: only one MLX TTS model at a time).
    func enableVoiceCloning() {
        voiceCloningEnabled = true
        if !voiceCloneAvailable {
            // Unload Kokoro to free GPU memory
            if kokoroAvailable {
                unloadKokoroModel()
            }
            isVoiceCloneDownloading = true
            Task { [weak self] in
                do {
                    try await QwenCloneModelManager.shared.ensureReady()
                } catch {
                    logger.error("Voice clone setup failed: \(error.localizedDescription)")
                }
                self?.isVoiceCloneDownloading = false
            }
        }
    }

    /// Disables voice cloning and unloads Qwen3-TTS model.
    func disableVoiceCloning() {
        voiceCloningEnabled = false
        Task { await QwenCloneModelManager.shared.unload() }
    }

    /// Sets the profile store for voice clone factory injection.
    func setProfileStore(_ store: any VoiceProfileStoring) {
        self.profileStore = store
    }

    // MARK: - Edge TTS consent

    func grantEdgeTTSConsent() {
        EdgeTTSConsentManager.grantConsent()
        objectWillChange.send()
    }

    // MARK: - For testing

    func setKokoroAvailableForTesting(_ value: Bool) { kokoroAvailable = value }
    func setVoiceCloneAvailableForTesting(_ value: Bool) { voiceCloneAvailable = value }

    // MARK: - Private

    private func observeModelManager() {
        Task { [weak self] in
            for await state in KokoroModelManager.shared.stateStream {
                await MainActor.run {
                    switch state {
                    case .ready:            self?.kokoroAvailable = true
                    case .failed, .idle:    self?.kokoroAvailable = false
                    case .loading:          break
                    }
                }
            }
        }
    }

    private func observeQwenCloneModelManager() {
        Task { [weak self] in
            for await state in QwenCloneModelManager.shared.stateStream {
                await MainActor.run {
                    switch state {
                    case .ready:                        self?.voiceCloneAvailable = true
                    case .failed, .idle:                self?.voiceCloneAvailable = false
                    case .downloading, .loading:        break
                    }
                }
            }
        }
    }
}
