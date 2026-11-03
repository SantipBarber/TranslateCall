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
        // Speakers mode mutes the mic here, before the VAD, while the remote translation plays (D-3).
        // Pause (M9 UI core D-5) comes first, so pausing never touches the echo gate's own state.
        let pausable = pauseGate?.gate(micStream, label: "outgoing-pause") ?? micStream
        let vadInput = micEchoGate?.gate(pausable) ?? pausable

        // VAD (non-fatal)
        let vad = await outgoingVADFactory()
        outgoingVAD = vad
        do {
            try await vad.activate(stream: vadInput)
            observeVADState(vad)
            logger.info("Outgoing: VAD activated")
        } catch {
            errorAlert = makeAlertItem(for: error)
            logger.warning("Outgoing: VAD failed — \(error.localizedDescription)")
        }

        startOutgoingCommitter(boundaries: vad.boundaryEvents)

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
            observeTTSEvents(tts, language: languagePairManager.targetLanguage, into: &outgoingTasks)
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
        outgoingCommitter?.cancelAll()   // held and in-flight sentences are never shown nor spoken
        outgoingCommitter = nil
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

            let vad = await incomingVADFactory()
            try ensureCurrent(generation)
            incomingVAD = vad
            try await vad.activate(stream: pauseGate?.gate(systemStream, label: "incoming-pause") ?? systemStream)
            try ensureCurrent(generation)
            observeIncomingVADState(vad)
            startIncomingCommitter(boundaries: vad.boundaryEvents)

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
            observeTTSEvents(tts, language: languagePairManager.sourceLanguage, into: &incomingTasks)

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
        // During stop() the session is going away: a late .stopped must not leave a stale banner.
        guard case .stopped(let reason) = event, !isStopping else { return }
        switch incomingStatus {
        case .starting:
            pendingStopReason = reason
        case .active:
            let generation = sessionGeneration
            await teardownIncomingServices()
            // A stop() (or Retry) that interleaved with the teardown already owns the status.
            guard generation == sessionGeneration, incomingStatus == .active, !isStopping else { return }
            incomingStatus = .stopped(reason)
            logger.warning("Incoming: stopped mid-session — \(reason.message)")
        default:
            break
        }
    }

    /// Deactivates and releases incoming VAD/STT/TTS and their observation tasks.
    /// Takes ownership synchronously before awaiting, so services a newer activation assigns
    /// meanwhile are never cleared without being deactivated.
    /// Covers every incoming teardown (stream stop, abandoned activation, stop()): with the TTS
    /// observer cancelled nothing would clear `isIncomingSpeaking`, so the incoming side is marked
    /// silent and the mic gate reopens here, before any await (REQ-H-06, design §3.2).
    func teardownIncomingServices() async {
        incomingTasks.forEach { $0.cancel() }
        incomingTasks.removeAll()
        incomingCommitter?.cancelAll()
        incomingCommitter = nil
        isIncomingSpeaking = false
        isIncomingSpeechActive = false
        reopenMicEchoGate()
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

    private func observeTTSState(
        _ tts: some SynthesisService,
        onSpeakingChange: @escaping (Bool) -> Void,
        into tasks: inout [Task<Void, Never>]
    ) {
        tasks.append(Task { [weak self] in
            for await speaking in tts.isSpeakingStream {
                // A value already queued when the teardown cancelled this task must not undo its
                // reset (a late `true` would re-mute the mic with no `false` to follow).
                guard !Task.isCancelled, self != nil else { return }
                onSpeakingChange(speaking)
            }
        })
    }

    /// Skips, fallbacks and drops of a `TTSPlaybackService` → the notice line (REQ-T-41).
    private func observeTTSEvents(
        _ tts: some SynthesisService,
        language: Locale.Language,
        into tasks: inout [Task<Void, Never>]
    ) {
        guard let events = tts.ttsEvents else { return }
        let languageName = languagePairManager.displayName(for: language)
        tasks.append(Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.showTTSNotice(event.noticeText(language: languageName))
            }
        })
    }

    func cancelAllTasks() {
        outgoingTasks.forEach { $0.cancel() }
        outgoingTasks.removeAll()
        incomingTasks.forEach { $0.cancel() }
        incomingTasks.removeAll()
    }
}
