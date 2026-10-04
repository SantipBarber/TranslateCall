# F8.5.2 — TTS Playback — Requirements

> Status: DRAFT — pending user review (2026-10-04)
> Backlog: `specs/m8.5-stabilization/backlog.md` (items A3, A9, A11, T6, A10 for Core/TTS + Core/VoiceCloning) plus findings from the 2026-10-04 code reading (A3b–A3e, A9b, A12)

## Overview

Make speech output reliable on every engine (AVSpeech, Kokoro, Qwen3-TTS voice clone, Edge TTS). Every utterance must either be heard in full and in order or be skipped with a visible reason, within bounded time. `isSpeaking` must be truthful, because the half-duplex logic depends on it. MLX inference must never overlap. To get there, synthesis (text → PCM) is separated from playback (queue, device output, speaking state, fallback) behind the existing `SynthesisService` protocol.

## Motivation (code reading 2026-10-04)

| ID | Defect | Effect for the user |
|----|--------|---------------------|
| A3 | `EdgeTTSService.waitForPlaybackEnd()` polls `playerNode.isPlaying`, which stays `true` after the buffer ends. | `speak()` never returns and `isSpeaking` stays `true`, so half-duplex suppresses the other direction forever. **One Edge utterance mutes the call.** |
| A3b | `EdgeTTSWebSocket.isConnected` is never reset when the server closes or the socket errors. | After an idle close, every later utterance reads a finished stream and returns empty audio: silent, with no error. |
| A3c | No timeout on connect or synthesis. | A stalled network hangs the utterance indefinitely. |
| A3d | Re-entrant `speak()` calls interleave on one socket and one event stream (actor reentrancy at awaits). | Garbled or lost utterances. |
| A3e | `stopSpeaking()` cannot interrupt an in-flight Edge synthesis. | Audio plays after Stop. |
| A9 | Kokoro and Qwen: `stopSpeaking()` during `await synthesize…` still schedules the stale buffer afterwards. | The previous sentence plays after Stop. |
| A9b | Kokoro and Qwen schedule with the default completion type (`.dataConsumed`). | "Done speaking" fires before the audio has been heard, so half-duplex lifts too early (feeds A6). |
| A12 | AVSpeech: `didFinish` (synthesis done) calls `playerNode.stop()` while buffers may still be playing, and each buffer is scheduled via its own `Task`. | Utterance tails can be cut off, and chunk order is not guaranteed. |
| T6 | One shared `QwenCloneClient` is used by session TTS and `VoicePreviewService`. `inferWithTimeout` cancels the Swift task but the MLX computation keeps running. | Overlapping MLX inferences crash the process (crash reports 2026-10-03). |
| A11 | No tests for `EdgeTTSWebSocket` / `EdgeTTSService`. | A3 regressions go unnoticed. |
| — | Outgoing calls `stopSpeaking()` before every new utterance while incoming queues, and Edge does neither. | Inconsistent: the user's own sentences get cut, and the remote side's do not. |

## Decisions taken (brainstorming 2026-10-04)

| ID | Decision |
|----|----------|
| D-1 | **Edge failure → per-utterance fallback.** The failed utterance is spoken with AVSpeech when a system voice exists for the locale; otherwise it is skipped with an unobtrusive notice. The next utterance tries Edge again (subject to the circuit breaker, REQ-T-23). |
| D-2 | **One global MLX inference gate**, plus the voice preview disabled while a session is active. On timeout the utterance falls back (D-1 rules) and the gate stays closed until MLX actually returns. |
| D-3 | **Queue in both directions with a cap of 3 pending utterances**, dropping the oldest when full. Outgoing no longer interrupts the previous utterance. |
| D-4 | **Architecture: separate synthesis from playback** (approach 1). `UtteranceSynthesizer` turns text into a PCM stream; one `TTSPlaybackService` per direction owns queue, output, speaking state, fallback and events. `SynthesisService` stays the coordinator-facing protocol. |
| D-5 | The half-duplex echo (A6) stays in F8.5.3. This feature guarantees a truthful `isSpeaking`, which F8.5.3 builds on. |
| D-6 | opengrep `asyncstream-unbounded` no longer flags declarations (done on the spec branch, bae2afd). This feature promotes it to ERROR. |

## Functional Requirements

### FR-8.5.2.1 — Synthesizers

**REQ-T-01**: A `UtteranceSynthesizer` protocol SHALL expose `engine: TTSEngine`, `canSpeak(_ locale: Locale) -> Bool` and `synthesize(text:locale:) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>`. The stream yields one utterance's PCM buffers in playback order, finishes when the utterance is complete, and throws on failure or timeout.

**REQ-T-02**: There SHALL be four synthesizers: AVSpeech (`AVSpeechSynthesizer.write`), Kokoro (`KokoroModelManager`), Qwen voice clone (through `MLXInferenceGate`) and Edge (`EdgeTTSWebSocket`). No synthesizer SHALL own an `AVAudioEngine` or player node.

**REQ-T-03**: The AVSpeech synthesizer SHALL yield buffers in callback order, without one `Task` per buffer, and SHALL finish the stream on the synthesizer's completion. It SHALL finish with no buffers when the utterance produced no audio.

**REQ-T-04**: Kokoro and Qwen SHALL keep their existing text truncation rules (500 characters for Kokoro, `config.textTruncationLimit` for Qwen, cut at a word boundary).

**REQ-T-05**: Edge SHALL decode the MP3 response to PCM in memory, without temporary files.

### FR-8.5.2.2 — Playback service

**REQ-T-10**: `TTSPlaybackService` (an actor conforming to `SynthesisService`) SHALL be the only `SynthesisService` the coordinator receives for any engine. It is built from `primary: UtteranceSynthesizer`, `fallback: UtteranceSynthesizer?` and an output.

**REQ-T-11**: `speak` SHALL enqueue and return without waiting for playback. One worker per service SHALL process utterances strictly one at a time, in FIFO order.

**REQ-T-12**: At most 3 utterances SHALL be pending (not counting the one in flight). When a 4th arrives, the oldest pending one SHALL be dropped and an `.utteranceDropped` event emitted. Empty or whitespace-only text SHALL be ignored.

**REQ-T-13**: Buffers SHALL be scheduled as they arrive. The service SHALL wait only for the last buffer of an utterance to have been played back (`.dataPlayedBack`).

**REQ-T-14**: `isSpeakingStream` SHALL emit `true` when an utterance starts while idle. It SHALL emit `false` only when the last buffer of the last queued utterance has played back, when the queue empties after a skip, or immediately on `stopSpeaking`/`deactivate`. There SHALL be no `false`→`true` flicker between consecutive queued utterances.

**REQ-T-15**: `stopSpeaking()` SHALL increment a generation counter, clear the queue, stop scheduled playback and abandon the in-flight synthesis. No buffer from an earlier generation SHALL ever be scheduled (A9, A3e).

**REQ-T-16**: Every utterance SHALL end, either played or skipped with an event, within a bounded time. A per-utterance watchdog (default 30 s, injectable) SHALL skip an utterance whose synthesizer never finishes.

**REQ-T-17**: `setAudioMonitor` SHALL keep working: the monitor receives a copy of every buffer that is scheduled.

**REQ-T-18**: The service SHALL expose `events: AsyncStream<TTSEvent>` (bounded buffer) with at least `.utteranceDropped`, `.utteranceSkipped(TTSSkipReason)` and `.fellBack(from: TTSEngine, to: TTSEngine)`. `TTSSkipReason` covers `noVoice`, `primaryFailed(String)`, `interrupted`, `timeout` and `outputUnavailable`.

**REQ-T-19**: Metrics SHALL be recorded once per utterance: the engine actually used, latency to the first buffer, text length and locale.

### FR-8.5.2.3 — Fallback and Edge resilience

**REQ-T-20**: If the primary fails before yielding any buffer, the same utterance SHALL be retried with the fallback (if it `canSpeak` the locale) and `.fellBack` emitted. Otherwise the utterance is skipped with `.utteranceSkipped(.primaryFailed)`.

**REQ-T-21**: If the primary fails after audio has started, the rest of the utterance SHALL be dropped (no replay through the fallback) and `.utteranceSkipped(.interrupted)` emitted.

**REQ-T-22**: The fallback for Edge, Kokoro and Qwen SHALL be AVSpeech when a system voice exists for the locale. AVSpeech as primary has no fallback.

**REQ-T-23**: After 3 consecutive primary failures, utterances SHALL go straight to the fallback for 30 s (injectable clock), then the primary is tried again.

**REQ-T-24**: `EdgeTTSWebSocket` SHALL derive `isConnected` from socket events: `disconnected`, `cancelled`, `peerClosed` and `error` set it to `false` and discard the event stream.

**REQ-T-25**: Edge timeouts SHALL be: connect 5 s, first audio chunk after sending SSML 5 s, whole utterance 20 s (all injectable for tests).

**REQ-T-26**: If the connection was dead when an utterance starts, or dies before any audio arrives, Edge SHALL reconnect once and retry. A second failure throws.

**REQ-T-27**: Edge SHALL be testable without network: the Starscream socket sits behind an `EdgeTransport` protocol.

### FR-8.5.2.4 — MLX inference gate

**REQ-T-30**: An `MLXInferenceGate` actor SHALL run at most one Qwen inference at a time, process-wide, for both session TTS and voice preview.

**REQ-T-31**: `QwenCloneModelManager` SHALL hand out inference only through the gate. No public API SHALL return the raw `QwenCloneClient`.

**REQ-T-32**: The gate SHALL accept a wait limit (default 2 s) and an inference limit (`config.inferenceTimeoutSeconds`). If the wait is exceeded it throws `.gateBusy`; if inference is exceeded it throws `.inferenceTimeout` to the caller while keeping the gate closed until the underlying inference returns. The late result is discarded.

**REQ-T-33**: The voice-preview controls SHALL be disabled while a translation session is active.

### FR-8.5.2.5 — Coordinator and UI

**REQ-T-40**: `AudioCoordinator.handleOutgoingTranslation` SHALL no longer call `stopSpeaking()` before speaking (D-3).

**REQ-T-41**: `TTSEvent.utteranceSkipped` and `.fellBack` SHALL surface as a non-modal notice line in the main window (latest event, auto-clearing after 5 s). They SHALL NOT appear as alerts.

**REQ-T-42**: The legacy `AVSpeechService`, `KokoroSpeechService`, `QwenCloneSpeechService` and `EdgeTTSService` SHALL be removed or reduced to synthesizers. No second playback implementation SHALL remain in `Core/TTS` or `Core/VoiceCloning` except `TTSAudioMonitor` and the voice preview's own player.

### FR-8.5.2.6 — Hygiene

**REQ-T-50**: In `Core/TTS` and `Core/VoiceCloning`: no `cont!`, no AsyncStream without an explicit buffering policy, and every `nonisolated(unsafe)` carries a `// SAFETY:` justification.

**REQ-T-51**: The opengrep rules `playernode-isplaying-poll`, `asyncstream-unbounded` and `asyncstream-force-unwrap` SHALL be promoted to ERROR once their last occurrence is gone. The rule `nonisolated-unsafe-justified` SHALL be promoted only if its findings reach zero repo-wide.

## Non-Functional Requirements

**NFR-T-01**: The gap between consecutive buffers of one AVSpeech utterance SHALL NOT be audibly different from today's (buffers are scheduled ahead, never awaited one by one).

**NFR-T-02**: `isSpeaking` SHALL become `false` no earlier than the moment the last audio sample has played, and no later than 150 ms after it (measured in the integration test).

**NFR-T-03**: Unit tests SHALL NOT use the network, real ML models (Kokoro/CoreML, Qwen/MLX) or an audio device.

## Out of Scope

- Half-duplex echo leak (A6), VAD (A7, T3, T4), Whisper accuracy (T2) → F8.5.3.
- Translation bridge (A8, T4 translation, T5) → F8.5.4.
- Streaming Edge playback (playing while audio still arrives): a latency optimisation for later.
- Refactoring the voice preview's own playback (it only goes through the gate and is disabled during sessions).

## Acceptance Criteria

1. `just pr` passes on the feature branch.
2. Unit tests cover every REQ-T-1x/2x/3x behaviour listed in design.md §5 with fake synthesizers, output, transport and clock.
3. Integration tier:
   - AVSpeech through `TTSPlaybackService` into BlackHole, captured by `AudioManager`: audio arrives in order, the tail is not cut, and `isSpeaking` turns `false` within NFR-T-02's window.
   - Edge "hello" (en-US) yields non-empty PCM within 10 s. Missing network **fails** with an explicit prerequisite message.
4. The manual checklist in tasks.md is completed:
   - Edge with the network cut mid-call falls back to AVSpeech with a notice and recovers within 30 s.
   - The preview is disabled during a session.
   - 10 rapid preview clicks outside a session do not crash.
   - Long AVSpeech utterances are not truncated.
   - Outgoing sentences are queued, not cut.
5. opengrep: rules promoted per REQ-T-51. Zero findings of the three rules in `Core/TTS` and `Core/VoiceCloning`.
6. Backlog: A3, A9, A11, T6 (and A3b–e, A9b, A12) marked fixed in F8.5.2 with their pinning tests.
