import Foundation

// MARK: - Rehearsal mode (M9 UI first-run REQ-FR-52/56)

extension AudioCoordinator {

    /// True while the mic capture is live; the rehearsal driver waits on this to end "Preparing…".
    var isMicCapturing: Bool {
        audioCapture.isCapturing
    }

    /// Ends a rehearsal that left the session inactive (a failed or superseded `start`) or a `stop()`.
    /// Restores the pre-rehearsal transcript, drops the session's error alert (it already went to
    /// `lastRehearsalError` via `errorAlert`'s didSet) and clears `isRehearsal` last, so observers
    /// keyed on `isOutgoingActive` still see `isRehearsal == true` while the session is stopping.
    func finishRehearsalIfNeeded() {
        guard isRehearsal else { return }
        if let savedTranscript {
            transcript = savedTranscript
        }
        self.savedTranscript = nil
        errorAlert = nil
        isRehearsal = false
    }
}
