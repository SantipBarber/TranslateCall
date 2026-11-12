# Changelog

All notable changes to TranslateCall. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions up to 0.8.0 are the `MARKETING_VERSION` bumps that closed a milestone (no git tags).
From 0.9.0 on, each release is also a git tag (`v0.9.0`). Add an entry with every PR (see the PR template).

## [Unreleased]

## [0.9.0] — 2026-11-12 — M8.5 Stabilization + M9 Product (in progress)

### Known issues and open decisions
- mlx-audio-swift comes from the fork `SantipBarber/mlx-audio-swift` (branch `translatecall-pitch-fix`). Upstream v0.1.9 (2026-11-09) contains the ICL priming fix (#371); ahead-of-sentence priming is upstream PR #391, still open. Back to the official package once both are released (QS-7).
- Apple Speech drops results under confidence 0.60 (QS-8). Drops are now traced; whether to lower the threshold waits for real-call data.
- `voice-pitch` scenario: one sentence goes over the ±12 % tolerance in 2 of 5 runs. Tolerance not decided.
- en>es Best latency sits at the 1.5 s gate (p50 ~1.5 s); translation is the largest stage (QS-5).
- Since macOS 27.2, `isSpeaking` ends 190–280 ms after the last audio, over the 150 ms limit (A30, known issue in tests).
- Edge TTS returns 403 and is shown as "Temporarily unavailable" (A27).
- Full list: `specs/m9-product/backlog.md`.

### M9 — Product (2026-10-17 → today)

#### Added
- Scenario tests (`just scenario`): echo loop, output picker, voice pitch, hesitations and the Pause button (#15, #18).
- Voice-clone streaming for the Best profile: Qwen3-TTS `generateStream` through `MLXInferenceGate`, guided 8 s reference reading in 10 languages, and early end-of-turn (tentative / commit / retract) so STT and translation start before the pause is confirmed (#14).
- UI settings: per-pair models, Settings tabs, downloads inside each row (#12).
- Benchmark harness: real-time end-to-end bench (`just bench`), quality metrics (WER, gaps, cuts) and a first baseline (#11).
- UI core: setup window, automatic model selection, status panel, menu bar, Settings (#10).
- UI redesign brief and the pen.dev prototype (42 screens) (#9).
- STT results dropped for low confidence are traced as `dropped` with the text and confidence (#19).

#### Changed
- The user's voice recording is analysed once per session, not once per sentence (#17).
- mlx-audio-swift 0.1.8 (through the fork, see Known issues) (#15).

#### Fixed
- The cloned voice no longer drifts higher than the user's voice (about 1 sentence in 8 came out +30–60 % higher) (#16).
- The speaker echo loop: the app no longer re-translates its own output (Q6) (#15).
- `pause-long` scenario: the pause now falls between words, not inside one (QS-8) (#19).
- Xcode 27.1 builds again (EventSource 1.5.1) (#13).
- The main window opens at launch (A26) (#8).

### M8.5 — Stabilization (2026-10-03 → 2026-10-17)

#### Added
- Development workflow: `just` entry point, pinned tool versions, SwiftLint strict, opengrep rules, unit and integration test tiers, ES/EN/UK audio fixtures, `just pr` gate publishing the `local/just-pr` status, PR template and CONTRIBUTING (#3).
- Source code of the five M0 proofs of concept (#2).

#### Changed
- Translation: persistent session, watchdog, off-screen bridges, warm-up at Start (F8.5.4, #7).
- Half-duplex replaced by Silero VAD plus a mic echo gate; no sentence is lost (F8.5.3, #6).
- TTS: synthesis and playback split, fallback chain, MLX gate, Edge TTS rewrite (F8.5.2, #5).
- Audio capture: per-session streams, mic hot swap, incoming status (F8.5.1, #4).

## [0.8.0] — 2026-03-17 — M8 Full language coverage
### Added
- WhisperKit STT: 99+ languages, CoreML on the ANE (F8.1).
- Edge TTS cloud fallback for Ukrainian and about 30 languages, with a consent dialog (F8.2).
- `TranslationEngineSelector` abstraction for future translation backends (F8.3).
### Changed
- Edge TTS WebSocket moved to Starscream; Swift 6 concurrency cleanup (2026-04-11).
### Fixed
- EN→UK translation (BUG-1); about 65 build warnings, now zero.

## [0.7.0] — 2026-03-16 — M6 Enhanced speech + M7 Voice cloning
### Added
- Parakeet STT through FluidAudio (F6.1) and Kokoro TTS through MLX-Audio (F6.2).
- Voice profile training (F7.1), Qwen3-TTS voice cloning (F7.2) and its UX (F7.3).

## [0.5.0] — 2026-03-10 — M4 Full pipeline + M5 Beta
### Added
- Bidirectional pipeline with `AudioCoordinator` and `AppContainer` wiring (F4.1); half-duplex manager (F4.2).
- Setup wizard, call-app selector and route test (F4.3).
- Menu bar status item, device and language persistence, keyboard shortcuts (F5.1, F5.2).
- Feedback menu and release scripts (F5.3).

## M1–M3 — Foundation, speech pipeline, translation core (2026-03-06 → 2026-03-09)
### Added
- Project setup, `AudioManager` and basic UI shell (M1).
- Speech pipeline: VAD, STT, TTS (M2). On-device translation core (M3).

## M0 — Proofs of concept (2026-01-17 → 2026-02-01)
- Project documentation and five PoCs; results in `docs/POC_RESULTS.md`.
