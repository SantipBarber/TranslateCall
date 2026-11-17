import Combine
import CoreAudio
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

// MARK: - RehearsalHost (M9 UI first-run REQ-FR-52…54, design §6.3)

extension AudioCoordinator: RehearsalHost {

    func startRehearsal(blackHole: AudioDeviceID) async {
        await start(captureTarget: nil, blackHoleDeviceID: blackHole, rehearsal: true)
    }

    func stopRehearsal() async {
        guard isRehearsal else { return }
        await stop()
    }

    /// `firstOutgoing` only once the rehearsal's own transcript began (`savedTranscript` is set
    /// together with the clear), so a previous call's entries never count.
    var snapshot: RehearsalSnapshot {
        let rehearsalTranscript = isRehearsal && savedTranscript != nil
        return RehearsalSnapshot(
            isCapturing: isMicCapturing,
            isActive: isOutgoingActive,
            firstOutgoing: rehearsalTranscript ? transcript.first { $0.direction == .outgoing } : nil,
            isTranslating: isOutgoingTranslating,
            isSpeaking: isOutgoingSpeaking,
            error: lastRehearsalError?.message
        )
    }

    /// `objectWillChange` fires before the change; hopping to the main queue reads the snapshot after it.
    var snapshots: AnyPublisher<RehearsalSnapshot, Never> {
        objectWillChange
            .receive(on: DispatchQueue.main)
            .compactMap { [weak self] _ in MainActor.assumeIsolated { self?.snapshot } }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
