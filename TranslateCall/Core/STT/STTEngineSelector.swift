import Combine
import Foundation
import OSLog

private let selectorLogger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "STTEngineSelector"
)

// MARK: - STTEngineSelector

/// Manages which `SpeechRecognizerService` is used for outgoing and incoming pipelines.
///
/// Responsibilities:
/// - Persist and restore the user's preferred `STTEngine` via `UserDefaults`.
/// - Observe `ParakeetModelManager` state to track model availability.
/// - Implement engine-selection logic: Parakeet for English outgoing, Apple Speech otherwise.
/// - Expose `@Published` state so SwiftUI views can react to preference and availability changes.
@MainActor
final class STTEngineSelector: ObservableObject {

    // MARK: - Published state

    /// The engine the user has selected. Persisted in `UserDefaults`.
    @Published private(set) var preferredEngine: STTEngine

    /// `true` when the Parakeet CoreML model is loaded and ready.
    ///
    /// Setter is internal (not private) to allow test-only mutation via an extension
    /// in the test target. Reads and writes only happen on @MainActor.
    @Published var parakeetAvailable: Bool = false

    /// `true` while the Parakeet model is being downloaded or loaded from cache.
    @Published private(set) var isDownloading: Bool = false

    /// The source locale most recently passed to `makeOutgoingService(for:)`.
    ///
    /// Drives the `usingFallback` computed property without requiring a dedicated
    /// `@Published` flag that could get out of sync.
    @Published private(set) var currentSourceLocale: Locale = Locale(identifier: "en-US")

    /// `true` when Parakeet is preferred but Apple Speech is being used instead
    /// (either because the source locale is not English, or the model is not yet available).
    var usingFallback: Bool {
        preferredEngine == .parakeet && (!currentSourceLocale.isEnglish || !parakeetAvailable)
    }

    // MARK: - Private

    private let defaults: UserDefaults
    private static let defaultsKey = "tlk.stt.engine"

    /// Creates an `AppleSpeechService` for the given locale.
    private let appleSpeechFactory: (Locale) -> any SpeechRecognizerService
    /// Creates a `ParakeetSpeechService` for the given locale.
    private let parakeetFactory: (Locale) -> any SpeechRecognizerService

    /// Observes `ParakeetModelManager.stateStream` to update `parakeetAvailable`.
    private var stateObservationTask: Task<Void, Never>?

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        appleSpeechFactory: @escaping (Locale) -> any SpeechRecognizerService = { AppleSpeechService(locale: $0) },
        parakeetFactory: @escaping (Locale) -> any SpeechRecognizerService = { ParakeetSpeechService(locale: $0) }
    ) {
        self.defaults = defaults
        self.appleSpeechFactory = appleSpeechFactory
        self.parakeetFactory = parakeetFactory

        let raw = defaults.string(forKey: STTEngineSelector.defaultsKey) ?? ""
        self.preferredEngine = STTEngine(rawValue: raw) ?? .appleSpeech

        // Start observing model state so the UI can show download progress
        // and so makeOutgoingService knows when Parakeet is ready.
        let stream = ParakeetModelManager.shared.stateStream
        stateObservationTask = Task { @MainActor [weak self] in
            for await state in stream {
                guard let self else { return }
                switch state {
                case .ready:
                    self.parakeetAvailable = true
                    self.isDownloading = false
                    selectorLogger.info("Parakeet model ready — engine selector updated")
                case .loading:
                    self.parakeetAvailable = false
                    self.isDownloading = true
                case .idle, .failed:
                    self.parakeetAvailable = false
                    self.isDownloading = false
                }
            }
        }
    }

    deinit {
        stateObservationTask?.cancel()
    }

    // MARK: - Service factories

    /// Returns the appropriate `SpeechRecognizerService` for the outgoing pipeline.
    ///
    /// Uses Parakeet when:
    /// - `preferredEngine == .parakeet`
    /// - AND `parakeetAvailable == true`
    /// - AND `locale` is an English locale
    ///
    /// Otherwise falls back to Apple Speech. Updates `currentSourceLocale` as a side effect.
    func makeOutgoingService(for locale: Locale) -> any SpeechRecognizerService {
        currentSourceLocale = locale
        if preferredEngine == .parakeet, parakeetAvailable, locale.isEnglish {
            selectorLogger.debug("Outgoing: using Parakeet for \(locale.identifier)")
            return parakeetFactory(locale)
        }
        if preferredEngine == .parakeet {
            let avail = self.parakeetAvailable
            // swiftlint:disable:next line_length
            selectorLogger.debug("Parakeet unavailable for outgoing (locale=\(locale.identifier), avail=\(avail)); using Apple Speech")
        }
        return appleSpeechFactory(locale)
    }

    /// Returns Apple Speech for the incoming pipeline.
    ///
    /// The remote speaker's language is the target language (typically non-English),
    /// and speaker-matching is irrelevant for the incoming direction.
    func makeIncomingService(for locale: Locale) -> any SpeechRecognizerService {
        appleSpeechFactory(locale)
    }

    // MARK: - Preference management

    /// Updates the preferred engine and persists the choice.
    ///
    /// If Parakeet is selected and the model is not yet available, triggers a background load.
    func setPreferredEngine(_ engine: STTEngine) {
        preferredEngine = engine
        defaults.set(engine.rawValue, forKey: STTEngineSelector.defaultsKey)
        selectorLogger.info("STT engine preference set to: \(engine.rawValue)")

        if engine == .parakeet, !parakeetAvailable {
            Task {
                do {
                    _ = try await ParakeetModelManager.shared.ensureReady()
                } catch {
                    selectorLogger.error(
                        "Parakeet model load failed after preference change: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Triggers a model re-download and clears the current preference state.
    ///
    /// Called from the Settings UI when the user requests a fresh download.
    func redownloadParakeetModel() {
        Task {
            do {
                try await ParakeetModelManager.shared.redownload()
            } catch {
                selectorLogger.error("Parakeet re-download failed: \(error.localizedDescription)")
            }
        }
    }

    /// Releases the Parakeet model from memory (e.g., user switches to Apple Speech).
    func unloadParakeetModel() {
        Task {
            await ParakeetModelManager.shared.unload()
        }
    }
}
