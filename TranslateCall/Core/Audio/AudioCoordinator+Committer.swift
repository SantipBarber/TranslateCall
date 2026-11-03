import Foundation

// MARK: - Early processing: results and VAD boundaries through a TurnCommitter (FR-QS.5, design §10.4)

extension AudioCoordinator {

    /// A new outgoing committer, fed the VAD's commits and retracts. A tentative is translated at once;
    /// show and speak (with the mute-turn and pause checks) run at its commit, in `deliverOutgoing`.
    func startOutgoingCommitter(boundaries: AsyncStream<SegmentBoundary>) {
        outgoingCommitter = TurnCommitter(
            translate: { [weak self] text in
                guard let self else { throw CancellationError() }
                return try await translateOutgoing(text)
            },
            deliver: { [weak self] in await self?.deliverOutgoing($0, translation: $1) }
        )
        outgoingTasks.append(Task { [weak self] in
            for await boundary in boundaries {
                guard !Task.isCancelled else { return }
                self?.outgoingCommitter?.receive(boundary)
            }
        })
    }

    /// Incoming counterpart of `startOutgoingCommitter`.
    func startIncomingCommitter(boundaries: AsyncStream<SegmentBoundary>) {
        incomingCommitter = TurnCommitter(
            translate: { [weak self] text in
                guard let self else { throw CancellationError() }
                return try await translateIncoming(text)
            },
            deliver: { [weak self] in await self?.deliverIncoming($0, translation: $1) }
        )
        incomingTasks.append(Task { [weak self] in
            for await boundary in boundaries {
                guard !Task.isCancelled else { return }
                self?.incomingCommitter?.receive(boundary)
            }
        })
    }

    /// Every result reaches the committer, empty ones too (they unblock the head, FR-QS.5); only
    /// non-empty text updates the live caption, which may show a tentative before its commit.
    func observeOutgoingTranscriptions(_ stt: some SpeechRecognizerService) {
        outgoingTasks.append(Task { [weak self] in
            for await result in stt.transcriptionStream {
                guard !Task.isCancelled, let self else { return }
                if !result.text.isEmpty { outgoingTranscription = result.text }
                outgoingCommitter?.receive(result)
            }
        })
    }

    func observeIncomingTranscriptions(_ stt: some SpeechRecognizerService) {
        incomingTasks.append(Task { [weak self] in
            for await result in stt.transcriptionStream {
                guard !Task.isCancelled, let self else { return }
                if !result.text.isEmpty { incomingTranscription = result.text }
                incomingCommitter?.receive(result)
            }
        })
    }
}
