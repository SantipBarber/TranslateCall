import Foundation
import OSLog

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "AudioCoordinator")

// MARK: - Translation handlers: translate, then deliver (show + speak)
// Each direction's `TurnCommitter` (AudioCoordinator+Committer.swift) calls the two halves.

extension AudioCoordinator {

    // MARK: - Translate

    func translateOutgoing(_ text: String) async throws -> String {
        try await outgoingTranslationService.translate(
            text: text,
            from: languagePairManager.sourceLanguage,
            to: languagePairManager.targetLanguage
        )
    }

    func translateIncoming(_ text: String) async throws -> String {
        try await incomingTranslationService.translate(
            text: text,
            from: languagePairManager.targetLanguage,
            to: languagePairManager.sourceLanguage
        )
    }

    // MARK: - Deliver (show + speak)

    /// Shows and speaks one outgoing sentence. `translation` is a sentence translation already started by
    /// the caller (cancelled here if the sentence is dropped); `nil` starts one here, after the guards pass.
    /// The guards apply to the whole sentence once (REQ-CS-13); `speakParts` speaks it part by part.
    func deliverOutgoing(_ text: String, translation: SentenceTranslation? = nil) async {
        // Never dropped while the other side speaks (F8.5.3 REQ-H-10): echo is handled by MicEchoGate.
        // Dropped while paused (M9 UI core REQ-UI-50), before the mute turn so the drop does not use it (UI-B3).
        guard !text.isEmpty, !isPaused else {
            translation?.cancel()
            return
        }
        // One-shot mute turn: user explicitly requested to skip this utterance.
        if suppressNextOutgoingTurnFlag {
            suppressNextOutgoingTurnFlag = false
            logger.debug("Suppressing next outgoing utterance (mute turn)")
            translation?.cancel()
            return
        }
        // The mic heard their translation on the speakers: speaking it would send it back (Task 18 Q6 loop).
        if selfEchoGuard.isEcho(text, at: .now) {
            logger.info("Dropped an outgoing sentence: echo of their translation")
            translation?.cancel()
            showTTSNotice(String(localized: "Ignored an echo of their translation. On speakers? Choose Speakers."))
            return
        }
        let sentence = translation ?? makeSentenceTranslation(text, outgoing: true)
        let entry = appendTranscript(.outgoing, text)
        isOutgoingTranslating = true   // until the last part is translated and spoken (REQ-CS-18)
        let generation = sessionGeneration
        // Stop cannot interrupt a translator that ignores cancellation: a late end must not
        // clear the next session's flag (UI-B2).
        defer { if generation == sessionGeneration { isOutgoingTranslating = false } }
        // No stopSpeaking() first: sentences queue and are coalesced, never cut or dropped (F8.5.3 D-5).
        do {
            try await speakParts(of: sentence, entry: entry, direction: .outgoing)
        } catch {
            skipTranscript(entry, error: error)
            handleTranslationFailure(error, outgoing: true)
        }
    }

    /// Incoming counterpart of `deliverOutgoing`.
    func deliverIncoming(_ text: String, translation: SentenceTranslation? = nil) async {
        // Never dropped while either TTS speaks (F8.5.3 REQ-H-11): SCStream captures only the call app,
        // which does not play the user's own voice back. Remote sentences queue like outgoing ones.
        guard !text.isEmpty, !isPaused else {
            translation?.cancel()
            return
        }
        let sentence = translation ?? makeSentenceTranslation(text, outgoing: false)
        let entry = appendTranscript(.incoming, text)
        isIncomingTranslating = true   // until the last part is translated and spoken (REQ-CS-18)
        let generation = sessionGeneration
        // Stop cannot interrupt a translator that ignores cancellation: a late end must not
        // clear the next session's flag (UI-B2).
        defer { if generation == sessionGeneration { isIncomingTranslating = false } }
        do {
            try await speakParts(of: sentence, entry: entry, direction: .incoming)
        } catch {
            skipTranscript(entry, error: error)
            handleTranslationFailure(error, outgoing: false)
        }
    }

    /// Opens both directions' translation sessions ahead of the first sentence (F8.5.4 REQ-TR-05).
    func warmUpTranslation() async {
        let source = languagePairManager.sourceLanguage
        let target = languagePairManager.targetLanguage
        await outgoingTranslationService.warmUp(from: source, to: target)
        await incomingTranslationService.warmUp(from: target, to: source)
    }

    /// Starts the voice clone warm-up (REQ-QS-31) as an outgoing task, so stop() cancels it; the gate then
    /// drains the model's run on its own. Nothing waits for it.
    func startVoiceCloneWarmUp() {
        guard let warmUp = voiceCloneWarmUp else { return }
        let locale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
        outgoingTasks.append(Task { await warmUp(locale) })
    }

    /// A sentence could not be translated (F8.5.4 D-1). The bridge already retried once, so the
    /// sentence is skipped with a notice and the direction moves on (REQ-TR-20). Errors that will
    /// repeat for every sentence raise the alert, once per session per kind (REQ-TR-21).
    func handleTranslationFailure(_ error: Error, outgoing: Bool) {
        if error is CancellationError { return }   // the session is stopping
        if let kind = (error as? TranslationError)?.configurationKind {
            guard alertedTranslationErrors.insert(kind).inserted else { return }
            errorAlert = makeAlertItem(for: error)
            return
        }
        logger.warning("Translation failed — \(error.localizedDescription, privacy: .public)")
        showTTSNotice(outgoing ? "Couldn't translate your sentence — skipped"
                               : "Couldn't translate their sentence — skipped")
    }

    // MARK: - Error helpers

    func makeAlertItem(for error: Error) -> AlertItem {
        switch error {
        case AudioError.permissionDenied:
            return AlertItem(
                title: "Microphone Access Required",
                message: "TranslateCall needs microphone access. Open System Settings to allow it.",
                action: .openSettings
            )
        case SystemAudioCaptureError.permissionDenied:
            return AlertItem(
                title: "Screen Recording Required",
                message: "TranslateCall needs Screen Recording permission to capture incoming audio. "
                    + "Enable it in System Settings.",
                action: .openSettings
            )
        case TranslationError.modelNotLoaded:
            return AlertItem(
                title: "Languages Not Downloaded",
                message: "Download this language pair (the Download button next to the languages), then start again.",
                action: nil
            )
        case TranslationError.unsupportedPair(_, _):
            return AlertItem(
                title: "Language Pair Unsupported",
                message: "This language pair is not supported.",
                action: nil
            )
        default:
            return AlertItem(title: "Error", message: error.localizedDescription, action: nil)
        }
    }
}

// MARK: - Translation error kinds

private extension TranslationError {
    /// Errors that repeat for every sentence until the user changes the setup (F8.5.4 REQ-TR-21).
    var configurationKind: String? {
        switch self {
        case .unsupportedPair: "unsupportedPair"
        case .modelNotLoaded: "modelNotLoaded"
        case .sessionError, .timedOut, .networkUnavailable: nil
        }
    }
}
