import AVFoundation
@testable import TranslateCall

/// Consumes a capture stream for the whole test (one iterator, never cancelled mid-test) and
/// records when each buffer arrived and how loud it was.
@MainActor
final class BufferLog {
    struct Entry { let at: ContinuousClock.Instant; let rms: Float; let duration: Duration }
    private(set) var entries: [Entry] = []
    private(set) var finished = false
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<AVAudioPCMBuffer>) {
        task = Task { @MainActor [weak self] in
            for await buffer in stream {
                let duration = Duration.seconds(Double(buffer.frameLength) / buffer.format.sampleRate)
                // Each buffer is one tap block, delivered once the block is full: its first sample was
                // captured about `duration` earlier. Stamp that instant (the main-actor hop still adds
                // a few ms) so timings compare with when the audio was played, not when it arrived.
                self?.entries.append(Entry(at: .now - duration, rms: MicTap.rms(buffer), duration: duration))
            }
            self?.finished = true
        }
    }

    func loudCount(since start: ContinuousClock.Instant, threshold: Float = -50) -> Int {
        entries.filter { $0.at >= start && $0.rms > threshold }.count
    }

    func count(since start: ContinuousClock.Instant) -> Int {
        entries.filter { $0.at >= start }.count
    }

    /// First / last buffer at or after `start` louder than `threshold` dBFS.
    func firstEntry(since start: ContinuousClock.Instant, threshold: Float) -> Entry? {
        entries.first { $0.at >= start && $0.rms > threshold }
    }

    func lastEntry(since start: ContinuousClock.Instant, threshold: Float) -> Entry? {
        entries.last { $0.at >= start && $0.rms > threshold }
    }

    /// Time between the last buffer before `instant` and the first buffer after it.
    func gapAround(_ instant: ContinuousClock.Instant) -> Duration? {
        guard let before = entries.last(where: { $0.at < instant }),
              let after = entries.first(where: { $0.at >= instant }) else { return nil }
        return after.at - before.at
    }

    func cancel() { task?.cancel() }
}
