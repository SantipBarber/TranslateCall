import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

/// The Swift side of the M9 data contracts. Pure Codable: runs in the unit tier, not behind the
/// bench tier gate.
@Suite("Bench models")
struct BenchModelsTests {
    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "tools/bench/tests/fixtures")
    }

    @Test func manifestSampleDecodes() throws {
        let data = try Data(contentsOf: Self.fixtures.appending(path: "manifest-v1-sample.json"))
        let manifest = try JSONDecoder().decode(BenchManifest.self, from: data)
        #expect(manifest.schema == 1)
        #expect(manifest.clips(variant: "es-ES", set: "pr").count == 1)
        #expect(manifest.clips(variant: "es-419", set: "pr").count == 1)
        #expect(manifest.clips(variant: "es-ES", set: "full").count == 1)
        #expect(manifest.clips(variant: "en", set: "full").count == 1)
        #expect(manifest.clips(variant: "en", set: "pr").isEmpty)
        #expect(manifest.mtOnly(from: "es", to: "en", set: "full").count == 1)
        #expect(manifest.mtOnly(from: "en", to: "es", set: "pr").count == 1)
    }

    @Test func utterancesGroupBySeqAsNanosecondOffsets() {
        let origin = ContinuousClock.now
        let events = [
            TraceEvent(direction: .outgoing, seq: 1, stage: .vadEnd,
                       time: origin.advanced(by: .milliseconds(7)), detail: [:]),
            TraceEvent(direction: .outgoing, seq: 0, stage: .vadEnd,
                       time: origin.advanced(by: .milliseconds(5)),
                       detail: ["trailingSilenceMs": "600"]),
        ]
        let utterances = RawRun.Utterance.from(events, origin: origin) { $0 == 0 ? "u0.wav" : nil }
        #expect(utterances.map(\.seq) == [0, 1])
        #expect(utterances[0].events["vadEnd"] == 5_000_000)
        #expect(utterances[0].detail["vadEnd"]?["trailingSilenceMs"] == "600")
        #expect(utterances[0].audio == "u0.wav")
        #expect(utterances[1].events["vadEnd"] == 7_000_000)
        #expect(utterances[1].detail.isEmpty)
    }

    @Test func rawSampleIsStable() throws {
        let run = RawRun(
            runId: "20261017T120000Z-abc1234",
            set: "pr",
            profile: "basic",
            runLine: "es-ES>en",
            informative: false,
            override: nil,
            meta: .init(commit: "abc1234", dirty: false, machine: "Mac14,3", macOS: "15.6",
                        xcode: "16.4", manifestSha256: String(repeating: "a", count: 64),
                        engines: ["stt": "apple", "tts": "avspeech", "translation": "apple"],
                        settings: ["vadTrailingSilenceMs": "600"]),
            clips: [
                .init(id: "cv-es-es-0001", feedStartNs: 0, feedEndNs: 3_500_000_000,
                      speechStartNs: 220_000_000, speechEndNs: 3_150_000_000),
                .init(id: "cv-es-419-0001", feedStartNs: 4_000_000_000, feedEndNs: 7_000_000_000,
                      speechStartNs: 4_180_000_000, speechEndNs: 6_900_000_000),
            ],
            utterances: [
                .init(seq: 0,
                      events: ["speechStart": 220_000_000, "vadEnd": 3_750_000_000,
                               "sttFinal": 4_100_000_000, "translated": 4_360_000_000,
                               "ttsFirstBuffer": 4_700_000_000, "ttsEnd": 6_000_000_000],
                      detail: ["vadEnd": ["segmentAudioMs": "2930", "trailingSilenceMs": "600"],
                               "sttFinal": ["text": "Buenos días", "engine": "apple"],
                               "translated": ["text": "Good morning"]],
                      audio: "utterances/0.wav"),
                .init(seq: 1,
                      events: ["speechStart": 4_180_000_000, "dropped": 7_500_000_000],
                      detail: ["dropped": ["reason": "empty"]],
                      audio: nil),
            ],
            mtOnly: [
                .init(id: "mt-en-es-0001", hyp: "La factura se enviará mañana por la mañana.",
                      error: nil, ms: 261.5),
                .init(id: "mt-es-en-0001", hyp: nil, error: "pack missing", ms: 0),
            ]
        )
        var bytes = try BenchJSON.encoder().encode(run)
        bytes.append(0x0A)
        let url = Self.fixtures.appending(path: "raw-v1-sample.json")
        if ProcessInfo.processInfo.environment["TC_WRITE_GOLDEN"] == "1" {
            try bytes.write(to: url)
            Issue.record("Wrote \(url.path); commit it.")
            return
        }
        #expect(bytes == (try Data(contentsOf: url)))
        #expect(try JSONDecoder().decode(RawRun.self, from: Data(contentsOf: url)) == run)
    }

    // MARK: - BenchEnvironment

    @Test func environmentDefaults() throws {
        let env = try BenchEnvironment.parse(["TC_BENCH_OUT": "/tmp/out"])
        #expect(env.set == "pr")
        #expect(env.profiles == [.basic, .best])
        #expect(!env.edge)
        #expect(env.overrideSTT == nil)
        #expect(env.overrideTTS == nil)
        #expect(env.out.path == "/tmp/out")
        #expect(env.manifest.path.hasSuffix("bench/manifests/phase1.json"))
        #expect(env.cache.path.hasSuffix("Library/Caches/TranslateCallBench"))
        #expect(env.commit == "unknown")
        #expect(!env.dirty)
    }

    @Test func environmentReadsEveryVariable() throws {
        let env = try BenchEnvironment.parse([
            "TC_BENCH_OUT": "/tmp/out", "TC_BENCH_SET": "full", "TC_BENCH_PROFILE": "best",
            "TC_BENCH_EDGE": "1", "TC_BENCH_OVERRIDE_STT": "parakeet", "TC_BENCH_OVERRIDE_TTS": "kokoro",
            "TC_BENCH_CACHE": "/tmp/cache", "TC_BENCH_MANIFEST": "/tmp/m.json",
            "TC_COMMIT": "abc1234", "TC_DIRTY": "1",
        ])
        #expect(env.set == "full")
        #expect(env.profiles == [.best])
        #expect(env.edge)
        #expect(env.overrideSTT == .parakeet)
        #expect(env.overrideTTS == .kokoro)
        #expect(env.cache.path == "/tmp/cache")
        #expect(env.manifest.path == "/tmp/m.json")
        #expect(env.commit == "abc1234")
        #expect(env.dirty)
    }

    @Test func environmentProfileAllMeansBasicAndBest() throws {
        let env = try BenchEnvironment.parse(["TC_BENCH_OUT": "/tmp/out", "TC_BENCH_PROFILE": "all"])
        #expect(env.profiles == [.basic, .best])
        let basic = try BenchEnvironment.parse(["TC_BENCH_OUT": "/tmp/out", "TC_BENCH_PROFILE": "basic"])
        #expect(basic.profiles == [.basic])
    }

    @Test func environmentRejectsMissingOutAndUnknownValues() {
        #expect(throws: BenchSetupError.self) { try BenchEnvironment.parse([:]) }
        #expect(throws: BenchSetupError.self) { try BenchEnvironment.parse(["TC_BENCH_OUT": ""]) }
        #expect(throws: BenchSetupError.self) {
            try BenchEnvironment.parse(["TC_BENCH_OUT": "/o", "TC_BENCH_SET": "huge"])
        }
        #expect(throws: BenchSetupError.self) {
            try BenchEnvironment.parse(["TC_BENCH_OUT": "/o", "TC_BENCH_OVERRIDE_STT": "nope"])
        }
    }

    @Test func environmentLinesFilter() throws {
        let all = try BenchEnvironment.parse(["TC_BENCH_OUT": "/o"])
        #expect(BenchRunLine.all.allSatisfy { all.selects($0) })
        let empty = try BenchEnvironment.parse(["TC_BENCH_OUT": "/o", "TC_BENCH_LINES": ""])
        #expect(BenchRunLine.all.allSatisfy { empty.selects($0) })
        let some = try BenchEnvironment.parse([
            "TC_BENCH_OUT": "/o", "TC_BENCH_LINES": "outgoing-es-419-en, incoming-en-es",
        ])
        #expect(some.selects(.outgoingEs419ToEn))
        #expect(some.selects(.incomingEnToEs))
        #expect(!some.selects(.outgoingEsESToEn))
        #expect(!some.selects(.outgoingEnToEs))
        #expect(throws: BenchSetupError.self) {
            try BenchEnvironment.parse(["TC_BENCH_OUT": "/o", "TC_BENCH_LINES": "outgoing-xx-en"])
        }
    }

    // MARK: - Clause split (REQ-CS-21)

    @Test func clauseSplitDefaultsOnWithoutAVariable() throws {
        #expect(try BenchEnvironment.parse(["TC_BENCH_OUT": "/o"]).clauseSplit)
    }

    @Test func clauseSplitZeroTurnsTheSplitOff() throws {
        let env = try BenchEnvironment.parse(["TC_BENCH_OUT": "/o", "TC_CLAUSE_SPLIT": "0"])
        #expect(!env.clauseSplit)
        #expect(!env.options(for: .best).clauseSplit)
    }

    @Test func clauseSplitOneTurnsTheSplitOn() throws {
        let env = try BenchEnvironment.parse(["TC_BENCH_OUT": "/o", "TC_CLAUSE_SPLIT": "1"])
        #expect(env.clauseSplit)
        #expect(env.options(for: .basic).clauseSplit)
    }

    @Test func clauseSplitRejectsOtherValues() {
        #expect(throws: BenchSetupError.self) {
            try BenchEnvironment.parse(["TC_BENCH_OUT": "/o", "TC_CLAUSE_SPLIT": "x"])
        }
    }

    // MARK: - AudioCollector

    private static func buffer(frames: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050, channels: 1,
                                   interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    private static func first(_ seq: Int, at time: ContinuousClock.Instant) -> TraceEvent {
        TraceEvent(direction: .outgoing, seq: seq, stage: .ttsFirstBuffer, time: time, detail: [:])
    }

    @Test func audioCollectorSplitsBuffersAtTheFirstBufferStamps() {
        let t0 = ContinuousClock.now
        func at(_ ms: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(ms)) }
        // Real order: the device stamps a buffer, then the tracer stamps ttsFirstBuffer a moment later.
        // Seq 0: 3 buffers (100/200/300 frames), its ttsEnd precedes the last buffer (synthesis split).
        // Seq 1: ttsFirstBuffer and ttsEnd share one stamp (synthesis finished first); 2 buffers.
        // Each buffer is scheduled before the audio before it ends: no silence between them.
        let buffers = [(at(10), Self.buffer(frames: 100)), (at(12), Self.buffer(frames: 200)),
                       (at(13), Self.buffer(frames: 300)), (at(100), Self.buffer(frames: 400)),
                       (at(110), Self.buffer(frames: 500))]
        let events = [
            Self.first(0, at: at(11)),
            TraceEvent(direction: .outgoing, seq: 0, stage: .ttsEnd, time: at(12), detail: [:]),
            Self.first(1, at: at(101)),
            TraceEvent(direction: .outgoing, seq: 1, stage: .ttsEnd, time: at(101), detail: [:]),
        ]
        var collector = AudioCollector()
        collector.add(buffers, events: events)
        #expect(collector.frameCount(seq: 0) == 600)
        #expect(collector.frameCount(seq: 1) == 900)
        #expect(collector.audioPath(seq: 0) == "audio/0.wav")
        #expect(collector.audioPath(seq: 1) == "audio/1.wav")
        #expect(collector.audioPath(seq: 2) == nil)
    }

    @Test func audioCollectorSharesAMergedAttemptsAudio() {
        let t0 = ContinuousClock.now
        let buffers = [(t0.advanced(by: .milliseconds(5)), Self.buffer(frames: 100)),
                       (t0.advanced(by: .milliseconds(7)), Self.buffer(frames: 150))]
        let stamp = t0.advanced(by: .milliseconds(6))
        var collector = AudioCollector()
        collector.add(buffers, events: [Self.first(3, at: stamp), Self.first(4, at: stamp)])
        #expect(collector.frameCount(seq: 3) == 250)
        #expect(collector.audioPath(seq: 4) == "audio/3.wav")
        #expect(collector.frameCount(seq: 4) == 250)
    }

    /// 441 frames at 22.05 kHz: 20 ms of a constant non-zero level, to tell audio from inserted silence.
    private static func tone(_ count: Int = 441) -> AVAudioPCMBuffer {
        let buffer = buffer(frames: count)
        for index in 0..<count { buffer.floatChannelData![0][index] = 0.5 }
        return buffer
    }

    private static func part(_ seq: Int, at time: ContinuousClock.Instant) -> TraceEvent {
        TraceEvent(direction: .outgoing, seq: seq, stage: .ttsPartBuffer, time: time, detail: ["part": "1"])
    }

    /// I2: a track is what a listener hears: a buffer scheduled after the audio before it ended starts
    /// after that much silence; one scheduled earlier queues behind it with none.
    @Test func audioCollectorPadsTheSilenceOfTheScheduleTimeline() throws {
        let t0 = ContinuousClock.now
        func at(_ ms: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(ms)) }
        // 20 ms buffers at 0, 5 (queued: plays 20…40) and 100 ms (60 ms after the audio ends at 40).
        let buffers = [(at(0), Self.tone()), (at(5), Self.tone()), (at(100), Self.tone())]
        var collector = AudioCollector()
        collector.add(buffers, events: [Self.first(0, at: at(1))])
        let samples = try #require(collector.samples(seq: 0))
        let silence = 1_323   // 60 ms at 22.05 kHz
        #expect(samples.count == 3 * 441 + silence)
        #expect(samples[0..<882].allSatisfy { $0 != 0 })
        #expect(samples[882..<882 + silence].allSatisfy { $0 == 0 })
        #expect(samples[(882 + silence)...].allSatisfy { $0 != 0 })
    }

    /// I2, M3: a split sentence whose part 1 is an attempt of its own holds both parts in its file, with
    /// the handoff gap as silence; the gap is not a stream gap of the voice (the tracker restarts).
    @Test func audioCollectorKeepsALatePartInItsSentence() throws {
        let t0 = ContinuousClock.now
        func at(_ ms: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(ms)) }
        // Part 0 plays 0…20 ms; part 1 is scheduled at 200 ms (180 ms handoff gap), then seq 1.
        let buffers = [(at(0), Self.tone()), (at(200), Self.tone()), (at(1_000), Self.tone())]
        let events = [Self.first(0, at: at(1)), Self.part(0, at: at(201)), Self.first(1, at: at(1_001))]
        var collector = AudioCollector()
        collector.add(buffers, events: events)
        #expect(collector.frameCount(seq: 0) == 2 * 441 + 3_969)   // 180 ms of silence between the parts
        #expect(collector.playback(seq: 0) == .init(gapCount: 0, gapMs: 0))
        #expect(collector.partAudioPath(seq: 0) == nil)
        #expect(collector.frameCount(seq: 1) == 441)
    }

    /// I2: a part 1 coalesced ahead of the next sentence ([A1,B0]) is at the start of B's file, which
    /// the sentence's `partAudio` names.
    @Test func audioCollectorNamesTheFileOfACoalescedPart() throws {
        let t0 = ContinuousClock.now
        func at(_ ms: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(ms)) }
        let buffers = [(at(0), Self.tone()), (at(10), Self.tone()), (at(20), Self.tone())]
        let events = [Self.first(0, at: at(1)), Self.part(0, at: at(11)), Self.first(1, at: at(11))]
        var collector = AudioCollector()
        collector.add(buffers, events: events)
        #expect(collector.frameCount(seq: 0) == 441)
        #expect(collector.frameCount(seq: 1) == 2 * 441)
        #expect(collector.partAudioPath(seq: 0) == "audio/1.wav")
        #expect(collector.partAudioPath(seq: 1) == nil)
        let utterances = RawRun.Utterance.from(events, origin: t0, audio: collector.audioPath(seq:),
                                               partAudio: collector.partAudioPath(seq:))
        #expect(utterances.first { $0.seq == 0 }?.partAudio == "audio/1.wav")
    }

    // MARK: - Run settings

    /// REQ-CS-21: the split switch is written to `meta.settings`, so on and off runs stay apart.
    @Test(arguments: [true, false])
    func runSettingsRecordTheClauseSplit(on: Bool) {
        let options = BenchOptions(profile: .best, clauseSplit: on)
        let settings = BenchRunner.runSettings(pause: 0.6, listeningMode: "auto", options: options,
                                               voiceProfile: ["voiceProfileId": "x"])
        #expect(settings["clauseSplit"] == (on ? "1" : "0"))
        #expect(settings["pauseSeconds"] == "0.6")
        #expect(settings["voiceProfileId"] == "x")
    }

    // MARK: - Playback

    @Test func decodesUtteranceWithoutPlayback() throws {
        let json = #"{"seq":0,"events":{"speechStart":1},"detail":{}}"#
        let utterance = try JSONDecoder().decode(RawRun.Utterance.self, from: Data(json.utf8))
        #expect(utterance.playback == nil)
    }

    @Test func encodesPlayback() throws {
        let utterance = RawRun.Utterance(seq: 2, events: [:], detail: [:], audio: nil,
                                         playback: .init(gapCount: 2, gapMs: 300))
        let data = try BenchJSON.encoder().encode(utterance)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"gapCount\" : 2"))
        #expect(text.contains("\"gapMs\" : 300"))
        #expect(try JSONDecoder().decode(RawRun.Utterance.self, from: data) == utterance)
        // Without playback the key is omitted, so old goldens stay byte-identical.
        let plain = try BenchJSON.encoder().encode(RawRun.Utterance(seq: 0, events: [:], detail: [:], audio: nil))
        #expect(!String(decoding: plain, as: UTF8.self).contains("playback"))
    }

    @Test func audioCollectorMeasuresGapsPerAttempt() {
        let t0 = ContinuousClock.now
        func at(_ ms: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(ms)) }
        // 22.05 kHz: 2205 frames = 100 ms. Seq 0: chunks at 0 and 100 ms (back to back, no gap), then a
        // chunk at 500 ms after 200 ms of audio played out: one gap of 300 ms. Seq 1: one chunk, no gap.
        let buffers = [(at(10), Self.buffer(frames: 2205)), (at(110), Self.buffer(frames: 2205)),
                       (at(510), Self.buffer(frames: 2205)), (at(1000), Self.buffer(frames: 2205))]
        let events = [Self.first(0, at: at(11)), Self.first(1, at: at(1001))]
        var collector = AudioCollector()
        collector.add(buffers, events: events)
        #expect(collector.playback(seq: 0) == .init(gapCount: 1, gapMs: 300))
        #expect(collector.playback(seq: 1) == .init(gapCount: 0, gapMs: 0))
        #expect(collector.playback(seq: 2) == nil)
    }
}
