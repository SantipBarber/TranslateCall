import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSPlaybackService")

// MARK: - Drain (clause split FR-CS.5, design §7a)

extension TTSPlaybackService {

    /// What the worker made of one utterance once its synthesis ended.
    enum Synthesis: Sendable {
        /// Known without waiting for any audio (no voice, failed with nothing heard, stale).
        case decided(Outcome)
        /// An attempt scheduled (or tried to schedule) audio: its drain waits for it to play out.
        case attempted(Attempted)
    }

    struct Attempted: Sendable {
        let end: AttemptEnd
        let record: AttemptRecord
        let engine: TTSEngine
    }

    struct Handoff: Sendable {
        let synthesis: Synthesis
        let utterance: Utterance
        let gen: UInt64
    }

    struct PendingDrain {
        let id: UInt64
        let task: Task<Void, Never>
    }

    /// Hands an utterance whose synthesis ended to a drain chained after the previous one, so
    /// outcomes are reported in utterance order (REQ-CS-52).
    func handOff(_ handoff: Handoff) {
        nextDrainID &+= 1
        let id = nextDrainID
        let previous = drains.last?.task
        let task = Task {
            await previous?.value
            await self.drain(handoff, id: id)
        }
        drains.append(PendingDrain(id: id, task: task))
    }

    /// One playing and one ahead at most (REQ-CS-51): with two drains pending, the next synthesis
    /// waits for the oldest one, so the sentences queuing meanwhile are coalesced.
    func waitForRoomAhead() async {
        while drains.count > 1, let oldest = drains.first?.task {
            await oldest.value
        }
    }

    private func drain(_ handoff: Handoff, id: UInt64) async {
        let outcome: Outcome
        switch handoff.synthesis {
        case .decided(let decided):
            outcome = decided
        case .attempted(let attempted):
            outcome = await conclude(attempted.end, record: attempted.record, engine: attempted.engine,
                                     utterance: handoff.utterance, gen: handoff.gen)
        }
        drains.removeAll { $0.id == id }
        guard handoff.gen == generation else { return }   // stopSpeaking already reported and cleared
        if case .skipped(let reason) = outcome {
            eventsContinuation.yield(.utteranceSkipped(reason))
            logger.warning("TTS sentence skipped: \(String(describing: reason), privacy: .public)")
        }
        // Not between two utterances: the one ahead (draining or synthesizing) keeps it true (REQ-CS-55).
        if queue.isEmpty, !isSynthesizing, drains.isEmpty { setSpeaking(false) }
    }
}
