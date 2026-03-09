import AVFoundation
import Combine
import OSLog
@preconcurrency import ScreenCaptureKit

// nonisolated(unsafe): top-level let is @MainActor under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor;
// Logger is immutable and thread-safe, so unsafe access is fine here.
nonisolated(unsafe) private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "AudioCoordinator")

/// Owns and manages both the outgoing (mic → BlackHole) and incoming (SCStream → speakers) pipelines.
///
/// All public API is `@MainActor`. `AudioViewModel` observes this object via Combine.
/// F4.2 hooks (`suppressIncomingPipeline`, `suppressOutgoingCapture`) are no-op stubs
/// filled in by `HalfDuplexManager` in F4.2.
@MainActor
final class AudioCoordinator: ObservableObject {

    // MARK: - Outgoing pipeline state

    @Published private(set) var outgoingTranscription: String?
    @Published private(set) var outgoingTranslation: String?
    @Published private(set) var isOutgoingSpeaking: Bool = false
    @Published private(set) var isOutgoingActive: Bool = false

    // MARK: - Incoming pipeline state

    @Published private(set) var incomingTranscription: String?
    @Published private(set) var incomingTranslation: String?
    @Published private(set) var isIncomingSpeaking: Bool = false
    @Published private(set) var isIncomingActive: Bool = false

    // MARK: - Shared state

    @Published private(set) var errorAlert: AlertItem?
    @Published private(set) var isSpeechActive: Bool = false
    @Published private(set) var isStarting: Bool = false
    @Published private(set) var availableCaptureApps: [SCRunningApplication] = []

    // MARK: - Injected dependencies

    let audioCapture: any AudioCapture
    private let systemCapture: any SystemAudioCapture

    // Factories are called at start() time so tests can inject pre-built mocks.
    private let outgoingVADFactory: () -> any VADService
    private let incomingVADFactory: () -> any VADService
    private let outgoingSTTFactory: (Locale) -> any SpeechRecognizerService
    private let incomingSTTFactory: (Locale) -> any SpeechRecognizerService
    private let outgoingTranslationService: any TranslationService
    private let incomingTranslationService: any TranslationService
    private let outgoingTTSFactory: (AudioDeviceID?) throws -> any SynthesisService
    private let incomingTTSFactory: (AudioDeviceID?) throws -> any SynthesisService

    let languagePairManager: LanguagePairManager

    // MARK: - Active services (created at start() time, released at stop())

    private var outgoingVAD: (any VADService)?
    private var incomingVAD: (any VADService)?
    private var outgoingSTT: (any SpeechRecognizerService)?
    private var incomingSTT: (any SpeechRecognizerService)?
    private var outgoingTTS: (any SynthesisService)?
    private var incomingTTS: (any SynthesisService)?

    // MARK: - Observation tasks

    private var outgoingTasks: [Task<Void, Never>] = []
    private var incomingTasks: [Task<Void, Never>] = []

    // MARK: - Init

    init(
        audioCapture: any AudioCapture,
        systemCapture: any SystemAudioCapture,
        outgoingVADFactory: @escaping () -> any VADService,
        incomingVADFactory: @escaping () -> any VADService,
        outgoingSTTFactory: @escaping (Locale) -> any SpeechRecognizerService,
        incomingSTTFactory: @escaping (Locale) -> any SpeechRecognizerService,
        outgoingTranslationService: any TranslationService,
        incomingTranslationService: any TranslationService,
        outgoingTTSFactory: @escaping (AudioDeviceID?) throws -> any SynthesisService,
        incomingTTSFactory: @escaping (AudioDeviceID?) throws -> any SynthesisService,
        languagePairManager: LanguagePairManager
    ) {
        self.audioCapture = audioCapture
        self.systemCapture = systemCapture
        self.outgoingVADFactory = outgoingVADFactory
        self.incomingVADFactory = incomingVADFactory
        self.outgoingSTTFactory = outgoingSTTFactory
        self.incomingSTTFactory = incomingSTTFactory
        self.outgoingTranslationService = outgoingTranslationService
        self.incomingTranslationService = incomingTranslationService
        self.outgoingTTSFactory = outgoingTTSFactory
        self.incomingTTSFactory = incomingTTSFactory
        self.languagePairManager = languagePairManager
    }

    // MARK: - Public actions

    /// Start both pipelines. Outgoing audio capture failure is fatal (early return, errorAlert set).
    /// All other outgoing failures and all incoming failures are non-fatal (errorAlert set, continue).
    func start(captureApp: SCRunningApplication? = nil, blackHoleDeviceID: AudioDeviceID? = nil) async {
        guard !isOutgoingActive else { return }
        isStarting = true
        defer { isStarting = false }

        do {
            try await startOutgoingPipeline(blackHoleDeviceID: blackHoleDeviceID)
        } catch {
            errorAlert = makeAlertItem(for: error)
            return
        }

        isOutgoingActive = true
        await startIncomingPipeline(captureApp: captureApp)
    }

    func stop() async {
        cancelAllTasks()

        // Outgoing pipeline
        await outgoingSTT?.deactivate()
        await outgoingVAD?.deactivate()
        audioCapture.stopCapture()
        await outgoingTTS?.deactivate()
        outgoingSTT = nil
        outgoingVAD = nil
        outgoingTTS = nil

        // Incoming pipeline
        await systemCapture.deactivate()
        await incomingVAD?.deactivate()
        await incomingSTT?.deactivate()
        await incomingTTS?.deactivate()
        incomingVAD = nil
        incomingSTT = nil
        incomingTTS = nil

        isOutgoingActive = false
        isIncomingActive = false
        isSpeechActive = false
        isOutgoingSpeaking = false
        isIncomingSpeaking = false
        outgoingTranscription = nil
        outgoingTranslation = nil
        incomingTranscription = nil
        incomingTranslation = nil

        logger.info("AudioCoordinator stopped")
    }

    /// Update STT locales when the language pair changes.
    func updateLanguagePair() async {
        let sourceLocale = Locale(identifier: languagePairManager.sourceLanguage.minimalIdentifier)
        let targetLocale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
        await outgoingSTT?.setLocale(sourceLocale)
        await incomingSTT?.setLocale(targetLocale)
    }

    // MARK: - F4.2 hooks (no-op stubs — filled by HalfDuplexManager in F4.2)

    func suppressIncomingPipeline(_ suppress: Bool) {}
    func suppressOutgoingCapture(_ suppress: Bool) {}

    // MARK: - Private — pipeline setup

    /// Starts the outgoing pipeline. Only `audioCapture.startCapture()` failure propagates to caller.
    /// VAD, STT, and TTS failures are caught and stored in `errorAlert` — pipeline continues
    /// without the failed component so the incoming pipeline can still start.
    private func startOutgoingPipeline(blackHoleDeviceID: AudioDeviceID?) async throws {
        // Fatal: mic permission required for the app to function at all.
        try await audioCapture.startCapture()
        logger.info("Outgoing: audio capture started")

        // VAD (non-fatal)
        let vad = outgoingVADFactory()
        outgoingVAD = vad
        do {
            try await vad.activate(stream: audioCapture.audioStream16kHz)
            observeVADState(vad)
            logger.info("Outgoing: VAD activated")
        } catch {
            errorAlert = makeAlertItem(for: error)
            logger.warning("Outgoing: VAD failed — \(error.localizedDescription)")
        }

        // STT (non-fatal)
        let sourceLocale = Locale(identifier: languagePairManager.sourceLanguage.minimalIdentifier)
        let stt = outgoingSTTFactory(sourceLocale)
        outgoingSTT = stt
        do {
            try await stt.activate(stream: vad.speechSegments)
            observeOutgoingTranscriptions(stt)
            logger.info("Outgoing: STT activated for \(sourceLocale.identifier)")
        } catch {
            errorAlert = makeAlertItem(for: error)
            logger.warning("Outgoing: STT failed — \(error.localizedDescription)")
        }

        // TTS (non-fatal)
        do {
            let tts = try outgoingTTSFactory(blackHoleDeviceID)
            outgoingTTS = tts
            observeTTSState(tts, onSpeakingChange: { [weak self] speaking in
                self?.isOutgoingSpeaking = speaking
            }, into: &outgoingTasks)
            logger.info("Outgoing: TTS activated")
        } catch {
            errorAlert = makeAlertItem(for: error)
            logger.warning("Outgoing: TTS failed — \(error.localizedDescription)")
        }
    }

    /// Starts the incoming pipeline. All failures are non-fatal — errorAlert is set
    /// and `isIncomingActive` remains false if activation fails.
    private func startIncomingPipeline(captureApp: SCRunningApplication?) async {
        do {
            try await systemCapture.activate(app: captureApp)
            logger.info("Incoming: system audio capture started")

            let vad = incomingVADFactory()
            incomingVAD = vad
            try await vad.activate(stream: systemCapture.audioStream16kHz)
            logger.info("Incoming: VAD activated")

            let targetLocale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
            let stt = incomingSTTFactory(targetLocale)
            incomingSTT = stt
            try await stt.activate(stream: vad.speechSegments)
            observeIncomingTranscriptions(stt)
            logger.info("Incoming: STT activated for \(targetLocale.identifier)")

            let tts = try incomingTTSFactory(nil)
            incomingTTS = tts
            observeTTSState(tts, onSpeakingChange: { [weak self] speaking in
                self?.isIncomingSpeaking = speaking
            }, into: &incomingTasks)
            logger.info("Incoming: TTS activated")

            isIncomingActive = true
        } catch {
            errorAlert = makeAlertItem(for: error)
            logger.warning("Incoming pipeline failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Observation helpers

    private func observeVADState(_ vad: some VADService) {
        outgoingTasks.append(Task { [weak self] in
            for await active in vad.vadStateEvents {
                self?.isSpeechActive = active
            }
        })
    }

    private func observeOutgoingTranscriptions(_ stt: some SpeechRecognizerService) {
        outgoingTasks.append(Task { [weak self] in
            guard let self else { return }
            for await result in stt.transcriptionStream {
                self.outgoingTranscription = result.text
                await self.handleOutgoingTranslation(of: result.text)
            }
        })
    }

    private func observeIncomingTranscriptions(_ stt: some SpeechRecognizerService) {
        incomingTasks.append(Task { [weak self] in
            guard let self else { return }
            for await result in stt.transcriptionStream {
                self.incomingTranscription = result.text
                await self.handleIncomingTranslation(of: result.text)
            }
        })
    }

    private func observeTTSState(
        _ tts: some SynthesisService,
        onSpeakingChange: @escaping (Bool) -> Void,
        into tasks: inout [Task<Void, Never>]
    ) {
        tasks.append(Task { [weak self] in
            for await speaking in tts.isSpeakingStream {
                guard self != nil else { return }
                onSpeakingChange(speaking)
            }
        })
    }

    private func cancelAllTasks() {
        outgoingTasks.forEach { $0.cancel() }
        outgoingTasks.removeAll()
        incomingTasks.forEach { $0.cancel() }
        incomingTasks.removeAll()
    }

    // MARK: - Translation handlers

    private func handleOutgoingTranslation(of text: String) async {
        guard !text.isEmpty else { return }
        await outgoingTTS?.stopSpeaking()
        do {
            let translated = try await outgoingTranslationService.translate(
                text: text,
                from: languagePairManager.sourceLanguage,
                to: languagePairManager.targetLanguage
            )
            outgoingTranslation = translated
            let locale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
            await outgoingTTS?.speak(text: translated, locale: locale)
        } catch {
            errorAlert = makeAlertItem(for: error)
        }
    }

    private func handleIncomingTranslation(of text: String) async {
        guard !text.isEmpty, !isIncomingSpeaking else { return }
        do {
            let translated = try await incomingTranslationService.translate(
                text: text,
                from: languagePairManager.targetLanguage,
                to: languagePairManager.sourceLanguage
            )
            incomingTranslation = translated
            let locale = Locale(identifier: languagePairManager.sourceLanguage.minimalIdentifier)
            await incomingTTS?.speak(text: translated, locale: locale)
        } catch {
            errorAlert = makeAlertItem(for: error)
        }
    }

    // MARK: - Error helpers

    private func makeAlertItem(for error: Error) -> AlertItem {
        switch error {
        case AudioError.permissionDenied:
            return AlertItem(
                title: "Microphone Access Required",
                message: "TranslateCall needs microphone access. Open System Settings to allow it.",
                action: .openSettings
            )
        case SystemAudioCaptureError.permissionDenied:
            return AlertItem(
                title: "Screen Recording Required",
                message: "TranslateCall needs Screen Recording permission to capture incoming audio. Enable it in System Settings.",
                action: .openSettings
            )
        case TranslationError.bridgeUnavailable:
            return AlertItem(title: "Translation Unavailable", message: "Translation bridge unavailable. Restart the app.", action: nil)
        case TranslationError.unsupportedPair(_, _):
            return AlertItem(title: "Language Pair Unsupported", message: "This language pair is not supported.", action: nil)
        default:
            return AlertItem(title: "Error", message: error.localizedDescription, action: nil)
        }
    }
}
