# M9 UI core — shared backlog

> Collected 2026-10-17 from the M9 UI core implementation and review.
> Every `.disabled("M9 …")`, `withKnownIssue("M9 …")` and opengrep WARNING points here.

## Sub-features

| Sub-feature | Spec | Items |
|-------------|------|-------|
| UI core | `m9-product/ui-core/` | A29, UI-L1, UI-L2 (closed), UI-B1…UI-B12 |
| UI settings | `m9-product/ui-settings/` | UI-B9 (closed), UI-B4/UI-B5 (narrowed), UI-S1…UI-S7 (UI-S3 closed) |
| Voice-clone streaming | `m9-product/qwen-streaming/` | UI-S3 (closed), QS-1…QS-6 |

## From the implementation

| # | Defect / Finding | Where | Guard in place |
|---|------------------|-------|----------------|
| A29 | `LanguagePairManagerTests` uses `UserDefaults.standard` in a parallel suite; it flaked once in 4 runs (P16) | `LanguagePairManagerTests.swift` | — |
| UI-L1 | Wire `TraceLatencyProvider` once `spec/m9-benchmark` is on `main` (D-3) | `LatencyProvider.swift` | `NoLatencyProvider` production placeholder; hidden label and setting |
| UI-L2 | ~~"Advanced…" opens the legacy tab until feature 2~~ Closed by UI settings: "Advanced…" opens the per-pair models sheet | `LanguageSection.swift` | — |
| UI-B1 | Pause speak/stopSpeaking priority race: after `speak`, `if isPaused { await tts.stopSpeaking() }` (T9) | `AudioCoordinator+Session.swift` (`+Pipeline` is at 398/400 lines) | — |
| UI-B2 | A stale session's handler `defer` can clear the new session's `is*Translating`: needs a generation check (T8) | `AudioCoordinator+Pipeline.swift` | — |
| UI-B3 | The mute-turn flag is consumed by a sentence the pause drops (T9) | `AudioCoordinator` | — |
| UI-B4 | Narrowed to the Qwen/Whisper part: `QwenCloneModelManager.unload` during an in-flight load does not cancel it; a corrupt Whisper cache can still re-download via `WhisperSpeechService.ensureReady` (the rest closed by UI settings T7) | `QwenCloneModelManager`, `WhisperSpeechService` | — |
| UI-B5 | Test gaps left after UI settings T5–T7: ModelCache tokenizer fallback + Parakeet probe; Readiness `.unsupported`/`.checking` and mic+pack combos; OpenAtLoginModel; `PermissionState.current`; `start()`/`schedule()` ordering | `TranslateCallTests/` | — |
| UI-B6 | Status panel: the "Partly working" header truncates the app name (the prototype drops the clock); the notice icon is chosen by string match (type the notices); clamped only at launch (re-clamp on screen change); duplicate "Translating…" (bubble + capsule) (T17, T18) | `StatusPanelView.swift`, `PanelNotices.swift`, `StatusPanel.swift`, `TranscriptView.swift` | — |
| UI-B7 | Menu bar: the longest subtitle truncates away the language pair; the dot overlaps the glyph (T19) | `MenuBarPopoverView.swift`, `MenuBarController.swift` | — |
| UI-B8 | Setup window: the "On-device" toolbar label may render icon-only; the voice toggle sticks ON+disabled when the target becomes unsupported; `play.fill` on non-start primary states; a11y labels built by interpolation (l10n word order); `.combine` hides the row "Open" action from VoiceOver (T15, T16) | `MainSetupView.swift`, `VoiceSection.swift`, `SetupFooter.swift`, `CallAppSection.swift` | — |
| UI-B9 | ~~Settings items~~ Closed by UI settings T10 (typed tabs, status refresh, checks, picker tag, legacy Edge picker) | `Features/Settings/` | — |
| UI-B10 | CallSessionModel: idle alerts (e.g. a device change after a call) raise and activate the main window, which can pull focus; teardown alerts during `stop()` vanish (T13) | `CallSessionModel.swift` | — |
| UI-B11 | CallAppMonitor: `LiveWorkspace` has no `deinit`; ".app" stripped anywhere in the name; Teams classic extra row (T11) | `CallAppMonitor.swift` | — |
| UI-B12 | l10n: `DirectionCopy.accessibilityLabel` lowercases a localized string (T10) | `DirectionCopy.swift` | — |

## From UI settings (feature 2)

| # | Defect / Finding | Where | Guard in place |
|---|------------------|-------|----------------|
| UI-S1 | A27's fix PR: flip `engines.edgeTTS.unavailable` in `ModelCatalog.json` once Edge TTS works again (the 403) | `ModelCatalog.json` | Edge shown as "Temporarily unavailable"; never resolved |
| UI-S2 | Real download progress: Whisper `downloadProgress` is never updated and no manager reports progress, so rows show an indeterminate bar (`DownloadState.downloading(progress: nil)`) | `ModelDownloads.swift`, `WhisperModelManager` | Indeterminate progress |
| UI-S3 | ~~Voice-clone path not measured by the bench~~ Closed by voice-clone streaming: the bench now measures the clone path (run 2026-11-01, guided voice of 7.61 s, first chunk p50 ~0.4 s). `just bench` reads model availability via `TTSEngineSelector.refreshModelAvailability()` | bench, `QwenCloneModelManager` | — |
| UI-S4 | Model managers' `stateStream` is a single-consumer `AsyncStream`; a second selector (test host) can miss `.ready`. Multicast later | `TTSEngineSelector.swift`, model managers | `refreshModelAvailability()` on demand |
| UI-S5 | Kokoro `ensureReady()` has no load-only mode (bench P20 risk); Kokoro loads at Start, not in the preloader | `KokoroModelManager` | Documented in `ModelPreloader` |
| UI-S6 | UI follow-ups parked in review: (a) localization of `approximateSize`, `latencyLabel` ("~0.4 s") and "Default (af_heart)", and String Catalog extraction (CLI builds do not extract); (b) VoiceOver combined labels on models-sheet rows and `PairRow`; (c) Voices tab: rename/delete errors swallowed, play during a call is a silent no-op; (d) log export re-entrancy and `runModal`; (e) preloader: off→on "Use my voice" within the 300 ms debounce leaves a stale loaded set, and no re-preload after a failed start; (f) "Available after the call" missing on Try again during a call | `Features/Settings/`, `Features/Main/PairModels*`, `ModelPreloader.swift`, `ModelDownloads.swift` | — |

## From voice-clone streaming

| # | Defect / Finding | Where | Guard in place |
|---|------------------|-------|----------------|
| QS-1 | Cancellable mlx-audio generation (upstream): `SpeechGenerationModel.generateStream` cannot be stopped, so the gate drains an abandoned stream to its end (up to ~5–8 s for a long sentence) and the next sentence waits or goes to the fallback. A cancel hook upstream would free the model at once | `MLXInferenceGate+Stream.swift`, mlx-audio-swift | `gateBusyAbandoned` fast-fail to AVSpeech; the breaker ignores it |
| QS-2 | Semantic end-of-turn detector (pilot), to replace the fixed pause in deciding when a turn is over. Research in `m9-product/qwen-streaming/research-end-of-turn.md`. PoC 3 (outside the repo): Qwen3-0.6B LoRA plus a rule; with thresholds chosen on validation it reached ES 100 % complete-accepted / 5.3 % cut-judged-complete and EN 97.5 % / 6.6 %, 27–40 ms on the M4. The target (≥ 80 % / ≤ 5 %) is not met on the cut side. A Colab notebook exists, untested on GPU. Real conversational data is the bottleneck | research only | Fixed pause plus early processing (tentative/commit/retract) |
| QS-3 | TTS engine follow-ups from `m9-product/qwen-streaming/research-tts-models.md`: stay with Qwen3-TTS. (a) PoC Qwen3-TTS 1.7B with mlx-audio-swift 0.1.7 (we use 0.1.2); (b) Pocket TTS PoC, blocked on gated Hugging Face weights for Spanish cloning | `Package.resolved`, `QwenCloneConfiguration.swift` | — |
| QS-4 | Streaming in the voice preview (Q-3): the preview in Settings › Voices stays non-streaming (the wait there does not bother the user). Only if wanted | `VoicePreviewService.swift` | — |
| QS-5 | Acceptance: G4 passed on 2026-11-02, but en>es Best sits at the latency gate (two full runs: p50 1518 ms, then 1498 ms). The largest stage is translation (p50 ~560 ms). Trimming it would bring back margin. Manual checklist (Task 18) still open | `specs/m9-product/qwen-streaming/tasks.md` | p90 1.74–1.82 s, well under 2.0 s |
| QS-6 | `bench/baseline.json` holds a single run, so only Basic is baselined. A Best baseline (full Best run) needs a baseline holding several runs, or one run per profile | `tools/bench/tcbench/baseline.py`, `compare.py` | Best figures recorded in `qwen-streaming/tasks.md` (G4) |
