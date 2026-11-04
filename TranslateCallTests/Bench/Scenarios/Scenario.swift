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
    /// How each clip is reshaped before it plays (design §5.2).
    var shape: ScenarioClipShape = .asIs
    var script: ScenarioScript = .clips

    var description: String { name }
}

/// A change to a clip's audio before it plays (design §5.2).
enum ScenarioClipShape: Sendable, Equatable {
    case asIs
    /// Silence inserted at the quietest 20 ms frame between 35 % and 65 % of the speech: a hesitation.
    case innerPause(seconds: Double)

    /// `samples` reshaped; `speech` is the range of samples with speech in them.
    func apply(_ samples: [Float], speech: Range<Int>, rate: Double) -> [Float] {
        guard case .innerPause(let seconds) = self else { return samples }
        let frame = Int(rate * 0.02)
        let span = speech.clamped(to: samples.indices)
        let low = span.lowerBound + Int(Double(span.count) * 0.35)
        let high = span.lowerBound + Int(Double(span.count) * 0.65) - frame
        guard high > low else { return samples }
        let quietest = stride(from: low, through: high, by: max(frame / 4, 1)).min { lhs, rhs in
            energy(samples[lhs..<(lhs + frame)]) < energy(samples[rhs..<(rhs + frame)])
        } ?? low
        var shaped = samples
        shaped.insert(contentsOf: [Float](repeating: 0, count: Int(seconds * rate)), at: quietest + frame / 2)
        return shaped
    }

    private func energy(_ frame: ArraySlice<Float>) -> Float { frame.reduce(0) { $0 + $1 * $1 } }
}

/// What a scenario does with its clips (design §5.3).
enum ScenarioScript: Sendable, Equatable {
    /// Each clip in turn, each settled before the next.
    case clips
    /// Task 18 Q4: the first `joined` clips as one long sentence; `pauseAfterAudio` after its first outgoing
    /// audio the session pauses for `pausedFor`, then the remaining clips play one by one.
    case pauseDuringClone(joined: Int, pauseAfterAudio: Duration, pausedFor: Duration)
}

/// A pass/fail check on what a scenario's session did.
enum ScenarioRule: Sendable, Equatable {
    /// The user never speaks: nothing may be spoken into the call. What the outgoing side recognized
    /// (echo the guard dropped) is reported, not failed.
    case noOutgoingSpeech
    /// No translation of `direction` is spoken twice, and no more than `perClip` per clip played.
    case spokenOnce(TraceDirection, perClip: Int = 1)
    /// Each clip's spoken utterances number within the range (1...1: a hesitation did not cut it).
    case piecesPerClip(ClosedRange<Int>)
    /// The share of the clips' transcript words in the recognized text that was spoken, all clips pooled.
    case wordsKept(minRecall: Double)
    /// No TTS buffer is scheduled while the session is paused (50 ms grace after the pause).
    case noAudioWhilePaused
    /// Every clip after the resume is spoken, the last by the voice clone (Task 18 Q4).
    case cloneAfterResume
    /// No TTS buffer of either direction is scheduled later than this after the last clip ended.
    case quietAfter(Duration)
    /// Each outgoing attempt's median F0 is within this share of the voice profile's (Task 18 pitch drift).
    case pitchNearReference(tolerance: Double)

    var name: String {
        switch self {
        case .noOutgoingSpeech: "noOutgoingSpeech"
        case .spokenOnce(.incoming, 1): "spokenOnce"
        case .spokenOnce(let direction, let perClip): "spokenOnce(\(direction.rawValue), ≤\(perClip)/clip)"
        case .piecesPerClip(let range): "piecesPerClip(\(range.lowerBound)...\(range.upperBound))"
        case .wordsKept(let recall): "wordsKept(≥\(Int(recall * 100))%)"
        case .noAudioWhilePaused: "noAudioWhilePaused"
        case .cloneAfterResume: "cloneAfterResume"
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
    /// The clips as played (shaped), with what is said in them (design §5.4).
    var clips: [Clip] = []
    /// From the pause to the resume, when the scenario paused.
    var paused: Range<ContinuousClock.Instant>?

    struct Clip: Sendable {
        let start: ContinuousClock.Instant
        let end: ContinuousClock.Instant
        let transcript: String
    }

    /// The outgoing seqs whose speech started in clip `index`'s window: its start − 0.5 s up to the next
    /// clip's start − 0.5 s.
    func outgoingSeqs(ofClip index: Int) -> [Int] {
        let lead = Duration.milliseconds(500)
        let from = clips[index].start - lead
        let until = index + 1 < clips.count ? clips[index + 1].start - lead : nil
        return events.filter { event in
            event.direction == .outgoing && event.stage == .speechStart && event.time >= from
                && until.map { event.time < $0 } ?? true
        }.sorted { $0.time < $1.time }.map(\.seq)
    }

    /// The outgoing seqs that were heard (had a first TTS buffer), with the engine heard.
    var spokenOutgoing: [Int: String] {
        Dictionary(events.filter { $0.direction == .outgoing && $0.stage == .ttsFirstBuffer }
            .map { ($0.seq, $0.detail["engine"] ?? "?") }, uniquingKeysWith: { first, _ in first })
    }
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
        case .spokenOnce(let direction, let perClip):
            let side = seen.events.filter { $0.direction == direction }
            let spokenSeqs = Set(side.filter { $0.stage == .ttsFirstBuffer }.map(\.seq))
            let attempts = Set(side.filter { $0.stage == .ttsFirstBuffer }.map(\.time)).count
            let texts = side.filter { $0.stage == .translated && spokenSeqs.contains($0.seq) }
                .compactMap { $0.detail["text"].map(Self.normalized) }
            let repeated = Dictionary(grouping: texts, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
            let passed = repeated.isEmpty && attempts <= seen.clipCount * perClip
            var summary = "\(attempts) \(direction.rawValue) attempt(s) spoken for \(seen.clipCount) clip(s)"
            if !repeated.isEmpty { summary += "; repeated: \(repeated.prefix(3).map { "\"\($0)\"" }.joined(separator: ", "))" }
            return verdict(passed, summary)
        case .pitchNearReference(let tolerance):
            return pitchVerdict(seen, tolerance: tolerance)
        case .piecesPerClip(let range):
            guard !seen.clips.isEmpty else { return verdict(false, "no clips") }
            let spoken = seen.spokenOutgoing
            let counts = seen.clips.indices.map { seen.outgoingSeqs(ofClip: $0).filter { spoken[$0] != nil }.count }
            return verdict(counts.allSatisfy(range.contains),
                           "spoken pieces per clip: " + counts.map(String.init).joined(separator: " "))
        case .wordsKept(let minRecall):
            return wordsVerdict(seen, minRecall: minRecall)
        case .noAudioWhilePaused:
            guard let paused = seen.paused else { return verdict(false, "the session never paused") }
            let from = paused.lowerBound + .milliseconds(50)
            let during = seen.scheduleTimes.filter { $0 >= from && $0 < paused.upperBound }
            return verdict(during.isEmpty, String(format: "%d TTS buffer(s) while paused (%.1f s)",
                                                  during.count, paused.lowerBound.duration(to: paused.upperBound)
                                                      .secondsValue))
        case .cloneAfterResume:
            return resumeVerdict(seen)
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

    private func wordsVerdict(_ seen: ScenarioObservation, minRecall: Double) -> ScenarioVerdict {
        guard !seen.clips.isEmpty else { return verdict(false, "no clips") }
        let spoken = seen.spokenOutgoing
        let recognized = Dictionary(seen.events.filter { $0.direction == .outgoing && $0.stage == .sttFinal }
            .map { ($0.seq, $0.detail["text"] ?? "") }, uniquingKeysWith: { first, _ in first })
        var (found, total) = (0, 0)
        var perClip: [(index: Int, recall: Double)] = []
        for index in seen.clips.indices {
            let reference = WordErrorRate.words(seen.clips[index].transcript)
            let heard = seen.outgoingSeqs(ofClip: index).filter { spoken[$0] != nil }
                .map { recognized[$0] ?? "" }.joined(separator: " ")
            var bag = Dictionary(WordErrorRate.words(heard).map { ($0, 1) }, uniquingKeysWith: +)
            let hits = reference.filter { word in
                guard let count = bag[word], count > 0 else { return false }
                bag[word] = count - 1
                return true
            }.count
            found += hits
            total += reference.count
            if !reference.isEmpty { perClip.append((index, Double(hits) / Double(reference.count))) }
        }
        guard total > 0 else { return verdict(false, "no transcripts") }
        let recall = Double(found) / Double(total)
        var summary = String(format: "%.0f%% of %d words kept", recall * 100, total)
        if let worst = perClip.min(by: { $0.recall < $1.recall }) {
            summary += String(format: "; worst #%d %.0f%%", worst.index, worst.recall * 100)
        }
        return verdict(recall >= minRecall, summary)
    }

    private func resumeVerdict(_ seen: ScenarioObservation) -> ScenarioVerdict {
        guard let paused = seen.paused else { return verdict(false, "the session never paused") }
        let after = seen.clips.indices.filter { seen.clips[$0].start >= paused.upperBound }
        guard !after.isEmpty else { return verdict(false, "no clip after the resume") }
        let spoken = seen.spokenOutgoing
        let engines = after.map { index in
            seen.outgoingSeqs(ofClip: index).compactMap { spoken[$0] }.last ?? "nothing"
        }
        return verdict(!engines.contains("nothing") && engines.last == TTSEngine.voiceClone.rawValue,
                       "after the resume: " + engines.joined(separator: " → "))
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
    static let rules: [ScenarioRule] = [.noOutgoingSpeech, .spokenOnce(.incoming), .quietAfter(.seconds(12))]

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

    /// Hesitations and the Pause button, Spanish → English on Best (Task 18 Q4/Q5, design §5.3).
    static let pauses: [Scenario] = [
        Scenario(name: "pause-short", line: .outgoingEsESToEn, profile: .best, listeningMode: .headphones,
                 echoes: [], playedLatency: a30, clipLimit: 6, observeAfter: .seconds(3),
                 rules: [.piecesPerClip(1...1), .spokenOnce(.outgoing), .wordsKept(minRecall: 0.85),
                         .quietAfter(.seconds(12))],
                 shape: .innerPause(seconds: 0.4)),
        Scenario(name: "pause-long", line: .outgoingEsESToEn, profile: .best, listeningMode: .headphones,
                 echoes: [], playedLatency: a30, clipLimit: 6, observeAfter: .seconds(3),
                 rules: [.piecesPerClip(1...2), .spokenOnce(.outgoing, perClip: 2), .wordsKept(minRecall: 0.85),
                         .quietAfter(.seconds(12))],
                 shape: .innerPause(seconds: 1.0)),
        Scenario(name: "pause-resume", line: .outgoingEsESToEn, profile: .best, listeningMode: .headphones,
                 echoes: [], playedLatency: a30, clipLimit: 6, observeAfter: .seconds(3),
                 rules: [.noAudioWhilePaused, .spokenOnce(.outgoing), .cloneAfterResume, .quietAfter(.seconds(12))],
                 script: .pauseDuringClone(joined: 3, pauseAfterAudio: .milliseconds(500),
                                           pausedFor: .milliseconds(300))),
    ]

    static var all: [Scenario] { echo + voice + pauses }

    static func named(_ name: String) -> Scenario? { all.first { $0.name == name } }
}
