import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

// MARK: - STTSegmentTaggingTests

/// Every STT result is tagged with its segment's id and kind (FR-QS.5, P4).
@Suite("STT segment tagging")
@MainActor
struct STTSegmentTaggingTests {

    private func makeSegment(id: UInt64, kind: SegmentKind, frames: Int = 16_000) -> SpeechSegment {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 16)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        if frames > 0 { buffer.floatChannelData![0].initialize(repeating: 0.01, count: frames) }
        return SpeechSegment(audio: buffer, capturedAt: Date(), id: id, kind: kind)
    }

    /// Runs one segment through a Parakeet service backed by `mock` and returns the first result.
    private func firstResult(
        for segment: SpeechSegment, mock: MockAsrTranscriber
    ) async throws -> TranscriptionResult? {
        let service = ParakeetSpeechService(
            locale: Locale(identifier: "en-US"), config: .default, transcriberFactory: { mock }
        )
        let collector = Task { () -> TranscriptionResult? in
            for await result in service.transcriptionStream { return result }
            return nil
        }
        try await service.activate(stream: AsyncStream { cont in
            cont.yield(segment)
            cont.finish()
        })
        let result = await collector.value
        await service.deactivate()
        return result
    }

    @Test("empty(for:locale:) carries the segment id and kind")
    func emptyResultCarriesSegment() {
        let segment = makeSegment(id: 7, kind: .tentative)
        let locale = Locale(identifier: "es-ES")
        let result = TranscriptionResult.empty(for: segment, locale: locale)
        #expect(result.segmentID == 7)
        #expect(result.kind == .tentative)
        #expect(result.text.isEmpty)
        #expect(result.confidence == 0)
        #expect(result.locale == locale)
        #expect(result.capturedAt == segment.capturedAt)
    }

    @Test("a Parakeet result copies segmentID and kind from its segment")
    func tagsPassThrough() async throws {
        let mock = MockAsrTranscriber()
        await mock.stubResult(text: "hello", confidence: 0.95)
        let result = try await firstResult(for: makeSegment(id: 5, kind: .tentative), mock: mock)
        #expect(result?.text == "hello")
        #expect(result?.segmentID == 5)
        #expect(result?.kind == .tentative)
    }

    @Test("a segment with no usable audio still yields one empty result")
    func noResultStillYieldsEmpty() async throws {
        let mock = MockAsrTranscriber()
        let result = try await firstResult(for: makeSegment(id: 3, kind: .final, frames: 0), mock: mock)
        #expect(result != nil)
        #expect(result?.text.isEmpty == true)
        #expect(result?.segmentID == 3)
        #expect(result?.kind == .final)
    }

    @Test("a low-confidence segment yields an empty tagged result")
    func lowConfidenceYieldsEmpty() async throws {
        let mock = MockAsrTranscriber()
        await mock.stubResult(text: "unclear", confidence: 0.1)
        let result = try await firstResult(for: makeSegment(id: 9, kind: .tentative), mock: mock)
        #expect(result?.text.isEmpty == true)
        #expect(result?.segmentID == 9)
        #expect(result?.kind == .tentative)
    }

    @Test("a recognition error yields an empty tagged result")
    func errorYieldsEmpty() async throws {
        let mock = MockAsrTranscriber()
        await mock.stubError(NSError(domain: "test", code: 1))
        let result = try await firstResult(for: makeSegment(id: 11, kind: .final), mock: mock)
        #expect(result?.text.isEmpty == true)
        #expect(result?.segmentID == 11)
    }
}
