import Foundation

// MARK: - Pause and the session transcript (M9 UI core D-5, REQ-UI-44/50…52, design §4.1–4.2)

extension AudioCoordinator {

    /// "Hearing them": the incoming VAD's speech state (REQ-UI-43).
    func observeIncomingVADState(_ vad: some VADService) {
        incomingTasks.append(Task { [weak self] in
            for await active in vad.vadStateEvents {
                guard !Task.isCancelled else { return }
                self?.isIncomingSpeechActive = active
            }
        })
    }

    /// A new session: empty transcript.
    func beginSessionUIState() {
        transcript.removeAll()
        pauseGate = PauseGate()
    }

    /// The session ended (stop, or a start that did not go active). The transcript stays readable
    /// until the next start.
    func endSessionUIState() {
        isOutgoingTranslating = false
        isIncomingTranslating = false
        isIncomingSpeechActive = false
        sessionStartedAt = nil
        pauseGate = nil
        isPaused = false
    }

    /// Pauses both directions with the engines kept warm: call audio and mic reach the VADs as
    /// silence, playing and queued translations stop, text arriving meanwhile is dropped.
    /// No-op outside a session or when already paused. The echo gate is not touched.
    func pause() async {
        guard isOutgoingActive, !isPaused else { return }
        isPaused = true
        pauseGate?.setPaused(true)
        await outgoingTTS?.stopSpeaking()
        await incomingTTS?.stopSpeaking()
    }

    /// Back to normal processing from the next buffer; nothing is reloaded (REQ-UI-51).
    func resume() {
        guard isPaused else { return }
        isPaused = false
        pauseGate?.setPaused(false)
    }

    /// Appends a sentence (translation pending) and keeps the newest `TranscriptEntry.limit`.
    func appendTranscript(_ direction: TranscriptDirection, _ text: String) -> UUID {
        let entry = TranscriptEntry(direction: direction, original: text)
        transcript.append(entry)
        if transcript.count > TranscriptEntry.limit {
            transcript.removeFirst(transcript.count - TranscriptEntry.limit)
        }
        return entry.id
    }

    func completeTranscript(_ id: UUID, translation: String) {
        guard let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[index].translation = translation
    }

    /// A failed sentence is marked skipped; a cancelled one (session stopping) is left as it is.
    func skipTranscript(_ id: UUID, error: Error) {
        guard !(error is CancellationError),
              let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[index].skipped = true
    }
}
