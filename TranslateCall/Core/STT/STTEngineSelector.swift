import Foundation
import OSLog

private let selectorLogger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "STTEngineSelector"
)

// MARK: - STTEngineSelector

/// Builds the `SpeechRecognizerService` of each pipeline from one resolution (M9 UI settings REQ-ST-02,
/// P5): the pair's choice where it is usable, else the catalog's first engine on disk, else Apple Speech.
@MainActor
final class STTEngineSelector {

    /// Resolution inputs; injectable for tests.
    var catalog: ModelCatalog = .bundled
    var cacheProbe: ModelCacheProbe = .live
    /// The current pair's stored choice; `ModelServices` wires it (P1). Default: no choice.
    var pairChoice: () -> PairModelChoice = { PairModelChoice() }

    /// Creates an `AppleSpeechService` for the given locale.
    let appleSpeechFactory: (Locale) -> any SpeechRecognizerService
    /// Creates a `ParakeetSpeechService` for the given locale.
    let parakeetFactory: (Locale) -> any SpeechRecognizerService
    /// Creates a `WhisperSpeechService` for the given locale.
    let whisperFactory: (Locale) -> any SpeechRecognizerService

    init(
        appleSpeechFactory: @escaping (Locale) -> any SpeechRecognizerService = { AppleSpeechService(locale: $0) },
        parakeetFactory: @escaping (Locale) -> any SpeechRecognizerService = { ParakeetSpeechService(locale: $0) },
        whisperFactory: @escaping (Locale) -> any SpeechRecognizerService = { WhisperSpeechService(locale: $0) }
    ) {
        self.appleSpeechFactory = appleSpeechFactory
        self.parakeetFactory = parakeetFactory
        self.whisperFactory = whisperFactory
    }

    /// What is on disk now (D-6: "ready" = downloaded).
    var availability: ModelAvailability {
        ModelAvailability(parakeetCached: cacheProbe.parakeet(), whisperCached: cacheProbe.whisper())
    }

    /// The engine the next session uses for `locale` in `direction`; also what the preloader loads.
    func resolvedEngine(for locale: Locale, direction: TranscriptDirection) -> STTEngine {
        ModelChoice.stt(for: locale, direction: direction, pairChoice: pairChoice().stt,
                        catalog: catalog, availability: availability)
    }

    // MARK: - Service factories

    /// The outgoing pipeline's recognizer (my speech).
    func makeOutgoingService(for locale: Locale) -> any SpeechRecognizerService {
        makeService(for: locale, direction: .outgoing)
    }

    /// The incoming pipeline's recognizer (their speech).
    func makeIncomingService(for locale: Locale) -> any SpeechRecognizerService {
        makeService(for: locale, direction: .incoming)
    }

    private func makeService(for locale: Locale, direction: TranscriptDirection) -> any SpeechRecognizerService {
        let engine = resolvedEngine(for: locale, direction: direction)
        selectorLogger.debug("\(String(describing: direction)): \(engine.rawValue) for \(locale.identifier)")
        switch engine {
        case .parakeet: return parakeetFactory(locale)
        case .whisper: return whisperFactory(locale)
        case .appleSpeech: return appleSpeechFactory(locale)
        }
    }
}
