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
    private let audioManager: AudioManager
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Designated init (used by AppContainer)

    init(coordinator: AudioCoordinator, audioManager: AudioManager, languagePairManager: LanguagePairManager) {
        self.coordinator = coordinator
        self.audioManager = audioManager
        self.languagePairManager = languagePairManager
        bindAudioManager()
        bindCoordinator()
    }

    // MARK: - Convenience init (used by previews and legacy tests)
    //
    // Creates a real AudioCoordinator with real services internally.
    // Factories are closures — services are only instantiated when start() is called,
    // so this init is safe to use in tests that never call start().

    convenience init(
        translationService: (any TranslationService)? = nil,
        incomingTranslationService: (any TranslationService)? = nil,
        languagePairManager: LanguagePairManager = LanguagePairManager()
    ) {
        let audioManager = AudioManager()
        let lpm = languagePairManager
        let outgoing: any TranslationService = translationService ?? PassthroughTranslationService()
        let incoming: any TranslationService = incomingTranslationService ?? PassthroughTranslationService()
        let coordinator = AudioCoordinator(
            audioCapture: audioManager,
            systemCapture: SystemAudioCaptureService(),
            outgoingVADFactory: { EnergyVADService() },
            incomingVADFactory: { EnergyVADService() },
            outgoingSTTFactory: { AppleSpeechService(locale: $0) },
            incomingSTTFactory: { AppleSpeechService(locale: $0) },
            outgoingTranslationService: outgoing,
            incomingTranslationService: incoming,
            outgoingTTSFactory: { try AVSpeechService(outputDeviceID: $0) },
            incomingTTSFactory: { _ in try AVSpeechService(outputDeviceID: nil) },
            languagePairManager: lpm
        )
        self.init(coordinator: coordinator, audioManager: audioManager, languagePairManager: lpm)
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

    // MARK: - Actions

    func toggleCapture() async {
        if isCapturing {
            await coordinator.stop()
        } else {
            await coordinator.start(
                captureApp: nil,
                blackHoleDeviceID: AudioDevice.deviceID(forNameContaining: "BlackHole")
            )
        }
    }

    func downloadLanguages() async {
        await coordinator.downloadLanguages()
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
    func translate(text: String, from: Locale.Language, to: Locale.Language) async throws -> String { text }
    func prepare(source: Locale.Language, target: Locale.Language) async throws {}
}
