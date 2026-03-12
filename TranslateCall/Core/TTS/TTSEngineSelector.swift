import Combine
import CoreAudio
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSEngineSelector")

// MARK: - TTSEngineSelector

/// Manages TTS engine selection, model availability, and service factory closures.
///
/// Mirrors `STTEngineSelector` from F6.1.
/// `makeOutgoingService` routes to Kokoro for English when available;
/// `makeIncomingService` always returns AVSpeech (lower overhead for remote voice).
@MainActor
final class TTSEngineSelector: ObservableObject {

    // MARK: - Published state

    @Published private(set) var preferredEngine: TTSEngine = .avSpeech
    @Published private(set) var kokoroAvailable: Bool = false
    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var currentTargetLocale: Locale = Locale.current

    var usingFallback: Bool {
        preferredEngine == .kokoro && (!kokoroAvailable || !currentTargetLocale.isEnglish)
    }

    // MARK: - UserDefaults

    private let defaults: UserDefaults
    private static let engineKey = "tlk.tts.engine"

    // MARK: - Factories (var — injectable for tests)

    var avSpeechFactory: (AudioDeviceID?) throws -> any SynthesisService = { deviceID in
        try AVSpeechService(outputDeviceID: deviceID)
    }
    var kokoroFactory: (AudioDeviceID?, KokoroConfiguration) throws -> any SynthesisService = { deviceID, config in
        try KokoroSpeechService(outputDeviceID: deviceID, configuration: config)
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.engineKey),
           let engine = TTSEngine(rawValue: raw) {
            preferredEngine = engine
        }
        observeModelManager()
    }

    // MARK: - Public API

    func setPreferredEngine(_ engine: TTSEngine) {
        preferredEngine = engine
        defaults.set(engine.rawValue, forKey: Self.engineKey)
    }

    /// Creates the outgoing TTS service for `locale` routed to `deviceID`.
    /// Returns Kokoro when preferred, available, and locale is English; otherwise AVSpeech.
    func makeOutgoingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> any SynthesisService {
        currentTargetLocale = locale
        if preferredEngine == .kokoro, kokoroAvailable, locale.isEnglish {
            let voiceID = defaults.string(forKey: KokoroConfiguration.voiceDefaultsKey) ?? ""
            let config = KokoroConfiguration(voiceIdentifier: voiceID)
            return try kokoroFactory(deviceID, config)
        }
        return try avSpeechFactory(deviceID)
    }

    /// Creates the incoming TTS service. Always AVSpeech — Kokoro not used for incoming.
    func makeIncomingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> any SynthesisService {
        return try avSpeechFactory(deviceID)
    }

    /// Triggers Kokoro model download; sets `isDownloading` while in-flight.
    func downloadKokoroModel() {
        isDownloading = true
        Task { [weak self] in
            _ = try? await KokoroModelManager.shared.ensureReady()
            self?.isDownloading = false
        }
    }

    func unloadKokoroModel() {
        kokoroAvailable = false
        Task { await KokoroModelManager.shared.unload() }
    }

    // MARK: - For testing

    func setKokoroAvailableForTesting(_ value: Bool) { kokoroAvailable = value }

    // MARK: - Private

    private func observeModelManager() {
        Task { [weak self] in
            for await state in KokoroModelManager.shared.stateStream {
                await MainActor.run {
                    switch state {
                    case .ready:            self?.kokoroAvailable = true
                    case .failed, .idle:    self?.kokoroAvailable = false
                    case .loading:          break
                    }
                }
            }
        }
    }
}
