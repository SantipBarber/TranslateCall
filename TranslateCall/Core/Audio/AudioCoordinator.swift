import AVFoundation
import Combine
import OSLog
@preconcurrency import ScreenCaptureKit

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "AudioCoordinator")

/// Owns and manages both the outgoing (mic → BlackHole) and incoming (SCStream → speakers) pipelines.
///
/// All public API is `@MainActor`. `AudioViewModel` observes this object via Combine.
/// F4.2 hooks (`suppressIncomingPipeline`, `suppressOutgoingCapture`) are no-op stubs
/// filled in by `HalfDuplexManager` in F4.2.
///
/// Pipeline setup, observation, translation & error helpers are in AudioCoordinator+Pipeline.swift.
@MainActor
final class AudioCoordinator: ObservableObject {

    // MARK: - Outgoing pipeline state

    @Published var outgoingTranscription: String?
    @Published var outgoingTranslation: String?
    @Published var isOutgoingSpeaking: Bool = false
    @Published private(set) var isOutgoingActive: Bool = false

    // MARK: - Incoming pipeline state

    @Published var incomingTranscription: String?
    @Published var incomingTranslation: String?
    @Published var isIncomingSpeaking: Bool = false
    @Published var isIncomingActive: Bool = false

    // MARK: - Shared state

    @Published var errorAlert: AlertItem?
    @Published var isSpeechActive: Bool = false
    @Published private(set) var isStarting: Bool = false
    @Published private(set) var availableCaptureApps: [SCRunningApplication] = []

    // MARK: - TTS Audio Monitor (local playback + recording of outgoing TTS)

    @Published var ttsMonitorEnabled: Bool = false {
        didSet { ttsMonitor?.isEnabled = ttsMonitorEnabled }
    }
    @Published private(set) var ttsMonitorRecording: Bool = false
    private(set) var ttsMonitor: TTSAudioMonitor?

    // MARK: - Injected dependencies

    let audioCapture: any AudioCapture
    private(set) var systemCapture: any SystemAudioCapture

    // Factories are called at start() time so tests can inject pre-built mocks.
    private(set) var outgoingVADFactory: () -> any VADService
    private(set) var incomingVADFactory: () -> any VADService
    private(set) var outgoingSTTFactory: (Locale) -> any SpeechRecognizerService
    private(set) var incomingSTTFactory: (Locale) -> any SpeechRecognizerService
    private(set) var outgoingTranslationService: any TranslationService
    private(set) var incomingTranslationService: any TranslationService
    private(set) var outgoingTTSFactory: (Locale, AudioDeviceID?) throws -> any SynthesisService
    private(set) var incomingTTSFactory: (Locale, AudioDeviceID?) throws -> any SynthesisService

    let languagePairManager: LanguagePairManager

    // MARK: - Half-duplex state (F4.2)

    @Published private(set) var halfDuplexState: HalfDuplexState = .listening

    /// Suppresses the outgoing translation stage when incoming TTS is speaking.
    /// Written on @MainActor; read in handleOutgoingTranslation (also @MainActor). No races.
    var outgoingCaptureSuppressed: Bool = false

    /// When true, the next outgoing utterance from STT is silently dropped (one-shot).
    /// Set via `suppressNextOutgoingTurn()` — resets automatically after one use.
    var suppressNextOutgoingTurnFlag: Bool = false

    /// Suppresses the incoming translation stage when outgoing TTS is speaking.
    var incomingCaptureSuppressed: Bool = false

    private var halfDuplexManager: HalfDuplexManager?
    private var halfDuplexCancellable: AnyCancellable?

    /// Configurable for tests; defaults to 300ms (PoC5-validated).
    private let halfDuplexTransitionDelay: Duration

    // MARK: - Active services (created at start() time, released at stop())

    var outgoingVAD: (any VADService)?
    var incomingVAD: (any VADService)?
    var outgoingSTT: (any SpeechRecognizerService)?
    var incomingSTT: (any SpeechRecognizerService)?
    var outgoingTTS: (any SynthesisService)?
    var incomingTTS: (any SynthesisService)?

    // MARK: - Observation tasks

    var outgoingTasks: [Task<Void, Never>] = []
    var incomingTasks: [Task<Void, Never>] = []

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
        outgoingTTSFactory: @escaping (Locale, AudioDeviceID?) throws -> any SynthesisService,
        incomingTTSFactory: @escaping (Locale, AudioDeviceID?) throws -> any SynthesisService,
        languagePairManager: LanguagePairManager,
        halfDuplexTransitionDelay: Duration = .milliseconds(300)
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
        self.halfDuplexTransitionDelay = halfDuplexTransitionDelay
    }

    // MARK: - Public actions

    /// Start both pipelines. Outgoing audio capture failure is fatal (early return, errorAlert set).
    /// All other outgoing failures and all incoming failures are non-fatal (errorAlert set, continue).
    func start(captureTarget: CaptureTarget? = nil, blackHoleDeviceID: AudioDeviceID? = nil) async {
        guard !isOutgoingActive else { return }
        setupHalfDuplex()
        isStarting = true
        defer { isStarting = false }

        do {
            try await startOutgoingPipeline(blackHoleDeviceID: blackHoleDeviceID)
        } catch {
            errorAlert = makeAlertItem(for: error)
            return
        }

        isOutgoingActive = true
        await startIncomingPipeline(captureTarget: captureTarget)
    }

    func stop() async {
        cancelAllTasks()
        teardownHalfDuplex()

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
        halfDuplexState = .listening
        outgoingTranscription = nil
        outgoingTranslation = nil
        incomingTranscription = nil
        incomingTranslation = nil
        suppressNextOutgoingTurnFlag = false

        logger.info("AudioCoordinator stopped")
    }

    /// Silently drops the next outgoing utterance from STT (one-shot mute turn).
    /// Calling this during an active session causes the very next recognized segment
    /// to be suppressed before translation and TTS. The flag resets automatically.
    func suppressNextOutgoingTurn() {
        suppressNextOutgoingTurnFlag = true
        logger.debug("Next outgoing turn will be suppressed")
    }

    // MARK: - TTS Monitor actions

    /// Initializes the monitor (lazy — only created when first enabled).
    func enableTTSMonitor() {
        if ttsMonitor == nil {
            do {
                ttsMonitor = try TTSAudioMonitor()
            } catch {
                errorAlert = makeAlertItem(for: error)
                return
            }
        }
        ttsMonitor?.isEnabled = true
        ttsMonitorEnabled = true
        Task { await outgoingTTS?.setAudioMonitor(ttsMonitor) }
    }

    func disableTTSMonitor() {
        ttsMonitor?.isEnabled = false
        ttsMonitorEnabled = false
        Task { await outgoingTTS?.setAudioMonitor(nil) }
    }

    func toggleTTSRecording() {
        guard let monitor = ttsMonitor else { return }
        if monitor.isRecording {
            monitor.stopRecording()
            ttsMonitorRecording = false
        } else {
            do {
                try monitor.startRecording()
                ttsMonitorRecording = true
            } catch {
                errorAlert = makeAlertItem(for: error)
            }
        }
    }

    func playLastRecording() {
        ttsMonitor?.playLastRecording()
    }

    /// Update STT locales when the language pair changes.
    func updateLanguagePair() async {
        let sourceLocale = Locale(identifier: languagePairManager.sourceLanguage.minimalIdentifier)
        let targetLocale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
        await outgoingSTT?.setLocale(sourceLocale)
        await incomingSTT?.setLocale(targetLocale)
    }

    /// Prepare the language pair (download translation models if needed).
    func downloadLanguages() async {
        do {
            try await outgoingTranslationService.prepare(
                source: languagePairManager.sourceLanguage,
                target: languagePairManager.targetLanguage
            )
            await languagePairManager.checkAvailability()
        } catch {
            errorAlert = makeAlertItem(for: error)
        }
    }

    // MARK: - F4.2 — HalfDuplexCoordinating conformance (implemented)

    func suppressOutgoingCapture(_ suppress: Bool) {
        outgoingCaptureSuppressed = suppress
    }

    func suppressIncomingPipeline(_ suppress: Bool) {
        incomingCaptureSuppressed = suppress
    }

    // MARK: - F4.2 — HalfDuplex lifecycle

    private func setupHalfDuplex() {
        let hdm = HalfDuplexManager(coordinator: self, transitionDelay: halfDuplexTransitionDelay)
        halfDuplexManager = hdm
        halfDuplexCancellable = hdm.$state
            .sink { @MainActor [weak self] state in
                self?.halfDuplexState = state
            }
    }

    private func teardownHalfDuplex() {
        halfDuplexCancellable = nil
        halfDuplexManager?.deactivate()
        halfDuplexManager = nil
    }
}

// MARK: - HalfDuplexCoordinating

extension AudioCoordinator: HalfDuplexCoordinating {
    var isOutgoingSpeakingPublisher: AnyPublisher<Bool, Never> {
        $isOutgoingSpeaking.eraseToAnyPublisher()
    }
    var isIncomingSpeakingPublisher: AnyPublisher<Bool, Never> {
        $isIncomingSpeaking.eraseToAnyPublisher()
    }
}
