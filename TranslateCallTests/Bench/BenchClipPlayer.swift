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

    /// Sound mixed on top of the stream (an acoustic echo), from stream sample `start`.
    private struct Mix {
        var start: Int
        var samples: [Float]
        var end: Int { start + samples.count }
    }

    private struct State {
        var pending: Pending?
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        var task: Task<Void, Never>?
        /// Instant of stream sample 0, and samples yielded so far.
        var origin: ContinuousClock.Instant?
        var position = 0
        var mixes: [Mix] = []
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
        state.withLock { current in
            current.origin = nil
            current.position = 0
            current.mixes = []
        }
        pending?.done.resume(returning: ClipFeed(chunkTimes: pending?.times ?? [], chunk: Self.chunk,
                                                 sampleRate: Self.sampleRate))
    }

    /// Plays `samples` (16 kHz mono) in real time; returns when the last chunk was delivered.
    /// Plays one clip at a time on a started stream: a second call while one is pending, or a call
    /// on a stopped player, would overwrite the earlier continuation or never return, so both fail loudly.
    func play(_ samples: [Float]) async -> ClipFeed {
        await withCheckedContinuation { done in
            state.withLock { current in
                precondition(current.continuation != nil, "BenchClipPlayer.play on a stopped player would never return")
                precondition(current.pending == nil, "BenchClipPlayer.play while another clip is pending")
                current.pending = Pending(samples: samples, done: done)
            }
        }
    }

    /// Plays `seconds` of silence (the stream is silent anyway; this only waits in step with it).
    func playSilence(seconds: Double) async {
        _ = await play(Array(repeating: 0, count: Int(seconds * Self.sampleRate)))
    }

    /// Adds `samples` (16 kHz mono) on top of the stream from `instant` on, like a sound the
    /// microphone hears. A part that would start before the current position starts there instead.
    /// Ignored while stopped.
    func mix(_ samples: [Float], at instant: ContinuousClock.Instant) {
        guard !samples.isEmpty else { return }
        state.withLock { current in
            guard let origin = current.origin else { return }
            let offset = Int((origin.duration(to: instant) / .seconds(1)) * Self.sampleRate)
            current.mixes.append(Mix(start: max(offset, current.position), samples: samples))
        }
    }

    /// Drops mixed sound that has not been yielded yet from `instant` on (playback stopped).
    func truncateMix(from instant: ContinuousClock.Instant) {
        state.withLock { current in
            guard let origin = current.origin else { return }
            let cut = max(Int((origin.duration(to: instant) / .seconds(1)) * Self.sampleRate), current.position)
            current.mixes = current.mixes.compactMap { mix in
                guard mix.start < cut else { return nil }
                var kept = mix
                kept.samples = Array(mix.samples.prefix(cut - mix.start))
                return kept
            }
        }
    }

    private func run(_ continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) async {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false) else { return }
        let period = Duration.seconds(Double(Self.chunk) / Self.sampleRate)
        var deadline = ContinuousClock.now
        state.withLock { $0.origin = deadline }
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
            defer { Self.addMixes(&current, into: dst) }
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

extension BenchClipPlayer {
    /// Adds the mixed sound that falls in the chunk being yielded, then advances the position.
    private static func addMixes(_ current: inout State, into dst: UnsafeMutablePointer<Float>) {
        let start = current.position
        let end = start + chunk
        for mix in current.mixes where mix.start < end && mix.end > start {
            for index in max(mix.start, start)..<min(mix.end, end) {
                dst[index - start] = max(-1, min(1, dst[index - start] + mix.samples[index - mix.start]))
            }
        }
        current.mixes.removeAll { $0.end <= end }
        current.position = end
    }
}
