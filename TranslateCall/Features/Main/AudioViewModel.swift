import Combine
import Foundation
import SwiftUI

// MARK: - Alert model (file-level to avoid nesting violations)

struct AlertItem: Identifiable {
    enum Action { case openSettings }

    let id = UUID()
    let title: String
    let message: String
    let action: Action?
}

// MARK: - ViewModel

/// Thin Combine adapter over `AudioCoordinator`.
///
/// Owns device-selection (AudioManager) and binds all pipeline state from the coordinator.
/// All pipeline logic lives in `AudioCoordinator`.
@MainActor
final class AudioViewModel: ObservableObject {

    // MARK: - Device state (from AudioManager)

    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published var selectedInput: AudioDevice?
    @Published var selectedOutput: AudioDevice?
    @Published private(set) var inputLevel: Float = -160
    @Published private(set) var isCapturing = false

    // MARK: - Outgoing pipeline state (from coordinator)

    @Published private(set) var isSpeechActive: Bool = false
    @Published private(set) var latestTranscription: String?
    @Published private(set) var latestTranslation: String?
    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var isStarting = false

    // MARK: - Incoming pipeline state (from coordinator)

    @Published private(set) var incomingTranscription: String?
    @Published private(set) var incomingTranslation: String?
    @Published private(set) var isIncomingActive: Bool = false

    // MARK: - Half-duplex state (from coordinator)

    @Published private(set) var halfDuplexState: HalfDuplexState = .listening

    // MARK: - Shared

    @Published var errorAlert: AlertItem?

    // MARK: - Dependencies

    let coordinator: AudioCoordinator
    let languagePairManager: LanguagePairManager
    let setupManager: SetupManager
    /// Manages which STT engine (Apple Speech / Parakeet) is active.
    let engineSelector: STTEngineSelector
    /// Manages which TTS engine (AVSpeech / Kokoro / Voice Clone) is active.
    let ttsEngineSelector: TTSEngineSelector
    let voiceProfileManager: VoiceProfileManager
    private let audioManager: AudioManager
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Designated init (used by AppContainer)

    init(
        coordinator: AudioCoordinator,
        audioManager: AudioManager,
        languagePairManager: LanguagePairManager,
        setupManager: SetupManager = SetupManager(),
        engineSelector: STTEngineSelector = STTEngineSelector(),
        ttsEngineSelector: TTSEngineSelector = TTSEngineSelector(),
        voiceProfileManager: VoiceProfileManager = VoiceProfileManager()
    ) {
        self.coordinator = coordinator
        self.audioManager = audioManager
        self.languagePairManager = languagePairManager
        self.setupManager = setupManager
        self.engineSelector = engineSelector
        self.ttsEngineSelector = ttsEngineSelector
        self.voiceProfileManager = voiceProfileManager
        bindAudioManager()
        bindCoordinator()
        bindVoiceProfileManager()
    }

    // MARK: - Convenience init (used by previews and legacy tests)
    //
    // Creates a real AudioCoordinator with real services internally.
    // Factories are closures — services are only instantiated when start() is called,
    // so this init is safe to use in tests that never call start().

    convenience init(
        translationService: (any TranslationService)? = nil,
        incomingTranslationService: (any TranslationService)? = nil,
        languagePairManager: LanguagePairManager = LanguagePairManager(),
        voiceProfileManager: VoiceProfileManager = VoiceProfileManager()
    ) {
        let audioManager = AudioManager()
        let lpm = languagePairManager
        let outgoing: any TranslationService = translationService ?? PassthroughTranslationService()
        let incoming: any TranslationService = incomingTranslationService ?? PassthroughTranslationService()
        let selector = STTEngineSelector()
        let ttsSelector = TTSEngineSelector()
        let coordinator = AudioCoordinator(
            audioCapture: audioManager,
            systemCapture: SystemAudioCaptureService(),
            outgoingVADFactory: { EnergyVADService() },
            incomingVADFactory: { EnergyVADService() },
            outgoingSTTFactory: { selector.makeOutgoingService(for: $0) },
            incomingSTTFactory: { selector.makeIncomingService(for: $0) },
            outgoingTranslationService: outgoing,
            incomingTranslationService: incoming,
            outgoingTTSFactory: { [ttsSelector] locale, deviceID in
                try ttsSelector.makeOutgoingService(for: locale, deviceID: deviceID)
            },
            incomingTTSFactory: { [ttsSelector] locale, deviceID in
                try ttsSelector.makeIncomingService(for: locale, deviceID: deviceID)
            },
            languagePairManager: lpm
        )
        self.init(
            coordinator: coordinator,
            audioManager: audioManager,
            languagePairManager: lpm,
            setupManager: SetupManager(),
            engineSelector: selector,
            ttsEngineSelector: ttsSelector,
            voiceProfileManager: voiceProfileManager
        )
    }

    // MARK: - Combine bindings

    private func bindAudioManager() {
        audioManager.$inputDevices.assign(to: &$inputDevices)
        audioManager.$outputDevices.assign(to: &$outputDevices)
        audioManager.$selectedInput.assign(to: &$selectedInput)
        audioManager.$selectedOutput.assign(to: &$selectedOutput)
        audioManager.$inputLevel.assign(to: &$inputLevel)
        audioManager.$isCapturing.assign(to: &$isCapturing)
    }

    private func bindCoordinator() {
        coordinator.$isSpeechActive.assign(to: &$isSpeechActive)
        coordinator.$outgoingTranscription.assign(to: &$latestTranscription)
        coordinator.$outgoingTranslation.assign(to: &$latestTranslation)
        coordinator.$isOutgoingSpeaking.assign(to: &$isSpeaking)
        coordinator.$isStarting.assign(to: &$isStarting)
        coordinator.$incomingTranscription.assign(to: &$incomingTranscription)
        coordinator.$incomingTranslation.assign(to: &$incomingTranslation)
        coordinator.$isIncomingActive.assign(to: &$isIncomingActive)
        coordinator.$halfDuplexState.assign(to: &$halfDuplexState)
        coordinator.$errorAlert.assign(to: &$errorAlert)
    }

    private func bindVoiceProfileManager() {
        // Wire active profile changes → TTSEngineSelector
        voiceProfileManager.$activeProfileId
            .sink { [weak self] profileId in
                self?.ttsEngineSelector.activeVoiceProfileId = profileId
            }
            .store(in: &cancellables)

        // Provide the profile store to the TTS engine selector for voice clone factory
        ttsEngineSelector.setProfileStore(voiceProfileManager.profileStore)
    }

    // MARK: - Actions

    /// Set to true when Edge TTS consent is needed before starting.
    @Published var showEdgeTTSConsent: Bool = false
    /// Set to true when waiting for consent before starting pipeline.
    private var pendingStartAfterConsent: Bool = false

    func toggleCapture() async {
        if isCapturing {
            await coordinator.stop()
        } else {
            // Check Edge TTS consent BEFORE starting
            let targetLocale = Locale(
                identifier: languagePairManager.targetLanguage.minimalIdentifier
            )
            if !AVSpeechService.hasVoice(for: targetLocale),
               !EdgeTTSConsentManager.consentGiven {
                // Show consent dialog and defer start
                pendingStartAfterConsent = true
                showEdgeTTSConsent = true
                return
            }
            await startPipeline()
        }
    }

    /// Called from consent dialog: user accepted or declined Edge TTS.
    func onEdgeTTSConsentResponse(accepted: Bool) {
        if accepted {
            ttsEngineSelector.grantEdgeTTSConsent()
        }
        if pendingStartAfterConsent {
            pendingStartAfterConsent = false
            Task { await startPipeline() }
        }
    }

    private func startPipeline() async {
        await coordinator.start(
            captureApp: setupManager.selectedCaptureApp,
            blackHoleDeviceID: setupManager.isBlackHolePresent
                ? AudioDevice.deviceID(forNameContaining: "BlackHole")
                : nil
        )
    }

    func downloadLanguages() async {
        await coordinator.downloadLanguages()
    }

    /// Suppresses the next outgoing utterance — the user's next spoken segment is silently dropped.
    /// Has no effect if the session is not active.
    func muteTurn() {
        guard isCapturing else { return }
        coordinator.suppressNextOutgoingTurn()
    }

    // MARK: - Display helpers for menu bar

    var sourceLanguageDisplay: String {
        languagePairManager.displayName(for: languagePairManager.sourceLanguage)
    }

    var targetLanguageDisplay: String {
        languagePairManager.displayName(for: languagePairManager.targetLanguage)
    }

    // MARK: - Device selection

    func selectInput(_ device: AudioDevice) {
        do {
            try audioManager.selectInput(device)
        } catch {
            errorAlert = AlertItem(title: "Device Error", message: error.localizedDescription, action: nil)
        }
    }

    func selectOutput(_ device: AudioDevice) {
        do {
            try audioManager.selectOutput(device)
        } catch {
            errorAlert = AlertItem(title: "Device Error", message: error.localizedDescription, action: nil)
        }
    }

    // MARK: - Preview factory

    static func preview(capturing: Bool = false, level: Float = -60) -> AudioViewModel {
        let instance = AudioViewModel()
        instance.inputDevices = AudioDevice.mockInputs
        instance.outputDevices = AudioDevice.mockOutputs
        instance.selectedInput = AudioDevice.mockInputs.first
        instance.selectedOutput = AudioDevice.mockOutputs.first
        instance.inputLevel = level
        return instance
    }
}

// MARK: - PassthroughTranslationService

/// No-op translation service used when no real service is provided (previews, lightweight tests).
private final class PassthroughTranslationService: TranslationService {
    func translate(
        text: String, from source: Locale.Language, to target: Locale.Language
    ) async throws -> String { text }
    func prepare(source: Locale.Language, target: Locale.Language) async throws {}
}
