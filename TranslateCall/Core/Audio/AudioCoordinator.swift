import AVFoundation
import Combine
import OSLog
@preconcurrency import ScreenCaptureKit

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "AudioCoordinator")

/// Owns and manages both the outgoing (mic → BlackHole) and incoming (SCStream → speakers) pipelines.
///
/// All public API is `@MainActor`. `AudioViewModel` observes this object via Combine.
/// No sentence is ever dropped at the translation stage (F8.5.3 D-4): echo is kept out by
/// `MicEchoGate`, which mutes the mic before the VAD in speakers mode only.
///
/// Pipeline setup, observation, translation & error helpers are in AudioCoordinator+Pipeline.swift.
@MainActor
final class AudioCoordinator: ObservableObject {

    // MARK: - Outgoing pipeline state

    @Published var outgoingTranscription: String?
    @Published var outgoingTranslation: String?
    @Published var isOutgoingSpeaking: Bool = false {
        didSet { updateConversationState() }
    }
    @Published private(set) var isOutgoingActive: Bool = false

    // MARK: - Incoming pipeline state

    @Published var incomingTranscription: String?
    @Published var incomingTranslation: String?
    @Published var isIncomingSpeaking: Bool = false {
        didSet {
            micEchoGate?.setIncomingSpeaking(isIncomingSpeaking)
            updateConversationState()
        }
    }
    /// Written only by the coordinator (here and in AudioCoordinator+Pipeline.swift); the setter is
    /// internal rather than `private(set)` because the extension lives in another file.
    @Published var incomingStatus: IncomingStatus = .idle {
        didSet { isIncomingActive = (incomingStatus == .active) }
    }
    /// Derived from `incomingStatus`; kept as its own publisher for existing bindings.
    @Published private(set) var isIncomingActive: Bool = false

    /// Bumped by start() and stop(); an activation that sees a different value was superseded.
    var sessionGeneration: UInt64 = 0
    var captureTarget: CaptureTarget?
    /// Subscribed once to `systemCapture.events` and never cancelled: cancelling the iterating
    /// task would terminate the service's long-lived stream (the A1 bug class).
    var incomingEventsTask: Task<Void, Never>?
    var incomingActivationTask: Task<Void, Never>?
    /// A `.stopped` event that arrived while incoming was `.starting`.
    var pendingStopReason: IncomingStopReason?
    var pendingStopReasonForTesting: IncomingStopReason? { pendingStopReason }
    /// True for the whole of `stop()`, so a Retry cannot start a session that stop() would not see.
    /// Readable from AudioCoordinator+Pipeline.swift (handleIncomingEvent ignores events meanwhile).
    private(set) var isStopping = false

    // MARK: - Shared state

    @Published var errorAlert: AlertItem?
    /// Translation errors already alerted in this session: each kind is alerted once (F8.5.4 REQ-TR-21).
    var alertedTranslationErrors: Set<String> = []
    @Published var isSpeechActive: Bool = false
    @Published private(set) var isStarting: Bool = false
    @Published private(set) var availableCaptureApps: [SCRunningApplication] = []

    // MARK: - TTS Audio Monitor (local playback + recording of outgoing TTS)

    @Published var ttsMonitorEnabled: Bool = false {
        didSet { ttsMonitor?.isEnabled = ttsMonitorEnabled }
    }
    @Published private(set) var ttsMonitorRecording: Bool = false
    private(set) var ttsMonitor: TTSAudioMonitor?

    // MARK: - TTS notice (F8.5.2 REQ-T-41)

    /// Latest TTS skip / fallback / drop, as one line; clears itself after `ttsNoticeDuration`.
    /// Never an alert. Written by AudioCoordinator+Pipeline.swift, hence not `private(set)`.
    @Published var ttsNotice: String?
    private var ttsNoticeTask: Task<Void, Never>?
    private let noticeClock: any Clock<Duration>
    private let ttsNoticeDuration: Duration
    /// Whether a pair's translation models are downloaded (F8.5.4 REQ-TR-06). Injected: unit tests never
    /// ask the real `LanguageAvailability`; the default (previews, tests) says yes.
    private let isTranslationPairInstalled: (Locale.Language, Locale.Language) async -> Bool

    // MARK: - Injected dependencies

    let audioCapture: any AudioCapture
    private(set) var systemCapture: any SystemAudioCapture

    // Factories are called at start() time so tests can inject pre-built mocks.
    // VAD factories are async: Silero loads its CoreML model (F8.5.3 REQ-V-01).
    private(set) var outgoingVADFactory: () async -> any VADService
    private(set) var incomingVADFactory: () async -> any VADService
    private(set) var outgoingSTTFactory: (Locale) -> any SpeechRecognizerService
    private(set) var incomingSTTFactory: (Locale) -> any SpeechRecognizerService
    private(set) var outgoingTranslationService: any TranslationService
    private(set) var incomingTranslationService: any TranslationService
    private(set) var outgoingTTSFactory: (Locale, AudioDeviceID?) throws -> any SynthesisService
    private(set) var incomingTTSFactory: (Locale, AudioDeviceID?) throws -> any SynthesisService

    let languagePairManager: LanguagePairManager

    // MARK: - Conversation state and mic echo gate (F8.5.3)

    /// How the user listens (from `ConversationSettings`); applied live to the gate (REQ-H-05).
    @Published var listeningMode: ListeningMode = .headphones {
        didSet { micEchoGate?.setMode(listeningMode) }
    }
    /// The gate is muting the mic (speakers mode, remote translation playing).
    @Published private(set) var isMicPaused = false {
        didSet { updateConversationState() }
    }
    @Published private(set) var conversationState: ConversationState = .listening

    /// This session's gate between the mic stream and the outgoing VAD; nil outside a session.
    private(set) var micEchoGate: MicEchoGate?
    private let echoGateTail: Duration
    private let echoGateClock: any Clock<Duration>

    /// When true, the next outgoing utterance from STT is silently dropped (one-shot).
    /// Set via `suppressNextOutgoingTurn()` — resets automatically after one use.
    var suppressNextOutgoingTurnFlag: Bool = false

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
        outgoingVADFactory: @escaping () async -> any VADService,
        incomingVADFactory: @escaping () async -> any VADService,
        outgoingSTTFactory: @escaping (Locale) -> any SpeechRecognizerService,
        incomingSTTFactory: @escaping (Locale) -> any SpeechRecognizerService,
        outgoingTranslationService: any TranslationService,
        incomingTranslationService: any TranslationService,
        outgoingTTSFactory: @escaping (Locale, AudioDeviceID?) throws -> any SynthesisService,
        incomingTTSFactory: @escaping (Locale, AudioDeviceID?) throws -> any SynthesisService,
        languagePairManager: LanguagePairManager,
        echoGateTail: Duration = .milliseconds(300),
        echoGateClock: any Clock<Duration> = ContinuousClock(),
        noticeClock: any Clock<Duration> = ContinuousClock(),
        ttsNoticeDuration: Duration = .seconds(5),
        isTranslationPairInstalled: @escaping (Locale.Language, Locale.Language) async -> Bool = { _, _ in true }
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
        self.echoGateTail = echoGateTail
        self.echoGateClock = echoGateClock
        self.noticeClock = noticeClock
        self.ttsNoticeDuration = ttsNoticeDuration
        self.isTranslationPairInstalled = isTranslationPairInstalled
    }

    // MARK: - Public actions

    /// Start both pipelines. Outgoing audio capture failure is fatal (early return, errorAlert set).
    /// All other outgoing failures and all incoming failures are non-fatal (errorAlert set, continue).
    /// A call while another start() is running is a no-op. A stop() (or the mic ending) while the
    /// outgoing pipeline is still coming up supersedes this start: it releases what it created and
    /// returns without going active.
    func start(captureTarget: CaptureTarget? = nil, blackHoleDeviceID: AudioDeviceID? = nil) async {
        guard !isOutgoingActive, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        // The hidden bridges cannot show the download sheet: no session without the packs (REQ-TR-06).
        let packsInstalled = await translationPacksInstalled()
        guard generation == sessionGeneration else { return }   // a Stop during the check: no alert
        guard packsInstalled else {
            errorAlert = makeAlertItem(for: TranslationError.modelNotLoaded)
            return
        }
        self.captureTarget = captureTarget
        micEchoGate = makeMicEchoGate()
        alertedTranslationErrors.removeAll()
        await warmUpTranslation()   // returns at once: the sessions open while capture starts (REQ-TR-05)

        do {
            try await startOutgoingPipeline(blackHoleDeviceID: blackHoleDeviceID)
        } catch {
            errorAlert = makeAlertItem(for: error)
            releaseMicEchoGate()   // no session: the gate is nil outside one
            return
        }
        guard generation == sessionGeneration, audioCapture.isCapturing else {
            logger.info("start() superseded (stop or mic ended) — releasing outgoing")
            await teardownOutgoingServices()
            releaseMicEchoGate()
            return
        }

        isOutgoingActive = true
        subscribeToIncomingEvents()
        let activation = Task { await self.activateIncoming() }
        incomingActivationTask = activation
        await activation.value
    }

    func stop() async {
        isStopping = true   // set before any await: blocks retryIncoming() for the whole teardown
        defer { isStopping = false }
        sessionGeneration &+= 1
        let pendingActivation = incomingActivationTask
        incomingActivationTask = nil
        await pendingActivation?.value   // a superseded activation tears itself down

        cancelAllTasks()
        releaseMicEchoGate()
        await teardownOutgoingServices()

        // Incoming pipeline
        await systemCapture.deactivate()
        await teardownIncomingServices()

        isOutgoingActive = false
        incomingStatus = .idle
        pendingStopReason = nil
        isSpeechActive = false
        isOutgoingSpeaking = false
        isIncomingSpeaking = false
        outgoingTranscription = nil
        outgoingTranslation = nil
        incomingTranscription = nil
        incomingTranslation = nil
        suppressNextOutgoingTurnFlag = false
        ttsNoticeTask?.cancel()
        ttsNotice = nil

        logger.info("AudioCoordinator stopped")
    }

    /// AudioManager stopped the mic on its own (device lost, switch and restore failed):
    /// tear the whole session down so the UI can Start again. No-op during a user stop().
    func handleOutgoingCaptureEnded() async {
        guard isOutgoingActive, !isStopping else { return }
        await stop()
    }

    /// Re-runs incoming activation on `captureTarget` (the call app chosen now, which may differ
    /// from the one start() saw) during a session (REQ-C-34). Allowed from `.stopped`, and from
    /// `.disabled` once a target exists; a no-op otherwise, so a double Retry activates once.
    func retryIncoming(captureTarget target: CaptureTarget?) {
        guard isOutgoingActive, !isStopping else { return }
        switch incomingStatus {
        case .stopped: break
        case .disabled where target != nil: break
        default: return
        }
        captureTarget = target
        incomingStatus = .starting
        incomingActivationTask = Task { await self.activateIncoming() }
    }

    /// Both directions' packs are downloaded; `start` alerts "download first" (F8.5.4 REQ-TR-06).
    private func translationPacksInstalled() async -> Bool {
        let source = languagePairManager.sourceLanguage
        let target = languagePairManager.targetLanguage
        guard await isTranslationPairInstalled(source, target) else { return false }
        return await isTranslationPairInstalled(target, source)
    }

    /// Silently drops the next outgoing utterance from STT (one-shot mute turn).
    /// Calling this during an active session causes the very next recognized segment
    /// to be suppressed before translation and TTS. The flag resets automatically.
    func suppressNextOutgoingTurn() {
        suppressNextOutgoingTurnFlag = true
        logger.debug("Next outgoing turn will be suppressed")
    }

    // MARK: - TTS notice

    /// Shows `text` in the notice line, replacing any earlier notice and restarting its timer.
    func showTTSNotice(_ text: String) {
        ttsNotice = text
        ttsNoticeTask?.cancel()
        let clock = noticeClock
        let duration = ttsNoticeDuration
        ttsNoticeTask = Task { [weak self] in
            do { try await clock.sleep(for: duration) } catch { return }
            guard !Task.isCancelled else { return }   // a newer notice replaced this one
            self?.ttsNotice = nil
        }
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

}

// MARK: - Mic echo gate and conversation state (F8.5.3 REQ-H-02…06, REQ-H-13, design §3.2–3.3)

extension AudioCoordinator {
    /// A gate for the session that is starting. Its paused reports are advisory (they can arrive
    /// out of order across threads), so each one only triggers a re-read of the gate on the main
    /// actor; reports from a session that is over (`sessionGeneration` moved on) are ignored.
    private func makeMicEchoGate() -> MicEchoGate {
        let generation = sessionGeneration
        return MicEchoGate(mode: listeningMode, tail: echoGateTail, clock: echoGateClock) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncMicPausedFromGate(generation: generation)
            }
        }
    }

    /// Sets `isMicPaused` from the gate's authoritative state (never from a report's value), so a
    /// late "paused" report after the mic reopened cannot leave it stuck paused: the gate's
    /// `onPausedChange` value is advisory, `MicEchoGate.isMicPaused` is authoritative (REQ-H-06).
    func syncMicPausedFromGate(generation: UInt64) {
        guard sessionGeneration == generation else { return }
        isMicPaused = micEchoGate?.isMicPaused ?? false
    }

    /// The incoming side went away: the mic must not stay muted (REQ-H-06).
    func reopenMicEchoGate() {
        micEchoGate?.reset()
        isMicPaused = false
    }

    private func releaseMicEchoGate() {
        reopenMicEchoGate()
        micEchoGate = nil
    }

    private func updateConversationState() {
        let state = ConversationState.derive(micPaused: isMicPaused, outgoingSpeaking: isOutgoingSpeaking,
                                             incomingSpeaking: isIncomingSpeaking)
        if state != conversationState { conversationState = state }
    }
}
