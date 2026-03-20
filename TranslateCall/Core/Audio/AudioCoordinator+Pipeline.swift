import AVFoundation
import OSLog
@preconcurrency import ScreenCaptureKit

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "AudioCoordinator")

// MARK: - Pipeline setup, observation, translation & error helpers

extension AudioCoordinator {

    // MARK: - Pipeline setup

    /// Starts the outgoing pipeline. Only `audioCapture.startCapture()` failure propagates to caller.
    /// VAD, STT, and TTS failures are caught and stored in `errorAlert` — pipeline continues
    /// without the failed component so the incoming pipeline can still start.
    func startOutgoingPipeline(blackHoleDeviceID: AudioDeviceID?) async throws {
        // Fatal: mic permission required for the app to function at all.
        try await audioCapture.startCapture()
        logger.info("Outgoing: audio capture started")

        // VAD (non-fatal)
        let vad = outgoingVADFactory()
        outgoingVAD = vad
        do {
            try await vad.activate(stream: audioCapture.audioStream16kHz)
            observeVADState(vad)
            logger.info("Outgoing: VAD activated")
        } catch {
            errorAlert = makeAlertItem(for: error)
            logger.warning("Outgoing: VAD failed — \(error.localizedDescription)")
        }

        // STT (non-fatal)
        let sourceLocale = Locale(identifier: languagePairManager.sourceLanguage.minimalIdentifier)
        let stt = outgoingSTTFactory(sourceLocale)
        outgoingSTT = stt
        do {
            try await stt.activate(stream: vad.speechSegments)
            observeOutgoingTranscriptions(stt)
            logger.info("Outgoing: STT activated for \(sourceLocale.identifier)")
        } catch {
            errorAlert = makeAlertItem(for: error)
            logger.warning("Outgoing: STT failed — \(error.localizedDescription)")
        }

        // TTS (non-fatal)
        let targetLocaleForTTS = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
        do {
            let tts = try outgoingTTSFactory(targetLocaleForTTS, blackHoleDeviceID)
            outgoingTTS = tts
            // Attach monitor if enabled (so user can hear outgoing TTS through speakers)
            if ttsMonitorEnabled {
                await tts.setAudioMonitor(ttsMonitor)
            }
            observeTTSState(tts, onSpeakingChange: { [weak self] speaking in
                self?.isOutgoingSpeaking = speaking
            }, into: &outgoingTasks)
            logger.info("Outgoing: TTS activated")
        } catch {
            errorAlert = makeAlertItem(for: error)
            logger.warning("Outgoing: TTS failed — \(error.localizedDescription)")
        }
    }

    /// Starts the incoming pipeline. All failures are non-fatal — errorAlert is set
    /// and `isIncomingActive` remains false if activation fails.
    func startIncomingPipeline(captureApp: SCRunningApplication?) async {
        guard captureApp != nil else {
            logger.info("Incoming: skipped — no capture app selected")
            return
        }
        do {
            try await systemCapture.activate(app: captureApp)
            logger.info("Incoming: system audio capture started")

            let vad = incomingVADFactory()
            incomingVAD = vad
            try await vad.activate(stream: systemCapture.audioStream16kHz)
            logger.info("Incoming: VAD activated")

            let targetLocale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
            let stt = incomingSTTFactory(targetLocale)
            incomingSTT = stt
            try await stt.activate(stream: vad.speechSegments)
            observeIncomingTranscriptions(stt)
            logger.info("Incoming: STT activated for \(targetLocale.identifier)")

            let sourceLocaleForTTS = Locale(identifier: languagePairManager.sourceLanguage.minimalIdentifier)
            let tts = try incomingTTSFactory(sourceLocaleForTTS, nil)
            incomingTTS = tts
            observeTTSState(tts, onSpeakingChange: { [weak self] speaking in
                self?.isIncomingSpeaking = speaking
            }, into: &incomingTasks)
            logger.info("Incoming: TTS activated")

            isIncomingActive = true
        } catch {
            errorAlert = makeAlertItem(for: error)
            logger.warning("Incoming pipeline failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Observation helpers

    private func observeVADState(_ vad: some VADService) {
        outgoingTasks.append(Task { [weak self] in
            for await active in vad.vadStateEvents {
                self?.isSpeechActive = active
            }
        })
    }

    private func observeOutgoingTranscriptions(_ stt: some SpeechRecognizerService) {
        outgoingTasks.append(Task { [weak self] in
            guard let self else { return }
            for await result in stt.transcriptionStream {
                self.outgoingTranscription = result.text
                await self.handleOutgoingTranslation(of: result.text)
            }
        })
    }

    private func observeIncomingTranscriptions(_ stt: some SpeechRecognizerService) {
        incomingTasks.append(Task { [weak self] in
            guard let self else { return }
            for await result in stt.transcriptionStream {
                self.incomingTranscription = result.text
                await self.handleIncomingTranslation(of: result.text)
            }
        })
    }

    private func observeTTSState(
        _ tts: some SynthesisService,
        onSpeakingChange: @escaping (Bool) -> Void,
        into tasks: inout [Task<Void, Never>]
    ) {
        tasks.append(Task { [weak self] in
            for await speaking in tts.isSpeakingStream {
                guard self != nil else { return }
                onSpeakingChange(speaking)
            }
        })
    }

    func cancelAllTasks() {
        outgoingTasks.forEach { $0.cancel() }
        outgoingTasks.removeAll()
        incomingTasks.forEach { $0.cancel() }
        incomingTasks.removeAll()
    }

    // MARK: - Translation handlers

    private func handleOutgoingTranslation(of text: String) async {
        // One-shot mute turn: user explicitly requested to skip this utterance.
        if suppressNextOutgoingTurnFlag {
            suppressNextOutgoingTurnFlag = false
            logger.debug("Suppressing next outgoing utterance (mute turn)")
            return
        }
        // Suppress when incoming TTS is playing on speakers — prevents mic-pickup feedback loop.
        guard !text.isEmpty, !outgoingCaptureSuppressed else { return }
        await outgoingTTS?.stopSpeaking()
        do {
            let translated = try await outgoingTranslationService.translate(
                text: text,
                from: languagePairManager.sourceLanguage,
                to: languagePairManager.targetLanguage
            )
            outgoingTranslation = translated
            let locale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
            await outgoingTTS?.speak(text: translated, locale: locale)
        } catch {
            errorAlert = makeAlertItem(for: error)
        }
    }

    private func handleIncomingTranslation(of text: String) async {
        // Suppress when outgoing TTS is active (BlackHole loopback prevention) or self is speaking.
        guard !text.isEmpty, !incomingCaptureSuppressed, !isIncomingSpeaking else { return }
        do {
            let translated = try await incomingTranslationService.translate(
                text: text,
                from: languagePairManager.targetLanguage,
                to: languagePairManager.sourceLanguage
            )
            incomingTranslation = translated
            let locale = Locale(identifier: languagePairManager.sourceLanguage.minimalIdentifier)
            await incomingTTS?.speak(text: translated, locale: locale)
        } catch {
            errorAlert = makeAlertItem(for: error)
        }
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
        case TranslationError.bridgeUnavailable:
            return AlertItem(
                title: "Translation Unavailable",
                message: "Translation bridge unavailable. Restart the app.",
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
