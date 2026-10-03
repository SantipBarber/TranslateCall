# M8.5 Stabilization — shared backlog

> Collected 2026-10-03 from the code audit and from running the F8.5.0 test tiers.
> Every `.disabled("F8.5.x: …")`, `withKnownIssue("F8.5.x: …")` and opengrep WARNING points here.
> Tags written before the split say `F8.5.1`; the table below says which sub-feature owns each item.

## Sub-features (decided 2026-10-03)

| Sub-feature | Spec | Items |
|-------------|------|-------|
| F8.5.1 Capture & streams | `f8.5.1-capture-streams/` | A1, A1b, A2, A4, A5, A5b, T1, A10 (Core/Audio) |
| F8.5.2 TTS playback | — | A3, A9, A11, T6, A10 (Core/TTS, VoiceCloning) |
| F8.5.3 Half-duplex + VAD | — | A6, A7, T3, T4 (VAD silence), T2 (evaluation) |
| F8.5.4 Translation | — | A8, T4 (`invalidate()`), T5 |

Out of M8.5 (strategic, later): min macOS 26 / SpeechAnalyzer, WhisperKit → Argmax SDK, own virtual audio driver.

## From the audit (2026-10-03)

| # | Defect | Where | Guard in place |
|---|--------|-------|----------------|
| A1 | Incoming stream created once; dead after Stop → Start | `SystemAudioCaptureService.swift:82` | — (needs test) |
| A1b | `SCStream` created with `delegate: nil` — stream errors / call app quitting go unnoticed | `SystemAudioCaptureService.swift:143` | — |
| A2 | `bufferListNoCopy` buffer escapes into a Task (use-after-free risk) | `SystemAudioCaptureService.swift:236-276` | opengrep `buffer-nocopy-escape` |
| A3 | Edge TTS waits on `isPlaying` forever; `isConnected` never resets; no timeout | `EdgeTTSService.swift:164-170`, `EdgeTTSWebSocket.swift` | opengrep `playernode-isplaying-poll` |
| A4 | Unbounded, unconsumed 48 kHz stream (memory leak) | `AudioManager.swift:52,148,261` | opengrep `asyncstream-unbounded` |
| A5 | Microphone picker not applied (`engine.inputNode` = system default) | `AudioManager.swift:216-248` | — |
| A5b | `selectInput` mid-session recreates streams; VAD keeps iterating the finished one → outgoing dies | `AudioManager.swift:189-198` | — |
| A6 | Half-duplex echo leak (suppression lifted before VAD/STT finish) | `HalfDuplexManager.swift:104-141`, `AudioCoordinator+Pipeline.swift:155-194` | — |
| A7 | Silero VAD never used in production; `VADServiceFactory` dead | `AppContainer.swift:39-40` | — |
| A8 | Translation bridge: single pending slot, no timeout, bridge view tied to the window | `TranslationBridge.swift:27-71` | — |
| A9 | Kokoro/Qwen actor reentrancy plays stale audio after `stopSpeaking` | `KokoroSpeechService.swift:104-110` | — |
| A10 | `cont!` force unwraps (6) and 41 unjustified `nonisolated(unsafe)` | various | opengrep WARNINGs |
| A11 | No EdgeTTSWebSocket / EdgeTTSService playback tests | `TranslateCallTests/` | — |

## Found by the F8.5.0 tiers

| # | Finding | Evidence | Guard in place |
|---|---------|----------|----------------|
| T1 | `start()` skips incoming without an `SCRunningApplication`, which tests can't build → 5 AudioCoordinator tests disabled (incl. `stop()`/`updateLanguagePair()` coverage) | `AudioCoordinatorTests.swift` | `.disabled("F8.5.1: …")` — needs an injectable capture target |
| T2 | Whisper `base` WER 0.5 on `uk-thanks` | integration tier | `withKnownIssue` — evaluate `small`, confidence threshold |
| T3 | `VADConfiguration` has no validation; inconsistent values crash in Debug (FluidAudio asserts) | Silero test crash | — |
| T4 | VAD silence wait (~700 ms) dominates latency; translation 300–960 ms per call (`invalidate()` each time) | `build/reports/latency.json` | latency recorded, not enforced |
| T5 | `TranslationService.supports` defaults to `true` for Apple Translation | `TranslationService.swift:51` | tests use `LanguageAvailability` directly |
| T6 | Qwen3-TTS (MLX) crashes the process when two inferences overlap; `VoicePreviewService.stop()` cancels the Task but not the running MLX inference, so rapid preview clicks can crash the app | crash reports 2026-10-03 17:10/17:14 (`mlx_slice_update` via `QwenCloneClient.synthesize`) | unit tests now inject a mock inferrer — production still needs serialization/cancellation |
