import AVFoundation
import Synchronization
import Testing
@testable import TranslateCall

/// When a segment reached the consumer, and how long it was.
struct SegmentArrival: Sendable {
    let at: ContinuousClock.Instant
    let frames: Int
}

/// Spliced speech fixtures, fed at real-time pace (F8.5.3 NFR-H-01/02, AC 3).
private enum SplicedSpeech {
    static let rate = 16_000.0
    static let chunk = 1_024

    /// The fixture's speech without the silence `say` puts around it.
    static func speech(_ id: String) throws -> [Float] {
        let fixture = try #require(try Fixtures.all().first { $0.id == id })
        let samples = try FileAudioSource.decode16kMono(Fixtures.url(for: fixture))
        let first = samples.firstIndex { abs($0) > 0.01 } ?? 0
        let last = samples.lastIndex { abs($0) > 0.01 } ?? samples.count - 1
        return Array(samples[first...last])
    }

    static func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * rate))
    }

    static func seconds(_ samples: Int) -> Duration {
        .seconds(Double(samples) / rate)
    }

    /// Streams `samples` as 1 024-sample 16 kHz buffers at wall-clock pace, starting now.
    /// `beforeBuffer` runs before each buffer with the sample offset it starts at.
    static func paced(_ samples: [Float], beforeBuffer: @escaping @Sendable (Int) -> Void = { _ in })
        -> (stream: AsyncStream<AVAudioPCMBuffer>, start: ContinuousClock.Instant, feeder: Task<Void, Never>) {
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self, bufferingPolicy: .unbounded)
        let start = ContinuousClock.now
        let feeder = Task.detached {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                             channels: 1, interleaved: false) else { return }
            for offset in stride(from: 0, to: samples.count, by: chunk) {
                let count = min(chunk, samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let data = buffer.floatChannelData?[0] else { break }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { src in
                    if let base = src.baseAddress { data.update(from: base + offset, count: count) }
                }
                beforeBuffer(offset)
                continuation.yield(buffer)
                try? await Task.sleep(until: start + seconds(offset + count))
            }
            continuation.finish()
        }
        return (stream, start, feeder)
    }
}

extension IntegrationTests {
    @Suite("Silero segmentation", .serialized) @MainActor
    struct SileroSegmentationTests {

        func makeSilero(pause: Double) async throws -> SileroVADService {
            var config = VADConfiguration()
            config.minSilenceDuration = pause
            do {
                return try await SileroVADService(config: config)
            } catch {
                try requirePrerequisite(false, "Silero VAD model (FluidAudio download): \(error)")
                throw error
            }
        }

        /// Runs `vad` over `audio` and returns the segments that arrived, once no more are coming.
        func segments(of audio: [Float], through vad: SileroVADService, expecting count: Int,
                      gate: MicEchoGate? = nil,
                      beforeBuffer: @escaping @Sendable (Int) -> Void = { _ in })
            async throws -> (arrivals: [SegmentArrival], start: ContinuousClock.Instant) {
            let arrivals = Mutex<[SegmentArrival]>([])
            let collector = Task {
                for await segment in vad.speechSegments {
                    let arrival = SegmentArrival(at: .now, frames: Int(segment.audio.frameLength))
                    arrivals.withLock { $0.append(arrival) }
                }
            }
            let feed = SplicedSpeech.paced(audio, beforeBuffer: beforeBuffer)
            try await vad.activate(stream: gate?.gate(feed.stream) ?? feed.stream)
            await feed.feeder.value
            _ = await waitUntil(timeout: .seconds(3)) { arrivals.withLock { $0.count } >= count }
            // Negative check: bounded wait; no extra segment may follow.
            _ = await waitUntil(timeout: .milliseconds(500)) { arrivals.withLock { $0.count } > count }
            await vad.deactivate()
            collector.cancel()
            return (arrivals.withLock { $0 }, feed.start)
        }

        @Test("a 1.0 s gap with a 0.6 s pause splits two sentences, within pause + 0.5 s (NFR-H-01)")
        func splitsAtPauseWithinBound() async throws {
            let pause = 0.6
            let first = try SplicedSpeech.speech("es-meeting")
            let second = try SplicedSpeech.speech("en-budget")
            let lead = SplicedSpeech.silence(0.5)
            let audio = lead + first + SplicedSpeech.silence(1.0) + second + SplicedSpeech.silence(1.5)

            let run = try await segments(of: audio, through: try await makeSilero(pause: pause), expecting: 2)

            #expect(run.arrivals.count == 2, "segments: \(run.arrivals.map(\.frames))")
            guard let closed = run.arrivals.first?.at else { return }
            let speechEnd = run.start + SplicedSpeech.seconds(lead.count + first.count)
            let latency = speechEnd.duration(to: closed)
            await LatencyReport.shared.record(fixture: "silero-pause-0.6", stage: .vad, ms: latency.milliseconds)
            #expect(latency <= .seconds(pause + 0.5), "segment closed \(latency) after the end of speech")
            #expect(latency >= .seconds(pause - 0.35), "segment closed before the pause: \(latency)")
        }

        @Test("a 0.3 s micro-pause with a 0.6 s pause does not split the sentence (NFR-H-02)")
        func microPauseDoesNotSplit() async throws {
            let audio = try SplicedSpeech.silence(0.5) + SplicedSpeech.speech("es-meeting")
                + SplicedSpeech.silence(0.3) + SplicedSpeech.speech("en-budget") + SplicedSpeech.silence(1.5)

            let run = try await segments(of: audio, through: try await makeSilero(pause: 0.6), expecting: 1)

            #expect(run.arrivals.count == 1, "segments: \(run.arrivals.map(\.frames))")
        }

        @Test("speakers mode: speech while incoming 'speaks' never becomes a segment; before and after do (A6)")
        func echoGateKeepsEchoOut() async throws {
            let first = try SplicedSpeech.speech("es-meeting")
            let echo = try SplicedSpeech.speech("en-hear")
            let last = try SplicedSpeech.speech("en-budget")
            let gap = SplicedSpeech.silence(1.0)
            let audio = SplicedSpeech.silence(0.5) + first + gap + echo + gap + last + SplicedSpeech.silence(1.5)
            let echoStart = SplicedSpeech.silence(0.5).count + first.count + gap.count
            let echoEnd = echoStart + echo.count
            let gate = MicEchoGate(mode: .speakers)

            let run = try await segments(of: audio, through: try await makeSilero(pause: 0.6), expecting: 2,
                                         gate: gate) { offset in
                // The remote translation "plays" from 0.2 s before the echo until its last sample.
                if offset >= echoStart - Int(0.2 * SplicedSpeech.rate), offset < echoEnd {
                    gate.setIncomingSpeaking(true)
                } else {
                    gate.setIncomingSpeaking(false)
                }
            }

            #expect(run.arrivals.count == 2, "segments: \(run.arrivals.map(\.frames))")
        }
    }
}
