import Combine
import CoreAudio
import Foundation

// MARK: - TTSEngineSelector

/// Resolves each direction's voice and builds its `TTSPlaybackService(primary:fallback:output:)`
/// (F8.5.2 §3.6). One resolution path (M9 UI settings REQ-ST-02…04, P5): the voice clone when ready,
/// else the pair's choice where usable, else the catalog; a system voice path without a system voice
/// falls back to Edge when the cloud rules permit it.
@MainActor
final class TTSEngineSelector: ObservableObject {

    // MARK: - Published state

    @Published private(set) var kokoroAvailable: Bool = false
    @Published private(set) var voiceCloneAvailable: Bool = false
    @Published private(set) var currentTargetLocale: Locale = Locale.current

    /// User toggle — persisted in UserDefaults.
    @Published var voiceCloningEnabled: Bool = false {
        didSet { defaults.set(voiceCloningEnabled, forKey: QwenCloneConfiguration.voiceCloningEnabledKey) }
    }

    /// Active voice profile ID — set by VoiceProfileManager observation.
    @Published var activeVoiceProfileId: UUID?

    /// True when Edge speaks my outgoing voice for the last target locale.
    var isUsingEdgeTTS: Bool {
        resolvedEngine(for: currentTargetLocale, direction: .outgoing) == .edgeTTS
    }

    // MARK: - UserDefaults

    let defaults: UserDefaults

    // MARK: - Factories (var — injectable for tests)

    /// Whether a system (AVSpeech) voice exists for a locale. Injectable so tests don't depend
    /// on which voices the machine has installed.
    var hasSystemVoice: (Locale) -> Bool = { AVSpeechUtteranceSynthesizer.hasVoice(for: $0) }

    /// Edge TTS consent (machine-wide); injectable so tests never depend on this Mac's answer.
    var edgeConsentGiven: () -> Bool = { EdgeTTSConsentManager.consentGiven }

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

    /// Resolution inputs; injectable for tests.
    var catalog: ModelCatalog = .bundled
    var cacheProbe: ModelCacheProbe = .live
    /// The current pair's stored choice; `ModelServices` wires it (P1). Default: no choice.
    var pairChoice: () -> PairModelChoice = { PairModelChoice() }
    /// "Allow cloud models"; `ModelServices` wires it from `CloudPolicy` (P1). Default: no cloud.
    var cloudAllowed: () -> Bool = { false }
    /// Starts the voice clone download; `ModelServices` wires it to `ModelDownloads` (S-4). Default: no-op.
    var startVoiceCloneDownload: () -> Void = {}
    /// Cancels a running voice clone download (best effort, S-4); `ModelServices` wires it. Default: no-op.
    var cancelVoiceCloneDownload: () -> Void = {}
    /// Downloads are blocked while a session runs (S-7); `ModelServices` wires it. Default: never blocked.
    var downloadsBlocked: () -> Bool = { false }

    /// The model managers whose state `refreshModelAvailability()` reads; tests inject their own.
    var kokoroManager: KokoroModelManager = .shared
    var voiceCloneManager: QwenCloneModelManager = .shared

    private(set) var profileStore: (any VoiceProfileStoring)?

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        voiceCloningEnabled = defaults.bool(forKey: QwenCloneConfiguration.voiceCloningEnabledKey)
        observeModelManager()
        observeQwenCloneModelManager()
    }

    // MARK: - Resolution

    /// What is usable now. The voice clone counts as ready when its model is on disk, "Use my voice" is
    /// on and a profile is active (D-6); the preloader loads it ahead of Start.
    var availability: ModelAvailability {
        ModelAvailability(kokoroCached: cacheProbe.kokoro(),
                          voiceCloneReady: voiceCloningEnabled && activeVoiceProfileId != nil
                              && cacheProbe.voiceClone(),
                          cloud: cloudSnapshot)
    }

    /// The cloud rules as a value (P2).
    var cloudSnapshot: CloudSnapshot {
        CloudSnapshot(allowed: cloudAllowed(), consented: edgeConsentGiven() ? [.edgeTTS] : [],
                      unavailable: catalog.isUnavailable(.edgeTTS) ? [.edgeTTS] : [])
    }

    /// The engine the next session speaks with for `locale` in `direction` (P5): what the factories
    /// build, what the preloader loads and what the models line reads.
    func resolvedEngine(for locale: Locale, direction: TranscriptDirection) -> TTSEngine {
        resolvedEngine(for: locale, direction: direction, availability: availability)
    }

    /// The engine speaking `locale` when "Use my voice" is off, for Settings › Voices (REQ-ST-22). Kokoro
    /// stays blocked while the voice clone is ready (NF-04), as the clone's model is still the one loaded.
    func standardEngine(for locale: Locale, direction: TranscriptDirection) -> TTSEngine {
        var now = availability
        if resolvedEngine(for: locale, direction: direction, availability: now) == .voiceClone {
            now.voiceCloneReady = false
            now.kokoroCached = false
        }
        return resolvedEngine(for: locale, direction: direction, availability: now)
    }

    /// Edge speaks my voice in `target` or theirs in `source`; the disk and the cloud rules are read once.
    func usesEdge(source: Locale, target: Locale) -> Bool {
        let now = availability
        return resolvedEngine(for: target, direction: .outgoing, availability: now) == .edgeTTS
            || resolvedEngine(for: source, direction: .incoming, availability: now) == .edgeTTS
    }

    private func resolvedEngine(for locale: Locale, direction: TranscriptDirection,
                                availability: ModelAvailability) -> TTSEngine {
        let engine = ModelChoice.tts(for: locale, direction: direction, pairChoice: pairChoice().voice,
                                     catalog: catalog, availability: availability)
        switch engine {
        case .voiceClone where profileStore == nil, .avSpeech:
            return systemOrEdgeEngine(for: locale, availability.cloud)
        default: return engine
        }
    }

    /// No system voice for `locale`, Edge could speak it and the cloud is allowed, but no consent yet:
    /// a start must first ask (REQ-ST-32).
    func needsEdgeConsent(for locale: Locale) -> Bool {
        let cloud = cloudSnapshot
        return !hasSystemVoice(locale) && EdgeTTSVoiceCatalog.supports(locale)
            && cloud.allowed && !cloud.unavailable.contains(.edgeTTS) && !cloud.consented.contains(.edgeTTS)
    }

    // MARK: - Public API

    /// Creates the outgoing TTS service (my voice, in `locale`) routed to `deviceID`.
    func makeOutgoingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> TTSPlaybackService {
        currentTargetLocale = locale
        return try makePlayback(primary: primary(for: locale, direction: .outgoing), locale: locale,
                                deviceID: deviceID)
    }

    /// Creates the incoming TTS service (their voice, in `locale`).
    func makeIncomingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> TTSPlaybackService {
        try makePlayback(primary: primary(for: locale, direction: .incoming), locale: locale, deviceID: deviceID)
    }

    func unloadKokoroModel() {
        kokoroAvailable = false
        Task { await KokoroModelManager.shared.unload() }
    }

    // MARK: - Voice Cloning API

    /// Enables voice cloning and, when the model is not loaded, starts its download through
    /// `ModelDownloads` (a no-op when on disk: the preloader then loads it). Unloads Kokoro first
    /// (NF-04: only one MLX TTS model at a time). A no-op during a session (S-7): nothing unloads mid-call.
    func enableVoiceCloning() {
        guard !downloadsBlocked() else { return }
        voiceCloningEnabled = true
        guard !voiceCloneAvailable else { return }
        if kokoroAvailable { unloadKokoroModel() }
        startVoiceCloneDownload()
    }

    /// Disables voice cloning, cancels a running download (so Start isn't left waiting for it) and
    /// unloads Qwen3-TTS model.
    func disableVoiceCloning() {
        voiceCloningEnabled = false
        cancelVoiceCloneDownload()
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

    // MARK: - Private

    /// Edge, Kokoro and the voice clone fall back to the system voice when the locale has one
    /// (REQ-T-22); AVSpeech as primary has no fallback.
    private func makePlayback(
        primary: any UtteranceSynthesizer, locale: Locale, deviceID: AudioDeviceID?
    ) throws -> TTSPlaybackService {
        let fallback = primary.engine != .avSpeech && hasSystemVoice(locale) ? avSpeechFactory() : nil
        return TTSPlaybackService(primary: primary, fallback: fallback, output: try outputFactory(deviceID))
    }

    /// The synthesizer for the resolved engine; a voice clone without a profile speaks with the system voice.
    private func primary(for locale: Locale, direction: TranscriptDirection) -> any UtteranceSynthesizer {
        switch resolvedEngine(for: locale, direction: direction) {
        case .voiceClone:
            guard let profileId = activeVoiceProfileId, let store = profileStore else { return avSpeechFactory() }
            return voiceCloneFactory(profileId, store)
        case .kokoro:
            let voiceID = defaults.string(forKey: KokoroConfiguration.voiceDefaultsKey) ?? ""
            return kokoroFactory(KokoroConfiguration(voiceIdentifier: voiceID))
        case .edgeTTS: return edgeFactory()
        case .avSpeech: return avSpeechFactory()
        }
    }

    /// AVSpeech when a system voice exists, else Edge when the cloud rules permit it, else AVSpeech, which
    /// then skips each sentence with a visible "No voice" notice.
    private func systemOrEdgeEngine(for locale: Locale, _ cloud: CloudSnapshot) -> TTSEngine {
        if hasSystemVoice(locale) { return .avSpeech }
        if cloud.permits(.edgeTTS), EdgeTTSVoiceCatalog.supports(locale) { return .edgeTTS }
        return .avSpeech
    }

    /// Sets `kokoroAvailable` and `voiceCloneAvailable` from the managers' current state, loading nothing.
    /// The state streams are single-consumer, so a second selector in the same process (the benchmark's)
    /// never sees a `.ready` that another consumer already took; this reads the state directly instead.
    func refreshModelAvailability() async {
        if case .ready = await kokoroManager.state { kokoroAvailable = true } else { kokoroAvailable = false }
        if case .ready = await voiceCloneManager.state {
            voiceCloneAvailable = true
        } else {
            voiceCloneAvailable = false
        }
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
