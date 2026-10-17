# M9 UI core — shared backlog

> Collected 2026-10-17 from the M9 UI core implementation and review.
> Every `.disabled("M9 …")`, `withKnownIssue("M9 …")` and opengrep WARNING points here.

## Sub-features

| Sub-feature | Spec | Items |
|-------------|------|-------|
| UI core | `m9-product/ui-core/` | A29, UI-L1, UI-L2, UI-B1…UI-B12 |

## From the implementation

| # | Defect / Finding | Where | Guard in place |
|---|------------------|-------|----------------|
| A29 | `LanguagePairManagerTests` uses `UserDefaults.standard` in a parallel suite; it flaked once in 4 runs (P16) | `LanguagePairManagerTests.swift` | — |
| UI-L1 | Wire `TraceLatencyProvider` once `spec/m9-benchmark` is on `main` (D-3) | `LatencyProvider.swift` | `NoLatencyProvider` production placeholder; hidden label and setting |
| UI-L2 | "Advanced…" opens the legacy tab until feature 2 | `LanguageSection.swift`, `SettingsOpener` | `SettingsTab.advancedLegacy` wired to "Advanced…" and legacy view |
| UI-B1 | Pause speak/stopSpeaking priority race: after `speak`, `if isPaused { await tts.stopSpeaking() }` (T9) | `AudioCoordinator+Session.swift` (`+Pipeline` is at 398/400 lines) | — |
| UI-B2 | A stale session's handler `defer` can clear the new session's `is*Translating`: needs a generation check (T8) | `AudioCoordinator+Pipeline.swift` | — |
| UI-B3 | The mute-turn flag is consumed by a sentence the pause drops (T9) | `AudioCoordinator` | — |
| UI-B4 | ModelPreloader: a failed load is still marked loaded; a coalesced cache-only failure surfaces once to a concurrent Start; no re-preload after a session or after returning to automatic; `QwenCloneModelManager.unload` during an in-flight load does not cancel it; a corrupt Whisper cache can still re-download via `WhisperSpeechService.ensureReady` (T6) | `ModelPreloader.swift`, `QwenCloneModelManager`, `WhisperSpeechService` | — |
| UI-B5 | Test gaps: selector-level automatic voice clone / nil store / Kokoro-incoming; ModelCache tokenizer fallback + Parakeet probe; Readiness `.unsupported`/`.checking` and mic+pack combos; OpenAtLoginModel; `PermissionState.current`; `start()`/`schedule()` ordering (T3–T6, T12, T20) | `TranslateCallTests/` | — |
| UI-B6 | Status panel: the "Partly working" header truncates the app name (the prototype drops the clock); the notice icon is chosen by string match (type the notices); clamped only at launch (re-clamp on screen change); duplicate "Translating…" (bubble + capsule) (T17, T18) | `StatusPanelView.swift`, `PanelNotices.swift`, `StatusPanel.swift`, `TranscriptView.swift` | — |
| UI-B7 | Menu bar: the longest subtitle truncates away the language pair; the dot overlaps the glyph (T19) | `MenuBarPopoverView.swift`, `MenuBarController.swift` | — |
| UI-B8 | Setup window: the "On-device" toolbar label may render icon-only; the voice toggle sticks ON+disabled when the target becomes unsupported; `play.fill` on non-start primary states; a11y labels built by interpolation (l10n word order); `.combine` hides the row "Open" action from VoiceOver (T15, T16) | `MainSetupView.swift`, `VoiceSection.swift`, `SetupFooter.swift`, `CallAppSection.swift` | — |
| UI-B9 | Settings: OpenAtLoginModel status read only at init; sequential per-language checks; nil `selectedInput` picker tag; SettingsView raw `String` tab; legacy tab Edge picker without consent shows no selection (T1, T20, T21) | `Features/Settings/` | — |
| UI-B10 | CallSessionModel: idle alerts (e.g. a device change after a call) raise and activate the main window, which can pull focus; teardown alerts during `stop()` vanish (T13) | `CallSessionModel.swift` | — |
| UI-B11 | CallAppMonitor: `LiveWorkspace` has no `deinit`; ".app" stripped anywhere in the name; Teams classic extra row (T11) | `CallAppMonitor.swift` | — |
| UI-B12 | l10n: `DirectionCopy.accessibilityLabel` lowercases a localized string (T10) | `DirectionCopy.swift` | — |
