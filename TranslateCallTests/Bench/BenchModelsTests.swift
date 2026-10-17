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
}
