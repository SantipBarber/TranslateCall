import Foundation
import OSLog

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "ModelCatalog")

// MARK: - ModelCatalog

/// Ordered engine preferences per language and stage, engine availability flags, and per-pair
/// benchmark data (M9 UI core REQ-UI-20, design §3.1; M9 UI settings S-2, S-3).
///
/// Loaded from the bundled `ModelCatalog.json`; the benchmark can rewrite that file without code
/// changes (D-2). Keys are BCP-47 language codes (`en`, `es`, …) plus `default`. Engine names are
/// the `STTEngine` / `TTSEngine` raw values; unknown names are ignored. Edge TTS is never listed.
struct ModelCatalog: Decodable, Equatable {
    let version: Int
    let stt: [String: [String]]
    let ttsOutgoing: [String: [String]]
    let ttsIncoming: [String: [String]]

    /// Engine-level flags such as "unavailable" (S-2).
    var engines: [String: EngineInfo] = [:]

    /// Per-language-pair benchmark metrics, keyed by `PairKey.storageKey` (S-3).
    var pairs: [String: [String: EngineMetrics]] = [:]

    /// The bundled catalog. A missing or invalid file is a packaging bug: it asserts in debug builds
    /// and falls back to `builtIn` in release builds (design §3.1).
    static let bundled: ModelCatalog = {
        guard let catalog = decode(from: Bundle.main.url(forResource: "ModelCatalog", withExtension: "json")) else {
            assertionFailure("ModelCatalog.json missing or invalid")
            return load(from: nil)
        }
        return catalog
    }()

    /// The fallback when the bundled file is missing or invalid. The bundled JSON may differ:
    /// the benchmark rewrites it without code changes (D-2).
    static let builtIn = ModelCatalog(
        version: 2,
        stt: ["en": ["parakeet", "whisper", "appleSpeech"], "default": ["whisper", "appleSpeech"]],
        ttsOutgoing: ["en": ["voiceClone", "kokoro", "avSpeech"], "default": ["voiceClone", "avSpeech"]],
        ttsIncoming: ["en": ["kokoro", "avSpeech"], "default": ["avSpeech"]],
        engines: ["edgeTTS": EngineInfo(unavailable: true)],
        pairs: [:]
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

    /// True when `engine` is explicitly flagged as unavailable in the catalog (S-2).
    func isUnavailable(_ engine: TTSEngine) -> Bool {
        engines[engine.rawValue]?.unavailable ?? false
    }

    /// Benchmark metrics for `pair` and `engine`, if any (S-3).
    func metrics(for pair: PairKey, engine: String) -> EngineMetrics? {
        pairs[pair.storageKey]?[engine]
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

extension ModelCatalog {
    private enum CodingKeys: String, CodingKey {
        case version
        case stt
        case ttsOutgoing
        case ttsIncoming
        case engines
        case pairs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        stt = try container.decode([String: [String]].self, forKey: .stt)
        ttsOutgoing = try container.decode([String: [String]].self, forKey: .ttsOutgoing)
        ttsIncoming = try container.decode([String: [String]].self, forKey: .ttsIncoming)
        engines = try container.decodeIfPresent([String: EngineInfo].self, forKey: .engines) ?? [:]
        pairs = try container.decodeIfPresent([String: [String: EngineMetrics]].self, forKey: .pairs) ?? [:]
    }
}

// MARK: - EngineInfo

/// Flags that apply to an engine across all language pairs (S-2).
struct EngineInfo: Decodable, Equatable {
    var unavailable = false
}

extension EngineInfo {
    private enum CodingKeys: String, CodingKey {
        case unavailable
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unavailable = try container.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
    }
}

// MARK: - EngineMetrics

/// Benchmark data for one engine within one language pair (S-3).
struct EngineMetrics: Decodable, Equatable {
    var tested = false
    var latencyMs: Int?

    /// Human-readable latency such as "~0.4 s" or "~0.5 s to first audio".
    func latencyLabel(isVoice: Bool) -> String? {
        guard let latencyMs else { return nil }
        let seconds = Double(latencyMs) / 1000.0
        let suffix = isVoice ? " to first audio" : ""
        return String(format: "~%.1f s%@", seconds, suffix)
    }
}

extension EngineMetrics {
    private enum CodingKeys: String, CodingKey {
        case tested
        case latencyMs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tested = try container.decodeIfPresent(Bool.self, forKey: .tested) ?? false
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs)
    }
}
