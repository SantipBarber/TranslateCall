import Foundation

// MARK: - Delivery of one sentence, part by part (QS-5 clause split, design §5–§6)
// `deliverOutgoing` / `deliverIncoming` (AudioCoordinator+Translation.swift) run the guards and own the
// transcript entry and the Translating flag; this speaks the parts. An unsplit sentence is one part.

extension AudioCoordinator {

    /// For each part in order: awaits its translation, shows the translation so far (live caption and
    /// transcript entry), then speaks the part unless paused (REQ-CS-11, -12, -14). Throws when the first
    /// part fails (the caller skips the sentence, REQ-CS-16) or the delivery is cancelled (REQ-CS-15).
    /// A later part's failure keeps what was spoken and marks the entry partly skipped (REQ-CS-16).
    func speakParts(of sentence: SentenceTranslation, entry: UUID, direction: TranscriptDirection) async throws {
        let tasks = sentence.tasks
        var translations: [String] = []
        var firstSpokenAt: UInt64?   // `pauseCount` when the first part was handed to TTS
        var spokenCount = 0
        for (index, task) in tasks.enumerated() {
            let part: String
            do {
                part = try await withTaskCancellationHandler { try await task.value } onCancel: {
                    tasks.forEach { $0.cancel() }
                }
                // A translator that ignores cancellation (the Apple bridge) must not speak after teardown.
                try Task.checkCancellation()
            } catch {
                sentence.cancel()
                if index == 0 { throw error }
                try Task.checkCancellation()   // the session is stopping: silent, as a cancellation
                markPartlySkipped(entry)
                // A part cancelled from outside while this delivery runs (`SentenceTranslation.cancel()`;
                // the committer's `cancelAll` cancels the delivery too, caught above) is no failure.
                guard !(error is CancellationError) else { return }
                handleTranslationFailure(error, outgoing: direction == .outgoing)
                return
            }
            translations.append(part)
            show(translations.joined(separator: " "), entry: entry, direction: direction)
            // Paused while translating, or since the first part was spoken (even if resumed since):
            // the rest is shown, not spoken (REQ-CS-14). The first part keeps today's rule.
            if speaks(index: index, firstSpokenAt: firstSpokenAt) {
                firstSpokenAt = firstSpokenAt ?? pauseCount
                spokenCount += 1
                await speak(part, direction: direction)
            }
        }
        // An echo the STT hears as one sentence must still be caught (REQ-CS-17).
        if direction == .incoming, sentence.isSplit, spokenCount == tasks.count {
            selfEchoGuard.played(translations.joined(separator: " "), at: .now)
        }
    }

    /// Not paused now; a later part also needs the first spoken and no Pause since (REQ-CS-14).
    private func speaks(index: Int, firstSpokenAt: UInt64?) -> Bool {
        guard !isPaused else { return false }
        guard index > 0 else { return true }
        return firstSpokenAt == pauseCount
    }

    /// The translation so far on the live caption and the transcript entry (twice for a split sentence).
    private func show(_ translation: String, entry: UUID, direction: TranscriptDirection) {
        switch direction {
        case .outgoing: outgoingTranslation = translation
        case .incoming: incomingTranslation = translation
        }
        completeTranscript(entry, translation: translation)
    }

    /// Speaks one part on the direction's TTS. Incoming parts go to the self-echo guard first (Q6).
    private func speak(_ part: String, direction: TranscriptDirection) async {
        let tts: (any SynthesisService)?
        let language: Locale.Language
        switch direction {
        case .outgoing:
            tts = outgoingTTS
            language = languagePairManager.targetLanguage
        case .incoming:
            tts = incomingTTS
            language = languagePairManager.sourceLanguage
            selfEchoGuard.played(part, at: .now)
        }
        await tts?.speak(text: part, locale: Locale(identifier: language.minimalIdentifier))
        // Pause's stopSpeaking may reach the TTS actor before this speak (jobs are not FIFO) (UI-B1).
        if isPaused { await tts?.stopSpeaking() }
    }
}
