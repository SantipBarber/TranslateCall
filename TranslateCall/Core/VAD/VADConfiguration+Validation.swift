import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "VADConfiguration")

// MARK: - Validation (F8.5.3 REQ-V-06, T3)

extension VADConfiguration {
    /// Seconds of audio Silero (FluidAudio `VadManager`) analyses per inference: 4 096 samples at 16 kHz.
    nonisolated static let sileroChunkDuration: TimeInterval = 4_096.0 / 16_000

    /// Shortest `maxSpeechDuration` accepted; FluidAudio needs it > 0.
    nonisolated static let minimumMaxSpeechDuration: TimeInterval = 0.1

    /// The silence FluidAudio is asked for. Its streaming state machine starts counting silence at the
    /// end of the first silent chunk, so the pause is reached one chunk earlier than configured: give it
    /// one chunk less, so the user's pause is honoured to within one chunk (F8.5.3 P2).
    nonisolated var sileroMinSilenceDuration: TimeInterval {
        max(0, minSilenceDuration - Self.sileroChunkDuration)
    }

    /// A copy that satisfies every FluidAudio precondition and assertion (`VadSegmentationConfig.init`):
    /// durations ≥ 0, `maxSpeechDuration` > 0, `minSpeechDuration` ≤ `maxSpeechDuration`,
    /// `minSilenceDuration` ≤ `maxSpeechDuration`, `speechPadding` ≤ `minSpeechDuration`, threshold in
    /// [0, 1]. Out-of-range or non-finite values are clamped (non-finite → the default, then clamped)
    /// and logged once. Never throws.
    nonisolated func validated() -> VADConfiguration {
        let defaults = VADConfiguration()
        var fixed = self
        var notes: [String] = []

        func clamp(_ name: String, _ value: Double, _ range: ClosedRange<Double>, default fallback: Double) -> Double {
            let start = value.isFinite ? value : fallback
            let result = min(max(start, range.lowerBound), range.upperBound)
            if result != value { notes.append("\(name) \(value) → \(result)") }
            return result
        }

        fixed.maxSpeechDuration = clamp("maxSpeechDuration", maxSpeechDuration,
                                        Self.minimumMaxSpeechDuration...(24 * 3_600),
                                        default: defaults.maxSpeechDuration)
        fixed.minSpeechDuration = clamp("minSpeechDuration", minSpeechDuration, 0...fixed.maxSpeechDuration,
                                        default: defaults.minSpeechDuration)
        fixed.minSilenceDuration = clamp("minSilenceDuration", minSilenceDuration, 0...fixed.maxSpeechDuration,
                                         default: defaults.minSilenceDuration)
        fixed.speechPadding = clamp("speechPadding", speechPadding, 0...fixed.minSpeechDuration,
                                    default: defaults.speechPadding)
        fixed.sileroThreshold = Float(clamp("sileroThreshold", Double(sileroThreshold), 0...1,
                                            default: Double(defaults.sileroThreshold)))
        fixed.energyThresholdDBFS = Float(clamp("energyThresholdDBFS", Double(energyThresholdDBFS), -160...0,
                                                default: Double(defaults.energyThresholdDBFS)))

        if !notes.isEmpty {
            logger.warning("VAD configuration clamped: \(notes.joined(separator: "; "), privacy: .public)")
        }
        return fixed
    }
}
