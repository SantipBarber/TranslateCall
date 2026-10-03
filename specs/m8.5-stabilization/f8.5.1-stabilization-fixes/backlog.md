# F8.5.1 — Stabilization fixes: backlog (input for requirements.md)

> Collected 2026-10-03 from the code audit and from running the F8.5.0 test tiers.
> Every `.disabled("F8.5.1: …")`, `withKnownIssue("F8.5.1: …")` and opengrep WARNING points here.

## From the audit (2026-10-03)

| # | Defect | Where | Guard in place |
|---|--------|-------|----------------|
| A1 | Incoming stream created once; dead after Stop → Start | `SystemAudioCaptureService.swift:82` | — (needs test) |
| A2 | `bufferListNoCopy` buffer escapes into a Task (use-after-free risk) | `SystemAudioCaptureService.swift:236-276` | opengrep `buffer-nocopy-escape` |
| A3 | Edge TTS waits on `isPlaying` forever; `isConnected` never resets; no timeout | `EdgeTTSService.swift:164-170`, `EdgeTTSWebSocket.swift` | opengrep `playernode-isplaying-poll` |
| A4 | Unbounded, unconsumed 48 kHz stream (memory leak) | `AudioManager.swift:52,148,261` | opengrep `asyncstream-unbounded` |
| A5 | Microphone picker not applied (`engine.inputNode` = system default) | `AudioManager.swift:216-248` | — |
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
