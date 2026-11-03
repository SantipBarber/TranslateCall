import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

@Suite("Scenario rules")
struct ScenarioRuleTests {
    private let origin = ContinuousClock.now

    private func event(_ direction: TraceDirection, _ seq: Int, _ stage: TraceStage, at seconds: Double,
                       _ detail: [String: String] = [:]) -> TraceEvent {
        TraceEvent(direction: direction, seq: seq, stage: stage, time: origin + .seconds(seconds), detail: detail)
    }

    private func seen(_ events: [TraceEvent], clips: Int = 2, schedules: [Double] = []) -> ScenarioObservation {
        ScenarioObservation(events: events, clipCount: clips, lastClipEnd: origin + .seconds(10),
                            scheduleTimes: schedules.map { origin + .seconds($0) })
    }

    @Test func echoRecognizedOutgoingFails() {
        let quiet = seen([event(.outgoing, 0, .sttFinal, at: 1, ["text": "  "])])
        #expect(ScenarioRule.noOutgoingFromEcho.check(quiet).passed)
        let echo = seen([event(.outgoing, 0, .sttFinal, at: 1, ["text": "hola qué tal"])])
        let verdict = ScenarioRule.noOutgoingFromEcho.check(echo)
        #expect(!verdict.passed)
        #expect(verdict.summary.contains("hola qué tal"))
    }

    @Test func repeatedTranslationFails() {
        let once = seen([
            event(.incoming, 0, .translated, at: 1, ["text": "Hola."]),
            event(.incoming, 0, .ttsFirstBuffer, at: 2),
            event(.incoming, 1, .translated, at: 5, ["text": "Adiós."]),
            event(.incoming, 1, .ttsFirstBuffer, at: 6),
        ])
        #expect(ScenarioRule.spokenOnce.check(once).passed)
        let twice = seen([
            event(.incoming, 0, .translated, at: 1, ["text": "Hola, amigo."]),
            event(.incoming, 0, .ttsFirstBuffer, at: 2),
            event(.incoming, 1, .translated, at: 5, ["text": "hola amigo"]),
            event(.incoming, 1, .ttsFirstBuffer, at: 6),
        ])
        let verdict = ScenarioRule.spokenOnce.check(twice)
        #expect(!verdict.passed)
        #expect(verdict.summary.contains("repeated"))
    }

    @Test func moreAttemptsThanClipsFails() {
        let events = (0..<3).flatMap { seq in
            [event(.incoming, seq, .translated, at: Double(seq), ["text": "frase \(seq)"]),
             event(.incoming, seq, .ttsFirstBuffer, at: Double(seq) + 0.5)]
        }
        #expect(!ScenarioRule.spokenOnce.check(seen(events, clips: 2)).passed)
        #expect(ScenarioRule.spokenOnce.check(seen(events, clips: 3)).passed)
    }

    @Test func mergedSeqsCountAsOneAttempt() {
        let events = [
            event(.incoming, 0, .translated, at: 1, ["text": "uno"]),
            event(.incoming, 1, .translated, at: 1.2, ["text": "dos"]),
            event(.incoming, 0, .ttsFirstBuffer, at: 2),
            event(.incoming, 1, .ttsFirstBuffer, at: 2),
        ]
        #expect(ScenarioRule.spokenOnce.check(seen(events, clips: 1)).passed)
    }

    @Test func lateBufferBreaksQuiet() {
        let rule = ScenarioRule.quietAfter(.seconds(12))
        #expect(rule.check(seen([], schedules: [11, 21.9])).passed)
        let verdict = rule.check(seen([], schedules: [11, 22.5]))
        #expect(!verdict.passed)
        #expect(verdict.summary.contains("12.5"))
    }
}

@Suite("Bench echo path")
struct BenchEchoPathTests {
    @Test func resamplesToSixteenKilohertz() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1,
                                                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400))
        buffer.frameLength = 2400
        for index in 0..<2400 { buffer.floatChannelData?[0][index] = 0.5 }
        let samples = BenchOutput.mono16k(buffer)
        #expect(samples.count == 1600)
        #expect(samples.allSatisfy { abs($0 - 0.5) < 1e-6 })
    }

    @Test func mixedSoundReachesTheStream() async throws {
        let player = BenchClipPlayer()
        var stream = player.start().makeAsyncIterator()
        _ = await stream.next()   // the stream is running
        player.mix(Array(repeating: 0.25, count: 2048), at: .now)
        var heard: Float = 0
        for _ in 0..<6 {
            guard let buffer = await stream.next(), let data = buffer.floatChannelData?[0] else { break }
            heard = max(heard, (0..<Int(buffer.frameLength)).map { data[$0] }.max() ?? 0)
        }
        player.stop()
        #expect(abs(heard - 0.25) < 1e-6)
    }

    @Test func truncatedMixIsNotHeard() async throws {
        let player = BenchClipPlayer()
        var stream = player.start().makeAsyncIterator()
        _ = await stream.next()
        player.mix(Array(repeating: 0.25, count: 16_000), at: .now + .seconds(0.3))
        player.truncateMix(from: .now)
        var heard: Float = 0
        for _ in 0..<8 {
            guard let buffer = await stream.next(), let data = buffer.floatChannelData?[0] else { break }
            heard = max(heard, (0..<Int(buffer.frameLength)).map { data[$0] }.max() ?? 0)
        }
        player.stop()
        #expect(heard == 0)
    }
}
