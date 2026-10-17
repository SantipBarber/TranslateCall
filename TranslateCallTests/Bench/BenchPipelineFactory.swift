import AVFoundation
import Foundation
import Synchronization
@testable import TranslateCall

/// Which language the bench user speaks and which side the clips play on (M9 REQ-BH-23).
struct BenchRunLine: Sendable, CustomStringConvertible {
    /// "My language" (LanguagePairManager source), as the app stores it.
    let userLanguage: String
    /// "Their language" (LanguagePairManager target).
    let otherLanguage: String
    /// Clips play on the call-app side (incoming) instead of the mic (outgoing).
    let incoming: Bool
    /// Manifest variant of the clips (`es-ES`, `es-419`, `en`).
    let variant: String

    var direction: TraceDirection { incoming ? .incoming : .outgoing }

    var description: String {
        incoming ? "incoming \(variant)>\(userLanguage)" : "outgoing \(variant)>\(otherLanguage)"
    }

    static let outgoingEsESToEn = BenchRunLine(userLanguage: "es-ES", otherLanguage: "en", incoming: false, variant: "es-ES")
    static let outgoingEs419ToEn = BenchRunLine(userLanguage: "es-419", otherLanguage: "en", incoming: false, variant: "es-419")
    static let outgoingEnToEs = BenchRunLine(userLanguage: "en", otherLanguage: "es", incoming: false, variant: "en")
    static let incomingEnToEs = BenchRunLine(userLanguage: "es", otherLanguage: "en", incoming: true, variant: "en")
}

struct BenchSetupError: Error, CustomStringConvertible {
    let description: String
}

/// The engine set a bench session runs on (M9 REQ-BH-30…34).
enum BenchProfile: String, CaseIterable, Sendable {
    /// Apple Speech + the default TTS (AVSpeech).
    case basic
    /// Parakeet STT + the user's active voice-clone profile.
    case best
}

struct BenchOptions: Sendable {
    var profile = BenchProfile.basic
    /// Edge TTS instead of the profile's TTS.
    var edge = false
    var overrideSTT: STTEngine?
    var overrideTTS: TTSEngine?
}

/// The fake output device: records when each buffer reached it (REQ-BH-20). Nothing is played.
final class BenchOutput: AudioOutputting, Sendable {
    private let inner = FakeOutput(autoComplete: true)
    private let scheduled = Mutex<[(ContinuousClock.Instant, AVAudioPCMBuffer)]>([])

    var scheduleTimes: [ContinuousClock.Instant] { scheduled.withLock { $0.map(\.0) } }

    /// Takes every buffer scheduled so far (and forgets it).
    func drain() -> [(ContinuousClock.Instant, AVAudioPCMBuffer)] {
        scheduled.withLock { current in
            defer { current.removeAll() }
            return current
        }
    }

    func schedule(_ buffer: AVAudioPCMBuffer) throws -> PlaybackHandle {
        let handle = try inner.schedule(buffer)
        scheduled.withLock { $0.append((.now, buffer)) }
        return handle
    }

    func stop() { inner.stop() }
    func shutdown() { inner.shutdown() }
}

/// A production `AudioCoordinator` built the way `AppContainer` builds it, with clip-fed mic and
/// system capture, traced stages, a fake output and throwaway `UserDefaults` (M9 design §3.3).
@MainActor
final class BenchSession {
    let line: BenchRunLine
    let coordinator: AudioCoordinator
    let mic: BenchAudioSource
    let system: BenchSystemAudioCapture
    let vads: VADProvider
    let stt: STTEngineSelector
    let tts: TTSEngineSelector
    let host: TranslationHostWindow
    let sink: CollectingTraceSink
    /// The measured direction's tracer (`line.direction`).
    let tracer: PipelineTracer
    let output: BenchOutput
    let origin: ContinuousClock.Instant
    private let otherTracer: PipelineTracer
    private let suiteName: String

    init(line: BenchRunLine, coordinator: AudioCoordinator, mic: BenchAudioSource, system: BenchSystemAudioCapture,
         vads: VADProvider, stt: STTEngineSelector, tts: TTSEngineSelector, host: TranslationHostWindow,
         sink: CollectingTraceSink, tracer: PipelineTracer, otherTracer: PipelineTracer,
         output: BenchOutput, origin: ContinuousClock.Instant, suiteName: String) {
        self.line = line
        self.coordinator = coordinator
        self.mic = mic
        self.system = system
        self.vads = vads
        self.stt = stt
        self.tts = tts
        self.host = host
        self.sink = sink
        self.tracer = tracer
        self.otherTracer = otherTracer
        self.output = output
        self.origin = origin
        self.suiteName = suiteName
    }

    /// The player that feeds the measured direction. Play only this one: the other direction stays silent.
    var player: BenchClipPlayer { line.incoming ? system.player : mic.player }

    /// Stops the session and releases everything it owns.
    ///
    /// Do not rely on this to finish an utterance: the tracing decorators drop a segment the VAD
    /// flushes at `deactivate`, so anything still open here is recorded as `dropped("session-stop")`.
    /// The runner drains first (an idle wait on `tracer.openSeqs`), then calls this.
    func tearDown() async {
        await coordinator.stop()
        tracer.closeOpen(reason: "session-stop")
        otherTracer.closeOpen(reason: "session-stop")
        host.close()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
enum BenchPipelineFactory {
    /// The user's real voice-clone choice: read, never written (NFR-BH-03).
    private static let activeProfileKey = "tlk.voiceCloning.activeProfileId"

    static func make(_ line: BenchRunLine, options: BenchOptions, vadProvider: VADProvider = VADProvider()) async throws
        -> BenchSession {
        let suiteName = "bench-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw BenchSetupError(description: "UserDefaults suite \(suiteName)")
        }
        // LanguagePairManager's keys (private there): the pair this session translates.
        defaults.set(line.userLanguage, forKey: "tlk.source.language")
        defaults.set(line.otherLanguage, forKey: "tlk.target.language")
        let pair = LanguagePairManager(defaults: defaults, languageLoader: { [] })
        let (outBridge, inBridge) = (TranslationBridgeModel(), TranslationBridgeModel())
        let host = TranslationHostWindow(outgoing: outBridge, incoming: inBridge)
        host.show()
        let translation = TranslationEngineSelector(outgoingBridge: outBridge, incomingBridge: inBridge, defaults: defaults)
        let stt = STTEngineSelector(defaults: defaults)
        let tts = TTSEngineSelector(defaults: defaults)
        do {
            try await configureEngines(stt: stt, tts: tts, options: options)
        } catch {
            host.close()
            defaults.removePersistentDomain(forName: suiteName)
            throw error
        }
        let settings = ConversationSettings(defaults: defaults)
        let vadConfig = settings.vadConfiguration
        let sink = CollectingTraceSink()
        let trailing = Duration.seconds(vadConfig.minSilenceDuration)
        let outTracer = PipelineTracer(direction: .outgoing, sink: sink, trailingSilence: trailing)
        let inTracer = PipelineTracer(direction: .incoming, sink: sink, trailingSilence: trailing)
        let output = BenchOutput()
        let vads = vadProvider
        let mic = BenchAudioSource()
        let system = BenchSystemAudioCapture()
        let coordinator = AudioCoordinator(
            audioCapture: mic,
            systemCapture: system,
            outgoingVADFactory: outTracer.tracingVAD { await vads.makeVAD(config: vadConfig) },
            incomingVADFactory: inTracer.tracingVAD { await vads.makeVAD(config: vadConfig) },
            outgoingSTTFactory: outTracer.tracingSTT { stt.makeOutgoingService(for: $0) },
            incomingSTTFactory: inTracer.tracingSTT { stt.makeIncomingService(for: $0) },
            outgoingTranslationService: outTracer.tracing(translation.makeOutgoingService()),
            incomingTranslationService: inTracer.tracing(translation.makeIncomingService()),
            outgoingTTSFactory: { locale, device in
                try traced(tts, outTracer, output: output) { try tts.makeOutgoingService(for: locale, deviceID: device) }
            },
            incomingTTSFactory: { locale, device in
                try traced(tts, inTracer, output: output) { try tts.makeIncomingService(for: locale, deviceID: device) }
            },
            languagePairManager: pair,
            isTranslationPairInstalled: AppleTranslationService.isInstalled
        )
        return BenchSession(
            line: line, coordinator: coordinator, mic: mic, system: system, vads: vads, stt: stt, tts: tts,
            host: host, sink: sink, tracer: line.incoming ? inTracer : outTracer,
            otherTracer: line.incoming ? outTracer : inTracer, output: output, origin: .now, suiteName: suiteName
        )
    }

    /// Starts the session and checks it is the one that was asked for (REQ-BH-24/34): no silent
    /// fallback to Energy VAD, to Apple Speech or to a stock voice.
    static func start(_ session: BenchSession, options: BenchOptions) async throws {
        let line = session.line
        await session.coordinator.start(captureTarget: line.incoming ? .app(bundleID: "bench") : nil)
        let alert = session.coordinator.errorAlert
        try requirePrerequisite(session.coordinator.isOutgoingActive,
                                "bench session started (\(alert?.title ?? "no alert"): \(alert?.message ?? "-"))")
        if line.incoming {
            try requirePrerequisite(session.coordinator.incomingStatus == .active,
                                    "incoming pipeline active (status \(session.coordinator.incomingStatus))")
        }
        try requirePrerequisite(session.vads.activeEngine == .silero, "Silero VAD")
        try requirePrerequisite(!session.stt.usingFallback,
                                "the requested STT engine (\(session.stt.preferredEngine.rawValue)) without falling back to Apple Speech")
        if options.profile == .best, !options.edge, options.overrideTTS == nil, !line.incoming {
            try requirePrerequisite(session.tts.voiceCloningActive, "voice cloning active (profile, model and toggle)")
        }
    }

    // MARK: - Engines

    private static func configureEngines(stt: STTEngineSelector, tts: TTSEngineSelector, options: BenchOptions) async throws {
        let best = options.profile == .best
        let engine = options.overrideSTT ?? (best ? .parakeet : .appleSpeech)
        stt.setPreferredEngine(engine)
        if engine == .parakeet {
            let ready = await waitUntil(timeout: .seconds(120)) { stt.parakeetAvailable }
            try requirePrerequisite(ready, "Parakeet model (download it in the app: STT → Parakeet)")
        } else if engine == .whisper {
            let ready = await waitUntil(timeout: .seconds(300)) { stt.whisperAvailable }
            try requirePrerequisite(ready, "Whisper model (download it in the app: STT → Whisper)")
        }

        if options.edge {
            tts.setPreferredEngine(.edgeTTS)
        } else if let override = options.overrideTTS {
            tts.setPreferredEngine(override)
        } else if best {
            let raw = UserDefaults.standard.string(forKey: activeProfileKey)
            try requirePrerequisite(raw.flatMap(UUID.init(uuidString:)) != nil, "an active voice-clone profile (M5)")
            guard let raw, let id = UUID(uuidString: raw) else { return }
            tts.activeVoiceProfileId = id
            tts.setProfileStore(VoiceProfileStore())
            tts.voiceCloningEnabled = true   // the selector's own (throwaway) suite
            try await QwenCloneModelManager.shared.ensureReady()
            let ready = await waitUntil(timeout: .seconds(120)) { tts.voiceCloneAvailable }
            try requirePrerequisite(ready, "Qwen3-TTS voice-clone model (enable voice cloning in the app)")
        }
    }

    /// Builds one direction's TTS service with every synthesizer and the output device traced, then
    /// puts the selector's factories back (P4). The service itself is traced too.
    private static func traced(
        _ tts: TTSEngineSelector, _ tracer: PipelineTracer, output: BenchOutput,
        build: () throws -> TTSPlaybackService
    ) throws -> any SynthesisService {
        let (savedOutput, savedAV, savedKokoro, savedClone, savedEdge) =
            (tts.outputFactory, tts.avSpeechFactory, tts.kokoroFactory, tts.voiceCloneFactory, tts.edgeFactory)
        defer {
            (tts.outputFactory, tts.avSpeechFactory, tts.kokoroFactory, tts.voiceCloneFactory, tts.edgeFactory) =
                (savedOutput, savedAV, savedKokoro, savedClone, savedEdge)
        }
        tts.outputFactory = { _ in tracer.tracing(output) }
        tts.avSpeechFactory = { tracer.tracing(savedAV()) }
        tts.kokoroFactory = { tracer.tracing(savedKokoro($0)) }
        tts.voiceCloneFactory = { id, store in tracer.tracing(savedClone(id, store)) }
        tts.edgeFactory = { tracer.tracing(savedEdge()) }
        return TracingSynthesisService(wrapping: try build(), tracer: tracer)
    }
}
