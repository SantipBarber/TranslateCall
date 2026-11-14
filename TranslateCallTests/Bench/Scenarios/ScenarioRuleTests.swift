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

    @Test func outgoingSpeechFails() {
        let recognizedOnly = seen([event(.outgoing, 0, .sttFinal, at: 1, ["text": "hola qué tal"])])
        let verdict = ScenarioRule.noOutgoingSpeech.check(recognizedOnly)
        #expect(verdict.passed)
        #expect(verdict.summary.contains("1 echo utterance(s) recognized"))
        let spoken = seen([event(.outgoing, 0, .sttFinal, at: 1, ["text": "hola qué tal"]),
                           event(.outgoing, 0, .ttsFirstBuffer, at: 2)])
        #expect(!ScenarioRule.noOutgoingSpeech.check(spoken).passed)
    }

    @Test func repeatedTranslationFails() {
        let once = seen([
            event(.incoming, 0, .translated, at: 1, ["text": "Hola."]),
            event(.incoming, 0, .ttsFirstBuffer, at: 2),
            event(.incoming, 1, .translated, at: 5, ["text": "Adiós."]),
            event(.incoming, 1, .ttsFirstBuffer, at: 6),
        ])
        #expect(ScenarioRule.spokenOnce(.incoming).check(once).passed)
        let twice = seen([
            event(.incoming, 0, .translated, at: 1, ["text": "Hola, amigo."]),
            event(.incoming, 0, .ttsFirstBuffer, at: 2),
            event(.incoming, 1, .translated, at: 5, ["text": "hola amigo"]),
            event(.incoming, 1, .ttsFirstBuffer, at: 6),
        ])
        let verdict = ScenarioRule.spokenOnce(.incoming).check(twice)
        #expect(!verdict.passed)
        #expect(verdict.summary.contains("repeated"))
    }

    @Test func moreAttemptsThanClipsFails() {
        let events = (0..<3).flatMap { seq in
            [event(.incoming, seq, .translated, at: Double(seq), ["text": "frase \(seq)"]),
             event(.incoming, seq, .ttsFirstBuffer, at: Double(seq) + 0.5)]
        }
        #expect(!ScenarioRule.spokenOnce(.incoming).check(seen(events, clips: 2)).passed)
        #expect(ScenarioRule.spokenOnce(.incoming).check(seen(events, clips: 3)).passed)
    }

    @Test func mergedSeqsCountAsOneAttempt() {
        let events = [
            event(.incoming, 0, .translated, at: 1, ["text": "uno"]),
            event(.incoming, 1, .translated, at: 1.2, ["text": "dos"]),
            event(.incoming, 0, .ttsFirstBuffer, at: 2),
            event(.incoming, 1, .ttsFirstBuffer, at: 2),
        ]
        #expect(ScenarioRule.spokenOnce(.incoming).check(seen(events, clips: 1)).passed)
    }

    @Test func splitSentenceCountsOnceOnItsWholeTranslation() {
        // Each sentence's `translated` carries part 0's text only; the sentence spoken is `translatedAll`.
        let split = seen([
            event(.incoming, 0, .translated, at: 1, ["text": "Hola", "parts": "2"]),
            event(.incoming, 0, .translatedAll, at: 1.1, ["text": "Hola, ¿cómo estás?"]),
            event(.incoming, 0, .ttsFirstBuffer, at: 2),
            event(.incoming, 0, .ttsPartBuffer, at: 3),
            event(.incoming, 1, .translated, at: 5, ["text": "Hola", "parts": "2"]),
            event(.incoming, 1, .translatedAll, at: 5.1, ["text": "Hola, ¿qué tal?"]),
            event(.incoming, 1, .ttsFirstBuffer, at: 6),
            event(.incoming, 1, .ttsPartBuffer, at: 7),
        ], clips: 2)
        #expect(ScenarioRule.spokenOnce(.incoming).check(split).passed)
    }

    // MARK: - Pauses (design §5.4)

    /// Clips of 4 s every 10 s from t = 0, each with its transcript.
    private func pauseSeen(_ events: [TraceEvent], transcripts: [String], paused: ClosedRange<Double>? = nil,
                           schedules: [Double] = []) -> ScenarioObservation {
        var seen = seen(events, clips: transcripts.count, schedules: schedules)
        seen.clips = transcripts.enumerated().map { index, text in
            ScenarioObservation.Clip(start: origin + .seconds(Double(index) * 10),
                                     end: origin + .seconds(Double(index) * 10 + 4), transcript: text)
        }
        seen.paused = paused.map { (origin + .seconds($0.lowerBound))..<(origin + .seconds($0.upperBound)) }
        return seen
    }

    /// One outgoing utterance: speech at `start`, recognized `text`, spoken (by `engine`) unless nil.
    private func utterance(_ seq: Int, at start: Double, _ text: String, engine: String? = "voiceClone")
        -> [TraceEvent] {
        var events = [event(.outgoing, seq, .speechStart, at: start),
                      event(.outgoing, seq, .sttFinal, at: start + 1, ["text": text]),
                      event(.outgoing, seq, .translated, at: start + 1.2, ["text": "t\(seq)"])]
        if let engine { events.append(event(.outgoing, seq, .ttsFirstBuffer, at: start + 2, ["engine": engine])) }
        return events
    }

    @Test func aCutClipBreaksOnePiece() {
        let whole = pauseSeen(utterance(0, at: 0.2, "uno dos") + utterance(1, at: 10.1, "tres cuatro"),
                              transcripts: ["uno dos", "tres cuatro"])
        #expect(ScenarioRule.piecesPerClip(1...1).check(whole).passed)
        let cut = pauseSeen(utterance(0, at: 0.2, "uno") + utterance(1, at: 2, "dos")
                            + utterance(2, at: 10.1, "tres cuatro"),
                            transcripts: ["uno dos", "tres cuatro"])
        let verdict = ScenarioRule.piecesPerClip(1...1).check(cut)
        #expect(!verdict.passed)
        #expect(verdict.summary.contains("2 1"))
        #expect(ScenarioRule.piecesPerClip(1...2).check(cut).passed)
    }

    @Test func aClipWithNothingSpokenBreaksPieces() {
        let lost = pauseSeen(utterance(0, at: 0.2, "uno dos", engine: nil) + utterance(1, at: 10.1, "tres cuatro"),
                             transcripts: ["uno dos", "tres cuatro"])
        #expect(!ScenarioRule.piecesPerClip(1...2).check(lost).passed)
    }

    @Test func lostWordsBreakWordsKept() {
        let transcripts = ["Uno, dos, tres y cuatro.", "Cinco seis siete ocho"]
        let kept = pauseSeen(utterance(0, at: 0.2, "uno dos") + utterance(1, at: 2, "tres y cuatro")
                             + utterance(2, at: 10.1, "cinco seis siete ocho"), transcripts: transcripts)
        #expect(ScenarioRule.wordsKept(minRecall: 0.85).check(kept).passed)
        // The second piece was recognized but never spoken: its words did not reach the other side.
        let lost = pauseSeen(utterance(0, at: 0.2, "uno dos") + utterance(1, at: 2, "tres y cuatro", engine: nil)
                             + utterance(2, at: 10.1, "cinco seis siete ocho"), transcripts: transcripts)
        let verdict = ScenarioRule.wordsKept(minRecall: 0.85).check(lost)
        #expect(!verdict.passed)
        #expect(verdict.summary.contains("67%"))   // 6 of 9 words
        #expect(verdict.summary.contains("#0 40%"))
    }

    @Test func outgoingRepeatsBreakSpokenOnce() {
        let events = [
            event(.outgoing, 0, .translated, at: 1, ["text": "Hello."]),
            event(.outgoing, 0, .ttsFirstBuffer, at: 2),
            event(.outgoing, 1, .translated, at: 5, ["text": "hello"]),
            event(.outgoing, 1, .ttsFirstBuffer, at: 6),
        ]
        #expect(ScenarioRule.spokenOnce(.incoming).check(seen(events)).passed)
        #expect(!ScenarioRule.spokenOnce(.outgoing).check(seen(events)).passed)
    }

    @Test func piecesPerClipRaiseTheAttemptLimit() {
        let events = (0..<4).flatMap { seq in
            [event(.outgoing, seq, .translated, at: Double(seq), ["text": "frase \(seq)"]),
             event(.outgoing, seq, .ttsFirstBuffer, at: Double(seq) + 0.5)]
        }
        #expect(!ScenarioRule.spokenOnce(.outgoing).check(seen(events, clips: 2)).passed)
        #expect(ScenarioRule.spokenOnce(.outgoing, perClip: 2).check(seen(events, clips: 2)).passed)
    }

    @Test func audioWhilePausedFails() {
        let quiet = pauseSeen([], transcripts: [], paused: 5...6, schedules: [4.9, 5.04, 6.2])
        #expect(ScenarioRule.noAudioWhilePaused.check(quiet).passed)
        let loud = pauseSeen([], transcripts: [], paused: 5...6, schedules: [5.5])
        #expect(!ScenarioRule.noAudioWhilePaused.check(loud).passed)
        #expect(!ScenarioRule.noAudioWhilePaused.check(pauseSeen([], transcripts: [])).passed)   // never paused
    }

    @Test func theCloneMustComeBackAfterTheResume() {
        let transcripts = ["a", "b", "c"]
        let back = pauseSeen(utterance(0, at: 0.2, "a") + utterance(1, at: 10.1, "b", engine: "avSpeech")
                             + utterance(2, at: 20.1, "c"), transcripts: transcripts, paused: 5...6)
        let verdict = ScenarioRule.cloneAfterResume.check(back)
        #expect(verdict.passed)
        #expect(verdict.summary.contains("avSpeech → voiceClone"))
        let stuck = pauseSeen(utterance(0, at: 0.2, "a") + utterance(1, at: 10.1, "b", engine: "avSpeech")
                              + utterance(2, at: 20.1, "c", engine: "avSpeech"), transcripts: transcripts, paused: 5...6)
        #expect(!ScenarioRule.cloneAfterResume.check(stuck).passed)
        let lost = pauseSeen(utterance(0, at: 0.2, "a") + utterance(1, at: 10.1, "b", engine: nil)
                             + utterance(2, at: 20.1, "c"), transcripts: transcripts, paused: 5...6)
        #expect(!ScenarioRule.cloneAfterResume.check(lost).passed)
    }

    @Test func innerPauseGoesIntoTheWordGapNearestTheMiddle() throws {
        // Speech from 1000 to 9000 samples (middle 5000), word gaps at 2000, 5600 and 8000; a quieter
        // stretch at 4000..<4320 that is not a word gap (a consonant inside a word).
        var samples = [Float](repeating: 0, count: 10_000)
        for index in 1000..<9000 { samples[index] = index % 2 == 0 ? 0.3 : -0.3 }
        for index in 4000..<4320 { samples[index] = 0.001 }
        let shaped = ScenarioClipShape.innerPause(seconds: 0.25)
            .apply(samples, speech: 1000..<9000, rate: 16_000, wordGaps: [2000, 5600, 8000, 9500])
        #expect(shaped.count == 10_000 + 4000)
        #expect(shaped[5600..<9600].allSatisfy { $0 == 0 })
        #expect(shaped[5599] != 0 && shaped[9600] != 0)
    }

    @Test func innerPauseGoesIntoTheQuietestGap() throws {
        // Speech from 1000 to 9000 samples with a quiet stretch at 5000..<5320; 16 kHz.
        var samples = [Float](repeating: 0, count: 10_000)
        for index in 1000..<9000 { samples[index] = index % 2 == 0 ? 0.3 : -0.3 }
        for index in 5000..<5320 { samples[index] = 0.001 }
        let shaped = ScenarioClipShape.innerPause(seconds: 0.25)
            .apply(samples, speech: 1000..<9000, rate: 16_000)
        #expect(shaped.count == 10_000 + 4000)
        let inserted = try #require(shaped.indices.first { $0 > 1000 && shaped[$0] == 0 })
        #expect((5000..<5320).contains(inserted))
        #expect(shaped[inserted..<(inserted + 4000)].allSatisfy { $0 == 0 })
    }

    @Test func lateBufferBreaksQuiet() {
        let rule = ScenarioRule.quietAfter(.seconds(12))
        #expect(rule.check(seen([], schedules: [11, 21.9])).passed)
        let verdict = rule.check(seen([], schedules: [11, 22.5]))
        #expect(!verdict.passed)
        #expect(verdict.summary.contains("12.5"))
    }
}

@Suite("Pitch estimator")
struct PitchEstimatorTests {
    /// A voice-like tone: fundamental plus decaying harmonics.
    private func tone(_ hz: Double, rate: Double = 24_000, seconds: Double = 0.5) -> [Float] {
        (0..<Int(rate * seconds)).map { index in
            let time = Double(index) / rate
            return Float((1...5).reduce(0.0) { $0 + sin(2 * .pi * hz * Double($1) * time) / Double($1) } * 0.3)
        }
    }

    @Test(arguments: [85.0, 95.0, 110.0, 180.0])
    func findsTheFundamental(_ hz: Double) throws {
        let f0 = try #require(PitchEstimator.medianF0(tone(hz), rate: 24_000))
        #expect(abs(f0 / hz - 1) < 0.02, "\(f0) Hz for \(hz) Hz")
    }

    @Test func silenceHasNoPitch() {
        #expect(PitchEstimator.medianF0([Float](repeating: 0, count: 24_000), rate: 24_000) == nil)
    }

    @Test func pitchRuleFlagsAHighSentence() {
        var seen = ScenarioObservation(events: [], clipCount: 3, lastClipEnd: .now, scheduleTimes: [])
        seen.referenceF0 = 92
        seen.outgoingF0 = [0: 90, 1: 96, 2: 108]
        let verdict = ScenarioRule.pitchNearReference(tolerance: 0.12).check(seen)
        #expect(!verdict.passed)
        #expect(verdict.summary.contains("#2 108 Hz"))
        seen.outgoingF0[2] = 100
        #expect(ScenarioRule.pitchNearReference(tolerance: 0.12).check(seen).passed)
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

    @Test func drainingKeepsTheScheduleTimes() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1,
                                                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        buffer.frameLength = 240
        let output = BenchOutput()
        _ = try output.schedule(buffer)
        #expect(output.drain().count == 1)
        #expect(output.drain().isEmpty)
        #expect(output.scheduleTimes.count == 1)   // quietAfter and noAudioWhilePaused read these
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
