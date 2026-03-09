import Combine
import Foundation
import Speech
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

@MainActor
final class AudioViewModel: ObservableObject {

    // MARK: - Published state (mirrored from AudioManager)

    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published var selectedInput: AudioDevice?
    @Published var selectedOutput: AudioDevice?
    @Published private(set) var inputLevel: Float = -160
    @Published private(set) var isCapturing = false

    // MARK: - VAD state

    @Published private(set) var isSpeechActive: Bool = false

    // MARK: - STT state

    @Published private(set) var latestTranscription: String?
    @Published private(set) var isTranscribing: Bool = false

    // MARK: - Translation state

    @Published private(set) var latestTranslation: String?
    @Published private(set) var isTranslating: Bool = false

    // MARK: - TTS state

    @Published private(set) var isSpeaking: Bool = false

    // MARK: - UI-specific state

    @Published private(set) var isStarting = false
    @Published var errorAlert: AlertItem?

    // MARK: - Private — audio pipeline

    private let audioManager: AudioManager
    private let vadFactory: VADServiceFactory
    private var cancellables: Set<AnyCancellable> = []
    private var vadStateTask: Task<Void, Never>?
    private var sttService: (any SpeechRecognizerService)?
    private var transcriptionTask: Task<Void, Never>?
    private var synthesisService: (any SynthesisService)?
    private var speakingTask: Task<Void, Never>?

    // MARK: - Private — translation pipeline

    private let translationService: (any TranslationService)?
    let languagePairManager: LanguagePairManager

    // MARK: - Init

    init(
        audioManager: AudioManager = AudioManager(),
        vadFactory: VADServiceFactory = VADServiceFactory(),
        translationService: (any TranslationService)? = nil,
        languagePairManager: LanguagePairManager = LanguagePairManager()
    ) {
        self.audioManager = audioManager
        self.vadFactory = vadFactory
        self.translationService = translationService
        self.languagePairManager = languagePairManager
        bindAudioManager()
    }

    // MARK: - Combine bindings

    private func bindAudioManager() {
        audioManager.$inputDevices
            .assign(to: &$inputDevices)
        audioManager.$outputDevices
            .assign(to: &$outputDevices)
        audioManager.$selectedInput
            .assign(to: &$selectedInput)
        audioManager.$selectedOutput
            .assign(to: &$selectedOutput)
        audioManager.$inputLevel
            .assign(to: &$inputLevel)
        audioManager.$isCapturing
            .assign(to: &$isCapturing)
    }

    // MARK: - Actions

    func toggleCapture() async {
        if isCapturing {
            audioManager.stopCapture()
            await vadFactory.service.deactivate()
            vadStateTask?.cancel()
            vadStateTask = nil
            isSpeechActive = false
            await deactivateSTT()
            await deactivateTTS()
        } else {
            isStarting = true
            defer { isStarting = false }
            do {
                try await audioManager.startCapture()
                try await vadFactory.service.activate(stream: audioManager.audioStream16kHz)
                observeVADState(vadFactory.service)
                await activateSTT(speechSegments: vadFactory.service.speechSegments, locale: .current)
                activateTTS()
            } catch AudioError.permissionDenied {
                errorAlert = AlertItem(
                    title: "Microphone Access Required",
                    message: "TranslateCall needs microphone access. Open System Settings to allow it.",
                    action: .openSettings
                )
            } catch {
                errorAlert = AlertItem(
                    title: "Audio Error",
                    message: error.localizedDescription,
                    action: nil
                )
            }
        }
    }

    // MARK: - VAD

    private func observeVADState(_ service: any VADService) {
        vadStateTask?.cancel()
        vadStateTask = Task { @MainActor [weak self] in
            for await active in service.vadStateEvents {
                self?.isSpeechActive = active
            }
        }
    }

    // MARK: - STT

    func activateSTT(speechSegments: AsyncStream<SpeechSegment>, locale: Locale) async {
        let service = AppleSpeechService(locale: locale)
        sttService = service
        observeTranscriptions(service)
        do {
            try await service.activate(stream: speechSegments)
        } catch STTError.permissionDenied {
            errorAlert = AlertItem(
                title: "Speech Recognition Required",
                message: "TranslateCall needs speech recognition access. Enable it in System Settings.",
                action: .openSettings
            )
        } catch STTError.recognizerUnavailable(let locale) {
            errorAlert = AlertItem(
                title: "Speech Recognizer Unavailable",
                message: "No speech recognizer available for \(locale.identifier).",
                action: nil
            )
        } catch {
            errorAlert = AlertItem(title: "STT Error", message: error.localizedDescription, action: nil)
        }
    }

    private func observeTranscriptions(_ service: any SpeechRecognizerService) {
        transcriptionTask?.cancel()
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await result in service.transcriptionStream {
                self.latestTranscription = result.text
                self.isTranscribing = false
                await self.handleTranslation(of: result.text)
            }
        }
    }

    private func deactivateSTT() async {
        await sttService?.deactivate()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        sttService = nil
        isTranscribing = false
        isTranslating = false
        latestTranslation = nil
    }

    // MARK: - Translation

    private func handleTranslation(of text: String) async {
        guard !text.isEmpty,
              let service = translationService,
              !isSpeaking
        else { return }

        await synthesisService?.stopSpeaking()
        isTranslating = true
        do {
            let translated = try await service.translate(
                text: text,
                from: languagePairManager.sourceLanguage,
                to: languagePairManager.targetLanguage
            )
            latestTranslation = translated
            isTranslating = false
            let targetLocale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
            await synthesisService?.speak(text: translated, locale: targetLocale)
        } catch {
            isTranslating = false
            errorAlert = AlertItem(
                title: "Translation Error",
                message: translationErrorMessage(for: error),
                action: nil
            )
        }
    }

    private func translationErrorMessage(for error: Error) -> String {
        switch error {
        case TranslationError.bridgeUnavailable:
            return "Translation unavailable. Restart the app."
        case TranslationError.unsupportedPair:
            return "This language pair is not supported. Change languages in settings."
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Language download

    func downloadLanguages() async {
        do {
            try await translationService?.prepare(
                source: languagePairManager.sourceLanguage,
                target: languagePairManager.targetLanguage
            )
            await languagePairManager.checkAvailability()
        } catch {
            errorAlert = AlertItem(title: "Download Failed", message: error.localizedDescription, action: nil)
        }
    }

    // MARK: - TTS

    private func activateTTS() {
        do {
            let service = try AVSpeechService()
            synthesisService = service
            observeSynthesisState(service)
        } catch {
            errorAlert = AlertItem(title: "TTS Error", message: error.localizedDescription, action: nil)
        }
    }

    private func observeSynthesisState(_ service: any SynthesisService) {
        speakingTask?.cancel()
        speakingTask = Task { @MainActor [weak self] in
            for await active in service.isSpeakingStream {
                self?.isSpeaking = active
            }
        }
    }

    private func deactivateTTS() async {
        await synthesisService?.deactivate()
        speakingTask?.cancel()
        speakingTask = nil
        synthesisService = nil
        isSpeaking = false
    }

    func startSynthesis(text: String, locale: Locale) {
        Task { await synthesisService?.speak(text: text, locale: locale) }
    }

    #if DEBUG
    func testTTS() {
        startSynthesis(text: "Hello, translation is working.", locale: .current)
    }
    #endif

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
        let instance = AudioViewModel(audioManager: AudioManager())
        instance.inputDevices = AudioDevice.mockInputs
        instance.outputDevices = AudioDevice.mockOutputs
        instance.selectedInput = AudioDevice.mockInputs.first
        instance.selectedOutput = AudioDevice.mockOutputs.first
        instance.inputLevel = level
        return instance
    }
}
