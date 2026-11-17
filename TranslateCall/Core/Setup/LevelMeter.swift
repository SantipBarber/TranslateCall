import AVFoundation
import Foundation

/// dBFS measurement and sustained-level detection for setup checks (REQ-FR-40/41).
nonisolated enum LevelMeter {
    static let silence: Float = -160

    /// Returns the peak absolute Float32 sample across every channel, in dBFS.
    static func peakDBFS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0,
              let channels = buffer.floatChannelData else { return silence }

        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                let sample = abs(channels[channel][frame])
                if sample.isFinite, sample > peak {
                    peak = sample
                }
            }
        }

        guard peak > 0 else { return silence }
        return 20 * log10(peak)
    }
}

/// One measured level and the duration of the audio represented by it.
nonisolated struct LevelSample: Sendable, Equatable {
    let dbfs: Float
    let duration: Duration
}

/// Detects a threshold held continuously for the requested duration, then latches success.
nonisolated struct SustainedLevelDetector: Sendable {
    private let threshold: Float
    private let minDuration: Duration
    private var runDuration: Duration = .zero
    private var hasReachedThreshold = false

    init(threshold: Float, minDuration: Duration) {
        self.threshold = threshold
        self.minDuration = minDuration
    }

    mutating func feed(_ sample: LevelSample) -> Bool {
        guard !hasReachedThreshold else { return true }
        guard sample.dbfs >= threshold else {
            runDuration = .zero
            return false
        }

        runDuration += sample.duration
        hasReachedThreshold = runDuration >= minDuration
        return hasReachedThreshold
    }
}
