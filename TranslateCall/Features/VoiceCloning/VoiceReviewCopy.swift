import Foundation

/// The review screen's messages that depend on the recording mode (REQ-QS-12/13).
enum VoiceReviewCopy {
    /// Only a guided reading is checked against a text: an auto-stop may have cut it.
    static func showsLimitWarning(mode: RecordingMode, reachedLimit: Bool) -> Bool {
        reachedLimit && mode.guidedText != nil
    }

    static func limitReached(seconds: Int) -> String {
        String(localized: """
            The recording reached the \(seconds)-second limit. \
            Check that the text below matches what you said, or record again.
            """)
    }

    /// Below this peak the grade is poor whatever was said: the microphone barely heard the user.
    static let lowLevelDbfs: Float = -30

    /// The save-blocking message. A quiet microphone is named first: re-reading louder text won't help it.
    /// Voiced seconds with one decimal in both modes.
    static func tooShort(mode: RecordingMode, voicedSeconds: Float, peakRmsDbfs: Float = 0) -> String {
        if peakRmsDbfs < lowLevelDbfs {
            let peak = String(format: "%.0f", peakRmsDbfs)
            return String(localized: """
                The microphone level is too low (\(peak) dBFS). Check the input device and its level \
                in System Settings › Sound, move closer to the microphone, and record again.
                """)
        }
        let voiced = String(format: "%.1f", voicedSeconds)
        switch mode {
        case .free:
            return String(localized: """
                Insufficient speech detected (\(voiced)s voiced). Please re-record with more speech.
                """)
        case .guided:
            let target = Int(QwenCloneConfiguration.guidedTargetSeconds)
            return String(localized: """
                Not enough speech detected (\(voiced)s voiced). Record again and read the whole text \
                at a calm pace, about \(target) seconds.
                """)
        }
    }
}
