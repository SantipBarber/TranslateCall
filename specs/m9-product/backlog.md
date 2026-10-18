# M9 UI core — shared backlog

> Collected 2026-10-17 from the M9 UI core implementation and review.
> Every `.disabled("M9 …")`, `withKnownIssue("M9 …")` and opengrep WARNING points here.

## Sub-features

| Sub-feature | Spec | Items |
|-------------|------|-------|
| UI core | `m9-product/ui-core/` | A29, UI-L1, UI-L2 (closed), UI-B1…UI-B12 |
| UI settings | `m9-product/ui-settings/` | UI-B9 (closed), UI-B4/UI-B5 (narrowed), UI-S1…UI-S7 |

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
| UI-S3 | Voice-clone path not measured by the bench: clone synthesis times out (~10 s gate) and falls back to AVSpeech in `just bench pr best` (run 2026-10-18T05-23-23Z-3bda0bb). Investigation owned by latency project 2. The bench reads model availability via `TTSEngineSelector.refreshModelAvailability()` (commit "fix(tts): refresh model availability on demand…") | bench, `QwenCloneModelManager` | Best marked "clone path not measured" |
| UI-S4 | Model managers' `stateStream` is a single-consumer `AsyncStream`; a second selector (test host) can miss `.ready`. Multicast later | `TTSEngineSelector.swift`, model managers | `refreshModelAvailability()` on demand |
| UI-S5 | Kokoro `ensureReady()` has no load-only mode (bench P20 risk); Kokoro loads at Start, not in the preloader | `KokoroModelManager` | Documented in `ModelPreloader` |
| UI-S6 | UI follow-ups parked in review: (a) localization of `approximateSize`, `latencyLabel` ("~0.4 s") and "Default (af_heart)", and String Catalog extraction (CLI builds do not extract); (b) VoiceOver combined labels on models-sheet rows and `PairRow`; (c) Voices tab: rename/delete errors swallowed, play during a call is a silent no-op; (d) log export re-entrancy and `runModal`; (e) preloader: off→on "Use my voice" within the 300 ms debounce leaves a stale loaded set, and no re-preload after a failed start; (f) "Available after the call" missing on Try again during a call | `Features/Settings/`, `Features/Main/PairModels*`, `ModelPreloader.swift`, `ModelDownloads.swift` | — |
