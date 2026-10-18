# M9 UI settings — Design

> Status: APPROVED (2026-10-17). Implements `requirements.md` (REQ-ST-xx). Visual reference: `design/translatecall.pen`, read only through the pencil MCP (`execute` + `TakeScreenshot` / `Get`). The prototype uses Inter and Lucide as stand-ins; build with the system font and SF Symbols.

## 1. Prototype → SwiftUI map

| Prototype frame (light / dark) | SwiftUI | REQ |
|---|---|---|
| Advanced — Models for ES ↔ DE (`yReTP` / `XpYEw`) | `PairModelsSheet` | 10–18 |
| Settings — Voices (`o3A5RO` / `G3LK2`) | `VoicesSettingsView` | 20–22 |
| Settings — Advanced (`PFRn8` / `T2mCTh`) | `AdvancedSettingsView` | 30–36 |

The sheet's prototype shows "My voice (Qwen3-TTS)" as a voice row; S-6 replaces it with the info line of REQ-ST-18 and renames the section. The prototype's "Whisper large-v3 turbo" label reads "Whisper" (the size is not chosen here). Everything else follows the frames.

Implementers screenshot the frame (light and dark) before writing the view, and compare it with a render of the view before review (ImageRenderer or an offscreen `NSHostingView` from a temporary, uncommitted test; Forms render blank under ImageRenderer).

## 2. File layout

Synchronized folders: new files need no `project.pbxproj` edit.

```
TranslateCall/
  Core/Models/        PairKey.swift, PairModelChoices.swift (store), ModelResolver.swift,
                      ModelCatalog.swift (+ v2 fields), ModelChoice.swift (resolution), ModelPreloader.swift,
                      ModelDownloads.swift (facade), CloudPolicy.swift
  Core/TTS/           SystemVoicePreference.swift
  Core/VAD/           VADPreference.swift
  Core/Diagnostics/   LogExporter.swift
  Features/Settings/  SettingsView.swift, SettingsTab.swift, GeneralSettingsView.swift,
                      VoicesSettingsView.swift, VoiceProfileRow.swift, StandardVoicePicker.swift,
                      AdvancedSettingsView.swift, PairRow.swift
  Features/Settings/Diagnostics/  STTMetricsView, TTSMetricsView, TTSMonitorRow (moved from Legacy/)
  Features/Models/    PairModelsSheet.swift, PairModelsModel.swift, EngineRow.swift, DownloadStateView.swift
```

Removed: `LegacyAdvancedSettingsView.swift`, `Legacy/ModelDownloadSheets.swift`, `Legacy/` (after the moves), `ModelChoice+Selectors.swift`'s `AutomaticModeSelector` protocol. `KokoroVoicePicker` moves into `StandardVoicePicker`.

## 3. Per-pair choices (REQ-ST-01…06)

### 3.1 Storage

```swift
nonisolated struct PairKey: Hashable, Codable, Sendable, Comparable {
    let first: String, second: String          // language codes, sorted: PairKey("es","de") == PairKey("de","es")
    init(_ a: String, _ b: String)
    var storageKey: String { "\(first)|\(second)" }
}
nonisolated struct PairModelChoice: Codable, Equatable, Sendable {
    var stt: STTEngine?                        // nil = recommended
    var voice: TTSEngine?                      // nil = recommended; never .voiceClone (S-6)
    var isEmpty: Bool { stt == nil && voice == nil }
}
@MainActor final class PairModelChoices: ObservableObject {
    @Published private(set) var all: [PairKey: PairModelChoice]
    init(defaults: UserDefaults = .standard)  // key "tlk.models.pairChoices", JSON [storageKey: PairModelChoice]
    func choice(for: PairKey) -> PairModelChoice
    func set(_: PairModelChoice, for: PairKey)  // empty → removes the entry
}
```

Owned by `AppContainer`, injected into both selectors, the preloader, `MainSetupModel` and the views. Unknown engine raw values decode as nil (a future build's engine never crashes an older one).

### 3.2 Resolution

`ModelChoice` keeps its pure catalog functions and gains a resolver that applies the pair choice first:

```swift
nonisolated struct ModelAvailability: Equatable {          // extended
    var parakeetCached, whisperCached, kokoroCached, voiceCloneReady: Bool
    var cloud: CloudPolicy.Snapshot                          // allowed, consented: Set<TTSEngine>, unavailable: Set<TTSEngine>
}
nonisolated enum ModelChoice {
    static func stt(for locale: Locale, direction: TranscriptDirection, pairChoice: STTEngine?,
                    catalog: ModelCatalog, availability: ModelAvailability) -> STTEngine
    static func tts(for locale: Locale, direction: TranscriptDirection, pairChoice: TTSEngine?,
                    catalog: ModelCatalog, availability: ModelAvailability) -> TTSEngine
    static func isUsable(_: STTEngine, locale:, direction:, availability:) -> Bool
    static func isUsable(_: TTSEngine, locale:, direction:, availability:) -> Bool
}
```

- `stt`: `pairChoice` if `isUsable`, else today's catalog rule.
- `tts`, outgoing: if the voice clone is ready and the catalog lists it for the language, it wins (REQ-ST-04); else `pairChoice` if usable; else the catalog rule. Incoming: `pairChoice` if usable; else the catalog rule.
- `isUsable(.edgeTTS)`: `EdgeTTSVoiceCatalog.supports(locale)` && `cloud.allowed` && `cloud.consented.contains(.edgeTTS)` && `!cloud.unavailable.contains(.edgeTTS)`.
- The `systemOrEdgePrimary` fallback (no system voice for the language) additionally requires `cloud.allowed` and Edge not marked unavailable (REQ-ST-32, S-3); the pre-Start Edge consent prompt fires under the same conditions.

The selectors drop `isAutomatic`, `preferredEngine`, `setPreferredEngine`, `setAutomatic`, the `tlk.*.engine` keys and the manual branches of `makeOutgoingService` / `makeIncomingService`. Both selectors get `LanguagePairManager` and `PairModelChoices` injected (today `makeOutgoingService(for:)` / `makeIncomingService(for:)` only receive a locale) and build the `PairKey` from the current pair. The factory branch per engine is unchanged. Edge, when resolved, builds through the existing `edgeFactory`.

`STTEngineSelector.usingFallback` / `TTSEngineSelector.usingFallback` keep their meaning (choice not usable) and feed the sheet's notes.

### 3.3 Cloud policy (REQ-ST-32)

```swift
@MainActor final class CloudPolicy: ObservableObject {
    @Published var allowed: Bool                 // "tlk.cloud.allowed"; first read defaults to EdgeTTSConsentManager.consentGiven
    func hasConsent(_ engine: TTSEngine) -> Bool // Edge: EdgeTTSConsentManager.consentGiven
    func grantConsent(_ engine: TTSEngine)
    var snapshot: Snapshot { get }               // + unavailable from the catalog
}
```

The existing pre-Start Edge consent prompt (feature 1 call 11) stays, but only fires when `allowed` is true.

### 3.4 "Models: Custom" (REQ-ST-05, 40)

Today `LanguageSection` reads `isAutomatic`. A new `MainSetupModel.modelsLabel` replaces that, derived from the current pair's choice and the resolved engines: "Recommended", "Custom" or "Custom · Cloud" (any direction resolves to a cloud engine).

## 4. Catalog v2 (S-2, S-3)

```json
{
  "version": 2,
  "stt": { … unchanged … }, "ttsOutgoing": { … }, "ttsIncoming": { … },
  "engines": { "edgeTTS": { "unavailable": true } },
  "pairs":   { }
}
```

- `engines[name].unavailable` (optional, default false).
- `pairs["de|es"][name] = { "tested": true, "latencyMs": 400 }` (optional). `latencyMs` shows as "~0.4 s" (one decimal); a voice engine's label is "~0.5 s to first audio".
- Both new keys decode with defaults when absent, so a v1 file still decodes. The bundled `ModelCatalog.json` moves to `version: 2` with `engines.edgeTTS.unavailable = true`, and `builtIn` mirrors it.
- The sheet's "Recommended" mark = the engine the catalog alone would pick for the pair with every model treated as on disk (so the recommendation doesn't change with what's downloaded). For a pair with two languages that resolve differently (e.g. Parakeet for EN, Whisper for ES), both rows get the mark, each with "for <language>".

## 5. Downloads (S-4, REQ-ST-14)

```swift
nonisolated enum DownloadableModel: CaseIterable, Sendable { case parakeet, whisper, kokoro, voiceClone
    var approximateSize: String   // "≈800 MB" etc., the figures the legacy sheets show today
}
nonisolated enum DownloadState: Equatable, Sendable {
    case notOnDisk, downloading(progress: Double?), ready, failed(String)
}
@MainActor final class ModelDownloads: ObservableObject {
    @Published private(set) var states: [DownloadableModel: DownloadState]
    init(probe: ModelCacheProbe, managers: DownloadManagers = .live)
    func start(_: DownloadableModel)              // no-op if downloading or ready
    func cancel(_: DownloadableModel)
    func refresh()                                // re-probe disk; called on sheet appear
    var didFinish: AnyPublisher<DownloadableModel, Never>
}
```

- `DownloadManagers.live` calls each manager's existing download+load path (`ParakeetModelManager.ensureReady`, `WhisperModelManager.ensureReady`, `KokoroModelManager.ensureReady`, `QwenCloneModelManager.ensureReady`). All four report `nil` progress (indeterminate): `WhisperModelManager.downloadProgress` is never updated today; real percentages are out of scope. The `progress: Double?` slot stays so a later change can fill it.
- Cancel is best effort: it calls the manager's `unload()` (which cancels its load task), then re-probes the disk. Underlying transfers may not stop at once and may leave partial files, which the on-disk checks already treat as not cached. The voice clone row offers no Cancel in the sheet (its download is owned by "Use my voice").
- On success the state is `.ready` and `didFinish` fires (the preloader listens; the sheet selects the model if the user picked it).
- Cancel returns to `.notOnDisk` (re-probed). A thrown error → `.failed(message)`.
- "Use my voice" in the main window keeps its own inline download (feature 1 call 3) but now goes through `ModelDownloads.start(.voiceClone)`, so both places show the same state.
- `ModelDownloads` lives in `AppContainer`; it is the only place that starts downloads from the UI.

## 6. The sheet (REQ-ST-10…18)

`PairModelsModel` (`@MainActor ObservableObject`), created per presentation with the `PairKey`:
- `staged: PairModelChoice`, initialised from the store;
- `rows(for stage) -> [EngineRowState]`: engine, display name, `isRecommended` (+ "for <language>"), `isCloud`, `tested`/`latency` (optional), `availability` (`.selectable`, `.partial(language)`, `.notForPair`, `.unavailable`), `download: DownloadState`, `isSelected` (staged choice, or the recommended row when the stage has none);
- `pick(_ engine, stage)`: not on disk → `downloads.start` and remember a pending pick, selected when `didFinish` fires (if the sheet is still open); cloud without consent → `pendingConsent = engine` (an in-sheet `.confirmationDialog`; Allow grants consent and stages it); otherwise stage it;
- `downloadsBlocked: Bool` (a session is running, S-7): rows not on disk show a disabled "Download" with "Available after the call"; `pick` of such a row does nothing;
- `reset()`, `commit()` (Done), Cancel just dismisses;
- `voiceCloneLine: String?` (REQ-ST-18).

Rows use `EngineRow` (radio, name, chip line, note line, trailing `DownloadStateView`). Width 460 pt like the prototype; the sheet scrolls only if the content is taller than the screen. Presented with `.sheet(item:)` from `MainSetupView` (current pair) and from `AdvancedSettingsView` (clicked pair).

## 7. Settings

### 7.1 Tabs (REQ-ST-51, 60)

`SettingsTab: String { general, voices, advanced }` with `init?(rawValue:)` mapping the legacy `"advancedLegacy"` to `.advanced`. `SettingsView` binds `@AppStorage(SettingsOpener.tabKey) var tab: SettingsTab = .general`. Width 560 as today. `SettingsOpener.open(tab:)` unchanged; "Advanced…" in `LanguageSection` now opens the sheet instead (UI-L2).

### 7.2 Voices (REQ-ST-20…22)

- `VoiceProfileRow` reads `VoiceProfileManager.profiles` / `activeProfileId`. Subtitle: `createdAt` (medium date) + duration ("12 s"). Play: `VoicePreviewService.playRecording(profileId:)`. Rename: an alert with a text field → `rename`. Delete: a confirmation → `delete`; deleting the active profile clears `activeProfileId` (today's behaviour).
- "Record a new voice…" presents today's `VoiceProfileListView` sheet.
- `StandardVoicePicker(language:)` resolves the engine in effect for that language (outgoing for their language, incoming for mine, through `ModelChoice` with the current pair) and lists its voices. `SystemVoicePreference` stores the Apple voice identifier per language under `tlk.tts.systemVoice.<code>` ("" = Automatic); `AVSpeechUtteranceSynthesizer` uses it when set and still installed, else today's best-voice pick. Kokoro keeps its existing single key (`KokoroConfiguration.voiceDefaultsKey`).

### 7.3 Advanced (REQ-ST-30…36)

- Pairs: `PairRow` per REQ-ST-31; value "Recommended" or "Custom · <engine display name>" (the first non-nil of stt, voice), orange as in the prototype.
- Cloud: a `Toggle` bound to `CloudPolicy.allowed`.
- Voice detector: `VADPreference` (`tlk.vad.engine`, `.silero` default / `.energy`); `VADProvider.makeVAD` reads it: `.energy` skips Silero.
- Diagnostics: `@AppStorage("ui.showMetrics")` toggle; when on, `STTMetricsView`, `TTSMetricsView`, `TTSMonitorRow` below it. "Export logs…" → `LogExporter.export()` reads `OSLogStore(scope: .currentProcessIdentifier)` filtered by subsystem `com.spbarber.TranslateCall` (entries since this launch, S-8) → `NSSavePanel` (`TranslateCall-logs-<date>.txt`). "Run setup again…" → today's `SetupWizardView` sheet.

### 7.4 Help menu (REQ-ST-52)

A `CommandGroup(replacing: .help)` with "TranslateCall Help" opening the usage-guide URL.

## 8. Preloader (REQ-ST-61)

- `wantedModels()` uses the resolver with the pair's choice (no `isAutomatic` guard any more).
- Triggers: pair change; `PairModelChoices.$all`; `TTSEngineSelector.$voiceCloningEnabled` and `$activeVoiceProfileId`; `ModelDownloads.didFinish`; `CloudPolicy.$allowed`. All merged, debounced 300 ms on the main queue, then the existing serial `schedule()`.
- `ModelLoaders.load` returns `Bool`; only `true` is added to `loaded`. A failed model is retried at the next trigger.
- Kokoro stays out of the preloader (P20); the voice clone stays owned by "Use my voice".

## 9. Backlog items (REQ-ST-60)

- `OpenAtLoginModel.refresh()` on `.onAppear` of Settings and on `NSApplication.didBecomeActiveNotification`.
- General's per-language checks run in a `withTaskGroup`.
- The microphone picker uses an explicit `Optional` tag: `.tag(String?.none)` for "System default".

## 10. Testing

| Suite | Covers |
|---|---|
| `PairKeyTests` | Order independence; storage key round-trip |
| `PairModelChoicesTests` | Persist/restore; empty removes; unknown engine names decode as nil (isolated `UserDefaults` suite, fixes A29's pattern) |
| `ModelChoiceTests` (extended) | Choice wins when usable; falls back when not on disk / unsupported language / incoming Parakeet / Kokoro with voice clone / cloud not allowed / no consent / unavailable; partial-language engines; voice clone wins outgoing |
| `ModelCatalogTests` (extended) | v1 file decodes; v2 fields; `builtIn` marks Edge unavailable; recommended marks with all models on disk |
| `CloudPolicyTests` | Default from existing consent; Edge fallback blocked when not allowed |
| `ModelDownloadsTests` | State transitions with fake managers: start, progress, success → didFinish, cancel, failure, no double start |
| `PairModelsModelTests` | Row states for ES↔DE, ES↔EN; pick stages; pick not on disk → download → selected; consent flow (allow/decline); reset; commit vs cancel; voice-clone line |
| `ModelPreloaderTests` (extended) | Pair choice drives picks; failed load not marked loaded and retried; each trigger re-runs |
| `SettingsTabTests` | Legacy raw value maps to `.advanced` |
| `SystemVoicePreferenceTests`, `VADPreferenceTests` | Stored pick used; missing voice → automatic |
| `STTEngineSelectorTests`, `TTSEngineSelectorTests` (rewritten) | Manual-mode tests removed; resolution through the pair choice; UI-B5 selector gaps (voice clone with nil store, Kokoro incoming) |
| `ModelCacheTests` (extended) | UI-B5: Whisper tokenizer fallback, Parakeet probe |

No UI-test target. Views: previews (light/dark, every state), pencil comparison, manual checklist.

**Manual checklist (user, before merge)**
- S1: Main window "Advanced…" opens the ES ↔ DE sheet; Parakeet is disabled with its reason; Edge does not show (cloud off).
- S2: Pick Apple Speech, Done → "Models: Custom"; a call uses Apple Speech; Reset to recommended → "Models: Recommended".
- S3: Pick a model not on disk → in-row download with progress and Cancel; finished → selected. Close the sheet mid-download, reopen → still downloading.
- S4: Turn on "Allow cloud models" → Edge appears disabled, "Temporarily unavailable".
- S5: Voices: play, rename, delete a profile; "Use" switches the active one; standard voice for Deutsch changed → used at the next call.
- S6: Advanced: pairs list, Custom in orange, the chevron opens the sheet for that pair; Voice detector Basic → next call works.
- S7: Show metrics → metrics appear; Export logs… writes a file with this launch's entries.
- S10: During a call, the sheet's download buttons are disabled with "Available after the call".
- S8: ⌘, after upgrading from feature 1 with the legacy tab stored → opens on Advanced.
- S9: Dark mode on every new screen vs the dark frames.

## 11. Risks

| Risk | Mitigation |
|---|---|
| Removing manual mode breaks selector tests and callers that use `setPreferredEngine` | One task removes it with a repo-wide grep; build + all tests before review |
| `ensureReady` downloads also load the model into memory (MLX exclusivity) | After `didFinish`, the preloader unloads what the pair doesn't want; Kokoro/voice clone exclusivity rules unchanged |
| Sheet over the main window while a call is running | Choices apply at the next Start (as all engine changes today); downloads are disabled during a session (S-7), so no model loads mid-call |

## 12. Claude's calls (not confirmed by the user — check while reading)

1. Pairs are unordered: ES ↔ DE and DE ↔ ES share choices.
2. One voice choice per pair for both directions (S-6), applied per language where the engine supports it.
3. "Recommended" marks are computed as if every model were on disk, so they don't move as you download.
4. "Allow cloud models" starts on for users who already gave Edge consent; off for everyone else. Off also blocks the existing Edge fallback for languages without a system voice.
5. Whisper keeps today's configured size; the sheet says "Whisper", not "large-v3 turbo".
6. Voice profile subtitle shows date + duration; profiles store no language or sentence count yet (feature 4 adds them).
7. Standard voice picker: per language, the voices of the engine in effect; "Automatic" default.
8. Voice detector offers Silero and Basic (energy); new setting `tlk.vad.engine`.
9. Metrics show inline in Advanced under the switch.
10. Logs: the app's subsystem since launch (S-8, user-approved).
11. "Usage guide" moves to the Help menu.
12. Choices made during a call apply at the next Start.
14. Every download shows indeterminate progress (Whisper's percentage plumbing doesn't exist).
15. Cancel is best effort; no cancel for the voice clone from the sheet.
16. Edge marked unavailable also blocks the existing no-system-voice fallback and its consent prompt.
13. Advanced lists the three priority pairs + current + customised pairs.
