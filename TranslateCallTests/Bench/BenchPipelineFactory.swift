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

/// Records when each buffer reached the (fake) output device.
final class ScheduleLog: AudioOutputting, Sendable {
    private let inner = FakeOutput(autoComplete: true)
    private let times = Mutex<[ContinuousClock.Instant]>([])

    var scheduleTimes: [ContinuousClock.Instant] { times.withLock { $0 } }

    func schedule(_ buffer: AVAudioPCMBuffer) throws -> PlaybackHandle {
        let handle = try inner.schedule(buffer)
        times.withLock { $0.append(.now) }
        return handle
    }

    func stop() { inner.stop() }
    func shutdown() { inner.shutdown() }
}

/// A production `AudioCoordinator` built the way `AppContainer` builds it, with a clip-fed mic,
/// a fake output and throwaway `UserDefaults` (M9 design §3.3). Gate version: Basic profile only.
@MainActor
final class BenchSession {
    let coordinator: AudioCoordinator
    let mic: BenchAudioSource
    let vads: VADProvider
    let host: TranslationHostWindow
    private let suiteName: String

    init(coordinator: AudioCoordinator, mic: BenchAudioSource, vads: VADProvider,
         host: TranslationHostWindow, suiteName: String) {
        self.coordinator = coordinator
        self.mic = mic
        self.vads = vads
        self.host = host
        self.suiteName = suiteName
    }

    func tearDown() async {
        await coordinator.stop()
        host.close()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
enum BenchPipelineFactory {
    static func makeBasic(_ line: BenchRunLine, output: any AudioOutputting) throws -> BenchSession {
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
        tts.outputFactory = { _ in output }
        let vadConfig = ConversationSettings(defaults: defaults).vadConfiguration
        // No preload: in .idle, makeVAD loads Silero synchronously.
        let vads = VADProvider()
        let mic = BenchAudioSource()
        let coordinator = AudioCoordinator(
            audioCapture: mic,
            systemCapture: MockSystemAudioCapture(),
            outgoingVADFactory: { await vads.makeVAD(config: vadConfig) },
            incomingVADFactory: { await vads.makeVAD(config: vadConfig) },
            outgoingSTTFactory: { stt.makeOutgoingService(for: $0) },
            incomingSTTFactory: { stt.makeIncomingService(for: $0) },
            outgoingTranslationService: translation.makeOutgoingService(),
            incomingTranslationService: translation.makeIncomingService(),
            outgoingTTSFactory: { try tts.makeOutgoingService(for: $0, deviceID: $1) },
            incomingTTSFactory: { try tts.makeIncomingService(for: $0, deviceID: $1) },
            languagePairManager: pair,
            isTranslationPairInstalled: AppleTranslationService.isInstalled
        )
        return BenchSession(coordinator: coordinator, mic: mic, vads: vads, host: host, suiteName: suiteName)
    }
}
