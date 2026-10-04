import Combine
import CoreAudio
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSEngineSelector")

// MARK: - TTSEngineSelector

/// Manages TTS engine selection, model availability, and the factories that build each direction's
/// `TTSPlaybackService(primary:fallback:output:)` (F8.5.2 §3.6).
///
/// Outgoing priority: explicit Edge > Voice Clone > Kokoro (English) > AVSpeech > Edge (consent) > AVSpeech.
/// Incoming: explicit Edge > AVSpeech > Edge (consent) > AVSpeech.
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
        !hasSystemVoice(currentTargetLocale)
            && !EdgeTTSConsentManager.consentGiven
    }

    /// True when Edge TTS is being used for the current locale.
    var isUsingEdgeTTS: Bool {
        !hasSystemVoice(currentTargetLocale)
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

    /// Whether a system (AVSpeech) voice exists for a locale. Injectable so tests don't depend
    /// on which voices the machine has installed.
    var hasSystemVoice: (Locale) -> Bool = { AVSpeechUtteranceSynthesizer.hasVoice(for: $0) }

    /// The device output of one playback service (unit tests inject a `FakeOutput`).
    var outputFactory: (AudioDeviceID?) throws -> any AudioOutputting = { try TTSOutput(deviceID: $0) }
    var avSpeechFactory: () -> any UtteranceSynthesizer = { AVSpeechUtteranceSynthesizer() }
    var kokoroFactory: (KokoroConfiguration) -> any UtteranceSynthesizer = {
        KokoroUtteranceSynthesizer(configuration: $0)
    }
    var voiceCloneFactory: (UUID, any VoiceProfileStoring) -> any UtteranceSynthesizer = { profileId, store in
        QwenUtteranceSynthesizer(
            activeProfileId: profileId,
            profileStore: store,
            inferrer: QwenCloneModelManager.shared.gatedInferrer()
        )
    }
    var edgeFactory: () -> any UtteranceSynthesizer = { EdgeUtteranceSynthesizer() }

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
    /// If user explicitly selected Edge TTS, use it directly.
    /// Otherwise: Voice Clone > Kokoro > AVSpeech > Edge TTS (auto fallback).
    func makeOutgoingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> TTSPlaybackService {
        currentTargetLocale = locale
        return try makePlayback(primary: outgoingPrimary(for: locale), locale: locale, deviceID: deviceID)
    }

    /// Creates the incoming TTS service.
    /// Uses Edge TTS if explicitly selected or as fallback when no AVSpeech voice.
    func makeIncomingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> TTSPlaybackService {
        try makePlayback(primary: incomingPrimary(for: locale), locale: locale, deviceID: deviceID)
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

    /// Edge, Kokoro and the voice clone fall back to the system voice when the locale has one
    /// (REQ-T-22); AVSpeech as primary has no fallback.
    private func makePlayback(
        primary: any UtteranceSynthesizer, locale: Locale, deviceID: AudioDeviceID?
    ) throws -> TTSPlaybackService {
        let fallback = primary.engine != .avSpeech && hasSystemVoice(locale) ? avSpeechFactory() : nil
        return TTSPlaybackService(primary: primary, fallback: fallback, output: try outputFactory(deviceID))
    }

    private func outgoingPrimary(for locale: Locale) -> any UtteranceSynthesizer {
        if preferredEngine == .edgeTTS, EdgeTTSVoiceCatalog.supports(locale) {
            return edgeFactory()
        }
        // Priority 1: Voice Clone (10 supported languages)
        if voiceCloningActive, QwenCloneConfiguration.supportsLocale(locale),
           let profileId = activeVoiceProfileId, let store = profileStore {
            return voiceCloneFactory(profileId, store)
        }
        // Priority 2: Kokoro (English only)
        if preferredEngine == .kokoro, kokoroAvailable, locale.isEnglish {
            let voiceID = defaults.string(forKey: KokoroConfiguration.voiceDefaultsKey) ?? ""
            return kokoroFactory(KokoroConfiguration(voiceIdentifier: voiceID))
        }
        return systemOrEdgePrimary(for: locale)
    }

    private func incomingPrimary(for locale: Locale) -> any UtteranceSynthesizer {
        if preferredEngine == .edgeTTS, EdgeTTSVoiceCatalog.supports(locale) {
            return edgeFactory()
        }
        return systemOrEdgePrimary(for: locale)
    }

    /// AVSpeech when a system voice exists, else Edge (consent required), else AVSpeech, which then
    /// skips each sentence with a visible "No voice" notice.
    private func systemOrEdgePrimary(for locale: Locale) -> any UtteranceSynthesizer {
        if hasSystemVoice(locale) { return avSpeechFactory() }
        if EdgeTTSConsentManager.consentGiven, EdgeTTSVoiceCatalog.supports(locale) { return edgeFactory() }
        return avSpeechFactory()
    }

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
