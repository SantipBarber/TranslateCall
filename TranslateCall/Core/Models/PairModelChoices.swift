import Combine
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "PairModelChoices")

// MARK: - PairKey

/// An unordered language pair: ES ↔ DE and DE ↔ ES are the same key (M9 UI settings REQ-ST-01).
nonisolated struct PairKey: Hashable, Codable, Sendable {
    let first: String
    let second: String

    /// Language codes (`es`, `de`, …), stored sorted.
    init(_ lhs: String, _ rhs: String) {
        (first, second) = lhs <= rhs ? (lhs, rhs) : (rhs, lhs)
    }

    /// The pair of two picker languages, by language code (`es-ES` → `es`).
    init(_ lhs: Locale.Language, _ rhs: Locale.Language) {
        self.init(Self.code(lhs), Self.code(rhs))
    }

    /// `"de|es"`: the key in `UserDefaults` and in the catalog's `pairs` table.
    var storageKey: String { "\(first)|\(second)" }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: "|").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(parts[0], parts[1])
    }

    static func code(_ language: Locale.Language) -> String {
        language.languageCode?.identifier ?? language.minimalIdentifier
    }
}

// MARK: - PairModelChoice

/// The user's choice per stage for one pair; nil = the catalog's recommendation (S-1).
nonisolated struct PairModelChoice: Codable, Equatable, Sendable {
    var stt: STTEngine?
    /// The standard voice; never `.voiceClone`, which "Use my voice" owns (S-6).
    var voice: TTSEngine?

    init(stt: STTEngine? = nil, voice: TTSEngine? = nil) {
        self.stt = stt
        self.voice = voice == .voiceClone ? nil : voice
    }

    var isEmpty: Bool { stt == nil && voice == nil }

    /// Unknown engine names (a newer build's engine) decode as nil instead of failing the whole store.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stt = (try? container.decodeIfPresent(String.self, forKey: .stt)).flatMap { $0 }
        let voice = (try? container.decodeIfPresent(String.self, forKey: .voice)).flatMap { $0 }
        self.init(stt: stt.flatMap(STTEngine.init(rawValue:)), voice: voice.flatMap(TTSEngine.init(rawValue:)))
    }
}

// MARK: - PairModelChoices

/// The stored per-pair choices (`tlk.models.pairChoices`, JSON `[storageKey: PairModelChoice]`).
@MainActor
final class PairModelChoices: ObservableObject {
    static let defaultsKey = "tlk.models.pairChoices"

    @Published private(set) var all: [PairKey: PairModelChoice]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        all = Self.load(from: defaults)
    }

    func choice(for pair: PairKey) -> PairModelChoice {
        all[pair] ?? PairModelChoice()
    }

    /// Stores `choice`; an empty one removes the pair ("Recommended").
    func set(_ choice: PairModelChoice, for pair: PairKey) {
        all[pair] = choice.isEmpty ? nil : choice
        save()
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: all.map { ($0.key.storageKey, $0.value) })
        do {
            defaults.set(try JSONEncoder().encode(raw), forKey: Self.defaultsKey)
        } catch {
            logger.error("Could not save pair choices: \(error.localizedDescription)")
        }
    }

    /// A missing or corrupt value is an empty store (every pair "Recommended").
    private static func load(from defaults: UserDefaults) -> [PairKey: PairModelChoice] {
        guard let data = defaults.data(forKey: defaultsKey),
              let raw = try? JSONDecoder().decode([String: PairModelChoice].self, from: data) else { return [:] }
        var result: [PairKey: PairModelChoice] = [:]
        for (key, choice) in raw where !choice.isEmpty {
            if let pair = PairKey(storageKey: key) { result[pair] = choice }
        }
        return result
    }
}
