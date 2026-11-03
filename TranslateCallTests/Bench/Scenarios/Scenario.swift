import Foundation
@testable import TranslateCall

/// A situation the app must cope with, run on the production pipeline with real-time playback and an
/// acoustic path (M9 scenario-tests design §3.2).
struct Scenario: Sendable, CustomStringConvertible {
    /// What one direction's output sounds like at the other capture: incoming → the mic (the user's
    /// speakers), outgoing → the call (the remote side's speakers).
    struct Echo: Sendable {
        let from: TraceDirection
        let gain: Float
        let delay: Duration
    }

    let name: String
    let line: BenchRunLine
    let profile: BenchProfile
    let listeningMode: ListeningMode
    let echoes: [Echo]
    /// When `.dataPlayedBack` fires after the audio ended (A30 on macOS 27.2).
    let playedLatency: Duration
    /// The first N clips of the line's PR set.
    let clipLimit: Int
    /// Silence kept running after the last clip, to catch a loop that keeps itself going.
    let observeAfter: Duration
    let rules: [ScenarioRule]

    var description: String { name }
}

/// A pass/fail check on what a scenario's session did.
enum ScenarioRule: Sendable, Equatable {
    /// The user never speaks: nothing may be spoken into the call. What the outgoing side recognized
    /// (echo the guard dropped) is reported, not failed.
    case noOutgoingSpeech
    /// No incoming translation is spoken twice, and no more are spoken than clips were played.
    case spokenOnce
    /// No TTS buffer of either direction is scheduled later than this after the last clip ended.
    case quietAfter(Duration)
    /// Each outgoing attempt's median F0 is within this share of the voice profile's (Task 18 pitch drift).
    case pitchNearReference(tolerance: Double)

    var name: String {
        switch self {
        case .noOutgoingSpeech: "noOutgoingSpeech"
        case .spokenOnce: "spokenOnce"
        case .quietAfter(let limit): "quietAfter(\(limit.secondsValue)s)"
        case .pitchNearReference(let tolerance): "pitchNearReference(±\(Int(tolerance * 100))%)"
        }
    }
}

/// What a scenario observed, reduced to what the rules read.
struct ScenarioObservation: Sendable {
    let events: [TraceEvent]
    let clipCount: Int
    let lastClipEnd: ContinuousClock.Instant
    /// Every TTS buffer scheduling instant, both directions.
    let scheduleTimes: [ContinuousClock.Instant]
    /// Median F0 of each outgoing attempt with audio, by seq (only when a pitch rule asks).
    var outgoingF0: [Int: Double] = [:]
    /// Median F0 of the active voice profile's recording.
    var referenceF0: Double?
}

struct ScenarioVerdict: Sendable, Codable, Equatable {
    let rule: String
    let passed: Bool
    let summary: String
}

extension ScenarioRule {
    func check(_ seen: ScenarioObservation) -> ScenarioVerdict {
        switch self {
        case .noOutgoingSpeech:
            let outgoing = seen.events.filter { $0.direction == .outgoing }
            let spoken = Set(outgoing.filter { $0.stage == .ttsFirstBuffer }.map(\.time)).count
            let heard = outgoing.filter { $0.stage == .sttFinal }
                .compactMap { $0.detail["text"]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var summary = "\(spoken) outgoing attempt(s) spoken; \(heard.count) echo utterance(s) recognized"
            if let first = heard.first { summary += " (first: \"\(first)\")" }
            return verdict(spoken == 0, summary)
        case .spokenOnce:
            let incoming = seen.events.filter { $0.direction == .incoming }
            let spokenSeqs = Set(incoming.filter { $0.stage == .ttsFirstBuffer }.map(\.seq))
            let attempts = Set(incoming.filter { $0.stage == .ttsFirstBuffer }.map(\.time)).count
            let texts = incoming.filter { $0.stage == .translated && spokenSeqs.contains($0.seq) }
                .compactMap { $0.detail["text"].map(Self.normalized) }
            let repeated = Dictionary(grouping: texts, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
            let passed = repeated.isEmpty && attempts <= seen.clipCount
            var summary = "\(attempts) incoming attempt(s) spoken for \(seen.clipCount) clip(s)"
            if !repeated.isEmpty { summary += "; repeated: \(repeated.prefix(3).map { "\"\($0)\"" }.joined(separator: ", "))" }
            return verdict(passed, summary)
        case .pitchNearReference(let tolerance):
            return pitchVerdict(seen, tolerance: tolerance)
        case .quietAfter(let limit):
            let late = seen.scheduleTimes.filter { $0 > seen.lastClipEnd + limit }
            let lastSeconds = seen.scheduleTimes.max().map { seen.lastClipEnd.duration(to: $0).secondsValue } ?? 0
            return verdict(late.isEmpty, late.isEmpty
                ? String(format: "last TTS buffer %.1f s after the last clip", lastSeconds)
                : String(format: "%d TTS buffer(s) after the limit; the last %.1f s after the last clip",
                         late.count, lastSeconds))
        }
    }

    private func pitchVerdict(_ seen: ScenarioObservation, tolerance: Double) -> ScenarioVerdict {
        guard let reference = seen.referenceF0 else { return verdict(false, "no voice profile F0") }
        guard !seen.outgoingF0.isEmpty else { return verdict(false, "no outgoing audio with a pitch") }
        let ordered = seen.outgoingF0.sorted { $0.key < $1.key }
        let outliers = ordered.filter { abs($0.value / reference - 1) > tolerance }
        let list = ordered.map { String(format: "%.0f", $0.value) }.joined(separator: " ")
        var summary = String(format: "reference %.0f Hz; sentences: %@ Hz", reference, list)
        if !outliers.isEmpty {
            summary += "; off: " + outliers.map { String(format: "#%d %.0f Hz", $0.key, $0.value) }
                .joined(separator: ", ")
        }
        return verdict(outliers.isEmpty, summary)
    }

    private func verdict(_ passed: Bool, _ summary: String) -> ScenarioVerdict {
        ScenarioVerdict(rule: name, passed: passed, summary: summary)
    }

    /// Lowercased, punctuation and extra spaces removed: a repeat is the same words.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The scenarios `just scenario` knows (design §2).
enum ScenarioCatalog {
    /// The Mac mini's speakers heard by the Brio, a few centimetres away (design §4).
    static let speakers = Scenario.Echo(from: .incoming, gain: 0.5, delay: .milliseconds(40))
    /// The remote side on speakers too: our outgoing voice comes back through the call.
    static let remoteSpeakers = Scenario.Echo(from: .outgoing, gain: 0.5, delay: .milliseconds(250))
    static let a30 = Duration.milliseconds(250)
    static let rules: [ScenarioRule] = [.noOutgoingSpeech, .spokenOnce, .quietAfter(.seconds(12))]

    /// The acoustic loop (Task 18 Q6), Basic: about 1 min each.
    static let echo: [Scenario] = [
        Scenario(name: "echo-speakers", line: .incomingEnToEs, profile: .basic, listeningMode: .speakers,
                 echoes: [speakers], playedLatency: a30, clipLimit: 6, observeAfter: .seconds(15), rules: rules),
        Scenario(name: "echo-headphones", line: .incomingEnToEs, profile: .basic, listeningMode: .headphones,
                 echoes: [speakers], playedLatency: a30, clipLimit: 6, observeAfter: .seconds(15), rules: rules),
        Scenario(name: "echo-both", line: .incomingEnToEs, profile: .basic, listeningMode: .speakers,
                 echoes: [speakers, remoteSpeakers], playedLatency: a30, clipLimit: 6, observeAfter: .seconds(20),
                 rules: rules),
        // The default mode with both sides on speakers: the loop the user heard in Task 18 Q6 (suspected).
        Scenario(name: "echo-headphones-both", line: .incomingEnToEs, profile: .basic, listeningMode: .headphones,
                 echoes: [speakers, remoteSpeakers], playedLatency: a30, clipLimit: 6, observeAfter: .seconds(20),
                 rules: rules),
    ]

    /// The voice clone's pitch against the user's recording, Spanish → English (Best).
    static let voice: [Scenario] = [
        Scenario(name: "voice-pitch", line: .outgoingEsESToEn, profile: .best, listeningMode: .headphones,
                 echoes: [], playedLatency: a30, clipLimit: 8, observeAfter: .seconds(3),
                 rules: [.pitchNearReference(tolerance: 0.12), .quietAfter(.seconds(12))]),
    ]

    static var all: [Scenario] { echo + voice }

    static func named(_ name: String) -> Scenario? { all.first { $0.name == name } }
}
