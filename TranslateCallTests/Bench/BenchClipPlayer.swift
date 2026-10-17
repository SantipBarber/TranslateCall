import AVFoundation
import Synchronization
@testable import TranslateCall

/// When a clip's chunks reached the pipeline. A chunk is yielded once its last sample is "captured"
/// (after its duration has elapsed), the way a microphone tap delivers audio, so a sample's capture
/// time is its chunk's delivery time minus the samples that follow it in the chunk (M9 design §3.2).
struct ClipFeed: Sendable {
    let chunkTimes: [ContinuousClock.Instant]
    let chunk: Int
    let sampleRate: Double

    var start: ContinuousClock.Instant { instant(ofSample: 0) }
    var end: ContinuousClock.Instant { chunkTimes.last ?? .now }

    /// Capture time of sample `index` of the clip.
    func instant(ofSample index: Int) -> ContinuousClock.Instant {
        guard !chunkTimes.isEmpty else { return .now }
        let chunkIndex = min(max(index, 0) / chunk, chunkTimes.count - 1)
        let samplesAfter = (chunkIndex + 1) * chunk - index
        return chunkTimes[chunkIndex] - .seconds(Double(samplesAfter) / sampleRate)
    }
}

/// An endless 16 kHz mono stream, paced in real time: silence, or the clip `play(_:)` is playing.
/// Shared by the mic-side and system-side bench sources.
final class BenchClipPlayer: Sendable {
    static let sampleRate: Double = 16_000
    static let chunk = 1024

    private struct Pending {
        var samples: [Float]
        var offset = 0
        var times: [ContinuousClock.Instant] = []
        var done: CheckedContinuation<ClipFeed, Never>
    }

    private struct State {
        var pending: Pending?
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        var task: Task<Void, Never>?
    }

    private let state = Mutex(State())

    var isRunning: Bool { state.withLock { $0.continuation != nil } }

    /// Starts the stream (silence until a clip plays). Bounded like a session stream (64 buffers).
    func start() -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingNewest(SessionAudioStream.capacity)
        )
        let task = Task.detached { [weak self] in await self?.run(continuation); return }
        state.withLock { current in
            current.continuation = continuation
            current.task = task
        }
        return stream
    }

    /// Finishes the stream; a clip still playing reports what was delivered.
    func stop() {
        let (task, continuation, pending) = state.withLock { current in
            defer { (current.task, current.continuation, current.pending) = (nil, nil, nil) }
            return (current.task, current.continuation, current.pending)
        }
        task?.cancel()
        continuation?.finish()
        pending?.done.resume(returning: ClipFeed(chunkTimes: pending?.times ?? [], chunk: Self.chunk,
                                                 sampleRate: Self.sampleRate))
    }

    /// Plays `samples` (16 kHz mono) in real time; returns when the last chunk was delivered.
    func play(_ samples: [Float]) async -> ClipFeed {
        await withCheckedContinuation { done in
            state.withLock { $0.pending = Pending(samples: samples, done: done) }
        }
    }

    /// Plays `seconds` of silence (the stream is silent anyway; this only waits in step with it).
    func playSilence(seconds: Double) async {
        _ = await play(Array(repeating: 0, count: Int(seconds * Self.sampleRate)))
    }

    private func run(_ continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) async {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false) else { return }
        let period = Duration.seconds(Double(Self.chunk) / Self.sampleRate)
        var deadline = ContinuousClock.now
        while !Task.isCancelled {
            deadline += period   // absolute deadlines: no drift from sleep overshoot
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.chunk)),
                  let dst = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(Self.chunk)
            let finished = fill(dst)
            continuation.yield(buffer)
            if let (feed, done) = finished { done.resume(returning: feed) }
        }
    }

    /// Copies the next clip chunk (or silence) into `dst`; returns the feed when the clip ended.
    private func fill(_ dst: UnsafeMutablePointer<Float>) -> (ClipFeed, CheckedContinuation<ClipFeed, Never>)? {
        dst.update(repeating: 0, count: Self.chunk)
        return state.withLock { current -> (ClipFeed, CheckedContinuation<ClipFeed, Never>)? in
            guard var pending = current.pending else { return nil }
            let count = min(Self.chunk, pending.samples.count - pending.offset)
            if count > 0 {
                pending.samples.withUnsafeBufferPointer { src in
                    if let base = src.baseAddress { dst.update(from: base + pending.offset, count: count) }
                }
            }
            pending.offset += Self.chunk
            pending.times.append(.now)
            guard pending.offset >= pending.samples.count else {
                current.pending = pending
                return nil
            }
            current.pending = nil
            return (ClipFeed(chunkTimes: pending.times, chunk: Self.chunk, sampleRate: Self.sampleRate), pending.done)
        }
    }
}

/// The mic side of a bench session: production `AudioCapture`, fed by a `BenchClipPlayer`.
@MainActor
final class BenchAudioSource: AudioCapture {
    let player = BenchClipPlayer()

    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> { player.start() }
    func stopCapture() { player.stop() }
    var isCapturing: Bool { player.isRunning }
}
