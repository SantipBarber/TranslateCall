import AVFoundation
import Testing
@testable import TranslateCall

/// Energy VAD early processing: a tentative segment at 0.2 s of silence, then commit or retract
/// (REQ-QS-40/43/44). Synthetic 16 kHz buffers, no audio device and no fixed sleeps: each test
/// waits for the last "speech ended" event, then ends the output streams and reads them whole.
@Suite(.serialized)
@MainActor
struct EnergyVADTentativeTests {

    private struct Emitted: Equatable {
        let kind: SegmentKind
        let id: UInt64
        let seconds: Double
    }

    private static let sampleRate = 16_000
    private static let bufferSamples = 1_600   // 0.1 s per buffer

    @Test func tentativeThenCommit() async throws {
        let audio = Self.tone(1.0) + Self.silence(0.7)
        let (segments, boundaries) = try await Self.run(audio)
        #expect(segments.map(\.kind) == [.tentative])
        #expect(segments.map(\.id) == [1])
        #expect(boundaries == [.commit(1)])
    }

    @Test func hesitation() async throws {
        let audio = Self.tone(1.0) + Self.silence(0.3) + Self.tone(1.0) + Self.silence(0.7)
        let (segments, boundaries) = try await Self.run(audio)
        #expect(segments.map(\.kind) == [.tentative, .tentative])
        #expect(segments.map(\.id) == [1, 2])
        #expect(boundaries == [.retract(1), .commit(2)])
        #expect((segments.last?.seconds ?? 0) >= 2.2, "the second tentative covers the whole utterance")
    }

    @Test func maxDurationForces() async throws {
        var config = VADConfiguration()
        config.maxSpeechDuration = 1
        let (segments, boundaries) = try await Self.run(Self.tone(1.5), config: config)
        #expect(!segments.isEmpty)
        #expect(segments.allSatisfy { $0.kind == .final })
        #expect(abs((segments.first?.seconds ?? 0) - 1.0) < 0.01, "first segment is the force-emit")
        #expect(boundaries.isEmpty)
    }

    // MARK: - Helpers

    /// Feeds `samples` in 0.1 s buffers, waits for the last speech-end event, then drains the streams.
    private static func run(
        _ samples: [Float], config: VADConfiguration = .default
    ) async throws -> ([Emitted], [SegmentBoundary]) {
        let vad = EnergyVADService(config: config)
        let states = vad.vadStateEvents
        try await vad.activate(stream: stream(of: samples))
        for await active in states where !active { break }
        await vad.finishStreams()
        var segments: [Emitted] = []
        for await segment in vad.speechSegments {
            let seconds = Double(segment.audio.frameLength) / segment.audio.format.sampleRate
            segments.append(Emitted(kind: segment.kind, id: segment.id, seconds: seconds))
        }
        var boundaries: [SegmentBoundary] = []
        for await boundary in vad.boundaryEvents { boundaries.append(boundary) }
        await vad.deactivate()
        return (segments, boundaries)
    }

    private static func stream(of samples: [Float]) -> AsyncStream<AVAudioPCMBuffer> {
        let buffers = stride(from: 0, to: samples.count, by: bufferSamples).map { start in
            buffer(Array(samples[start..<min(start + bufferSamples, samples.count)]))
        }
        return AsyncStream { continuation in
            buffers.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    private static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        return buffer
    }

    /// 440 Hz sine at −20 dBFS RMS (amplitude 0.1·√2).
    private static func tone(_ seconds: Double) -> [Float] {
        let amplitude = Float(0.1 * 2.0.squareRoot())
        return (0..<Int(seconds * Double(sampleRate))).map { index in
            amplitude * sin(2 * Float.pi * 440 * Float(index) / Float(sampleRate))
        }
    }

    private static func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * Double(sampleRate)))
    }
}
