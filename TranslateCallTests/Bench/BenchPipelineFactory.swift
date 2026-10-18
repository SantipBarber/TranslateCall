import AVFoundation
import FluidAudio
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

    static let all: [BenchRunLine] = [.outgoingEsESToEn, .outgoingEs419ToEn, .outgoingEnToEs, .incomingEnToEs]
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

/// Whether a model is already on disk. A bench run never downloads a model (NFR-BH-03): it asks
/// first and fails with "download it in the app first (M5)" instead of triggering a load.
struct BenchModelPresence: Sendable {
    var silero: @Sendable () async -> Bool
    var parakeet: @Sendable () async -> Bool
    var whisper: @Sendable () async -> Bool
    var kokoro: @Sendable () async -> Bool
    var voiceClone: @Sendable () async -> Bool

    static let onDisk = BenchModelPresence(
        silero: {
            let folder = AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent()
                .appendingPathComponent("silero-vad-coreml")
            return ModelNames.VAD.requiredModels.allSatisfy {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
        },
        parakeet: {
            let version = await MainActor.run { ParakeetConfiguration.default.modelVersion }
            return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
        },
        whisper: {
            let folder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
                .appendingPathComponent(WhisperConfiguration.default.modelSize.whisperKitName)
            return FileManager.default.fileExists(atPath: folder.path)
        },
        kokoro: {
            let folder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/fluidaudio/Models/kokoro")
            // Every variant, not any: loading the default config must never fall back to a download (NFR-BH-03).
            return ModelNames.TTS.Variant.allCases.allSatisfy {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path)
            }
        },
        voiceClone: { QwenCloneModelManager.shared.isModelCached() }
    )
}

struct BenchOptions: Sendable {
    var presence = BenchModelPresence.onDisk
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

/// The primary synthesizer engine each direction's TTS service was actually built with, so `start`
/// can refuse a run that silently measures another voice than the one asked for.
final class BuiltEngines: Sendable {
    private let engines = Mutex<[TraceDirection: TTSEngine]>([:])

    subscript(direction: TraceDirection) -> TTSEngine? { engines.withLock { $0[direction] } }

    func record(_ engine: TTSEngine, for direction: TraceDirection) {
        engines.withLock { $0[direction] = engine }
    }
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
    let builtEngines: BuiltEngines
    private let otherTracer: PipelineTracer
    private let suiteName: String

    init(line: BenchRunLine, coordinator: AudioCoordinator, mic: BenchAudioSource, system: BenchSystemAudioCapture,
         vads: VADProvider, stt: STTEngineSelector, tts: TTSEngineSelector, host: TranslationHostWindow,
         sink: CollectingTraceSink, tracer: PipelineTracer, otherTracer: PipelineTracer,
         output: BenchOutput, origin: ContinuousClock.Instant, builtEngines: BuiltEngines, suiteName: String) {
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
        self.builtEngines = builtEngines
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

    static func make(_ line: BenchRunLine, options: BenchOptions, vadProvider: VADProvider = VADProvider(preferred: { .silero })) async throws
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
        let stt = STTEngineSelector()
        let tts = TTSEngineSelector(defaults: defaults)
        do {
            try await configureEngines(stt: stt, tts: tts, line: line, options: options)
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
        let built = BuiltEngines()
        let voices = ttsEngines(options)
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
                try traced(tts, outTracer, voice: voices.outgoing, output: output, built: built) {
                    try tts.makeOutgoingService(for: locale, deviceID: device)
                }
            },
            incomingTTSFactory: { locale, device in
                try traced(tts, inTracer, voice: voices.incoming, output: output, built: built) {
                    try tts.makeIncomingService(for: locale, deviceID: device)
                }
            },
            languagePairManager: pair,
            isTranslationPairInstalled: AppleTranslationService.isInstalled
        )
        return BenchSession(
            line: line, coordinator: coordinator, mic: mic, system: system, vads: vads, stt: stt, tts: tts,
            host: host, sink: sink, tracer: line.incoming ? inTracer : outTracer,
            otherTracer: line.incoming ? outTracer : inTracer, output: output, origin: .now, builtEngines: built, suiteName: suiteName
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
        try requireSTT(session, options: options)
        try requireTTS(session, options: options)
    }

    // MARK: - Checks

    /// The STT engine a profile means on `line` (REQ-BH-31). Parakeet is English and outgoing only,
    /// so Best on any other line is Apple Speech.
    static func sttEngine(for line: BenchRunLine, options: BenchOptions) -> STTEngine {
        if let override = options.overrideSTT { return override }
        let parakeetFits = options.profile == .best && !line.incoming
            && Locale(identifier: line.userLanguage).isEnglish
        return parakeetFits ? .parakeet : .appleSpeech
    }

    /// The language the measured direction recognizes: the user's outgoing, the other side's incoming.
    static func recognizedLocale(_ line: BenchRunLine) -> Locale {
        Locale(identifier: line.incoming ? line.otherLanguage : line.userLanguage)
    }

    /// The selector runs the engine this line asked for on the measured direction, not a fallback.
    private static func requireSTT(_ session: BenchSession, options: BenchOptions) throws {
        let line = session.line
        let engine = sttEngine(for: line, options: options)
        let locale = recognizedLocale(line)
        let direction: TranscriptDirection = line.incoming ? .incoming : .outgoing
        // The resolver returns the pinned engine only when it serves this locale and direction and is on disk.
        try requirePrerequisite(session.stt.resolvedEngine(for: locale, direction: direction) == engine,
                                "STT engine \(engine.rawValue) usable on \(line) (\(locale.identifier)) without falling back to Apple Speech")
    }

    /// Each direction's TTS was built with the engine asked for (no silent AVSpeech).
    private static func requireTTS(_ session: BenchSession, options: BenchOptions) throws {
        let (outgoing, incoming) = ttsEngines(options)
        let clone = outgoing == .voiceClone
        // The incoming TTS exists only on an incoming line; the outgoing one always does.
        var expectations = [(TraceDirection.outgoing, outgoing)]
        if session.line.incoming { expectations.append((.incoming, incoming)) }
        for (direction, expected) in expectations {
            let built = session.builtEngines[direction]
            try requirePrerequisite(built == expected,
                                    "\(direction) TTS built with \(expected.rawValue), got \(built?.rawValue ?? "none")")
        }
        if clone {
            let tts = session.tts
            let active = tts.voiceCloningEnabled && tts.voiceCloneAvailable && tts.activeVoiceProfileId != nil
            try requirePrerequisite(active, "voice cloning active (profile, model and toggle)")
        }
    }

    /// The voice each direction's TTS is built with (REQ-BH-32…34): Edge on both sides with `edge`,
    /// else the override or Best's voice clone outgoing and the system voice incoming.
    static func ttsEngines(_ options: BenchOptions) -> (outgoing: TTSEngine, incoming: TTSEngine) {
        if options.edge { return (.edgeTTS, .edgeTTS) }
        let clone = options.profile == .best && options.overrideTTS == nil
        return (options.overrideTTS ?? (clone ? .voiceClone : .avSpeech), .avSpeech)
    }

    // MARK: - Engines

    private static func configureEngines(
        stt: STTEngineSelector, tts: TTSEngineSelector, line: BenchRunLine, options: BenchOptions
    ) async throws {
        // The VAD loads at start and would download Silero if it were missing.
        try requirePrerequisite(await options.presence.silero(), "Silero VAD model — download it in the app first (M5)")
        let engine = sttEngine(for: line, options: options)
        // Never before the model is known to be on disk: selecting Parakeet or Whisper would start a download.
        if engine == .parakeet {
            try requirePrerequisite(await options.presence.parakeet(),
                                    "Parakeet model — download it in the app first (M5)")
        } else if engine == .whisper {
            try requirePrerequisite(await options.presence.whisper(),
                                    "Whisper model — download it in the app first (M5)")
        }
        // Pinned through the pair's choice: the resolver keeps it wherever it is usable (M9 UI settings P5).
        stt.pairChoice = { PairModelChoice(stt: engine) }
        // Load-only paths: they throw instead of downloading (D-6).
        if engine == .parakeet {
            let loaded = (try? await ParakeetModelManager.shared.loadCached()) != nil
            try requirePrerequisite(loaded, "Parakeet model (download it in the app: STT → Parakeet)")
        } else if engine == .whisper {
            let loaded = (try? await WhisperModelManager.shared.loadCached()) != nil
            try requirePrerequisite(loaded, "Whisper model (download it in the app: STT → Whisper)")
        }

        // The voice is pinned per direction when each TTS service is built (`traced`).
        if options.edge {
            // Explicit Edge, as the bench always ran it: cloud allowed, consented and not marked
            // unavailable, whatever the bundled catalog (S-3) and this Mac's consent say.
            var catalog = tts.catalog
            catalog.engines[TTSEngine.edgeTTS.rawValue] = EngineInfo(unavailable: false)
            tts.catalog = catalog
            tts.cloudAllowed = { true }
            tts.edgeConsentGiven = { true }
        } else if options.overrideTTS == .kokoro {
            try requirePrerequisite(await options.presence.kokoro(),
                                    "Kokoro model — download it in the app first (M5)")
            // Kokoro has no load-only path (P20); its presence check above keeps this from downloading.
            _ = try await KokoroModelManager.shared.ensureReady()
            await tts.refreshModelAvailability()
            try requirePrerequisite(tts.kokoroAvailable, "Kokoro model (download it in the app: TTS → Kokoro)")
        } else if options.overrideTTS == nil, options.profile == .best {
            let raw = UserDefaults.standard.string(forKey: activeProfileKey)
            try requirePrerequisite(raw.flatMap(UUID.init(uuidString:)) != nil, "an active voice-clone profile (M5)")
            guard let raw, let id = UUID(uuidString: raw) else { return }
            try requirePrerequisite(await options.presence.voiceClone(),
                                    "Qwen3-TTS voice-clone model — download it in the app first (M5)")
            tts.activeVoiceProfileId = id
            tts.setProfileStore(VoiceProfileStore())
            tts.voiceCloningEnabled = true   // the selector's own (throwaway) suite
            let loaded = (try? await QwenCloneModelManager.shared.loadCached()) != nil
            try requirePrerequisite(loaded, "Qwen3-TTS voice-clone model — download it in the app first (M5)")
            await tts.refreshModelAvailability()
            try requirePrerequisite(tts.voiceCloneAvailable, "Qwen3-TTS voice-clone model (enable voice cloning in the app)")
        }
    }

    /// Builds one direction's TTS service with every synthesizer and the output device traced, then
    /// puts the selector's factories back (P4). The service itself is traced too.
    private static func traced(
        _ tts: TTSEngineSelector, _ tracer: PipelineTracer, voice: TTSEngine, output: BenchOutput,
        built: BuiltEngines, build: () throws -> TTSPlaybackService
    ) throws -> any SynthesisService {
        let (savedOutput, savedAV, savedKokoro, savedClone, savedEdge, savedChoice) =
            (tts.outputFactory, tts.avSpeechFactory, tts.kokoroFactory, tts.voiceCloneFactory, tts.edgeFactory,
             tts.pairChoice)
        defer {
            (tts.outputFactory, tts.avSpeechFactory, tts.kokoroFactory, tts.voiceCloneFactory, tts.edgeFactory,
             tts.pairChoice) = (savedOutput, savedAV, savedKokoro, savedClone, savedEdge, savedChoice)
        }
        // This direction's voice, pinned through the pair's choice (the voice clone wins outgoing when ready;
        // `PairModelChoice` drops `.voiceClone`, so Best pins nothing there).
        tts.pairChoice = { PairModelChoice(voice: voice) }
        // The first synthesizer a build asks for is the primary (the fallback is built after it).
        let primary = Mutex<TTSEngine?>(nil)
        func wrap(_ synthesizer: any UtteranceSynthesizer) -> any UtteranceSynthesizer {
            primary.withLock { $0 = $0 ?? synthesizer.engine }
            return tracer.tracing(synthesizer)
        }
        tts.outputFactory = { _ in tracer.tracing(output) }
        tts.avSpeechFactory = { wrap(savedAV()) }
        tts.kokoroFactory = { wrap(savedKokoro($0)) }
        tts.voiceCloneFactory = { id, store in wrap(savedClone(id, store)) }
        tts.edgeFactory = { wrap(savedEdge()) }
        let service = TracingSynthesisService(wrapping: try build(), tracer: tracer)
        if let engine = primary.withLock({ $0 }) { built.record(engine, for: tracer.direction) }
        return service
    }
}
