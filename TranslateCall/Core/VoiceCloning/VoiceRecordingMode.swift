import Accelerate
import Foundation

/// How a voice reference is recorded: free-form (long) or reading a guided text (short).
nonisolated enum RecordingMode: Sendable, Equatable {
    case free
    case guided(language: String)

    var maxSeconds: Double {
        switch self {
        case .free: QwenCloneConfiguration.freeMaxSeconds
        case .guided: QwenCloneConfiguration.guidedMaxSeconds
        }
    }

    var guidedText: String? {
        switch self {
        case .free: nil
        case .guided(let language): GuidedReadingTexts.text(for: language)
        }
    }
}

/// Grading, save-blocking and silence-trimming rules for recorded voice references.
nonisolated enum VoiceQualityRules {
    /// Silence kept on each side after trimming.
    static let keptSilenceSeconds: Double = 0.3
    /// 10 ms mean-square threshold, -40 dBFS.
    static let voiceThresholdMeanSquare: Float = 0.0001

    private static var guidedMinVoiced: Float {
        Float(QwenCloneConfiguration.guidedMinimumVoicedSeconds)
    }

    static func grade(
        peakRmsDbfs: Float,
        hasClipping: Bool,
        voicedSeconds: Float,
        mode: RecordingMode
    ) -> VoiceQualityGrade {
        switch mode {
        case .free:
            if peakRmsDbfs < -30 || voicedSeconds < 8 || hasClipping { return .poor }
            if peakRmsDbfs < -20 || voicedSeconds < 20 { return .fair }
            return .good
        case .guided:
            if peakRmsDbfs < -30 || hasClipping || voicedSeconds < guidedMinVoiced { return .poor }
            if peakRmsDbfs < -20 { return .fair }
            return .good
        }
    }

    static func isSaveBlocked(_ quality: VoiceQualityMetrics, mode: RecordingMode) -> Bool {
        guard quality.grade == .poor else { return false }
        switch mode {
        case .free: return quality.voicedDurationSeconds < 8
        case .guided: return quality.voicedDurationSeconds < guidedMinVoiced
        }
    }

    /// Trims leading/trailing silence (below -40 dBFS in 10 ms chunks) beyond `keptSilenceSeconds`.
    static func trimSilence(_ samples: [Float], sampleRate: Double) -> [Float] {
        let chunk = max(Int(sampleRate / 100), 1)
        let chunkCount = samples.count / chunk
        func isVoiced(_ index: Int) -> Bool {
            var meanSq: Float = 0
            let slice = Array(samples[index * chunk ..< (index + 1) * chunk])
            vDSP_measqv(slice, 1, &meanSq, vDSP_Length(chunk))
            return meanSq >= voiceThresholdMeanSquare
        }
        guard let first = (0 ..< chunkCount).first(where: isVoiced),
              let last = (0 ..< chunkCount).last(where: isVoiced) else { return samples }
        let keep = Int(keptSilenceSeconds * sampleRate)
        let start = max(0, first * chunk - keep)
        let end = min(samples.count, (last + 1) * chunk + keep)
        guard start > 0 || end < samples.count else { return samples }
        return Array(samples[start ..< end])
    }
}
