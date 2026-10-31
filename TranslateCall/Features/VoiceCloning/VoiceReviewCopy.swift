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

    /// The save-blocking "too short" message; voiced seconds with one decimal in both modes.
    static func tooShort(mode: RecordingMode, voicedSeconds: Float) -> String {
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
