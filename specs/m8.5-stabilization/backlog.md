# M8.5 Stabilization — shared backlog

> Collected 2026-10-03 from the code audit and from running the F8.5.0 test tiers.
> Every `.disabled("F8.5.x: …")`, `withKnownIssue("F8.5.x: …")` and opengrep WARNING points here.
> Tags written before the split say `F8.5.1`; the table below says which sub-feature owns each item.

## Sub-features (decided 2026-10-03)

| Sub-feature | Spec | Items |
|-------------|------|-------|
| F8.5.1 Capture & streams | `f8.5.1-capture-streams/` | A1, A1b, A2, A4, A5, A5b, T1, A10 (Core/Audio) |
| F8.5.2 TTS playback | `f8.5.2-tts-playback/` | A3, A3b–e, A9, A9b, A12, A11, T6, A10 (Core/TTS, VoiceCloning) |
| F8.5.3 Half-duplex + VAD | — | A6, A7, A13, A14, A15, T3, T4 (VAD silence), T2 (evaluation) |
| F8.5.4 Translation | — | A8, T4 (`invalidate()`), T5 |

Out of M8.5 (strategic, later): min macOS 26 / SpeechAnalyzer, WhisperKit → Argmax SDK, own virtual audio driver.

## From the audit (2026-10-03)

| # | Defect | Where | Guard in place |
|---|--------|-------|----------------|
| A1 | Incoming stream created once; dead after Stop → Start | `SystemAudioCaptureService.swift:82` | fixed in F8.5.1 — `AudioCoordinatorTests.restartGivesFreshIncomingStream` |
| A1b | `SCStream` created with `delegate: nil` — stream errors / call app quitting go unnoticed | `SystemAudioCaptureService.swift:143` | fixed in F8.5.1 — `AudioCoordinatorTests.streamStopTearsDownIncoming`, `SystemAudioCaptureServiceTests.stopReasonMapping` |
| A2 | `bufferListNoCopy` buffer escapes into a Task (use-after-free risk) | `SystemAudioCaptureService.swift:236-276` | fixed in F8.5.1 — `SystemAudioCaptureServiceTests.extractedBufferOwnsMemory`; opengrep `buffer-nocopy-escape` (ERROR) |
| A3 | Edge TTS waits on `isPlaying` forever; `isConnected` never resets; no timeout | `EdgeTTSService.swift:164-170`, `EdgeTTSWebSocket.swift` | fixed in F8.5.2 (PR #5) — `EdgeTTSService` deleted; `TTSPlaybackServiceTests.truthfulSpeaking`, `.stalledOutput`; opengrep `playernode-isplaying-poll` (ERROR) |
| A3b | Edge `isConnected` never reset on server close/error → silent empty audio forever | `EdgeTTSWebSocket.swift:22,144` | fixed in F8.5.2 — `EdgeTTSWebSocketTests.closingEventDisconnects`, `EdgeUtteranceSynthesizerTests.reconnectsOnce`, `.emptyTurnFallsBack` |
| A3c | Edge: no connect/synthesis timeout | `EdgeTTSWebSocket.swift` | fixed in F8.5.2 — `EdgeTTSWebSocketTests.connectTimeout`, `.firstChunkTimeout`, `.utteranceTimeout` |
| A3d | Edge: re-entrant `speak` interleaves on one socket | `EdgeTTSService.swift:50` | fixed in F8.5.2 — one worker per direction: `TTSPlaybackServiceTests.fifoOneAtATime` |
| A3e | Edge: `stopSpeaking` can't interrupt in-flight synthesis | `EdgeTTSService.swift:87` | fixed in F8.5.2 — `TTSPlaybackServiceTests.stopDuringSynthesis` |
| A9b | Kokoro/Qwen schedule with `.dataConsumed` → isSpeaking false before audio is heard | `KokoroSpeechService.swift:214` | fixed in F8.5.2 — `.dataPlayedBack` handles: `TTSPlaybackServiceTests.schedulesAheadAwaitsLast`, `TTSPlaybackIntegrationTests.avSpeechThroughBlackHole` |
| A12 | AVSpeech `didFinish` stops the player while buffers still play (tail cut); one Task per buffer (order) | `AVSpeechService.swift:150-200` | fixed in F8.5.2 — `TTSPlaybackIntegrationTests.avSpeechThroughBlackHole`, `TTSPlaybackServiceTests.observerSeesEveryBuffer` (order) |
| A4 | Unbounded, unconsumed 48 kHz stream (memory leak) | `AudioManager.swift:52,148,261` | fixed in F8.5.1 — `SessionAudioStreamTests.overflowDropsOldest`; opengrep `asyncstream-unbounded` |
| A5 | Microphone picker not applied (`engine.inputNode` = system default) | `AudioManager.swift:216-248` | fixed in F8.5.1 — `MicCaptureIntegrationTests.selectedDeviceIsUsed` |
| A5b | `selectInput` mid-session recreates streams; VAD keeps iterating the finished one → outgoing dies | `AudioManager.swift:189-198` | fixed in F8.5.1 — `MicCaptureIntegrationTests.hotSwapKeepsStream` |
| A5c | AVAudioEngine input-node client format stays at the default device's after rebinding CurrentDevice: other-rate devices are silent or crash in `installTap` (found in F8.5.1 integration) | `AudioManager.swift` | fixed in F8.5.1 (tap at hardware rate) — `MicCaptureIntegrationTests.hotSwapAcrossSampleRates` |
| A6 | Half-duplex echo leak (suppression lifted before VAD/STT finish) | `HalfDuplexManager.swift:104-141`, `AudioCoordinator+Pipeline.swift:155-194` | — |
| A7 | Silero VAD never used in production; `VADServiceFactory` dead | `AppContainer.swift:39-40` | — |
| A8 | Translation bridge: single pending slot, no timeout, bridge view tied to the window | `TranslationBridge.swift:27-71` | — |
| A9 | Kokoro/Qwen actor reentrancy plays stale audio after `stopSpeaking` | `KokoroSpeechService.swift:104-110` | fixed in F8.5.2 — `TTSPlaybackServiceTests.stopDuringSynthesis`, `KokoroUtteranceSynthesizerTests.cancelledWhileLoading` |
| A10 | `cont!` force unwraps (6) and 41 unjustified `nonisolated(unsafe)` | various | Core/Audio, Core/TTS, Core/VoiceCloning clean (F8.5.1–F8.5.2); `asyncstream-*` ERROR; 4 `nonisolated(unsafe)` left in Core/STT, Core/Translation |
| A11 | No EdgeTTSWebSocket / EdgeTTSService playback tests | `TranslateCallTests/` | fixed in F8.5.2 — `EdgeTTSWebSocketTests`, `EdgeUtteranceSynthesizerTests`, `EdgeTTSIntegrationTests.hello` |

## Found by the F8.5.0 tiers

| # | Finding | Evidence | Guard in place |
|---|---------|----------|----------------|
| T1 | `start()` skips incoming without an `SCRunningApplication`, which tests can't build → 5 AudioCoordinator tests disabled (incl. `stop()`/`updateLanguagePair()` coverage) | `AudioCoordinatorTests.swift` | fixed in F8.5.1 — the 5 re-enabled `AudioCoordinatorTests` |
| T2 | Whisper `base` WER 0.5 on `uk-thanks` | integration tier | `withKnownIssue` — evaluate `small`, confidence threshold |
| T3 | `VADConfiguration` has no validation; inconsistent values crash in Debug (FluidAudio asserts) | Silero test crash | — |
| T4 | VAD silence wait (~700 ms) dominates latency; translation 300–960 ms per call (`invalidate()` each time) | `build/reports/latency.json` | latency recorded, not enforced |
| T5 | `TranslationService.supports` defaults to `true` for Apple Translation | `TranslationService.swift:51` | tests use `LanguageAvailability` directly |
| T6 | Qwen3-TTS (MLX) crashes the process when two inferences overlap; `VoicePreviewService.stop()` cancels the Task but not the running MLX inference, so rapid preview clicks can crash the app | crash reports 2026-10-03 17:10/17:14 (`mlx_slice_update` via `QwenCloneClient.synthesize`) | fixed in F8.5.2 — `MLXInferenceGateTests.oneAtATime`, `.timeoutKeepsGateClosed`, `.gateBusy`; manual M2 |

## Found by the F8.5.2 review (2026-10-04)

| # | Finding | Where | Guard in place |
|---|---------|-------|----------------|
| A13 | Two-way TTS queueing (D-3/D-7) × half-duplex suppression: while incoming TTS speaks a backlog (up to 4 sentences) `outgoingCaptureSuppressed` drops the user's translated sentences silently (and vice versa for incoming while the user's backlog plays); Edge-only locale with Edge down keeps `isSpeaking` true during silent failed attempts. Options: shrink suppression to the echo-risky case, flush the other direction's queue when the user starts speaking, show a "not sent" notice. Owner: F8.5.3 | `AudioCoordinator+Pipeline.swift` (`handleIncomingTranslation` guard), `HalfDuplexManager.swift`, `TTSPlaybackService.swift` | `AudioCoordinatorTTSTests.incomingDroppedWhileSuppressed` (pins today's drop, REQ-T-43); manual M6 |

## From the F8.5.2 manual checklist (2026-10-04)

| # | Finding | Where | Guard in place |
|---|---------|-------|----------------|
| A14 | No way for one person to hear the translated voice end to end. Outgoing TTS goes to BlackHole (it is heard only through the call app or the **Monitor** toggle); incoming needs a remote party. Solo procedure, until a test harness exists: (1) outgoing: turn **Monitor** on in the main window and speak; (2) incoming: quit Zoom/Teams so every running app is listed as capture app, pick Safari/Chrome, play speech in the remote language in it; the translation plays on the default output. Idea: a "loopback test" mode or a call-simulation container (see dev-workflow future idea). Owner: F8.5.3 (decide) | `SetupManager.swift:72-81` (capture-app list), `ContentView.swift` monitor row | manual only |
| A15 | Long speech is split into many short sentences: the VAD ends a segment at short pauses (minSilence 0.75 s), so a long sentence is translated in pieces (F8.5.2 M3). Same knob as T4. Owner: F8.5.3 | `VADConfiguration` | manual M3 |
| A16 | Kokoro judged "not very good" (F8.5.2 M5) — quality vs. Stop/Start behaviour not yet separated. Detail before deciding. Owner: unassigned | `KokoroUtteranceSynthesizer` | — |
