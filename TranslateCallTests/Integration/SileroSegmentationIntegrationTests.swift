import AVFoundation
import Synchronization
import Testing
@testable import TranslateCall

/// When a segment reached the consumer, and how long it was.
struct SegmentArrival: Sendable {
    let at: ContinuousClock.Instant
    let frames: Int
    var id: UInt64 = 0
    var kind: SegmentKind = .final
}

/// What one Silero run yielded: every segment, every boundary (with its arrival), and the start.
struct SegmentationRun: Sendable {
    let arrivals: [SegmentArrival]
    let boundaries: [(boundary: SegmentBoundary, at: ContinuousClock.Instant)]
    let start: ContinuousClock.Instant

    /// The sentences the pipeline delivers (FR-QS.5): finals, and tentatives later committed, each
    /// at the moment it is delivered (a committed tentative at its commit). Retracted ones are not.
    var delivered: [SegmentArrival] {
        Self.delivered(arrivals, boundaries)
    }

    static func delivered(_ arrivals: [SegmentArrival],
                          _ boundaries: [(boundary: SegmentBoundary, at: ContinuousClock.Instant)])
        -> [SegmentArrival] {
        arrivals.compactMap { segment in
            if segment.kind == .final { return segment }
            guard let commit = boundaries.first(where: { $0.boundary == .commit(segment.id) }) else { return nil }
            return SegmentArrival(at: max(commit.at, segment.at), frames: segment.frames,
                                  id: segment.id, kind: segment.kind)
        }.sorted { $0.at < $1.at }
    }
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

        /// Runs `vad` over `audio` and returns what it yielded, once no more sentences are coming:
        /// `count` delivered sentences (finals + committed tentatives), then a bounded wait for an extra one.
        func segments(of audio: [Float], through vad: SileroVADService, expecting count: Int,
                      gate: MicEchoGate? = nil,
                      beforeBuffer: @escaping @Sendable (Int) -> Void = { _ in })
            async throws -> SegmentationRun {
            let arrivals = Mutex<[SegmentArrival]>([])
            let boundaries = Mutex<[(boundary: SegmentBoundary, at: ContinuousClock.Instant)]>([])
            let collector = Task {
                for await segment in vad.speechSegments {
                    let arrival = SegmentArrival(at: .now, frames: Int(segment.audio.frameLength),
                                                 id: segment.id, kind: segment.kind)
                    arrivals.withLock { $0.append(arrival) }
                }
            }
            let boundaryCollector = Task {
                for await boundary in vad.boundaryEvents {
                    let stamped = (boundary: boundary, at: ContinuousClock.now)
                    boundaries.withLock { $0.append(stamped) }
                }
            }
            let delivered = { SegmentationRun.delivered(arrivals.withLock { $0 }, boundaries.withLock { $0 }).count }
            let feed = SplicedSpeech.paced(audio, beforeBuffer: beforeBuffer)
            try await vad.activate(stream: gate?.gate(feed.stream) ?? feed.stream)
            await feed.feeder.value
            _ = await waitUntil(timeout: .seconds(3)) { delivered() >= count }
            // Negative check: bounded wait; no extra sentence may follow.
            _ = await waitUntil(timeout: .milliseconds(500)) { delivered() > count }
            await vad.deactivate()
            collector.cancel()
            boundaryCollector.cancel()
            return SegmentationRun(arrivals: arrivals.withLock { $0 }, boundaries: boundaries.withLock { $0 },
                                   start: feed.start)
        }

        @Test("a 1.0 s gap with a 0.6 s pause splits two sentences, within pause + 0.5 s (NFR-H-01)")
        func splitsAtPauseWithinBound() async throws {
            let pause = 0.6
            let first = try SplicedSpeech.speech("es-meeting")
            let second = try SplicedSpeech.speech("en-budget")
            let lead = SplicedSpeech.silence(0.5)
            let audio = lead + first + SplicedSpeech.silence(1.0) + second + SplicedSpeech.silence(1.5)

            let run = try await segments(of: audio, through: try await makeSilero(pause: pause), expecting: 2)

            // The sentence closes when it is delivered: its commit (or its final), not its tentative.
            let sentences = run.delivered
            #expect(sentences.count == 2, "sentences: \(sentences.map(\.frames)), segments: \(run.arrivals)")
            guard let closed = sentences.first else { return }
            if closed.kind == .tentative, let tentative = run.arrivals.first(where: { $0.id == closed.id }) {
                #expect(tentative.at <= closed.at, "the tentative arrives before its commit")
            }
            let speechEnd = run.start + SplicedSpeech.seconds(lead.count + first.count)
            let latency = speechEnd.duration(to: closed.at)
            print("LATENCY silero-pause-0.6 vad \(latency.milliseconds) ms")
            #expect(latency <= .seconds(pause + 0.5), "segment closed \(latency) after the end of speech")
            #expect(latency >= .seconds(pause - 0.35), "segment closed before the pause: \(latency)")
        }

        @Test("a 0.3 s micro-pause with a 0.6 s pause does not split the sentence (NFR-H-02)")
        func microPauseDoesNotSplit() async throws {
            let audio = try SplicedSpeech.silence(0.5) + SplicedSpeech.speech("es-meeting")
                + SplicedSpeech.silence(0.3) + SplicedSpeech.speech("en-budget") + SplicedSpeech.silence(1.5)

            let run = try await segments(of: audio, through: try await makeSilero(pause: 0.6), expecting: 1)

            // One delivered sentence; a tentative retracted at the micro-pause does not count.
            #expect(run.delivered.count == 1, "sentences: \(run.delivered.map(\.frames)), segments: \(run.arrivals)")
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

            let frames = run.delivered.map(\.frames)
            #expect(frames.count == 2, "sentences: \(frames), segments: \(run.arrivals)")
            // A leaked echo merged into a segment would add the 1 s gap and its speech: each segment must
            // match its own sentence plus what Silero adds (0.1 s padding + the 0.6 s pause), within ±35 %.
            guard frames.count == 2 else { return }
            let added = SplicedSpeech.silence(0.6 + 0.1).count
            #expect(Self.isClose(frames[0], to: first.count + added),
                    "first segment \(frames[0]) vs \(first.count) + \(added) (echo \(echo.count))")
            #expect(Self.isClose(frames[1], to: last.count + added),
                    "last segment \(frames[1]) vs \(last.count) + \(added) (echo \(echo.count))")
        }

        static func isClose(_ frames: Int, to expected: Int, tolerance: Double = 0.35) -> Bool {
            abs(Double(frames - expected)) <= tolerance * Double(expected)
        }
    }
}
