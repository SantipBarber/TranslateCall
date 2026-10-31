import Foundation
import Synchronization
import Testing
@testable import TranslateCall

/// M9 REQ-BH-10…13, design §2.1: order-based correlation of one direction's stages.
@Suite("PipelineTracer")
struct PipelineTracerTests {
    /// A manual clock: every stamp is `origin + offset`, offsets set by the test.
    final class ManualNow: Sendable {
        let origin = ContinuousClock.now
        private let offset = Mutex(Duration.zero)
        func advance(_ delta: Duration) { offset.withLock { $0 += delta } }
        var now: ContinuousClock.Instant { origin + offset.withLock { $0 } }
    }

    let sink = CollectingTraceSink()
    let clock = ManualNow()
    let date0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func makeTracer() -> PipelineTracer {
        let clock = clock
        return PipelineTracer(direction: .outgoing, sink: sink, trailingSilence: .milliseconds(600),
                              now: { clock.now }, originDate: date0)
    }

    @Test func fullUtteranceInOrder() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1.5)
        tracer.transcribed(capturedAt: date0, text: "hola", engine: "AppleSpeechService", confidence: 0.9)
        tracer.translated(source: "hola", result: "hello")
        tracer.speakRequested(text: "hello")
        tracer.synthesisStarted(text: "hello", engine: "x")
        tracer.bufferScheduled()
        tracer.synthesisFinished()
        #expect(sink.stages(of: 0) == [.speechStart, .vadEnd, .sttFinal, .translated, .ttsFirstBuffer, .ttsEnd])
        #expect(sink.event(0, .ttsFirstBuffer)?.detail == ["engine": "x"])
        #expect(tracer.openSeqs.isEmpty)
    }

    @Test func vadEndCarriesSegmentAndTrailingSilence() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1.5)
        #expect(sink.event(0, .vadEnd)?.detail == ["segmentAudioMs": "1500", "trailingSilenceMs": "600"])
    }

    @Test func speechStartMapsTheSegmentDateOntoTheClock() {
        clock.advance(.seconds(3))
        let tracer = makeTracer()   // origin: date0 ↔ clock at +3 s
        tracer.segmentClosed(capturedAt: date0.addingTimeInterval(-1.5), audioSeconds: 1)
        let start = try? #require(sink.event(0, .speechStart)).time
        #expect(start == clock.origin + .milliseconds(1_500))
    }

    @Test func segmentWithoutTranscriptIsDroppedWhenALaterOneIsTranscribed() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1)
        tracer.segmentClosed(capturedAt: date0.addingTimeInterval(2), audioSeconds: 1)
        tracer.transcribed(capturedAt: date0.addingTimeInterval(2), text: "b", engine: "x", confidence: 1)
        #expect(sink.event(0, .dropped)?.detail["reason"] == "stt-empty")
        #expect(sink.event(1, .sttFinal)?.detail["text"] == "b")
    }

    @Test func emptyTranscriptEndsTheUtterance() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1)
        tracer.transcribed(capturedAt: date0, text: "", engine: "x", confidence: 1)
        #expect(sink.event(0, .dropped)?.detail["reason"] == "empty-text")
        #expect(tracer.openSeqs.isEmpty)
    }

    @Test func translationFailureDropsWithTheError() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1)
        tracer.transcribed(capturedAt: date0, text: "a", engine: "x", confidence: 1)
        tracer.translationFailed(source: "a", error: TranslationError.timedOut)
        #expect(sink.event(0, .dropped)?.detail["reason"]?.hasPrefix("translate-") == true)
    }

    @Test func mergedSynthesisStampsEveryUtterance() {
        let tracer = makeTracer()
        for (index, text) in ["one", "two"].enumerated() {
            let date = date0.addingTimeInterval(Double(index))
            tracer.segmentClosed(capturedAt: date, audioSeconds: 1)
            tracer.transcribed(capturedAt: date, text: text, engine: "x", confidence: 1)
            tracer.translated(source: text, result: text.uppercased())
            tracer.speakRequested(text: text.uppercased())
        }
        tracer.synthesisStarted(text: "ONE TWO", engine: "x")
        tracer.bufferScheduled()
        #expect(sink.event(0, .ttsFirstBuffer)?.detail["mergedSeqs"] == "0,1")
        #expect(sink.event(1, .ttsFirstBuffer)?.detail["mergedSeqs"] == "0,1")
    }

    @Test func fallbackRetryOnTheSameTextKeepsTheAttempt() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1)
        tracer.transcribed(capturedAt: date0, text: "a", engine: "x", confidence: 1)
        tracer.translated(source: "a", result: "A")
        tracer.speakRequested(text: "A")
        tracer.synthesisStarted(text: "A", engine: "x")
        tracer.synthesisFinished()          // primary failed, no audio
        tracer.synthesisStarted(text: "A", engine: "y")  // fallback
        tracer.bufferScheduled()
        tracer.synthesisFinished()
        #expect(sink.event(0, .ttsFirstBuffer)?.detail["engine"] == "y")
        #expect(sink.stages(of: 0).suffix(2) == [.ttsFirstBuffer, .ttsEnd])
    }

    @Test func bufferScheduledAfterTheSynthesizerFinishedStillCounts() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1)
        tracer.transcribed(capturedAt: date0, text: "a", engine: "x", confidence: 1)
        tracer.translated(source: "a", result: "A")
        tracer.speakRequested(text: "A")
        tracer.synthesisStarted(text: "A", engine: "x")
        tracer.synthesisFinished()   // the stream ended before the consumer scheduled its buffers
        tracer.bufferScheduled()
        #expect(sink.stages(of: 0).suffix(2) == [.ttsFirstBuffer, .ttsEnd])
    }

    @Test func retractedUtteranceForgotten() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1, id: 1)
        tracer.segmentRetracted(id: 1)
        #expect(tracer.openSeqs.isEmpty)
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 2, id: 2)   // same utterance, longer tentative
        tracer.transcribed(capturedAt: date0, text: "hola", engine: "x", confidence: 1, segmentID: 2)
        #expect(sink.stages(of: 0) == [.speechStart, .vadEnd, .retracted])
        #expect(sink.stages(of: 1) == [.speechStart, .vadEnd, .sttFinal])
        #expect(sink.event(1, .sttFinal)?.detail["text"] == "hola")
    }

    @Test func lateResultOfARetractedSegmentIsIgnored() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1, id: 1)
        tracer.segmentRetracted(id: 1)
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 2, id: 2)
        tracer.transcribed(capturedAt: date0, text: "hola", engine: "x", confidence: 1, segmentID: 1)
        tracer.transcribed(capturedAt: date0, text: "hola mundo", engine: "x", confidence: 1, segmentID: 2)
        tracer.translated(source: "hola mundo", result: "hello world")
        #expect(sink.event(1, .sttFinal)?.detail["text"] == "hola mundo")
        #expect(sink.stages(of: 1) == [.speechStart, .vadEnd, .sttFinal, .translated])
        #expect(sink.stages(of: 0) == [.speechStart, .vadEnd, .retracted])
    }

    @Test func retractAfterTheNextSegmentClosedHitsTheRightOne() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1, id: 1)
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 2, id: 2)   // the final, same capturedAt
        tracer.segmentRetracted(id: 1)
        #expect(sink.stages(of: 0) == [.speechStart, .vadEnd, .retracted])
        #expect(sink.stages(of: 1) == [.speechStart, .vadEnd])
        #expect(tracer.openSeqs == [1])
    }

    @Test func boundaryBeforeItsSegmentIsApplied() {
        let tracer = makeTracer()
        tracer.segmentRetracted(id: 5)
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1, id: 5)
        #expect(sink.stages(of: 0) == [.speechStart, .vadEnd, .retracted])
        #expect(tracer.openSeqs.isEmpty)
    }

    /// G3 M1: a boundary for a segment that already ended (empty text) is not kept, so a rebuilt VAD
    /// reusing the id under the same tracer does not get it.
    @Test func staleBoundaryOfAFinishedSegmentIsNotKept() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1, id: 1)
        tracer.transcribed(capturedAt: date0, text: "", engine: "x", confidence: 0, segmentID: 1)   // dropped
        tracer.segmentRetracted(id: 1)                                     // late: its utterance is gone
        tracer.segmentClosed(capturedAt: date0 + 5, audioSeconds: 1, id: 1)   // rebuilt VAD, same id
        #expect(sink.stages(of: 1) == [.speechStart, .vadEnd])
        #expect(tracer.openSeqs == [1])
    }

    /// G3 M1: after a rebuild the ids start again, and an early boundary of the new VAD still applies.
    @Test func earlyBoundaryAfterAVADRebuildStillApplies() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1, id: 7)
        tracer.closeOpen(reason: "stop")
        tracer.segmentClosed(capturedAt: date0 + 5, audioSeconds: 1, id: 1)   // rebuilt VAD
        tracer.segmentCommitted(id: 2)                                          // before its segment
        tracer.segmentClosed(capturedAt: date0 + 6, audioSeconds: 1, id: 2)
        #expect(sink.stages(of: 2) == [.speechStart, .vadEnd, .committed])
    }

    /// G3 M1: `closeOpen` forgets boundaries still waiting for their segment.
    @Test func closeOpenForgetsEarlyBoundaries() {
        let tracer = makeTracer()
        tracer.segmentRetracted(id: 9)
        tracer.closeOpen(reason: "stop")
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1, id: 9)
        #expect(sink.stages(of: 0) == [.speechStart, .vadEnd])
        #expect(tracer.openSeqs == [0])
    }

    @Test func committedStamped() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1, id: 3)
        tracer.segmentCommitted(id: 3)
        tracer.transcribed(capturedAt: date0, text: "hola", engine: "x", confidence: 1, segmentID: 3)
        #expect(sink.stages(of: 0) == [.speechStart, .vadEnd, .committed, .sttFinal])
        #expect(tracer.openSeqs == [0])
    }

    @Test func closeOpenDropsWhatIsLeft() {
        let tracer = makeTracer()
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1)
        tracer.closeOpen(reason: "idle-timeout")
        #expect(sink.event(0, .dropped)?.detail["reason"] == "idle-timeout")
        #expect(tracer.openSeqs.isEmpty)
    }

    private func terminalCount(_ seq: Int) -> Int {
        sink.stages(of: seq).filter { $0 == .dropped || $0 == .ttsEnd }.count
    }

    private func closeMidSynthesis(_ tracer: PipelineTracer) {
        tracer.segmentClosed(capturedAt: date0, audioSeconds: 1)
        tracer.transcribed(capturedAt: date0, text: "a", engine: "x", confidence: 1)
        tracer.translated(source: "a", result: "A")
        tracer.speakRequested(text: "A")
        tracer.synthesisStarted(text: "A", engine: "x")
        tracer.closeOpen(reason: "idle-timeout")
        tracer.synthesisFinished()
    }

    @Test func lateBufferAfterCloseOpenAddsNoSecondTerminalEvent() {
        let tracer = makeTracer()
        closeMidSynthesis(tracer)
        tracer.bufferScheduled()
        #expect(terminalCount(0) == 1)
        #expect(sink.stages(of: 0).last == .dropped)
    }

    @Test func nextSynthesisAfterCloseOpenAddsNoSecondTerminalEvent() {
        let tracer = makeTracer()
        closeMidSynthesis(tracer)
        tracer.synthesisStarted(text: "B", engine: "x")
        #expect(terminalCount(0) == 1)
    }

    @Test func overheadPerEventIsUnder50Microseconds() {
        let tracer = PipelineTracer(direction: .outgoing, sink: NoopTraceSink(), trailingSilence: .milliseconds(600))
        let start = ContinuousClock.now
        for index in 0..<2_000 {   // 5 events per utterance → 10 000 events
            let date = Date(timeIntervalSinceReferenceDate: Double(index))
            tracer.segmentClosed(capturedAt: date, audioSeconds: 1)
            tracer.transcribed(capturedAt: date, text: "t\(index)", engine: "x", confidence: 1)
            tracer.translated(source: "t\(index)", result: "T\(index)")
            tracer.closeOpen(reason: "x")
        }
        let perEvent = start.duration(to: .now) / 10_000
        #expect(perEvent < .microseconds(50), "\(perEvent) per event")
    }
}
