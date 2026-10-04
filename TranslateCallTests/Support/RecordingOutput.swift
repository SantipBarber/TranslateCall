import AVFoundation
import Synchronization
@testable import TranslateCall

/// Wraps a real output and records what was scheduled: when the first buffer went out, the total
/// audio length and the digital silence at the end of the last buffer (integration tier only).
final class RecordingOutput: AudioOutputting, Sendable {
    private struct State {
        var firstScheduleAt: ContinuousClock.Instant?
        var scheduledSeconds: Double = 0
        var trailingSilenceSeconds: Double = 0
    }

    private let inner: any AudioOutputting
    private let state = Mutex(State())

    init(wrapping inner: any AudioOutputting) {
        self.inner = inner
    }

    var firstScheduleAt: ContinuousClock.Instant? { state.withLock { $0.firstScheduleAt } }
    var scheduledDuration: Duration { .seconds(state.withLock { $0.scheduledSeconds }) }
    var trailingSilence: Duration { .seconds(state.withLock { $0.trailingSilenceSeconds }) }

    func schedule(_ buffer: AVAudioPCMBuffer) throws -> PlaybackHandle {
        let handle = try inner.schedule(buffer)
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let silence = Self.trailingSilence(of: buffer)
        state.withLock { current in
            if current.firstScheduleAt == nil { current.firstScheduleAt = .now }
            current.scheduledSeconds += seconds
            current.trailingSilenceSeconds = silence
        }
        return handle
    }

    func stop() { inner.stop() }
    func shutdown() { inner.shutdown() }

    /// Seconds of near-zero samples (|x| < 1e-4) at the end of a Float32 buffer.
    private static func trailingSilence(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        var silent = 0
        var index = Int(buffer.frameLength) - 1
        while index >= 0, abs(samples[index]) < 1e-4 {
            silent += 1
            index -= 1
        }
        return Double(silent) / buffer.format.sampleRate
    }
}
