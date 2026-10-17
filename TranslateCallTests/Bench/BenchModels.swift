import Foundation
@testable import TranslateCall

/// The parts of `bench/manifests/*.json` (schema 1, written by `tcbench manifest`) the runner reads.
/// Python owns the format; `tools/bench/tests/fixtures/manifest-v1-sample.json` pins it for both sides.
struct BenchManifest: Decodable, Sendable {
    struct Clip: Decodable, Sendable {
        let id: String
        let lang: String
        let variant: String
        /// Path of the normalised 16 kHz WAV, relative to the cache directory.
        let audio: String
        let speechStartMs: Double
        let speechEndMs: Double
        let tiers: [String]
        let sha256: String
    }

    struct MTSentence: Decodable, Sendable {
        let id: String
        let srcLang: String
        let tgtLang: String
        let src: String
        let tiers: [String]
    }

    let schema: Int
    let clips: [Clip]
    let mtOnly: [MTSentence]

    func clips(variant: String, set: String) -> [Clip] {
        clips.filter { $0.variant == variant && $0.tiers.contains(set) }
    }

    func mtOnly(from source: String, to target: String, set: String) -> [MTSentence] {
        mtOnly.filter { $0.srcLang == source && $0.tgtLang == target && $0.tiers.contains(set) }
    }
}

/// `raw.json`, schema 1 (M9 design §3.5): what one run line × profile observed. Times are
/// nanoseconds since the session's origin instant. Python derives every metric from it.
struct RawRun: Codable, Equatable {
    struct Meta: Codable, Equatable {
        var commit: String
        var dirty: Bool
        var machine: String
        var macOS: String
        var xcode: String
        var manifestSha256: String
        var engines: [String: String]
        var settings: [String: String]
    }

    struct Clip: Codable, Equatable {
        let id: String
        let feedStartNs: Int64
        let feedEndNs: Int64
        let speechStartNs: Int64
        let speechEndNs: Int64
    }

    struct Utterance: Codable, Equatable {
        let seq: Int
        /// Stage → ns; stages the utterance never reached are absent.
        let events: [String: Int64]
        /// Detail of each stage's event (`text`, `engine`, `reason`, `mergedSeqs`…).
        let detail: [String: [String: String]]
        let audio: String?
    }

    struct MTResult: Codable, Equatable {
        let id: String
        let hyp: String?
        let error: String?
        let ms: Double
    }

    var schema = 1
    let runId: String
    let set: String
    let profile: String
    let runLine: String
    let informative: Bool
    let override: String?
    let meta: Meta
    let clips: [Clip]
    let utterances: [Utterance]
    let mtOnly: [MTResult]
}

extension RawRun.Utterance {
    /// Groups `events` of one direction by seq, as offsets from `origin`.
    static func from(_ events: [TraceEvent], origin: ContinuousClock.Instant,
                     audio: (Int) -> String? = { _ in nil }) -> [RawRun.Utterance] {
        Dictionary(grouping: events, by: \.seq).keys.sorted().map { seq in
            let mine = events.filter { $0.seq == seq }
            return RawRun.Utterance(
                seq: seq,
                events: Dictionary(mine.map { ($0.stage.rawValue, origin.nanoseconds(to: $0.time)) },
                                   uniquingKeysWith: { first, _ in first }),
                detail: Dictionary(mine.filter { !$0.detail.isEmpty }.map { ($0.stage.rawValue, $0.detail) },
                                   uniquingKeysWith: { first, _ in first }),
                audio: audio(seq)
            )
        }
    }
}

extension ContinuousClock.Instant {
    func nanoseconds(to later: ContinuousClock.Instant) -> Int64 {
        let (seconds, attoseconds) = duration(to: later).components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}

enum BenchJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
