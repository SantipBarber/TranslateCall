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
        let micStream = try await audioCapture.startCapture()
        logger.info("Outgoing: audio capture started")

        // VAD (non-fatal)
        let vad = outgoingVADFactory()
        outgoingVAD = vad
        do {
            try await vad.activate(stream: micStream)
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

    /// Deactivates and releases the outgoing VAD/STT/TTS and their observation tasks, and stops
    /// the mic. Takes ownership synchronously before awaiting (like `teardownIncomingServices`).
    func teardownOutgoingServices() async {
        outgoingTasks.forEach { $0.cancel() }
        outgoingTasks.removeAll()
        let (stt, vad, tts) = (outgoingSTT, outgoingVAD, outgoingTTS)
        outgoingSTT = nil
        outgoingVAD = nil
        outgoingTTS = nil
        await stt?.deactivate()
        await vad?.deactivate()
        audioCapture.stopCapture()
        await tts?.deactivate()
    }

    private struct SupersededActivation: Error {}

    private func ensureCurrent(_ generation: UInt64) throws {
        guard generation == sessionGeneration else { throw SupersededActivation() }
    }

    /// Starts (or restarts) the incoming pipeline. Never throws: the outcome is `incomingStatus`.
    func activateIncoming() async {
        guard let captureTarget else {
            incomingStatus = .disabled
            logger.info("Incoming: disabled — no capture target")
            return
        }
        incomingStatus = .starting
        pendingStopReason = nil
        let generation = sessionGeneration
        do {
            let systemStream = try await systemCapture.activate(target: captureTarget)
            try ensureCurrent(generation)

            let vad = incomingVADFactory()
            incomingVAD = vad
            try await vad.activate(stream: systemStream)
            try ensureCurrent(generation)

            let targetLocale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
            let stt = incomingSTTFactory(targetLocale)
            incomingSTT = stt
            try await stt.activate(stream: vad.speechSegments)
            try ensureCurrent(generation)
            observeIncomingTranscriptions(stt)

            let sourceLocaleForTTS = Locale(identifier: languagePairManager.sourceLanguage.minimalIdentifier)
            let tts = try incomingTTSFactory(sourceLocaleForTTS, nil)
            incomingTTS = tts
            observeTTSState(tts, onSpeakingChange: { [weak self] speaking in
                self?.isIncomingSpeaking = speaking
            }, into: &incomingTasks)

            if let reason = pendingStopReason {
                await abandonIncomingActivation()
                incomingStatus = .stopped(reason)
                return
            }
            incomingStatus = .active
            logger.info("Incoming: active")
        } catch is SupersededActivation {
            await abandonIncomingActivation()
            logger.info("Incoming: activation superseded by stop()")
        } catch {
            await abandonIncomingActivation()   // the thrown error wins over a pending stop event
            if case SystemAudioCaptureError.permissionDenied = error {
                errorAlert = makeAlertItem(for: error)
            }
            incomingStatus = .stopped(IncomingStopReason(error: error))
            logger.warning("Incoming: stopped — \(error.localizedDescription)")
        }
    }

    /// Undoes a partial or doomed activation: drops any pending stop event, releases the incoming
    /// services and stops system capture.
    private func abandonIncomingActivation() async {
        pendingStopReason = nil
        await teardownIncomingServices()
        await systemCapture.deactivate()
    }

    func subscribeToIncomingEvents() {
        guard incomingEventsTask == nil else { return }
        let events = systemCapture.events
        incomingEventsTask = Task { [weak self] in
            for await event in events {
                await self?.handleIncomingEvent(event)
            }
        }
    }

    func handleIncomingEvent(_ event: SystemCaptureEvent) async {
        guard case .stopped(let reason) = event else { return }
        switch incomingStatus {
        case .starting:
            pendingStopReason = reason
        case .active:
            let generation = sessionGeneration
            await teardownIncomingServices()
            // A stop() that interleaved with the teardown already reset us to .idle.
            guard generation == sessionGeneration else { return }
            isIncomingSpeaking = false
            incomingStatus = .stopped(reason)
            logger.warning("Incoming: stopped mid-session — \(reason.message)")
        default:
            break
        }
    }

    /// Deactivates and releases incoming VAD/STT/TTS and their observation tasks.
    /// Takes ownership synchronously before awaiting, so services a newer activation assigns
    /// meanwhile are never cleared without being deactivated.
    func teardownIncomingServices() async {
        incomingTasks.forEach { $0.cancel() }
        incomingTasks.removeAll()
        let (vad, stt, tts) = (incomingVAD, incomingSTT, incomingTTS)
        incomingVAD = nil
        incomingSTT = nil
        incomingTTS = nil
        await vad?.deactivate()
        await stt?.deactivate()
        await tts?.deactivate()
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
