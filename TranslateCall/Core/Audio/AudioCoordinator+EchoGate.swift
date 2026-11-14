import Foundation

// MARK: - Mic echo gate and conversation state (F8.5.3 REQ-H-02…06, REQ-H-13, design §3.2–3.3)

extension AudioCoordinator {

    /// A gate for the session that is starting. Its paused reports are advisory (they can arrive
    /// out of order across threads), so each one only triggers a re-read of the gate on the main
    /// actor; reports from a session that is over (`sessionGeneration` moved on) are ignored.
    func makeMicEchoGate() -> MicEchoGate {
        let generation = sessionGeneration
        return MicEchoGate(mode: listeningMode, tail: echoGateTail, clock: echoGateClock) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncMicPausedFromGate(generation: generation)
            }
        }
    }

    /// Sets `isMicPaused` from the gate's authoritative state (never from a report's value), so a
    /// late "paused" report after the mic reopened cannot leave it stuck paused: the gate's
    /// `onPausedChange` value is advisory, `MicEchoGate.isMicPaused` is authoritative (REQ-H-06).
    func syncMicPausedFromGate(generation: UInt64) {
        guard sessionGeneration == generation else { return }
        isMicPaused = micEchoGate?.isMicPaused ?? false
    }

    /// The incoming side went away: the mic must not stay muted (REQ-H-06).
    func reopenMicEchoGate() {
        micEchoGate?.reset()
        isMicPaused = false
    }

    func releaseMicEchoGate() {
        reopenMicEchoGate()
        micEchoGate = nil
    }

    func updateConversationState() {
        let state = ConversationState.derive(micPaused: isMicPaused, outgoingSpeaking: isOutgoingSpeaking,
                                             incomingSpeaking: isIncomingSpeaking)
        if state != conversationState { conversationState = state }
    }
}
