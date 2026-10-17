import Foundation
import OSLog

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "ModelCatalog")

// MARK: - ModelCatalog

/// Ordered engine preferences per language and stage (M9 UI core REQ-UI-20, design §3.1).
///
/// Loaded from the bundled `ModelCatalog.json`; the benchmark can rewrite that file without code
/// changes (D-2). Keys are BCP-47 language codes (`en`, `es`, …) plus `default`. Engine names are
/// the `STTEngine` / `TTSEngine` raw values; unknown names are ignored. Edge TTS is never listed.
struct ModelCatalog: Decodable, Equatable {
    let version: Int
    let stt: [String: [String]]
    let ttsOutgoing: [String: [String]]
    let ttsIncoming: [String: [String]]

    /// The bundled catalog. A missing or invalid file is a packaging bug: it asserts in debug builds
    /// and falls back to `builtIn` in release builds (design §3.1).
    static let bundled: ModelCatalog = {
        guard let catalog = decode(from: Bundle.main.url(forResource: "ModelCatalog", withExtension: "json")) else {
            assertionFailure("ModelCatalog.json missing or invalid")
            return load(from: nil)
        }
        return catalog
    }()

    /// The fallback when the bundled file is missing or invalid (the version-1 preferences). The
    /// bundled JSON may differ: the benchmark rewrites it without code changes (D-2).
    static let builtIn = ModelCatalog(
        version: 1,
        stt: ["en": ["parakeet", "whisper", "appleSpeech"], "default": ["whisper", "appleSpeech"]],
        ttsOutgoing: ["en": ["voiceClone", "kokoro", "avSpeech"], "default": ["voiceClone", "avSpeech"]],
        ttsIncoming: ["en": ["kokoro", "avSpeech"], "default": ["avSpeech"]]
    )

    /// Decodes the catalog at `url`; any failure logs and returns `builtIn`. Never asserts.
    static func load(from url: URL?) -> ModelCatalog {
        guard let catalog = decode(from: url) else {
            logger.error("ModelCatalog.json missing or invalid; using the built-in catalog")
            return builtIn
        }
        return catalog
    }

    /// The catalog at `url`, or nil when it is missing or does not decode.
    static func decode(from url: URL?) -> ModelCatalog? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ModelCatalog.self, from: data)
    }

    func sttEngines(for locale: Locale) -> [STTEngine] {
        names(in: stt, for: locale).compactMap(STTEngine.init(rawValue:))
    }

    func ttsEngines(for locale: Locale, direction: TranscriptDirection) -> [TTSEngine] {
        let table = direction == .outgoing ? ttsOutgoing : ttsIncoming
        return names(in: table, for: locale).compactMap(TTSEngine.init(rawValue:)).filter { $0 != .edgeTTS }
    }

    private func names(in table: [String: [String]], for locale: Locale) -> [String] {
        let code = locale.language.languageCode?.identifier ?? ""
        return table[code] ?? table["default"] ?? []
    }
}
