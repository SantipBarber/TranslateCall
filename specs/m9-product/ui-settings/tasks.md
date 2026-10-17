# M9 UI settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the temporary "Advanced (legacy)" Settings tab with the prototype's definitive screens. That means per-pair model choices with an "Advanced…" sheet (in-row downloads, cloud consent), Settings › Voices and Settings › Advanced. The global manual engine mode and the modal download sheets go away.

**Architecture:**
- **Per-pair choices.** A `PairModelChoices` store (one optional engine per stage per unordered pair) and a `CloudPolicy` feed a pure resolver (`ModelChoice` with a `pairChoice` argument). Both selectors resolve every engine through it (`resolvedEngine(for:direction:)`), and so do the preloader and the main window's models line.
- **Downloads.** `ModelDownloads` is the only place the UI starts a download (per-model state, none during a call).
- **The sheet.** `PairModelsModel` stages a pair's choices for the sheet.
- **Settings.** The Settings tabs are thin views over small pure helpers (`StandardVoices`, `AdvancedPairs`, `VADPreference`, `LogExporter`).

**Tech Stack:**
- Swift 6 (app target: default MainActor isolation, `MemberImportVisibility`);
- SwiftUI + AppKit (`Settings` scene, `NSSavePanel`);
- Combine, `Synchronization.Mutex`;
- OSLog (`OSLogStore`), AVFoundation (`AVSpeechSynthesisVoice`);
- FluidAudio / WhisperKit / mlx-audio-swift (through the existing managers only);
- Swift Testing, `just`, SwiftLint (strict), opengrep;
- the pencil MCP, to read `design/translatecall.pen`.

**Spec:** `specs/m9-product/ui-settings/requirements.md`, `specs/m9-product/ui-settings/design.md` (APPROVED 2026-10-17, S-1…S-8). Context: `specs/m9-product/ui-core/design.md` §3 (models), `specs/m9-product/ui-redesign/design-brief.md` (text-fitting rules), `specs/m9-product/backlog.md`.

## Global Constraints

- **Branches and PR:**
  - work on branch `feat/m9-ui-settings`, created from `spec/m9-ui-settings`; spec and code ship in one PR;
  - never commit to `main`;
  - `just pr` must pass before the PR;
  - execution is subagent-driven (the user's standing choice). Tasks marked **pi** go to pi per the global CLAUDE.md rules (`pi-task -m <model> -v <name> "…"`, the task as a self-contained requirements file). pi's output gets the same review as a Claude subagent's.
- Commits: Conventional Commits; end every message with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016Hg7cU3iFYAdPhg1wykfYr
  ```
- **Build settings:**
  - `SWIFT_VERSION = 6.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`;
  - the app target has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: a type used off the main actor must say `nonisolated`. `STTEngine`/`TTSEngine` are `nonisolated`; `VADEngine`, `ModelCatalog` and `ModelChoice` are main-actor (P15);
  - the test target has no default isolation: suites touching app types are `@MainActor`;
  - `MemberImportVisibility` is on: a test that reads `AVSpeechSynthesisVoice` members imports AVFoundation.
- New files are picked up automatically (`PBXFileSystemSynchronizedRootGroup`), and a `.json` next to sources is bundled. Never edit `project.pbxproj`.
- **Unit tests:**
  - no audio device, no ML model, no network, no `UserDefaults.standard` (always `UserDefaults(suiteName: "test-\(UUID())")`);
  - no real `EdgeTTSConsentManager` writes: inject `edgeConsentGiven`, or use `CloudPolicy(edgeConsentGiven:grantEdgeConsent:)`;
  - no fixed sleeps: wait with `waitUntil` / `mainQueueHop` (`TranslateCallTests/Support/AsyncTestHelpers.swift`).
- **Recipes:**
  - one or more suites: `just test-only <SuiteStructName> […]`;
  - the unit tier: `just test`;
  - lint: `just lint` (`swiftlint --strict`);
  - static analysis: `just scan`;
  - the gate: `just pr`.
- **SwiftLint strict** (app target only):
  - lines ≤ 120;
  - function bodies ≤ 50, type bodies ≤ 250 (extensions excluded), files ≤ 400;
  - cyclomatic complexity ≤ 10;
  - identifiers ≥ 3 characters;
  - **tuples ≤ 2 members** (use a small struct);
  - `for_where`: a `for` whose body is a single `if` must use `where`. `await` is not allowed in `where`, so bind the result first (P-replay);
  - sorted imports.

  Budgets:
  - `AudioViewModel.swift` is at 370 lines; do not grow it;
  - `AudioCoordinator+Pipeline.swift` is at 398/400; do not touch it;
  - `AppContainer.init` is at its 50-line limit, so new services go in `UIServices` (P1).
- **UI rules:**
  - English strings through the String Catalog: `Text("…")` literals are keys, and model code uses `String(localized:)`;
  - native look: system font, SF Symbols, colours through `Theme` (no hex in views), automatic light/dark;
  - text fitting per the brief: single-line labels use `.lineLimit(1)` and `.truncationMode(.tail)`; notes wrap.
- **Prototype:** read `design/translatecall.pen` only through the pencil MCP: `get_app_state`, then `execute` with `TakeScreenshot([...])` or `Get`. Never use Read or Grep on it.
  - Each view task screenshots its light and dark frames before writing the view. Before review, it renders the view in light and dark and compares the two.
  - Render with an `NSHostingView` in an offscreen window from a temporary, uncommitted test: Forms and ScrollViews render blank under `ImageRenderer`, and AppKit controls show as yellow placeholders there.
  - pen.dev saves to the main checkout: never switch the main checkout to a branch without `design/translatecall.pen`.
- **Volume access:** if a build fails with "Operation not permitted" under `/Volumes/SpBarberDev`, stop and ask the user to re-grant access (macOS TCC). Do not work around it.
- Do not touch `/Users/spbarber/Desarrollo/TranslateCall-bench` (`spec/m9-benchmark`).

## Review Focus

- **The model a pair was set to is no longer on this Mac** (the cache was deleted, or the download failed). The call uses the recommended engine; the sheet shows the row as "Download · ≈… MB" or "Download failed" with Try again. Pinned in Task 4 (`sttChoiceFallsBack`, first row) and Task 6 (`downloadFails`).
- **Edge chosen for a pair, then "Allow cloud models" turned off.** Edge never runs: not as the pair's choice, nor as the no-system-voice fallback, nor through the pre-Start consent prompt. The models line drops "· Cloud". Pinned in Task 4 (`edgeChoiceNeedsCloud`) and Task 5 (`fallbackNeedsCloud`, `needsConsentForUkrainian`).
- **A download starts before a call and finishes during it.** Nothing loads mid-call. The preloader runs once the session ends. Pinned in Task 7 (`runsAfterSession`).
- **"Use my voice" pressed twice, or the sheet reopened, while a model downloads.** Only one download runs, and the reopened sheet shows it still downloading. Pinned in Task 6 (`downloadSucceeds`: a second `start` is ignored) and checklist S3.
- **A Mac upgraded from feature 1 with the legacy tab stored.** ⌘, opens Advanced, not a blank tab. Pinned in Task 10 (`tabs`) and checklist S8.

## Decisions made while planning (spec deviations are marked ⚠)

Tasks 1–8, 10, 11 and 13 were replayed on a throwaway clone of `spec/m9-ui-settings` at 2f6029b (see Replay notes). The replay ran `build-for-testing`, every new and affected suite, the whole unit tier, `just lint` and `just scan`, all green.

| # | Point | Choice |
|---|-------|--------|
| P1 ⚠ | design §3.1–3.3 inject `PairModelChoices` / `CloudPolicy` into the selectors | The selectors take closures: `pairChoice: () -> PairModelChoice` and (TTS) `cloudAllowed: () -> Bool` and `startVoiceCloneDownload: () -> Void`, each with a safe default (no choice, no cloud, no-op). `ModelServices` (in `UIServices`) owns the store, the policy and the downloads, and wires the closures. `AppContainer.init` stays at 50 lines, and tests set the closures directly. |
| P2 ⚠ | design §3.3 `CloudPolicy.snapshot` | `CloudPolicy` owns the switch and the consent. The TTS selector builds its `cloudSnapshot` from `cloudAllowed()`, `edgeConsentGiven()` and `catalog.isUnavailable(.edgeTTS)`, so the resolver stays a pure function of one `ModelAvailability`. |
| P3 | What the manual mode leaves behind in `STTEngineSelector` | Everything except resolution goes: `UserDefaults`, `preferredEngine`, `usingFallback`, `currentSourceLocale`, the Parakeet/Whisper state observation and download flags, `whisperAutoLoad`, `setPreferredEngine`, and the redownload and unload helpers. Their only callers were the legacy tab and its sheets. The init keeps the three factories. |
| P4 | The same in `TTSEngineSelector` | Removed: `preferredEngine`, `tlk.tts.engine`, `usingFallback`, `voiceCloningActive`, `isDownloading`, `downloadKokoroModel`, the `voiceCloneAutoLoad` init parameter (T5), and `isVoiceCloneDownloading` (T6). `needsEdgeTTSConsent` becomes `needsEdgeConsent(for:)`. `isUsingEdgeTTS` now reads `resolvedEngine`. `kokoroAvailable`/`voiceCloneAvailable` stay: `enableVoiceCloning` still uses them. |
| P5 | One resolution path | `resolvedEngine(for:direction:)` on both selectors is what the factories build, what the preloader loads and what the models line reads. The TTS version includes the no-system-voice → Edge fallback, and maps a voice clone without a profile store to that same path. |
| P6 ⚠ | Picking the row that is "Recommended" for both languages | Stores nothing for that stage, so the pair stays "Recommended" and follows future catalog changes. |
| P7 | Kokoro's download also loads it | `DownloadManagers.live` unloads Kokoro right after `ensureReady`. Kokoro is never preloaded (P20 of feature 1) and must not sit next to the voice clone (NF-04). |
| P8 | Whisper's `ensureReady` returns a non-`Sendable` `WhisperKit` | The download calls `loadIfNeeded()`. |
| P9 | A row picked while its model downloads | The row is selected when the download finishes, if the sheet is still open. Done before then commits without it. Cancel and close never stop the download (REQ-ST-17). |
| P10 ⚠ | Between Task 5 and Task 9, "Advanced…" has no destination | Task 5 routes it to `MainSetupActions.openModels` (default no-op), and Task 9 presents the sheet. This is branch-internal only. |
| P11 | Not in design §8: a preload skipped during a call | `ModelPreloader.start(triggers:)` also gets "session ended" (`coordinator.$isOutgoingActive` falling to false), so choices or downloads made during a call are loaded after it. |
| P12 ⚠ | REQ-ST-40 names only "Models: Custom · Cloud" | `ModelsLabel` also has "Models: Recommended · Cloud", used when no choice is stored but the no-system-voice fallback resolves to Edge. |
| P13 | The Advanced pairs' title order, and the sheet's direction for a pair that is not current | `AdvancedPairs.ordered(_:currentSource:)`: the current source language first if it is in the pair, else Spanish, German, English, else alphabetical. The sheet opens with that order as mine → theirs. |
| P14 | Prototype order of the voice rows | Apple voices, Kokoro, Microsoft Edge voices (Edge only while cloud models are allowed). Speech rows: Whisper, Apple Speech, Parakeet. "My voice" is never a row (S-6). |
| P15 | `VADEngine`'s conformances are main-actor isolated | `VADPreference` is main-actor too (not `nonisolated`). |
| P16 | Logs | `OSLogStore(scope: .currentProcessIdentifier)` filtered by subsystem, since launch (S-8). The pure `LogExporter.text` / `fileName` are tested; the store read is checked by hand (S7). |
| P17 | UI-B9 "nil tag" in the microphone picker | A "System default" row tagged `AudioDevice?.none`, shown only while no device is selected. |
| P18 | UI-B9 concurrent checks | `DownloadedLanguages.list` runs the checks in a task group, so its `isInstalled` becomes `@escaping @Sendable`. `AppleTranslationService.isInstalled` converts. |
| P19 | The voice clone in `ModelDownloads` | Used only by "Use my voice" (no sheet row, S-6). It has no Cancel, because its unload belongs to `disableVoiceCloning`. |
| P20 | `ModelServices` and `UserDefaults.standard` | Two initializers: production (`PairModelChoices()`, `CloudPolicy()`, the live `ModelDownloads`) and an injected one for tests. |
| P21 | Legacy tab value | `SettingsTab` declares `init?(rawValue:)` mapping `"advancedLegacy"` to `.advanced`; `@AppStorage` reads it through `RawRepresentable`. |

## File Structure

```
TranslateCall/
  App/AppContainer.swift              MOD T5 UIServices.models (choices, cloud), MainSetupModel(models:tts:);
                                          T6 downloads; T7 preloader triggers
  App/TranslateCallApp.swift          MOD T5 env objects (choices, cloud), Help menu; T6 env downloads
  App/HelpLinks.swift                 NEW T5
  Core/Models/PairModelChoices.swift  NEW T1 (PairKey, PairModelChoice, PairModelChoices)
  Core/Models/ModelCatalog.swift/.json MOD T2 (v2: engines, pairs; EngineInfo, EngineMetrics)
  Core/Models/CloudPolicy.swift       NEW T3 (CloudSnapshot, CloudPolicy)
  Core/Models/ModelChoice.swift       MOD T4 (pairChoice, serves, isUsable, allOnDisk); T5 removes the automatic flag
  Core/Models/ModelChoice+Selectors.swift  DEL T5
  Core/Models/ModelServices.swift     NEW T5; MOD T6 (downloads)
  Core/Models/ModelDownloads.swift    NEW T6
  Core/Models/ModelPreloader.swift    MOD T5 (no manual guard), T7 (Bool loads, triggers)
  Core/STT/STTEngineSelector.swift    MOD T5 (rewritten: resolution only)
  Core/TTS/TTSEngineSelector.swift    MOD T5 (resolution, cloud), T6 (startVoiceCloneDownload)
  Core/TTS/StandardVoices.swift       NEW T11 (SystemVoicePreference, SystemVoice, VoiceOption, StandardVoices)
  Core/TTS/AVSpeechUtteranceSynthesizer.swift  MOD T11 (preferred voice)
  Core/VAD/VADPreference.swift        NEW T13;  Core/VAD/VADProvider.swift  MOD T13
  Core/Diagnostics/LogExporter.swift  NEW T13
  Features/Main/ModelsLabel.swift     NEW T5
  Features/Main/MainSetupModel.swift  MOD T5 (modelsLabel)
  Features/Main/MainSetupView.swift, LanguageSection.swift, MainSetupPreviews.swift  MOD T5; T6 (VoiceSection
                                          download flag); T9 (sheet)
  Features/Main/VoiceSection.swift    MOD T6 (isDownloading)
  Features/Main/AudioViewModel+Start.swift  MOD T5 (needsEdgeConsent(for:))
  Features/Models/PairModelsModel.swift NEW T8;  EngineRow.swift, DownloadStateView.swift, PairModelsSheet.swift NEW T9
  Features/Settings/SettingsOpener.swift  MOD T10 (SettingsTab);  SettingsView.swift MOD T5, T10, T12, T14
  Features/Settings/GeneralSettingsView.swift  MOD T10 (UI-B9)
  Features/Settings/VoicesSettingsView.swift, VoiceProfileRow.swift, StandardVoicePicker.swift  NEW T12
  Features/Settings/AdvancedPairs.swift NEW T13;  AdvancedSettingsView.swift, PairRow.swift NEW T14
  Features/Settings/Diagnostics/      T14 moves STTMetricsView, TTSMetricsView, TTSMonitorRow from Legacy/
  Features/Settings/LegacyAdvancedSettingsView.swift, Legacy/ModelDownloadSheets.swift  DEL T5
  Features/Settings/Legacy/KokoroVoicePicker.swift  DEL T12 (replaced by StandardVoices.kokoroOptions)
TranslateCallTests/
  PairModelChoicesTests T1; ModelCatalogV2Tests T2; CloudPolicyTests T3; ModelResolutionTests T4;
  STTEngineSelectorTests (rewritten), TTSEngineSelectorTests (rewritten), EdgeTTSTests (selector suite rewritten),
  WhisperSTTTests (routing suite removed), ModelPreloaderTests, MainSetupModelTests, SettingsOpenerTests  MOD T5;
  ModelChoiceSelectorTests, TTSEngineSelectorVoiceCloneTests, LegacyAdvancedSettingsTests  DEL T5;
  ModelDownloadsTests T6; ModelPreloaderTests MOD T7; PairModelsModelTests T8; SettingsOpenerTests,
  GeneralSettingsTests MOD T10; StandardVoicesTests T11; AdvancedSettingsLogicTests T13
specs/m9-product/backlog.md, docs/ARCHITECTURE.md   MOD T15
```

**Dependency order:**
- T1 → T2 → T3 → T4 → T5 → T6 → T7;
- T8 needs T2, T3, T4 and T6;
- T9 needs T5 and T8;
- T10 needs T5;
- T11 needs T5;
- T12 needs T10 and T11;
- T13 needs T1 and T8 (it uses `PairModelsModel.name`);
- T14 needs T9, T10 and T13;
- then T15 and T16.

**Executor per task:**
- **pi:** T1, T2, T3, T10, T11, T13 (mechanical, full code given, no prototype). The pi labels are in memory `pi-usage-tracking`.
- **opus:** T5, T6, T7 (concurrency or a cross-cutting rewrite), and the final whole-branch review.
- **sonnet:** T4, T8, T9, T12, T14, T15.

---

### Task 1: Per-pair choice store — `PairKey`, `PairModelChoice`, `PairModelChoices` (pi)

**Files:**
- Create: `TranslateCall/Core/Models/PairModelChoices.swift`
- Test: `TranslateCallTests/PairModelChoicesTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated struct PairKey: Hashable, Codable, Sendable`, with `init(_: String, _: String)` (sorted), `init(_: Locale.Language, _: Locale.Language)`, `storageKey` (`"de|es"`), `init?(storageKey:)` and `static func code(_:)`;
  - `nonisolated struct PairModelChoice: Codable, Equatable, Sendable`, with `stt: STTEngine?` and `voice: TTSEngine?` (never `.voiceClone`), `isEmpty`, and `init(stt:voice:)`;
  - `@MainActor final class PairModelChoices: ObservableObject`, with `static let defaultsKey = "tlk.models.pairChoices"`, `@Published private(set) var all: [PairKey: PairModelChoice]`, `init(defaults:)`, `choice(for:)` and `set(_:for:)` (an empty choice removes the entry).

- [ ] **Step 1: Write the failing tests** — `TranslateCallTests/PairModelChoicesTests.swift`:

```swift
import Foundation
import Testing
@testable import TranslateCall

@MainActor
private func freshDefaults() -> UserDefaults {
    let name = "PairModelChoicesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Per-pair model choices (M9 UI settings REQ-ST-01)") @MainActor
struct PairModelChoicesTests {

    @Test("a pair has no order: ES ↔ DE is DE ↔ ES; the storage key round-trips")
    func pairKeyIsUnordered() throws {
        #expect(PairKey("es", "de") == PairKey("de", "es"))
        #expect(PairKey("es", "de").storageKey == "de|es")
        #expect(PairKey(Locale.Language(identifier: "es-ES"), Locale.Language(identifier: "de")) == PairKey("de", "es"))
        #expect(try #require(PairKey(storageKey: "de|es")) == PairKey("es", "de"))
        #expect(PairKey(storageKey: "nope") == nil)
    }

    @Test("choices persist across instances; an empty choice removes the pair")
    func persistAndRemove() {
        let defaults = freshDefaults()
        let store = PairModelChoices(defaults: defaults)
        store.set(PairModelChoice(stt: .appleSpeech), for: PairKey("es", "de"))
        #expect(PairModelChoices(defaults: defaults).choice(for: PairKey("de", "es")).stt == .appleSpeech)

        store.set(PairModelChoice(), for: PairKey("es", "de"))
        #expect(PairModelChoices(defaults: defaults).all.isEmpty)
        #expect(store.choice(for: PairKey("es", "de")).isEmpty)
    }

    @Test("the voice clone is never stored as a pair's voice (S-6)")
    func voiceCloneNeverStored() {
        #expect(PairModelChoice(voice: .voiceClone).voice == nil)
    }

    @Test("unknown engine names decode as nil; a corrupt value is an empty store")
    func tolerantDecoding() throws {
        let defaults = freshDefaults()
        let json = #"{"de|es":{"stt":"futureEngine","voice":"kokoro"}}"#
        defaults.set(Data(json.utf8), forKey: PairModelChoices.defaultsKey)
        let choice = PairModelChoices(defaults: defaults).choice(for: PairKey("es", "de"))
        #expect(choice == PairModelChoice(voice: .kokoro))

        defaults.set(Data("{ nope".utf8), forKey: PairModelChoices.defaultsKey)
        #expect(PairModelChoices(defaults: defaults).all.isEmpty)
    }
}
```

- [ ] **Step 2: Run them, expect a compile failure** — `just test-only PairModelChoicesTests` → "cannot find 'PairKey' in scope".

- [ ] **Step 3: Implement** — `TranslateCall/Core/Models/PairModelChoices.swift` (full code; pi copies it):

```swift
import Combine
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "PairModelChoices")

// MARK: - PairKey

/// An unordered language pair: ES ↔ DE and DE ↔ ES are the same key (M9 UI settings REQ-ST-01).
nonisolated struct PairKey: Hashable, Codable, Sendable {
    let first: String
    let second: String

    /// Language codes (`es`, `de`, …), stored sorted.
    init(_ lhs: String, _ rhs: String) {
        (first, second) = lhs <= rhs ? (lhs, rhs) : (rhs, lhs)
    }

    /// The pair of two picker languages, by language code (`es-ES` → `es`).
    init(_ lhs: Locale.Language, _ rhs: Locale.Language) {
        self.init(Self.code(lhs), Self.code(rhs))
    }

    /// `"de|es"`: the key in `UserDefaults` and in the catalog's `pairs` table.
    var storageKey: String { "\(first)|\(second)" }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: "|").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(parts[0], parts[1])
    }

    static func code(_ language: Locale.Language) -> String {
        language.languageCode?.identifier ?? language.minimalIdentifier
    }
}

// MARK: - PairModelChoice

/// The user's choice per stage for one pair; nil = the catalog's recommendation (S-1).
nonisolated struct PairModelChoice: Codable, Equatable, Sendable {
    var stt: STTEngine?
    /// The standard voice; never `.voiceClone`, which "Use my voice" owns (S-6).
    var voice: TTSEngine?

    init(stt: STTEngine? = nil, voice: TTSEngine? = nil) {
        self.stt = stt
        self.voice = voice == .voiceClone ? nil : voice
    }

    var isEmpty: Bool { stt == nil && voice == nil }

    /// Unknown engine names (a newer build's engine) decode as nil instead of failing the whole store.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stt = (try? container.decodeIfPresent(String.self, forKey: .stt)).flatMap { $0 }
        let voice = (try? container.decodeIfPresent(String.self, forKey: .voice)).flatMap { $0 }
        self.init(stt: stt.flatMap(STTEngine.init(rawValue:)), voice: voice.flatMap(TTSEngine.init(rawValue:)))
    }
}

// MARK: - PairModelChoices

/// The stored per-pair choices (`tlk.models.pairChoices`, JSON `[storageKey: PairModelChoice]`).
@MainActor
final class PairModelChoices: ObservableObject {
    static let defaultsKey = "tlk.models.pairChoices"

    @Published private(set) var all: [PairKey: PairModelChoice]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        all = Self.load(from: defaults)
    }

    func choice(for pair: PairKey) -> PairModelChoice {
        all[pair] ?? PairModelChoice()
    }

    /// Stores `choice`; an empty one removes the pair ("Recommended").
    func set(_ choice: PairModelChoice, for pair: PairKey) {
        all[pair] = choice.isEmpty ? nil : choice
        save()
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: all.map { ($0.key.storageKey, $0.value) })
        do {
            defaults.set(try JSONEncoder().encode(raw), forKey: Self.defaultsKey)
        } catch {
            logger.error("Could not save pair choices: \(error.localizedDescription)")
        }
    }

    /// A missing or corrupt value is an empty store (every pair "Recommended").
    private static func load(from defaults: UserDefaults) -> [PairKey: PairModelChoice] {
        guard let data = defaults.data(forKey: defaultsKey),
              let raw = try? JSONDecoder().decode([String: PairModelChoice].self, from: data) else { return [:] }
        var result: [PairKey: PairModelChoice] = [:]
        for (key, choice) in raw where !choice.isEmpty {
            if let pair = PairKey(storageKey: key) { result[pair] = choice }
        }
        return result
    }
}
```

- [ ] **Step 4: Run** — `just test-only PairModelChoicesTests` → passes; `just lint` → clean.

- [ ] **Step 5: Commit** — `feat(models): per-pair model choice store (M9 UI settings REQ-ST-01)`.

---

### Task 2: Catalog v2 — engine flags and per-pair benchmark data (pi)

**Files:**
- Modify: `TranslateCall/Core/Models/ModelCatalog.swift`, `TranslateCall/Core/Models/ModelCatalog.json`
- Test: `TranslateCallTests/ModelCatalogV2Tests.swift` (the existing `ModelCatalogTests` must stay green)

**Interfaces:**
- Consumes: Task 1 (`PairKey`).
- Produces:
  - `ModelCatalog.engines: [String: EngineInfo]` and `ModelCatalog.pairs: [String: [String: EngineMetrics]]`, both `var`s defaulting to `[:]`, so the memberwise init keeps its four-argument form;
  - `func isUnavailable(_ engine: TTSEngine) -> Bool`;
  - `func metrics(for pair: PairKey, engine: String) -> EngineMetrics?`;
  - `struct EngineInfo: Decodable, Equatable { var unavailable = false }`;
  - `struct EngineMetrics: Decodable, Equatable { var tested = false; var latencyMs: Int? }`, with `func latencyLabel(isVoice: Bool) -> String?` returning `"~0.4 s"` / `"~0.5 s to first audio"`;
  - `ModelCatalog.builtIn` and the bundled JSON become `version: 2` with `"engines": {"edgeTTS": {"unavailable": true}}` and `"pairs": {}`.

- [ ] **Step 1: Write the failing tests** — `TranslateCallTests/ModelCatalogV2Tests.swift`:

```swift
import Foundation
import Testing
@testable import TranslateCall

@Suite("ModelCatalog v2 (M9 UI settings S-2, S-3)") @MainActor
struct ModelCatalogV2Tests {

    private func decode(_ json: String) throws -> ModelCatalog {
        try JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))
    }

    @Test("a v1 file still decodes, with no engine flags and no pair data")
    func v1StillDecodes() throws {
        let catalog = try decode(#"{"version":1,"stt":{"default":["appleSpeech"]},"ttsOutgoing":{},"ttsIncoming":{}}"#)
        #expect(catalog.engines.isEmpty && catalog.pairs.isEmpty)
        #expect(!catalog.isUnavailable(.edgeTTS))
    }

    @Test("v2 reads engine flags and per-pair metrics; the label formats seconds")
    func v2Fields() throws {
        let catalog = try decode("""
            {"version":2,"stt":{},"ttsOutgoing":{},"ttsIncoming":{},
             "engines":{"edgeTTS":{"unavailable":true}},
             "pairs":{"de|es":{"whisper":{"tested":true,"latencyMs":400},"voiceClone":{"latencyMs":500}}}}
            """)
        #expect(catalog.isUnavailable(.edgeTTS))
        let whisper = try #require(catalog.metrics(for: PairKey("es", "de"), engine: "whisper"))
        #expect(whisper.tested)
        #expect(whisper.latencyLabel(isVoice: false) == "~0.4 s")
        let clone = try #require(catalog.metrics(for: PairKey("de", "es"), engine: "voiceClone"))
        #expect(!clone.tested)
        #expect(clone.latencyLabel(isVoice: true) == "~0.5 s to first audio")
        #expect(catalog.metrics(for: PairKey("en", "es"), engine: "whisper") == nil)
        #expect(EngineMetrics(tested: true).latencyLabel(isVoice: false) == nil)
    }

    @Test("the bundled catalog and the built-in fallback mark Edge unavailable (A27) and carry no pair data")
    func bundledMarksEdgeUnavailable() {
        for catalog in [ModelCatalog.bundled, .builtIn] {
            #expect(catalog.version == 2)
            #expect(catalog.isUnavailable(.edgeTTS))
            #expect(catalog.pairs.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run, expect failure** — `just test-only ModelCatalogV2Tests` → "value of type 'ModelCatalog' has no member 'engines'".

- [ ] **Step 3: Implement.** The decoding needs care: a v1 file must still decode, and the memberwise init must survive.
  - Put `init(from:)` in **extensions** of `ModelCatalog`, `EngineInfo` and `EngineMetrics`. In the type body it would remove the memberwise init.
  - Each extension declares a `private enum CodingKeys`. Synthesis does not provide them once `init(from:)` is custom on a `Decodable`-only type.
  - Use `decodeIfPresent(...) ?? [:]` / `?? false`.
  - Update the doc comment.
  - The bundled JSON:

```json
{
  "version": 2,
  "stt": {
    "en": ["parakeet", "whisper", "appleSpeech"],
    "default": ["whisper", "appleSpeech"]
  },
  "ttsOutgoing": {
    "en": ["voiceClone", "kokoro", "avSpeech"],
    "default": ["voiceClone", "avSpeech"]
  },
  "ttsIncoming": {
    "en": ["kokoro", "avSpeech"],
    "default": ["avSpeech"]
  },
  "engines": {
    "edgeTTS": { "unavailable": true }
  },
  "pairs": {}
}
```

- [ ] **Step 4: Run** — `just test-only ModelCatalogV2Tests ModelCatalogTests` → both pass; `just lint` → clean.

- [ ] **Step 5: Commit** — `feat(models): catalog v2 with engine flags and per-pair metrics (S-2, S-3)`.

---

### Task 3: Cloud policy — the switch, consent, the snapshot (pi)

**Files:**
- Create: `TranslateCall/Core/Models/CloudPolicy.swift`
- Test: `TranslateCallTests/CloudPolicyTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated struct CloudSnapshot: Equatable, Sendable`, with `allowed`, `consented: Set<TTSEngine>`, `unavailable: Set<TTSEngine>` and `permits(_:)`;
  - `@MainActor final class CloudPolicy: ObservableObject`, with `static let allowedKey = "tlk.cloud.allowed"`, `@Published var allowed: Bool` (stored on set), `init(defaults:edgeConsentGiven:grantEdgeConsent:)`, `hasConsent(_:)` and `grantConsent(_:)`.

- [ ] **Step 1: Write the failing tests** — `TranslateCallTests/CloudPolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import TranslateCall

@MainActor
private func freshDefaults() -> UserDefaults {
    let name = "CloudPolicyTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Cloud policy (M9 UI settings REQ-ST-15, 32)") @MainActor
struct CloudPolicyTests {

    @Test("off by default; on for an install that already consented to Edge; then stored")
    func defaultFollowsExistingConsent() {
        #expect(!CloudPolicy(defaults: freshDefaults(), edgeConsentGiven: { false }, grantEdgeConsent: {}).allowed)
        let defaults = freshDefaults()
        #expect(CloudPolicy(defaults: defaults, edgeConsentGiven: { true }, grantEdgeConsent: {}).allowed)
        #expect(defaults.object(forKey: CloudPolicy.allowedKey) as? Bool == true)

        let policy = CloudPolicy(defaults: defaults, edgeConsentGiven: { true }, grantEdgeConsent: {})
        policy.allowed = false
        #expect(!CloudPolicy(defaults: defaults, edgeConsentGiven: { true }, grantEdgeConsent: {}).allowed)
    }

    @Test("consent is per engine; only Edge is a cloud engine")
    func consent() {
        var granted = false
        let policy = CloudPolicy(defaults: freshDefaults(), edgeConsentGiven: { granted },
                                 grantEdgeConsent: { granted = true })
        #expect(!policy.hasConsent(.edgeTTS))
        policy.grantConsent(.kokoro)
        #expect(!granted)
        policy.grantConsent(.edgeTTS)
        #expect(policy.hasConsent(.edgeTTS))
        #expect(!policy.hasConsent(.avSpeech))
    }

    @Test("a cloud engine runs only when allowed, consented and available (NFR-ST-02)",
          arguments: [(true, true, false, true), (false, true, false, false),
                      (true, false, false, false), (true, true, true, false)])
    func permits(allowed: Bool, consented: Bool, unavailable: Bool, expected: Bool) {
        let snapshot = CloudSnapshot(allowed: allowed, consented: consented ? [.edgeTTS] : [],
                                     unavailable: unavailable ? [.edgeTTS] : [])
        #expect(snapshot.permits(.edgeTTS) == expected)
    }
}
```

- [ ] **Step 2: Run, expect failure** — `just test-only CloudPolicyTests` → "cannot find 'CloudPolicy' in scope".

- [ ] **Step 3: Implement** — full code:

```swift
import Combine
import Foundation

// MARK: - CloudSnapshot

/// What the cloud rules allow right now, as a value for the pure resolution (M9 UI settings REQ-ST-02, 32).
nonisolated struct CloudSnapshot: Equatable, Sendable {
    /// "Allow cloud models" (Settings › Advanced).
    var allowed = false
    /// Cloud engines the user consented to.
    var consented: Set<TTSEngine> = []
    /// Cloud engines the catalog marks unavailable (S-3).
    var unavailable: Set<TTSEngine> = []

    /// A cloud engine may run: allowed, consented and not marked unavailable (NFR-ST-02).
    func permits(_ engine: TTSEngine) -> Bool {
        allowed && consented.contains(engine) && !unavailable.contains(engine)
    }
}

// MARK: - CloudPolicy

/// "Allow cloud models" and per-engine consent (REQ-ST-15, 32). Edge TTS is the only cloud engine;
/// its consent stays in `EdgeTTSConsentManager` (machine-wide), injected so tests never touch it.
@MainActor
final class CloudPolicy: ObservableObject {
    static let allowedKey = "tlk.cloud.allowed"

    @Published var allowed: Bool {
        didSet { defaults.set(allowed, forKey: Self.allowedKey) }
    }

    private let defaults: UserDefaults
    private let edgeConsentGiven: () -> Bool
    private let grantEdgeConsent: () -> Void

    /// The first read defaults to the existing Edge consent, then is stored (REQ-ST-32).
    init(defaults: UserDefaults = .standard,
         edgeConsentGiven: @escaping () -> Bool = { EdgeTTSConsentManager.consentGiven },
         grantEdgeConsent: @escaping () -> Void = { EdgeTTSConsentManager.grantConsent() }) {
        self.defaults = defaults
        self.edgeConsentGiven = edgeConsentGiven
        self.grantEdgeConsent = grantEdgeConsent
        let stored = defaults.object(forKey: Self.allowedKey) as? Bool
        allowed = stored ?? edgeConsentGiven()
        if stored == nil { defaults.set(allowed, forKey: Self.allowedKey) }
    }

    func hasConsent(_ engine: TTSEngine) -> Bool {
        engine == .edgeTTS && edgeConsentGiven()
    }

    func grantConsent(_ engine: TTSEngine) {
        guard engine == .edgeTTS else { return }
        objectWillChange.send()
        grantEdgeConsent()
    }
}
```

- [ ] **Step 4: Run** — `just test-only CloudPolicyTests` → passes; `just lint` → clean.

- [ ] **Step 5: Commit** — `feat(models): cloud policy and consent (REQ-ST-15, 32)`.

---

### Task 4: Resolution with the pair's choice (sonnet)

**Files:**
- Modify: `TranslateCall/Core/Models/ModelChoice.swift`
- Test: `TranslateCallTests/ModelResolutionTests.swift` (the existing `ModelCatalogTests` must stay green)

**Interfaces:**
- Consumes: Task 3 (`CloudSnapshot`).
- Produces:
  - `ModelAvailability` gains `var cloud = CloudSnapshot()` and `static let allOnDisk` (Parakeet, Whisper and Kokoro cached; no clone; no cloud);
  - `ModelChoice.stt(for:direction:pairChoice: STTEngine? = nil, catalog:availability:)`;
  - `ModelChoice.tts(for:direction:pairChoice: TTSEngine? = nil, catalog:availability:)`;
  - `ModelChoice.serves(_: STTEngine | TTSEngine, locale:direction:) -> Bool` (language and direction only);
  - `ModelChoice.isUsable(_: STTEngine | TTSEngine, for:direction:availability:) -> Bool`.

  The automatic-flag API (`automaticKey`, `isAutomatic(in:)`, `setAutomatic`) stays until Task 5.

- [ ] **Step 1: Write the failing tests** — `TranslateCallTests/ModelResolutionTests.swift`:

```swift
import Foundation
import Testing
@testable import TranslateCall

private let en = Locale(identifier: "en-US")
private let es = Locale(identifier: "es-ES")
private let de = Locale(identifier: "de-DE")
private let edgeOK = CloudSnapshot(allowed: true, consented: [.edgeTTS])

@Suite("Resolution with a pair choice (M9 UI settings REQ-ST-02…04)") @MainActor
struct ModelResolutionTests {

    @Test("a usable STT choice wins over the catalog")
    func sttChoiceWins() {
        let all = ModelAvailability(parakeetCached: true, whisperCached: true)
        #expect(ModelChoice.stt(for: es, direction: .outgoing, pairChoice: .appleSpeech,
                                catalog: .builtIn, availability: all) == .appleSpeech)
    }

    @Test("an STT choice that is not usable falls back to the catalog",
          arguments: [
            (STTEngine.whisper, es, TranscriptDirection.outgoing, ModelAvailability(), STTEngine.appleSpeech),
            (.parakeet, es, .outgoing, ModelAvailability(parakeetCached: true, whisperCached: true), .whisper),
            (.parakeet, en, .incoming, ModelAvailability(parakeetCached: true, whisperCached: true), .whisper),
            (.parakeet, en, .outgoing, ModelAvailability(parakeetCached: true), .parakeet)
          ])
    func sttChoiceFallsBack(choice: STTEngine, locale: Locale, direction: TranscriptDirection,
                            availability: ModelAvailability, expected: STTEngine) {
        #expect(ModelChoice.stt(for: locale, direction: direction, pairChoice: choice,
                                catalog: .builtIn, availability: availability) == expected)
    }

    @Test("a voice choice applies to both directions where it serves the language (REQ-ST-03)")
    func voiceChoiceBothDirections() {
        let kokoro = ModelAvailability(kokoroCached: true)
        #expect(ModelChoice.tts(for: en, direction: .outgoing, pairChoice: .avSpeech,
                                catalog: .builtIn, availability: kokoro) == .avSpeech)
        #expect(ModelChoice.tts(for: en, direction: .incoming, pairChoice: .avSpeech,
                                catalog: .builtIn, availability: kokoro) == .avSpeech)
        #expect(ModelChoice.tts(for: es, direction: .incoming, pairChoice: .kokoro,
                                catalog: .builtIn, availability: kokoro) == .avSpeech, "Kokoro: English only")
    }

    @Test("the voice clone wins outgoing whatever the choice; the choice still applies incoming (REQ-ST-04)")
    func voiceCloneWinsOutgoing() {
        let clone = ModelAvailability(voiceCloneReady: true, cloud: edgeOK)
        #expect(ModelChoice.tts(for: es, direction: .outgoing, pairChoice: .edgeTTS,
                                catalog: .builtIn, availability: clone) == .voiceClone)
        #expect(ModelChoice.tts(for: es, direction: .incoming, pairChoice: .edgeTTS,
                                catalog: .builtIn, availability: clone) == .edgeTTS)
    }

    @Test("Kokoro chosen while the voice clone is ready falls back to the system voice (NF-04)")
    func kokoroBlockedByVoiceClone() {
        let both = ModelAvailability(kokoroCached: true, voiceCloneReady: true)
        #expect(ModelChoice.tts(for: en, direction: .incoming, pairChoice: .kokoro,
                                catalog: .builtIn, availability: both) == .avSpeech)
    }

    @Test("Edge as a choice needs cloud allowed, consent and availability (REQ-ST-32, S-3)",
          arguments: [
            (edgeOK, TTSEngine.edgeTTS),
            (CloudSnapshot(allowed: false, consented: [.edgeTTS]), .avSpeech),
            (CloudSnapshot(allowed: true), .avSpeech),
            (CloudSnapshot(allowed: true, consented: [.edgeTTS], unavailable: [.edgeTTS]), .avSpeech)
          ])
    func edgeChoiceNeedsCloud(cloud: CloudSnapshot, expected: TTSEngine) {
        #expect(ModelChoice.tts(for: de, direction: .incoming, pairChoice: .edgeTTS, catalog: .builtIn,
                                availability: ModelAvailability(cloud: cloud)) == expected)
    }

    @Test("serves ignores the disk: Parakeet and the voice clone are outgoing only")
    func servesRules() {
        #expect(ModelChoice.serves(STTEngine.parakeet, locale: en, direction: .outgoing))
        #expect(!ModelChoice.serves(STTEngine.parakeet, locale: en, direction: .incoming))
        #expect(!ModelChoice.serves(STTEngine.parakeet, locale: es, direction: .outgoing))
        #expect(!ModelChoice.serves(TTSEngine.voiceClone, locale: es, direction: .incoming))
        #expect(ModelChoice.serves(TTSEngine.kokoro, locale: en, direction: .incoming))
    }
}
```

- [ ] **Step 2: Run, expect failure** — `just test-only ModelResolutionTests` → "extra argument 'pairChoice' in call".

- [ ] **Step 3: Implement** the rules of REQ-ST-02…04.
  - **`serves`:**
    - `engine.supports(locale:)`;
    - not Parakeet for incoming;
    - not the voice clone for incoming.
  - **`isUsable`:** `serves`, plus readiness:
    - Apple Speech and AVSpeech are always ready;
    - Parakeet and Whisper are ready when cached;
    - Kokoro is ready when cached and the voice clone is not ready (NF-04);
    - the voice clone is ready when `voiceCloneReady`;
    - Edge is ready when `cloud.permits(.edgeTTS)`.
  - **`stt`:** the choice if usable, else the first usable catalog engine, else `.appleSpeech`.
  - **`tts`:**
    1. if the catalog lists `.voiceClone` for the language and it is usable, `.voiceClone`;
    2. else the choice if usable;
    3. else the first usable listed engine;
    4. else `.avSpeech`.
  - **Algorithm order:** keep the voice-clone-first step before the choice; a test pins it.
  - Update the type's doc comment.

- [ ] **Step 4: Run** — `just test-only ModelResolutionTests ModelCatalogTests` → both pass; `just lint` → clean.

- [ ] **Step 5: Commit** — `feat(models): resolve engines with the pair's choice (REQ-ST-02…04)`.

---

### Task 5: Selectors through the pair's choice; remove manual mode and the legacy tab (opus)

The switch-over: from here on there is no global manual mode. One commit, because the build only goes green once every caller of the old API is gone.

**Files:**
- Modify:
  - `TranslateCall/Core/Models/ModelChoice.swift` (drop `automaticKey`, `isAutomatic(in:)`, `setAutomatic(_:in:)`);
  - `TranslateCall/Core/STT/STTEngineSelector.swift` (rewrite, P3);
  - `TranslateCall/Core/TTS/TTSEngineSelector.swift` (P4, P5);
  - `TranslateCall/Core/Models/ModelPreloader.swift` (drop the `isAutomatic` guards; `wantedModels` uses `resolvedEngine`);
  - `TranslateCall/App/AppContainer.swift`, `TranslateCall/App/TranslateCallApp.swift`;
  - `TranslateCall/Features/Main/MainSetupModel.swift`, `LanguageSection.swift`, `MainSetupView.swift`, `MainSetupPreviews.swift`, `AudioViewModel+Start.swift`;
  - `TranslateCall/Features/Settings/SettingsView.swift`.
- Create:
  - `TranslateCall/Core/Models/ModelServices.swift`;
  - `TranslateCall/Features/Main/ModelsLabel.swift`;
  - `TranslateCall/App/HelpLinks.swift`.
- Delete:
  - `TranslateCall/Core/Models/ModelChoice+Selectors.swift`;
  - `TranslateCall/Features/Settings/LegacyAdvancedSettingsView.swift`;
  - `TranslateCall/Features/Settings/Legacy/ModelDownloadSheets.swift`;
  - `TranslateCallTests/ModelChoiceSelectorTests.swift`, `TranslateCallTests/TTSEngineSelectorVoiceCloneTests.swift`, `TranslateCallTests/LegacyAdvancedSettingsTests.swift`.
- Tests:
  - rewrite `TranslateCallTests/STTEngineSelectorTests.swift` and `TranslateCallTests/TTSEngineSelectorTests.swift`;
  - replace the `TTSEngineSelectorEdgeTTSTests` suite in `EdgeTTSTests.swift`;
  - delete the `STTEngineSelectorWhisperRoutingTests` suite from `WhisperSTTTests.swift`;
  - modify `ModelPreloaderTests.swift` and `MainSetupModelTests.swift`.

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - **`STTEngineSelector`:**
    - `init(appleSpeechFactory:parakeetFactory:whisperFactory:)`, which drops `defaults:` and `whisperAutoLoad:`;
    - `var catalog`, `var cacheProbe`, `var pairChoice: () -> PairModelChoice`;
    - `var availability: ModelAvailability`;
    - `func resolvedEngine(for: Locale, direction: TranscriptDirection) -> STTEngine`;
    - `makeOutgoingService(for:)` / `makeIncomingService(for:)`.
  - **`TTSEngineSelector`:**
    - `init(defaults:)`, which drops `voiceCloneAutoLoad:`;
    - `var pairChoice`, `var cloudAllowed: () -> Bool` (default `{ false }`);
    - `var availability`, `var cloudSnapshot: CloudSnapshot`;
    - `func resolvedEngine(for:direction:) -> TTSEngine`;
    - `func needsEdgeConsent(for: Locale) -> Bool`;
    - `isUsingEdgeTTS` (reads `resolvedEngine` for `currentTargetLocale`, outgoing).
  - **`ModelServices`** (`@MainActor struct`):
    - `choices: PairModelChoices` and `cloud: CloudPolicy`;
    - the production `init(stt:tts:languagePairManager:isSessionActive:)`;
    - the injected `init(choices:cloud:stt:tts:languagePairManager:)`, which wires `pairChoice` (both selectors, from the current pair) and `cloudAllowed`. Task 6 adds `downloads`.
  - **`UIServices.models: ModelServices`**, created before the preloader.
  - **`MainSetupModel`:**
    - `init(…, session:, models: ModelServices? = nil, tts: TTSEngineSelector? = nil, isInstalled:…, permissions:…)`;
    - `@Published private(set) var modelsLabel: String`, recomputed on choices, cloud and TTS changes.
  - **`ModelsLabel.text(hasChoice:usesCloud:)`:** "Models: Recommended" / "Models: Custom" / "Models: Recommended · Cloud" / "Models: Custom · Cloud" (P12).
  - **`LanguageSection(manager:pair:modelsLabel:onAdvanced:isLocked:onDownload:)`:** the selectors are gone from it.
  - **`MainSetupContent`:**
    - loses `sttSelector`;
    - gains `modelsLabel: String`;
    - `MainSetupActions.openModels` (default no-op, P10).
  - **`HelpLinks.usageGuide: URL`**, and a Help menu item "TranslateCall Help" (`CommandGroup(replacing: .help)`; keep the existing "Send Feedback…" group after it).
  - `container.uiServices.models.choices` and `.cloud` are injected as environment objects in both scenes.

- [ ] **Step 1: Rewrite the selector tests** (they fail to compile until Step 3):
  - `TranslateCallTests/STTEngineSelectorTests.swift`:

```swift
import Foundation
import Testing
@testable import TranslateCall

/// Records which STT factory a selector used.
@MainActor
private final class STTPicks {
    var used: [String] = []
    func factory(_ name: String) -> (Locale) -> any SpeechRecognizerService {
        { [weak self] locale in self?.used.append(name); return MockSpeechRecognizerService(locale: locale) }
    }
}

@MainActor
private func makeSTT(_ picks: STTPicks, probe: ModelCacheProbe,
                     choice: PairModelChoice = PairModelChoice()) -> STTEngineSelector {
    let selector = STTEngineSelector(appleSpeechFactory: picks.factory("apple"),
                                     parakeetFactory: picks.factory("parakeet"), whisperFactory: picks.factory("whisper"))
    selector.catalog = .builtIn
    selector.cacheProbe = probe
    selector.pairChoice = { choice }
    return selector
}

private let cachedAll = ModelCacheProbe(parakeet: { true }, whisper: { true }, kokoro: { true }, voiceClone: { false })

@Suite("STTEngineSelector (M9 UI settings REQ-ST-02)") @MainActor
struct STTEngineSelectorTests {

    @Test("recommended: the catalog with what is on disk, per direction")
    func recommended() {
        let picks = STTPicks()
        let stt = makeSTT(picks, probe: cachedAll)
        _ = stt.makeOutgoingService(for: Locale(identifier: "en-US"))
        _ = stt.makeIncomingService(for: Locale(identifier: "en-US"))
        _ = stt.makeOutgoingService(for: Locale(identifier: "es-ES"))
        #expect(picks.used == ["parakeet", "whisper", "whisper"])
    }

    @Test("nothing on disk → Apple Speech, even with Parakeet chosen for the pair")
    func nothingOnDisk() {
        let picks = STTPicks()
        let stt = makeSTT(picks, probe: .none, choice: PairModelChoice(stt: .parakeet))
        _ = stt.makeOutgoingService(for: Locale(identifier: "en-US"))
        #expect(picks.used == ["apple"])
    }

    @Test("the pair's choice wins where it is usable; elsewhere the catalog decides (REQ-ST-03)")
    func pairChoice() {
        let picks = STTPicks()
        let stt = makeSTT(picks, probe: cachedAll, choice: PairModelChoice(stt: .parakeet))
        _ = stt.makeOutgoingService(for: Locale(identifier: "en-US"))   // Parakeet: English, outgoing
        _ = stt.makeIncomingService(for: Locale(identifier: "es-ES"))   // not Spanish → catalog: Whisper
        #expect(picks.used == ["parakeet", "whisper"])
        #expect(stt.resolvedEngine(for: Locale(identifier: "en-US"), direction: .incoming) == .whisper)
    }
}
```

  - `TranslateCallTests/TTSEngineSelectorTests.swift`, the file below **without** the test `enableVoiceCloningStartsDownload`, which Task 6 adds:

```swift
import CoreAudio
import Foundation
import Testing
@testable import TranslateCall

// MARK: - TTSEngineSelectorTests

/// `TTSEngineSelector` playback composition and resolution through the pair choice (M9 UI settings
/// REQ-ST-02…04). Fake synthesizers and output, a fresh `UserDefaults` suite, injected disk checks: no
/// audio device, no model, no installed-voice dependency.
@Suite("TTSEngineSelector")
@MainActor
struct TTSEngineSelectorTests {

    private let kokoroOnDisk = ModelCacheProbe(parakeet: { false }, whisper: { false }, kokoro: { true },
                                               voiceClone: { true })

    func makeSelector(systemVoice: @escaping (Locale) -> Bool = { _ in true },
                      probe: ModelCacheProbe = .none, choice: PairModelChoice = PairModelChoice()) -> TTSEngineSelector {
        let selector = TTSEngineSelector(defaults: UserDefaults(suiteName: "TTSEngineSelectorTests.\(UUID())")!)
        selector.catalog = .builtIn
        selector.cacheProbe = probe
        selector.pairChoice = { choice }
        selector.hasSystemVoice = systemVoice
        selector.outputFactory = { _ in FakeOutput() }
        selector.avSpeechFactory = { FakeSynthesizer(engine: .avSpeech) }
        selector.kokoroFactory = { _ in FakeSynthesizer(engine: .kokoro) }
        selector.voiceCloneFactory = { _, _ in FakeSynthesizer(engine: .voiceClone) }
        selector.edgeFactory = { FakeSynthesizer(engine: .edgeTTS) }
        return selector
    }

    @Test("nothing on disk: AVSpeech primary with no fallback (REQ-T-22)")
    func avSpeechHasNoFallback() throws {
        let service = try makeSelector().makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(service.primaryEngine == .avSpeech)
        #expect(service.fallbackEngine == nil)
    }

    @Test("recommended: Kokoro for English when on disk, both directions, with the AVSpeech fallback")
    func kokoroRecommendedForEnglish() throws {
        let selector = makeSelector(probe: kokoroOnDisk)
        let outgoing = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(outgoing.primaryEngine == .kokoro)
        #expect(outgoing.fallbackEngine == .avSpeech)
        #expect(try selector.makeIncomingService(for: Locale(identifier: "en-US"), deviceID: nil).primaryEngine
                == .kokoro)
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "es-ES"), deviceID: nil).primaryEngine
                == .avSpeech)
    }

    @Test("a pair's voice choice overrides the recommendation in both directions")
    func pairChoiceOverrides() throws {
        let selector = makeSelector(probe: kokoroOnDisk, choice: PairModelChoice(voice: .avSpeech))
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil).primaryEngine
                == .avSpeech)
        #expect(try selector.makeIncomingService(for: Locale(identifier: "en-US"), deviceID: nil).primaryEngine
                == .avSpeech)
    }

    @Test("the voice clone is the outgoing voice when on disk, enabled and with a profile (REQ-ST-04)")
    func voiceCloneOutgoing() throws {
        let selector = makeSelector(probe: kokoroOnDisk, choice: PairModelChoice(voice: .kokoro))
        selector.setProfileStore(MockVoiceProfileStore())
        #expect(!selector.availability.voiceCloneReady, "not enabled, no profile")
        selector.voiceCloningEnabled = true
        selector.activeVoiceProfileId = UUID()
        #expect(selector.availability.voiceCloneReady, "on disk is enough; loading is not required")
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "es-ES"), deviceID: nil).primaryEngine
                == .voiceClone)
        #expect(try selector.makeIncomingService(for: Locale(identifier: "en-US"), deviceID: nil).primaryEngine
                == .avSpeech, "Kokoro is blocked while the voice clone is ready (NF-04)")
    }

    @Test("a voice clone with no profile store falls back to the system voice")
    func voiceCloneWithoutStore() throws {
        let selector = makeSelector(probe: kokoroOnDisk)
        selector.voiceCloningEnabled = true
        selector.activeVoiceProfileId = UUID()
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "es-ES"), deviceID: nil).primaryEngine
                == .avSpeech)
    }

    @Test("Edge as the pair's choice gets the AVSpeech fallback only when the locale has a system voice")
    func fallbackNeedsSystemVoice() throws {
        let selector = makeSelector(systemVoice: { $0.language.languageCode?.identifier == "en" },
                                    choice: PairModelChoice(voice: .edgeTTS))
        selector.catalog = ModelCatalog(version: 2, stt: [:], ttsOutgoing: ["default": ["avSpeech"]],
                                        ttsIncoming: ["default": ["avSpeech"]])
        selector.cloudAllowed = { true }
        selector.edgeConsentGiven = { true }
        let english = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(english.primaryEngine == .edgeTTS)
        #expect(english.fallbackEngine == .avSpeech)
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "uk-UA"), deviceID: nil).fallbackEngine == nil)
    }

    @Test("the output is built for the device the coordinator passes")
    func outputGetsDevice() throws {
        let selector = makeSelector()
        var devices: [AudioDeviceID?] = []
        selector.outputFactory = { devices.append($0); return FakeOutput() }
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: 42)
        _ = try selector.makeIncomingService(for: Locale(identifier: "es-ES"), deviceID: nil)
        #expect(devices == [42, nil])
    }

    @Test("an output that cannot open makes the factory throw (the coordinator shows it)")
    func outputFailureThrows() {
        let selector = makeSelector()
        selector.outputFactory = { _ in throw STSError.deviceRoutingFailed }
        #expect(throws: STSError.deviceRoutingFailed) {
            _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: 42)
        }
    }

    @Test("makeOutgoingService updates currentTargetLocale")
    func makeOutgoingServiceUpdatesCurrentLocale() throws {
        let selector = makeSelector()
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-AU"), deviceID: nil)
        #expect(selector.currentTargetLocale == Locale(identifier: "en-AU"))
    }

    @Test("\"Use my voice\" with the model not loaded starts the download through ModelDownloads (S-4)")
    func enableVoiceCloningStartsDownload() {
        let selector = makeSelector()
        var started = 0
        selector.startVoiceCloneDownload = { started += 1 }
        selector.enableVoiceCloning()
        #expect(selector.voiceCloningEnabled)
        #expect(started == 1)
    }

    @Test("Voice Clone supports Spanish, French, and other languages")
    func voiceCloneSupportsMultipleLanguages() {
        for code in ["es-ES", "fr-FR", "de-DE", "it-IT", "pt-BR", "ru-RU", "zh-Hans", "ja-JP", "ko-KR"] {
            #expect(TTSEngine.voiceClone.supports(locale: Locale(identifier: code)))
        }
        #expect(!TTSEngine.voiceClone.supports(locale: Locale(identifier: "hi-IN")))
        #expect(!TTSEngine.voiceClone.supports(locale: Locale(identifier: "ar-SA")))
    }
}
```

  - In `EdgeTTSTests.swift`, replace the whole `TTSEngineSelectorEdgeTTSTests` suite with:

```swift
@Suite("TTSEngineSelector Edge TTS routing (M9 UI settings REQ-ST-32)")
@MainActor
struct TTSEngineSelectorEdgeTTSTests {

    /// Every language except Ukrainian has a system voice; consent and the cloud switch are injected,
    /// so no test touches `UserDefaults.standard`.
    private func makeSelector(allowed: Bool, consent: Bool) -> TTSEngineSelector {
        let selector = TTSEngineSelector(defaults: UserDefaults(suiteName: "EdgeTTSTests.\(UUID())")!)
        selector.catalog = ModelCatalog(version: 2, stt: [:], ttsOutgoing: ["default": ["avSpeech"]],
                                        ttsIncoming: ["default": ["avSpeech"]])
        selector.cacheProbe = .none
        selector.outputFactory = { _ in FakeOutput() }
        selector.avSpeechFactory = { FakeSynthesizer(engine: .avSpeech) }
        selector.edgeFactory = { FakeSynthesizer(engine: .edgeTTS) }
        selector.hasSystemVoice = { $0.language.languageCode?.identifier != "uk" }
        selector.cloudAllowed = { allowed }
        selector.edgeConsentGiven = { consent }
        return selector
    }

    @Test("Ukrainian with the cloud allowed and no consent needs the consent prompt before Start")
    func needsConsentForUkrainian() {
        let uk = Locale(identifier: "uk")
        #expect(makeSelector(allowed: true, consent: false).needsEdgeConsent(for: uk))
        #expect(!makeSelector(allowed: false, consent: false).needsEdgeConsent(for: uk), "cloud off: no prompt")
        #expect(!makeSelector(allowed: true, consent: true).needsEdgeConsent(for: uk))
        #expect(!makeSelector(allowed: true, consent: false).needsEdgeConsent(for: Locale(identifier: "en")))
    }

    @Test("the no-system-voice fallback uses Edge only with the cloud allowed and consent")
    func fallbackNeedsCloud() throws {
        let consented = makeSelector(allowed: true, consent: true)
        let service = try consented.makeOutgoingService(for: Locale(identifier: "uk"), deviceID: nil)
        #expect(consented.isUsingEdgeTTS)
        #expect(service.primaryEngine == .edgeTTS)
        #expect(service.fallbackEngine == nil)   // no Ukrainian system voice to fall back to

        let off = makeSelector(allowed: false, consent: true)
        #expect(try off.makeOutgoingService(for: Locale(identifier: "uk"), deviceID: nil).primaryEngine == .avSpeech)
        #expect(!off.isUsingEdgeTTS)
    }

    @Test("Edge marked unavailable blocks the fallback and the prompt (S-3)")
    func unavailableBlocksFallback() throws {
        let selector = makeSelector(allowed: true, consent: true)
        selector.catalog = .builtIn   // marks Edge unavailable
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "uk"), deviceID: nil).primaryEngine
                == .avSpeech)
        selector.edgeConsentGiven = { false }
        #expect(!selector.needsEdgeConsent(for: Locale(identifier: "uk")))
    }
}
```

  - In `WhisperSTTTests.swift`, delete everything from `// MARK: - STTEngineSelector (Whisper routing) Tests` to the end of the file. Resolution is covered by the suites above.
  - In `ModelPreloaderTests.swift`:
    - the `Harness` builds `STTEngineSelector(appleSpeechFactory:parakeetFactory:whisperFactory:)`, without `defaults:`;
    - `voiceCloneWhenOutgoingChoice` adds `harness.tts.setProfileStore(MockVoiceProfileStore())` before enabling the voice (resolution needs a store, P5);
    - replace `manualAndSession` and `manualKeepsLoadedModels` with `sessionBlocks` and `pairChoiceDrivesPicks`:

```swift
    @Test("a session in progress blocks any change")
    func sessionBlocks() async {
        let harness = Harness(source: "en", target: "es", probe: cachedAll)
        let busy = harness.preloader(sessionActive: { true })
        await busy.preload()
        #expect(harness.log.entries.isEmpty)
    }

    @Test("the pair's choice drives the picks: Apple Speech chosen → Whisper unloaded (REQ-ST-61)")
    func pairChoiceDrivesPicks() async {
        let harness = Harness(source: "es", target: "en", probe: cachedAll)
        let preloader = harness.preloader()
        await preloader.preload()
        #expect(preloader.loaded == [.whisper])
        harness.stt.pairChoice = { PairModelChoice(stt: .appleSpeech) }
        await preloader.preload()
        #expect(harness.log.entries.last == "unload whisper")
        #expect(preloader.loaded.isEmpty)
    }
```

  - In `MainSetupModelTests.swift`:
    - the harness gains `let tts = TTSEngineSelector(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)` and `let models: ModelServices`;
    - it builds them as in Task 6 Step 1, minus the `downloads:` argument;
    - it passes `models: models, tts: tts` to `MainSetupModel`;
    - add the test `modelsLabel` (Task 6 Step 1 shows the final harness; the test is the same):

```swift
    @Test("the models line: Recommended; Custom with a pair choice; · Cloud when Edge will speak (REQ-ST-05, 40)")
    func modelsLabel() async {
        let harness = SetupHarness()
        #expect(harness.model.modelsLabel == "Models: Recommended")
        harness.models.choices.set(PairModelChoice(stt: .appleSpeech), for: PairKey("en", "de"))
        #expect(await waitUntil { harness.model.modelsLabel == "Models: Custom" })
        harness.tts.hasSystemVoice = { _ in false }
        harness.models.cloud.allowed = true
        #expect(await waitUntil { harness.model.modelsLabel == "Models: Custom · Cloud" })
        #expect(ModelsLabel.text(hasChoice: false, usesCloud: true) == "Models: Recommended · Cloud")
    }
```

  - `SettingsOpenerTests` stays as it is until Task 10.

- [ ] **Step 2: Run, expect failure** — `just test-only STTEngineSelectorTests` → compile errors on `pairChoice` / `resolvedEngine`.

- [ ] **Step 3: Implement.**
  - **Delete the manual mode.** Run `grep -rn "setPreferredEngine\|isAutomatic\|preferredEngine\|automaticKey\|setAutomatic\|usingFallback\|voiceCloningActive\|needsEdgeTTSConsent\|whisperAutoLoad\|voiceCloneAutoLoad\|LegacyAdvanced\|ModelDownloadSheets\|advancedLegacy" TranslateCall TranslateCallTests`. When done, the only hits are `TranslationEngineSelector` (a separate selector, untouched) and `SettingsTab.advancedLegacy` with its test (Task 10).
  - **TTS resolution** (the one path, P5):

```swift
    func resolvedEngine(for locale: Locale, direction: TranscriptDirection) -> TTSEngine {
        let engine = ModelChoice.tts(for: locale, direction: direction, pairChoice: pairChoice().voice,
                                     catalog: catalog, availability: availability)
        switch engine {
        case .voiceClone where profileStore == nil, .avSpeech: return systemOrEdgeEngine(for: locale)
        default: return engine
        }
    }

    /// AVSpeech when a system voice exists, else Edge when the cloud rules permit it, else AVSpeech.
    private func systemOrEdgeEngine(for locale: Locale) -> TTSEngine {
        if hasSystemVoice(locale) { return .avSpeech }
        if cloudSnapshot.permits(.edgeTTS), EdgeTTSVoiceCatalog.supports(locale) { return .edgeTTS }
        return .avSpeech
    }

    func needsEdgeConsent(for locale: Locale) -> Bool {
        let cloud = cloudSnapshot
        return !hasSystemVoice(locale) && EdgeTTSVoiceCatalog.supports(locale)
            && cloud.allowed && !cloud.unavailable.contains(.edgeTTS) && !cloud.consented.contains(.edgeTTS)
    }
```

    `outgoingPrimary` / `incomingPrimary` switch on `resolvedEngine` to build the synthesizer (the voice clone without a store/profile builds AVSpeech). Kokoro reads `KokoroConfiguration.voiceDefaultsKey` as today.
  - **`availability`** (TTS): `ModelAvailability(kokoroCached: cacheProbe.kokoro(), voiceCloneReady: voiceCloningEnabled && activeVoiceProfileId != nil && cacheProbe.voiceClone(), cloud: cloudSnapshot)`.
  - **`AudioViewModel.needsEdgeConsentBeforeStart`** → `ttsEngineSelector.needsEdgeConsent(for: targetLocale)`. Drop the now-unused `import AVFoundation`.
  - **`ModelPreloader.wantedModels()`** uses `stt.resolvedEngine(for: source, .outgoing)`, `(target, .incoming)` and `tts.resolvedEngine(for: target, .outgoing)`. `preload()` keeps only the session guard.
  - **`UIServices.init`:**
    - builds `let inSession = { coordinator.isOutgoingActive || coordinator.isStarting }`;
    - builds `models = ModelServices(stt:tts:languagePairManager:isSessionActive: inSession)` before the preloader;
    - passes `models: models, tts: tts` to `MainSetupModel`.
  - **`MainSetupModel.currentModelsLabel()`:**
    - `hasChoice` = the current pair's stored choice is not empty;
    - `usesCloud` = `tts.resolvedEngine(target, .outgoing) == .edgeTTS || tts.resolvedEngine(source, .incoming) == .edgeTTS`;
    - add `models.choices`, `models.cloud` and `tts` `objectWillChange` to the change sources.
  - **`SettingsView`:** only the General tab remains (Tasks 10, 12 and 14 add the others). The metrics views, `TTSMonitorRow` and `KokoroVoicePicker` stay in `Legacy/`, unused, until Tasks 12 and 14.

- [ ] **Step 4: Run** — `just test-only STTEngineSelectorTests TTSEngineSelectorTests TTSEngineSelectorEdgeTTSTests ModelPreloaderTests MainSetupModelTests ModelResolutionTests ModelCatalogTests`, then `just build`, `just lint`. All green.

- [ ] **Step 5: Run the unit tier** — `just test` → green. A `TranslationBridgeIntegrationTests` latency ceiling failing under load is not this task; re-run before suspecting code.

- [ ] **Step 6: Commit** — `refactor(models)!: per-pair choices replace the global manual engine mode (S-1)`.

---

### Task 6: `ModelDownloads` — in-row downloads, and "Use my voice" through it (opus)

**Files:**
- Create: `TranslateCall/Core/Models/ModelDownloads.swift`
- Modify:
  - `TranslateCall/Core/Models/ModelServices.swift` (`downloads`; wire `tts.startVoiceCloneDownload`);
  - `TranslateCall/Core/TTS/TTSEngineSelector.swift` (`startVoiceCloneDownload`; `enableVoiceCloning` uses it; drop `isVoiceCloneDownloading`);
  - `TranslateCall/Features/Main/VoiceSection.swift` (`isDownloading: Bool`);
  - `TranslateCall/Features/Main/MainSetupView.swift` (`@EnvironmentObject downloads`, `voiceCloneDownloading`);
  - `MainSetupPreviews.swift`;
  - `TranslateCall/App/TranslateCallApp.swift` (env object `models.downloads`).
- Test: `TranslateCallTests/ModelDownloadsTests.swift`; modify `TTSEngineSelectorTests.swift` and `MainSetupModelTests.swift`.

**Interfaces:**
- Consumes: Task 5 (`ModelServices`).
- Produces:
  - `nonisolated enum DownloadableModel: String, CaseIterable, Sendable { parakeet, whisper, kokoro, voiceClone }`, with `approximateSize` ("≈800 MB", "≈150 MB", "≈300 MB", "≈2 GB"), `init?(_: STTEngine)` and `init?(_: TTSEngine)`;
  - `nonisolated enum DownloadState: Equatable, Sendable { notOnDisk, downloading(progress: Double?), ready, failed(String) }`;
  - `nonisolated struct DownloadManagers: Sendable { download, cancel; static let live }`;
  - `@MainActor final class ModelDownloads: ObservableObject`:
    - `@Published private(set) var states`;
    - `let didFinish: PassthroughSubject<DownloadableModel, Never>`;
    - `init(probe:managers:isSessionActive:)`;
    - `isBlocked`, `state(_:)`, `start(_:)`, `cancel(_:)`, `refresh()`;
  - `ModelServices.downloads`, and the injected init becomes `init(choices:cloud:downloads:stt:tts:languagePairManager:)`;
  - `TTSEngineSelector.startVoiceCloneDownload: () -> Void` (default no-op);
  - `VoiceSection(…, isDownloading: Bool, …)`.

- [ ] **Step 1: Write the failing tests** — `TranslateCallTests/ModelDownloadsTests.swift`:

```swift
import Combine
import Foundation
import Synchronization
import Testing
@testable import TranslateCall

/// A fake download that waits until the test finishes or fails it; counts starts and cancels.
private final class FakeDownloads: Sendable {
    private let pending = Mutex<[DownloadableModel: CheckedContinuation<Void, any Error>]>([:])
    private let log = Mutex<[String]>([])
    var entries: [String] { log.withLock { $0 } }
    var isWaiting: Bool { pending.withLock { !$0.isEmpty } }

    var managers: DownloadManagers {
        DownloadManagers(
            download: { model in
                self.log.withLock { $0.append("download \(model.rawValue)") }
                try await withCheckedThrowingContinuation { continuation in
                    self.pending.withLock { $0[model] = continuation }
                }
            },
            cancel: { model in self.log.withLock { $0.append("cancel \(model.rawValue)") } })
    }

    func finish(_ model: DownloadableModel, error: (any Error)? = nil) {
        let continuation = pending.withLock { $0.removeValue(forKey: model) }
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
}

private struct Boom: LocalizedError { var errorDescription: String? { "No network" } }

/// The disk check flips to true once a fake download finishes.
private final class FakeDisk: Sendable {
    let onDisk = Mutex<Set<DownloadableModel>>([])
    var probe: ModelCacheProbe {
        ModelCacheProbe(parakeet: { self.onDisk.withLock { $0.contains(.parakeet) } },
                        whisper: { self.onDisk.withLock { $0.contains(.whisper) } },
                        kokoro: { self.onDisk.withLock { $0.contains(.kokoro) } },
                        voiceClone: { self.onDisk.withLock { $0.contains(.voiceClone) } })
    }
}

@Suite("ModelDownloads (M9 UI settings S-4, S-7)") @MainActor
struct ModelDownloadsTests {

    @Test("states come from the disk; sizes are the legacy figures; engines map to models")
    func initialStates() {
        let disk = FakeDisk()
        disk.onDisk.withLock { $0 = [.whisper] }
        let downloads = ModelDownloads(probe: disk.probe, managers: FakeDownloads().managers)
        #expect(downloads.state(.whisper) == .ready)
        #expect(downloads.state(.parakeet) == .notOnDisk)
        #expect(DownloadableModel.parakeet.approximateSize == "≈800 MB")
        #expect(DownloadableModel.voiceClone.approximateSize == "≈2 GB")
        #expect(DownloadableModel(STTEngine.appleSpeech) == nil)
        #expect(DownloadableModel(TTSEngine.kokoro) == .kokoro)
        #expect(DownloadableModel(TTSEngine.edgeTTS) == nil)
    }

    @Test("start → downloading (no progress) → ready, and didFinish fires once")
    func downloadSucceeds() async {
        let fake = FakeDownloads()
        let downloads = ModelDownloads(probe: FakeDisk().probe, managers: fake.managers)
        var finished: [DownloadableModel] = []
        let token = downloads.didFinish.sink { finished.append($0) }
        downloads.start(.parakeet)
        #expect(downloads.state(.parakeet) == .downloading(progress: nil))
        downloads.start(.parakeet)   // a second start while downloading is ignored
        #expect(await waitUntil { fake.isWaiting })
        fake.finish(.parakeet)
        #expect(await waitUntil { downloads.state(.parakeet) == .ready })
        #expect(finished == [.parakeet])
        #expect(fake.entries == ["download parakeet"])
        token.cancel()
    }

    @Test("a failure shows the error; starting again retries")
    func downloadFails() async {
        let fake = FakeDownloads()
        let downloads = ModelDownloads(probe: FakeDisk().probe, managers: fake.managers)
        downloads.start(.kokoro)
        #expect(await waitUntil { fake.isWaiting })
        fake.finish(.kokoro, error: Boom())
        #expect(await waitUntil { downloads.state(.kokoro) == .failed("No network") })
        downloads.start(.kokoro)
        #expect(downloads.state(.kokoro) == .downloading(progress: nil))
        #expect(await waitUntil { fake.isWaiting })
        fake.finish(.kokoro)
        #expect(await waitUntil { downloads.state(.kokoro) == .ready })
    }

    @Test("cancel asks the manager to stop and re-probes the disk; a late finish changes nothing")
    func cancelIsBestEffort() async {
        let fake = FakeDownloads()
        let downloads = ModelDownloads(probe: FakeDisk().probe, managers: fake.managers)
        var finished = 0
        let token = downloads.didFinish.sink { _ in finished += 1 }
        downloads.start(.whisper)
        #expect(await waitUntil { fake.isWaiting })
        downloads.cancel(.whisper)
        #expect(downloads.state(.whisper) == .notOnDisk)
        #expect(await waitUntil { fake.entries.contains("cancel whisper") })
        fake.finish(.whisper)
        await mainQueueHop()
        #expect(downloads.state(.whisper) == .notOnDisk)
        #expect(finished == 0)
        token.cancel()
    }

    @Test("no download starts while a session runs (S-7)")
    func blockedDuringSession() {
        let fake = FakeDownloads()
        let downloads = ModelDownloads(probe: FakeDisk().probe, managers: fake.managers, isSessionActive: { true })
        #expect(downloads.isBlocked)
        downloads.start(.parakeet)
        #expect(downloads.state(.parakeet) == .notOnDisk)
        #expect(fake.entries.isEmpty)
    }

    @Test("a model already on disk is not downloaded again")
    func readyIsNoOp() {
        let disk = FakeDisk()
        disk.onDisk.withLock { $0 = [.voiceClone] }
        let fake = FakeDownloads()
        let downloads = ModelDownloads(probe: disk.probe, managers: fake.managers)
        downloads.start(.voiceClone)
        #expect(downloads.state(.voiceClone) == .ready)
        #expect(fake.entries.isEmpty)
    }
}
```

  Add to `TTSEngineSelectorTests` the test `enableVoiceCloningStartsDownload` (from the Task 5 listing). The final `MainSetupModelTests` harness block:

```swift
        let session = CallSessionModel(coordinator: coordinator, viewModel: viewModel)
        tts.cacheProbe = .none
        tts.edgeConsentGiven = { true }
        tts.catalog = ModelCatalog(version: 2, stt: [:], ttsOutgoing: [:], ttsIncoming: [:])   // Edge available
        let modelDefaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        models = ModelServices(choices: PairModelChoices(defaults: modelDefaults),
                               cloud: CloudPolicy(defaults: modelDefaults, edgeConsentGiven: { true },
                                                  grantEdgeConsent: {}),
                               downloads: ModelDownloads(probe: .none, managers: DownloadManagers(
                                   download: { _ in }, cancel: { _ in })),
                               stt: STTEngineSelector(), tts: tts, languagePairManager: languages)
        models.cloud.allowed = false
        model = MainSetupModel(monitor: monitor, setupManager: setupManager, languagePairManager: languages,
                               session: session, models: models, tts: tts,
                               isInstalled: installed, permissions: permissions)
    }
```

- [ ] **Step 2: Run, expect failure** — `just test-only ModelDownloadsTests` → "cannot find 'ModelDownloads' in scope".

- [ ] **Step 3: Implement.**
  - **The download lifecycle:**
    - `start(_:)` is a no-op while blocked, while a task exists for the model, or when the state is `.ready`;
    - otherwise it sets `.downloading(progress: nil)` and keeps a `Task` per model;
    - when the task completes:
      - the state becomes `.ready` and `didFinish` fires;
      - on error, the state becomes `.failed(error.localizedDescription)`;
      - in both cases, only when the task was not cancelled.
  - **`cancel(_:)`** (best effort, design §5):
    - removes and cancels the task;
    - calls `managers.cancel` in a detached `Task`;
    - re-probes: `.ready` if on disk, else `.notOnDisk`.
  - **`refresh()`** re-probes every model without a task, and runs in `init`.
  - **`DownloadManagers.live`:**
    - Parakeet: `ensureReady()`;
    - Whisper: `loadIfNeeded()` (P8);
    - Kokoro: `ensureReady()` then `unload()` (P7);
    - voice clone: `ensureReady()`;
    - cancel: Parakeet `unload()`, Whisper `unloadModel()`, Kokoro `unload()`, voice clone nothing (P19).
  - **`enableVoiceCloning()`:**
    - sets `voiceCloningEnabled = true`;
    - when `voiceCloneAvailable` is false, unloads Kokoro if it is loaded, then calls `startVoiceCloneDownload()`;
    - when the model is already on disk, `start` is a no-op and the preloader loads it (Task 7 trigger).
  - **`MainSetupView`** passes `voiceCloneDownloading: downloads.state(.voiceClone) == .downloading(progress: nil)` to `MainSetupContent`, which hands it to `VoiceSection(isDownloading:)`.

- [ ] **Step 4: Run** — `just test-only ModelDownloadsTests TTSEngineSelectorTests MainSetupModelTests`; repeat `ModelDownloadsTests` 3 times (concurrency); `just lint`.

- [ ] **Step 5: Commit** — `feat(models): one download facade for the UI; "Use my voice" goes through it (S-4, S-7)`.

---

### Task 7: Preloader — failed loads retried, re-run on every trigger (opus)

**Files:**
- Modify: `TranslateCall/Core/Models/ModelPreloader.swift`, `TranslateCall/Core/Models/ModelServices.swift` (`preloadTriggers(tts:)`), `TranslateCall/App/AppContainer.swift`
- Test: `TranslateCallTests/ModelPreloaderTests.swift`

**Interfaces:**
- Consumes: Tasks 5 and 6.
- Produces:
  - `ModelLoaders.load: @Sendable (PreloadModel) async -> Bool` (true = loaded);
  - `ModelPreloader.start(triggers: [AnyPublisher<Void, Never>] = [])`;
  - `ModelServices.preloadTriggers(tts:) -> [AnyPublisher<Void, Never>]`: `choices.$all`, `cloud.$allowed`, `downloads.didFinish`, `tts.$voiceCloningEnabled` and `tts.$activeVoiceProfileId`, each mapped to `()`.

- [ ] **Step 1: Write the failing tests.**
  - In `ModelPreloaderTests.swift`, `LoaderLog` gains failures:

```swift
/// Records load/unload calls in order; models in `failing` fail to load.
private final class LoaderLog: Sendable {
    private let calls = Mutex<[String]>([])
    let failing = Mutex<Set<PreloadModel>>([])
    var entries: [String] { calls.withLock { $0 } }
    var loaders: ModelLoaders {
        ModelLoaders(load: { model in
                         self.calls.withLock { $0.append("load \(model)") }
                         return !self.failing.withLock { $0.contains(model) }
                     },
                     unload: { model in self.calls.withLock { $0.append("unload \(model)") } })
    }
}
```

  - Add `import Combine` and these tests:

```swift
    @Test("a failed load is not recorded as loaded and is retried at the next preload (UI-B4)")
    func failedLoadIsRetried() async {
        let harness = Harness(source: "es", target: "en", probe: cachedAll)
        harness.log.failing.withLock { $0 = [.whisper] }
        let preloader = harness.preloader()
        await preloader.preload()
        #expect(preloader.loaded.isEmpty)
        harness.log.failing.withLock { $0 = [] }
        await preloader.preload()
        #expect(harness.log.entries == ["load whisper", "load whisper"])
        #expect(preloader.loaded == [.whisper])
    }

    @Test("a preload skipped during a call runs when the session-end trigger fires")
    func runsAfterSession() async {
        let harness = Harness(source: "es", target: "en", probe: cachedAll)
        var inSession = true
        var checks = 0
        let preloader = harness.preloader(sessionActive: { checks += 1; return inSession })
        let ended = PassthroughSubject<Void, Never>()
        preloader.start(triggers: [ended.eraseToAnyPublisher()])
        #expect(await waitUntil { checks >= 1 })
        #expect(harness.log.entries.isEmpty)
        inSession = false
        ended.send()
        #expect(await waitUntil { preloader.loaded == [.whisper] })
    }

    @Test("every trigger re-runs the preloader, debounced (REQ-ST-61)")
    func triggersRerun() async {
        let harness = Harness(source: "es", target: "en", probe: cachedAll)
        let preloader = harness.preloader()
        let trigger = PassthroughSubject<Void, Never>()
        preloader.start(triggers: [trigger.eraseToAnyPublisher()])
        #expect(await waitUntil { preloader.loaded == [.whisper] })
        harness.stt.pairChoice = { PairModelChoice(stt: .appleSpeech) }
        trigger.send()
        trigger.send()
        #expect(await waitUntil { preloader.loaded.isEmpty })
        #expect(harness.log.entries.filter { $0 == "unload whisper" }.count == 1)
    }
```

- [ ] **Step 2: Run, expect failure** — `just test-only ModelPreloaderTests` → "cannot convert value of type '() -> ()' to … '-> Bool'" / "extra argument 'triggers'".

- [ ] **Step 3: Implement.**
  - **`preload()`:**
    - unloads each model `loaded` holds that `wantedModels()` does not, removing it from `loaded`;
    - for each wanted model not yet loaded, `let didLoad = await loaders.load(model)` and `if didLoad { loaded.insert(model) }`. A `where await` does not compile, and a lone `if` trips `for_where`.
  - **`start(triggers:)`:**
    - merges the pair publisher (mapped to `()`) with `triggers` (`Publishers.MergeMany`);
    - debounces 300 ms on `DispatchQueue.main`;
    - sinks into the existing serial `schedule()`.
  - **`UIServices`:** `modelPreloader.start(triggers: models.preloadTriggers(tts: tts) + [sessionEnded])`, outside the test host. `sessionEnded` is `coordinator.$isOutgoingActive.removeDuplicates().filter { !$0 }.map { _ in () }.eraseToAnyPublisher()` (P11).
  - Update the doc comments (REQ-ST-61).

- [ ] **Step 4: Run** — `just test-only ModelPreloaderTests` 3 times; `just lint`.

- [ ] **Step 5: Commit** — `fix(models): preloader retries failed loads and follows choices, downloads and sessions (UI-B4, REQ-ST-61)`.

---

### Task 8: `PairModelsModel` — the sheet's staged choices, rows, consent and downloads (sonnet)

**Files:**
- Create: `TranslateCall/Features/Models/PairModelsModel.swift`
- Test: `TranslateCallTests/PairModelsModelTests.swift`

**Interfaces:**
- Consumes: Task 1 (`PairKey`, `PairModelChoices`), Task 2 (`metrics`, `isUnavailable`), Task 3 (`CloudPolicy`), Task 4 (`serves`, `allOnDisk`), Task 6 (`ModelDownloads`).
- Produces:
  - `nonisolated enum PairEngine: Hashable, Sendable { stt(STTEngine), tts(TTSEngine) }`, with `isVoice` and `downloadable`;
  - `nonisolated enum Recommendation: Equatable, Sendable { none, both, only(language: String) }`;
  - `nonisolated struct EngineRowState: Identifiable, Equatable, Sendable`, with `engine`, `name`, `recommendation`, `isCloud`, `tested`, `latency: String?`, `availability: .selectable | .partial(language:) | .notForPair | .unavailable`, `download: DownloadState?` and `isSelected`;
  - `@MainActor final class PairModelsModel: ObservableObject`:
    - `init(source:target:displayName:choices:cloud:downloads:catalog: = .bundled, voiceCloneOn:)`;
    - `@Published private(set) var staged`, `pendingConsent: TTSEngine?`;
    - `pair`, `title`, `downloadsBlocked`, `voiceCloneLine: String?`;
    - `speechRows`, `voiceRows`;
    - `pick(_:)`, `confirmConsent()`, `declineConsent()`, `reset()`, `commit()`;
    - `nonisolated static func name(_: PairEngine) -> String`.

- [ ] **Step 1: Write the failing tests** — `TranslateCallTests/PairModelsModelTests.swift`:

```swift
import Combine
import Foundation
import Synchronization
import Testing
@testable import TranslateCall

/// Downloads that finish when the test says so; the disk check follows.
private final class ControlledDownloads: Sendable {
    let onDisk = Mutex<Set<DownloadableModel>>([])
    private let pending = Mutex<[DownloadableModel: CheckedContinuation<Void, any Error>]>([:])
    var isWaiting: Bool { pending.withLock { !$0.isEmpty } }

    var probe: ModelCacheProbe {
        ModelCacheProbe(parakeet: { self.onDisk.withLock { $0.contains(.parakeet) } },
                        whisper: { self.onDisk.withLock { $0.contains(.whisper) } },
                        kokoro: { self.onDisk.withLock { $0.contains(.kokoro) } },
                        voiceClone: { self.onDisk.withLock { $0.contains(.voiceClone) } })
    }

    var managers: DownloadManagers {
        DownloadManagers(download: { model in
                             try await withCheckedThrowingContinuation { cont in self.pending.withLock { $0[model] = cont } }
                         },
                         cancel: { _ in })
    }

    func finish(_ model: DownloadableModel) {
        onDisk.withLock { _ = $0.insert(model) }
        pending.withLock { $0.removeValue(forKey: model) }?.resume()
    }
}

@MainActor
private struct SheetHarness {
    let defaults: UserDefaults
    let choices: PairModelChoices
    let cloud: CloudPolicy
    let fake = ControlledDownloads()
    let downloads: ModelDownloads

    init(onDisk: Set<DownloadableModel> = [.whisper, .parakeet, .kokoro], cloudAllowed: Bool = false,
         session: Bool = false) {
        let name = "PairModelsModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(cloudAllowed, forKey: CloudPolicy.allowedKey)
        choices = PairModelChoices(defaults: defaults)
        fake.onDisk.withLock { $0 = onDisk }
        var consent = false
        cloud = CloudPolicy(defaults: defaults, edgeConsentGiven: { consent },
                            grantEdgeConsent: { consent = true })
        downloads = ModelDownloads(probe: fake.probe, managers: fake.managers, isSessionActive: { session })
    }

    func model(_ source: String, _ target: String, catalog: ModelCatalog = .builtIn,
               voiceCloneOn: Bool = false) -> PairModelsModel {
        let names = ["es": "Español", "de": "Deutsch", "en": "English"]
        return PairModelsModel(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target),
                               displayName: { names[$0.minimalIdentifier] ?? $0.minimalIdentifier },
                               choices: choices, cloud: cloud, downloads: downloads, catalog: catalog,
                               voiceCloneOn: voiceCloneOn)
    }
}

private func row(_ rows: [EngineRowState], _ engine: PairEngine) throws -> EngineRowState {
    try #require(rows.first { $0.engine == engine })
}

@Suite("PairModelsModel — the Advanced… sheet (M9 UI settings REQ-ST-10…18)") @MainActor
struct PairModelsModelTests {

    @Test("ES ↔ DE: Whisper recommended and selected; Parakeet not for this pair; no Edge with cloud off")
    func spanishGerman() throws {
        let sheet = SheetHarness().model("es", "de")
        #expect(sheet.title == "Models for Español ↔ Deutsch")
        let whisper = try row(sheet.speechRows, .stt(.whisper))
        #expect(whisper.recommendation == .both && whisper.isSelected && whisper.download == .ready)
        #expect(try row(sheet.speechRows, .stt(.parakeet)).availability == .notForPair)
        #expect(try row(sheet.speechRows, .stt(.appleSpeech)).download == nil)
        #expect(try row(sheet.voiceRows, .tts(.avSpeech)).recommendation == .both)
        #expect(try row(sheet.voiceRows, .tts(.kokoro)).availability == .notForPair)
        #expect(!sheet.voiceRows.contains { $0.engine == .tts(.edgeTTS) })
        #expect(!sheet.speechRows.contains { $0.tested || $0.latency != nil }, "no benchmark data yet (S-2)")
    }

    @Test("EN ↔ ES: Parakeet recommended for English only, Whisper for Español; Kokoro partial")
    func englishSpanish() throws {
        let sheet = SheetHarness().model("en", "es")
        #expect(try row(sheet.speechRows, .stt(.parakeet)).recommendation == .only(language: "English"))
        #expect(try row(sheet.speechRows, .stt(.parakeet)).availability == .partial(language: "English"))
        #expect(try row(sheet.speechRows, .stt(.whisper)).recommendation == .only(language: "Español"))
        #expect(try row(sheet.voiceRows, .tts(.kokoro)).availability == .partial(language: "English"))
    }

    @Test("Done stores the staged choice; Cancel (no commit) stores nothing; Reset clears it")
    func stageCommitReset() {
        let harness = SheetHarness()
        let sheet = harness.model("es", "de")
        sheet.pick(.stt(.appleSpeech))
        #expect(sheet.staged.stt == .appleSpeech)
        #expect(harness.choices.all.isEmpty, "staged only")
        sheet.commit()
        #expect(harness.choices.choice(for: PairKey("de", "es")).stt == .appleSpeech)

        let again = harness.model("de", "es")
        #expect(again.staged.stt == .appleSpeech)
        again.reset()
        again.commit()
        #expect(harness.choices.all.isEmpty)
    }

    @Test("picking the row recommended for both languages stores nothing (stays Recommended)")
    func pickingRecommendedStoresNothing() {
        let harness = SheetHarness()
        let sheet = harness.model("es", "de")
        sheet.pick(.stt(.appleSpeech))
        sheet.pick(.stt(.whisper))
        #expect(sheet.staged.isEmpty)
    }

    @Test("a model not on disk downloads in its row and is selected when it finishes (REQ-ST-14)")
    func pickDownloadsThenSelects() async throws {
        let harness = SheetHarness(onDisk: [])
        let sheet = harness.model("en", "es")
        #expect(try row(sheet.speechRows, .stt(.parakeet)).download == .notOnDisk)
        sheet.pick(.stt(.parakeet))
        #expect(try row(sheet.speechRows, .stt(.parakeet)).download == .downloading(progress: nil))
        #expect(sheet.staged.stt == nil)
        #expect(await waitUntil { harness.fake.isWaiting })
        harness.fake.finish(.parakeet)
        #expect(await waitUntil { sheet.staged.stt == .parakeet })
    }

    @Test("during a call a model not on disk cannot be picked (S-7)")
    func noDownloadDuringCall() throws {
        let harness = SheetHarness(onDisk: [], session: true)
        let sheet = harness.model("en", "es")
        #expect(sheet.downloadsBlocked)
        sheet.pick(.stt(.parakeet))
        #expect(try row(sheet.speechRows, .stt(.parakeet)).download == .notOnDisk)
        sheet.pick(.stt(.appleSpeech))
        #expect(sheet.staged.stt == .appleSpeech, "models already on this Mac can still be picked")
    }

    @Test("Edge: shown with cloud on; marked unavailable it can't be picked (S-3)")
    func edgeUnavailable() throws {
        let sheet = SheetHarness(cloudAllowed: true).model("es", "de")
        let edge = try row(sheet.voiceRows, .tts(.edgeTTS))
        #expect(edge.isCloud && edge.availability == .unavailable)
        sheet.pick(.tts(.edgeTTS))
        #expect(sheet.pendingConsent == nil && sheet.staged.voice == nil)
    }

    @Test("Edge available: the first pick asks for consent; Allow stages it, Not now keeps the previous choice")
    func edgeConsent() {
        let available = ModelCatalog(version: 2, stt: ModelCatalog.builtIn.stt,
                                     ttsOutgoing: ModelCatalog.builtIn.ttsOutgoing,
                                     ttsIncoming: ModelCatalog.builtIn.ttsIncoming)
        let harness = SheetHarness(cloudAllowed: true)
        let sheet = harness.model("es", "de", catalog: available)
        sheet.pick(.tts(.edgeTTS))
        #expect(sheet.pendingConsent == .edgeTTS)
        sheet.declineConsent()
        #expect(sheet.pendingConsent == nil && sheet.staged.voice == nil)
        sheet.pick(.tts(.edgeTTS))
        sheet.confirmConsent()
        #expect(harness.cloud.hasConsent(.edgeTTS))
        #expect(sheet.staged.voice == .edgeTTS)
    }

    @Test("the voice-clone line shows only with \"Use my voice\" on and their language supported (REQ-ST-18)")
    func voiceCloneLine() {
        let harness = SheetHarness()
        #expect(harness.model("es", "de").voiceCloneLine == nil)
        #expect(harness.model("es", "de", voiceCloneOn: true).voiceCloneLine
                == "Your voice is used for Deutsch while “Use my voice” is on.")
        #expect(harness.model("es", "th", voiceCloneOn: true).voiceCloneLine == nil)
    }

    @Test("benchmark data shows as tested and latency when the catalog has it (S-2)")
    func metricsShown() throws {
        let catalog = ModelCatalog(version: 2, stt: ModelCatalog.builtIn.stt,
                                   ttsOutgoing: ModelCatalog.builtIn.ttsOutgoing,
                                   ttsIncoming: ModelCatalog.builtIn.ttsIncoming,
                                   pairs: ["de|es": ["whisper": EngineMetrics(tested: true, latencyMs: 400)]])
        let whisper = try row(SheetHarness().model("es", "de", catalog: catalog).speechRows, .stt(.whisper))
        #expect(whisper.tested && whisper.latency == "~0.4 s")
    }
}
```

- [ ] **Step 2: Run, expect failure** — `just test-only PairModelsModelTests` → "cannot find 'PairModelsModel' in scope".

- [ ] **Step 3: Implement.** The decisions the tests don't fully fix:
  - **Sides.** Speech recognition hears my language outgoing and theirs incoming; the voice speaks theirs outgoing and mine incoming. Use a private `struct Side { locale, direction, name }`: a 3-tuple trips `large_tuple`.
  - **`availability`:**
    - `.unavailable` when the catalog marks the TTS engine;
    - `.notForPair` when `serves` holds for neither side;
    - `.partial(language:)` when it holds for exactly one side (and the two names differ);
    - else `.selectable`.
  - **`recommendation`:** compare each side's `ModelChoice.stt/tts(…, catalog:, availability: .allOnDisk)` with the engine:
    - all sides match → `.both`;
    - one side matches → `.only(language:)`;
    - none → `.none`.
  - **`isSelected`:** the staged engine, or, when the stage has none, `recommendation != .none`.
  - **`pick`:**
    - ignore `.notForPair` / `.unavailable`;
    - not on disk: if blocked, do nothing; else remember `pendingPick` and `downloads.start`;
    - a cloud engine without consent → `pendingConsent`;
    - else stage it. Staging the `.both` row stores nil (P6).
  - **Change forwarding:** forward `downloads.objectWillChange` and `cloud.objectWillChange` to `objectWillChange`. On `downloads.didFinish` for the pending pick's model, stage it (P9).
  - **Copy, through `String(localized:)`:**
    - title "Models for <A> ↔ <B>";
    - the voice-clone line "Your voice is used for <B> while “Use my voice” is on.";
    - names: "Whisper", "Apple Speech", "Parakeet", "Apple voices", "Kokoro", "Microsoft Edge voices" (and "My voice" for completeness).
  - Rows: speech `[.whisper, .appleSpeech, .parakeet]`; voice `[.avSpeech, .kokoro]` plus `.edgeTTS` while `cloud.allowed` (P14).

- [ ] **Step 4: Run** — `just test-only PairModelsModelTests` (3 times); `just lint`.

- [ ] **Step 5: Commit** — `feat(models): the per-pair models sheet model (REQ-ST-10…18)`.

---

### Task 9: The "Advanced…" sheet — views, and the main window wiring (sonnet)

**Files:**
- Create: `TranslateCall/Features/Models/EngineRow.swift`, `DownloadStateView.swift`, `PairModelsSheet.swift`
- Modify: `TranslateCall/Features/Main/MainSetupView.swift` (present the sheet; `openModels`)

**Interfaces:**
- Consumes: Task 8 (`PairModelsModel`, `EngineRowState`), Task 6 (`ModelDownloads`, `DownloadableModel.approximateSize`), Task 5 (`ModelServices` env objects).
- Produces:
  - `PairModelsSheet(model: PairModelsModel, onClose: () -> Void)` (it owns nothing else; the caller creates the model);
  - `EngineRow(row:, blocked: Bool, onPick:, onCancel:, onRetry:)`;
  - `DownloadStateView(state:size:blocked:onDownload:onCancel:onRetry:)`;
  - `PairModelsSheet.makeModel(source:target:languages:services:tts:)`, a static helper Task 14 reuses.

- [ ] **Step 1: Screenshot the frames** — the pencil MCP, `TakeScreenshot(["yReTP", "XpYEw"])`. Note:
  - the 460 pt width;
  - the section header icons;
  - the chip line (Recommended in accent, On-device green, Cloud orange, Tested grey);
  - the note line under a row;
  - the footer: "Reset to recommended" as a link on the left, Cancel and Done (the default) on the right.

- [ ] **Step 2: Build the views.** Copy and structure (S-6 overrides the prototype's voice rows):
  - **Header:** the title (`model.title`), plus the line "Recommended models are tested for this pair and run on this Mac. You can choose another one for each step.".
  - **Sections:**
    - "Speech recognition";
    - "Translation": one non-selectable row, "Apple Translation", with "Recommended" and "On-device" chips;
    - "Voice when “Use my voice” is off", with `voiceCloneLine` under the section header when non-nil.
  - **Chip line:** "Recommended" (or "Recommended for <language>"), "On-device"/"Cloud", "Tested <A> · <B>" and the latency, the last two only when present.
  - **Notes:**
    - `.partial` → "Used for <language> only.";
    - `.notForPair` → "Not available for this pair.";
    - `.unavailable` → "Temporarily unavailable.";
    - Edge without consent → "The translated text is sent to Microsoft to create the voice. You'll be asked to confirm.".
  - **Trailing `DownloadStateView`:**
    - `.notOnDisk` → "Download · ≈<size>" button (disabled with "Available after the call" when blocked);
    - `.downloading` → an indeterminate `ProgressView` + "Cancel";
    - `.failed` → "Download failed" + "Try again";
    - `.ready` → nothing.

    There is no Cancel for the voice clone, but it never appears in the sheet.
  - **Consent:** `.confirmationDialog` on `model.pendingConsent`, with "Allow" → `confirmConsent()` and "Not now" → `declineConsent()`, and the message above.
  - **Footer:** "Reset to recommended" → `reset()`, "Cancel" → `onClose()`, "Done" → `commit()` then `onClose()`.
  - **Layout:** a disabled row is dimmed (`.secondary`) with its radio disabled. The sheet scrolls only when taller than the screen. The text-fitting rules apply. Call `downloads.refresh()` in `.onAppear`.

- [ ] **Step 3: Wire the main window.** `MainSetupView`:
  - holds `@State private var modelsSheet: PairModelsModel?`;
  - sets `actions.openModels = { modelsSheet = PairModelsSheet.makeModel(…current pair…) }`;
  - presents it with `.sheet(item:)`: `PairModelsModel` is a class, so give it `Identifiable` with `id = pair.storageKey`, or wrap it;
  - passes `voiceCloneOn: ttsSelector.voiceCloningEnabled`;
  - injects the env objects `PairModelChoices`, `CloudPolicy` and `ModelDownloads` from Task 5/6.

- [ ] **Step 4: Previews and comparison.**
  - **Previews** (light and dark), all on fixture stores (`UserDefaults(suiteName: "preview.models")`, fake `DownloadManagers`):
    - ES ↔ DE recommended;
    - EN ↔ ES with Parakeet not on disk;
    - downloading;
    - failed;
    - blocked during a call;
    - cloud on with Edge unavailable;
    - "Use my voice" on;
    - a catalog with metrics.
  - **Compare** the render with `yReTP` / `XpYEw` (NSHostingView offscreen, a temporary uncommitted test).
  - Then `just build`, `just lint`, `just test-only MainSetupModelTests PairModelsModelTests`.

- [ ] **Step 5: Commit** — `feat(ui): the per-pair models sheet behind "Advanced…" (REQ-ST-10…18, UI-L2)`.

---

### Task 10: Settings tabs and the UI-B9 items (pi)

**Files:**
- Modify: `TranslateCall/Features/Settings/SettingsOpener.swift`, `SettingsView.swift`, `GeneralSettingsView.swift`
- Test: `TranslateCallTests/SettingsOpenerTests.swift`, `TranslateCallTests/GeneralSettingsTests.swift`

**Interfaces:**
- Produces:
  - `enum SettingsTab: String { general, voices, advanced }`, with `init?(rawValue:)` mapping `"advancedLegacy"` → `.advanced` (P21);
  - `SettingsView` binds `@AppStorage(SettingsOpener.tabKey) private var tab = SettingsTab.general` and tags with the enum. Its tabs here: General only; Voices comes in Task 12 and Advanced in Task 14;
  - `OpenAtLoginModel.refresh()`;
  - `DownloadedLanguages.list(…, isInstalled: @escaping @Sendable …)`, concurrent (P18).

- [ ] **Step 1: Write the failing tests.**
  - In `SettingsOpenerTests`, `opensOnTab` uses `.advanced` and expects `"advanced"`. Add:

```swift
    @Test("three tabs; the feature-1 legacy value opens Advanced (REQ-ST-51)")
    func tabs() {
        #expect(SettingsTab.allCases == [.general, .voices, .advanced])
        #expect(SettingsTab(rawValue: "advancedLegacy") == .advanced)
        #expect(SettingsTab(rawValue: "nope") == nil)
    }
```

  - Append to `GeneralSettingsTests.swift` (add `import Synchronization`):

```swift
/// Counts calls in flight and remembers the highest count.
private final class InFlightGauge: Sendable {
    private let state = Mutex<(now: Int, peak: Int)>((0, 0))
    var peak: Int { state.withLock { $0.peak } }
    func enter() { state.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) } }
    func leave() { state.withLock { $0.now -= 1 } }
}

@Suite("General settings — UI-B9 (M9 UI settings REQ-ST-60)") @MainActor
struct GeneralSettingsBacklogTests {

    @Test("Open at login re-reads the system status on refresh")
    func openAtLoginRefresh() {
        var enabled = false
        let login = OpenAtLoginModel(isEnabled: { enabled }, register: {}, unregister: {})
        enabled = true
        #expect(!login.isEnabled)
        login.refresh()
        #expect(login.isEnabled)
    }

    @Test("the per-language checks run concurrently")
    func checksRunConcurrently() async {
        let gauge = InFlightGauge()
        let list = await DownloadedLanguages.list(
            source: Locale.Language(identifier: "es"),
            supported: ["de", "en", "fr", "it"].map(Locale.Language.init(identifier:)),
            displayName: { $0.minimalIdentifier },
            isInstalled: { _, _ in
                gauge.enter()
                try? await Task.sleep(for: .milliseconds(50))
                gauge.leave()
                return true
            })
        #expect(list == ["de", "en", "es", "fr", "it"])
        #expect(gauge.peak > 1)
    }
}
```

- [ ] **Step 2: Run, expect failure** — `just test-only SettingsOpenerTests GeneralSettingsBacklogTests` → "type 'SettingsTab' has no member 'advanced'".

- [ ] **Step 3: Implement.**
  - **`SettingsTab`:**

```swift
/// The Settings tabs (M9 UI settings REQ-ST-51).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case voices
    case advanced
    var id: String { rawValue }

    /// The feature-1 value `"advancedLegacy"` still stored on upgraded Macs opens Advanced.
    init?(rawValue: String) {
        switch rawValue {
        case "general": self = .general
        case "voices": self = .voices
        case "advanced", "advancedLegacy": self = .advanced
        default: return nil
        }
    }
}
```

  - **`OpenAtLoginModel.refresh()`:** `let current = readEnabled(); if current != isEnabled { isEnabled = current }`.
  - **`GeneralSettingsView`:** calls `login.refresh()` in `.onAppear` and on `NSApplication.didBecomeActiveNotification`.
  - **`DownloadedLanguages.list`:**

```swift
/// The languages whose models are installed for `source` (P17): there is no list API, so each supported
/// language is asked through `isInstalled`, all at once (UI-B9). Pure so the tests inject both closures.
nonisolated enum DownloadedLanguages {
    static func list(
        source: Locale.Language,
        supported: [Locale.Language],
        displayName: (Locale.Language) -> String,
        isInstalled: @escaping @Sendable (Locale.Language, Locale.Language) async -> Bool
    ) async -> [String] {
        let others = supported.filter { $0.minimalIdentifier != source.minimalIdentifier }
        let installed = await withTaskGroup(of: Locale.Language?.self) { group in
            for language in others {
                group.addTask { await isInstalled(source, language) ? language : nil }
            }
            return await group.reduce(into: [Locale.Language]()) { if let language = $1 { $0.append(language) } }
        }
        let names = Set([displayName(source)] + installed.map(displayName))
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
```

  - **Microphone picker:** before the `ForEach`, add `if viewModel.selectedInput == nil { Text("System default").tag(AudioDevice?.none) }` (P17).

- [ ] **Step 4: Run** — `just test-only SettingsOpenerTests GeneralSettingsTests GeneralSettingsBacklogTests`; `just build`; `just lint`.

- [ ] **Step 5: Commit** — `fix(settings): typed tabs with the legacy value mapped; UI-B9 (REQ-ST-51, 60)`.

---

### Task 11: Standard voices — the stored pick, the AVSpeech lookup, picker options (pi)

**Files:**
- Create: `TranslateCall/Core/TTS/StandardVoices.swift`
- Modify: `TranslateCall/Core/TTS/AVSpeechUtteranceSynthesizer.swift`
- Test: `TranslateCallTests/StandardVoicesTests.swift` (the existing `AVSpeechUtteranceSynthesizerTests` must stay green)

**Interfaces:**
- Produces:
  - `SystemVoicePreference`: `key(for:)` = `"tlk.tts.systemVoice.<code>"`, `identifier(for: Locale, defaults:) -> String?` and `set(_:for:defaults:)`;
  - `SystemVoice` (with `installed`), `VoiceOption`;
  - `StandardVoices`: `automatic`, `appleOptions(for:installed:)`, `label(_:)`, `kokoroOptions` and `edgeVoiceName(for:)`;
  - `AVSpeechUtteranceSynthesizer`:
    - `init(config:preferredVoice: @escaping @Sendable (Locale) -> String? = { SystemVoicePreference.identifier(for: $0) })`;
    - `static func voice(for: Locale, preferred: String?) -> AVSpeechSynthesisVoice?`, used by `synthesize`.

- [ ] **Step 1: Write the failing tests** — `TranslateCallTests/StandardVoicesTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

@Suite("Standard voices (M9 UI settings REQ-ST-22)") @MainActor
struct StandardVoicesTests {

    private let installed = [
        SystemVoice(identifier: "de.anna", name: "Anna", language: "de-DE", quality: 1),
        SystemVoice(identifier: "de.helena", name: "Helena", language: "de-DE", quality: 2),
        SystemVoice(identifier: "de.petra", name: "Petra", language: "de-AT", quality: 3),
        SystemVoice(identifier: "es.monica", name: "Mónica", language: "es-ES", quality: 1)
    ]

    @Test("Apple options: Automatic first, then the language's voices, best quality first")
    func appleOptions() {
        let options = StandardVoices.appleOptions(for: Locale(identifier: "de-DE"), installed: installed)
        #expect(options.map(\.id) == ["", "de.petra", "de.helena", "de.anna"])
        #expect(options.map(\.name) == ["Automatic", "Petra (Premium) · Apple", "Helena (Enhanced) · Apple",
                                        "Anna · Apple"])
    }

    @Test("the pick is stored per language; empty means Automatic")
    func preferenceRoundTrip() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let german = Locale(identifier: "de-DE")
        #expect(SystemVoicePreference.identifier(for: german, defaults: defaults) == nil)
        SystemVoicePreference.set("de.anna", for: "de", defaults: defaults)
        #expect(SystemVoicePreference.identifier(for: german, defaults: defaults) == "de.anna")
        #expect(SystemVoicePreference.identifier(for: Locale(identifier: "es-ES"), defaults: defaults) == nil)
        SystemVoicePreference.set(nil, for: "de", defaults: defaults)
        #expect(SystemVoicePreference.identifier(for: german, defaults: defaults) == nil)
    }

    @Test("a picked voice that is not installed falls back to the best voice")
    func missingVoiceFallsBack() {
        let locale = Locale(identifier: "en-US")
        #expect(AVSpeechUtteranceSynthesizer.voice(for: locale, preferred: "not.a.voice")?.identifier
                == AVSpeechUtteranceSynthesizer.bestVoice(for: locale)?.identifier)
    }

    @Test("Kokoro keeps the legacy list; Edge shows its fixed voice")
    func kokoroAndEdge() {
        #expect(StandardVoices.kokoroOptions.first == VoiceOption(id: "", name: "Default (af_heart)"))
        #expect(StandardVoices.kokoroOptions.count == 5)
        #expect(StandardVoices.edgeVoiceName(for: Locale(identifier: "uk-UA")) != nil)
        #expect(StandardVoices.edgeVoiceName(for: Locale(identifier: "xx")) == nil)
    }
}
```

- [ ] **Step 2: Run, expect failure** — `just test-only StandardVoicesTests` → "cannot find 'SystemVoice' in scope".

- [ ] **Step 3: Implement** — full code of the new file:

```swift
import AVFoundation
import Foundation

// MARK: - SystemVoicePreference

/// The Apple voice picked per language in Settings › Voices (REQ-ST-22); "" or absent = Automatic.
nonisolated enum SystemVoicePreference {
    static func key(for languageCode: String) -> String { "tlk.tts.systemVoice.\(languageCode)" }

    static func identifier(for locale: Locale, defaults: UserDefaults = .standard) -> String? {
        guard let code = locale.language.languageCode?.identifier,
              let id = defaults.string(forKey: key(for: code)), !id.isEmpty else { return nil }
        return id
    }

    static func set(_ identifier: String?, for languageCode: String, defaults: UserDefaults = .standard) {
        defaults.set(identifier ?? "", forKey: key(for: languageCode))
    }
}

// MARK: - StandardVoices

/// An installed system voice, as plain values so the picker logic is testable.
nonisolated struct SystemVoice: Equatable, Sendable {
    let identifier: String
    let name: String
    /// BCP-47, e.g. `de-DE`.
    let language: String
    /// 1 default, 2 enhanced, 3 premium (`AVSpeechSynthesisVoiceQuality` raw values).
    let quality: Int

    static var installed: [SystemVoice] {
        AVSpeechSynthesisVoice.speechVoices().map {
            SystemVoice(identifier: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue)
        }
    }
}

/// One entry of a "Standard voice for <language>" picker.
nonisolated struct VoiceOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// The options of the standard voice picker per engine (REQ-ST-22).
nonisolated enum StandardVoices {
    static let automatic = VoiceOption(id: "", name: String(localized: "Automatic"))

    /// Automatic, then the installed voices of the language, best quality first, then by name.
    static func appleOptions(for locale: Locale, installed: [SystemVoice]) -> [VoiceOption] {
        let code = locale.language.languageCode?.identifier ?? ""
        let voices = installed
            .filter { ($0.language.components(separatedBy: "-").first ?? "") == code }
            .sorted { ($0.quality, $1.name) > ($1.quality, $0.name) }
        return [automatic] + voices.map { VoiceOption(id: $0.identifier, name: label($0)) }
    }

    /// "Anna · Apple", "Anna (Enhanced) · Apple", "Anna (Premium) · Apple".
    static func label(_ voice: SystemVoice) -> String {
        switch voice.quality {
        case 3: "\(voice.name) (Premium) · Apple"
        case 2: "\(voice.name) (Enhanced) · Apple"
        default: "\(voice.name) · Apple"
        }
    }

    /// Kokoro's voices (the legacy picker's list; English only).
    static let kokoroOptions: [VoiceOption] = [
        VoiceOption(id: "", name: "Default (af_heart)"), VoiceOption(id: "af_heart", name: "af_heart"),
        VoiceOption(id: "af_bella", name: "af_bella"), VoiceOption(id: "am_adam", name: "am_adam"),
        VoiceOption(id: "am_michael", name: "am_michael")
    ]

    /// Edge's fixed voice for the language, shown read-only.
    static func edgeVoiceName(for locale: Locale) -> String? {
        EdgeTTSVoiceCatalog.defaultVoice(for: locale)?.friendlyName
    }
}
```

  In `AVSpeechUtteranceSynthesizer`, store `preferredVoice` and add:

```swift
    /// The picked voice when it is still installed and speaks the locale's language, else `bestVoice`.
    static func voice(for locale: Locale, preferred: String?) -> AVSpeechSynthesisVoice? {
        let lang = String(locale.identifier.replacingOccurrences(of: "_", with: "-").prefix(2))
        if let preferred, let voice = AVSpeechSynthesisVoice(identifier: preferred), voice.language.hasPrefix(lang) {
            return voice
        }
        return bestVoice(for: locale)
    }
```

  `synthesize` uses `Self.voice(for: locale, preferred: preferredVoice(locale))` instead of `bestVoice`.

- [ ] **Step 4: Run** — `just test-only StandardVoicesTests AVSpeechUtteranceSynthesizerTests`; `just lint`.

- [ ] **Step 5: Commit** — `feat(tts): a standard voice per language (REQ-ST-22)`.

---

### Task 12: Settings › Voices (sonnet)

**Files:**
- Create: `TranslateCall/Features/Settings/VoicesSettingsView.swift`, `VoiceProfileRow.swift`, `StandardVoicePicker.swift`
- Modify: `TranslateCall/Features/Settings/SettingsView.swift` (the Voices tab, `Label("Voices", systemImage: "waveform")`, tag `.voices`)
- Delete: `TranslateCall/Features/Settings/Legacy/KokoroVoicePicker.swift`

**Interfaces:**
- Consumes:
  - Task 11 (`StandardVoices`, `SystemVoicePreference`);
  - Task 5 (`TTSEngineSelector.resolvedEngine`);
  - `VoiceProfileManager` (`profiles`, `activeProfileId`, `setActiveProfile`, `rename`, `delete`);
  - `VoicePreviewService(profileStore:)`'s `playRecording(profileId:)`.
- Produces:
  - `VoicesSettingsView` (environment objects only);
  - `VoicesSettingsContent` (fixture-friendly, as `GeneralSettingsContent`);
  - `VoiceProfileRow(profile:isActive:onUse:onPlay:onRename:onDelete:)`;
  - `StandardVoicePicker(language: Locale.Language)`.

- [ ] **Step 1: Screenshot the frames** — `TakeScreenshot(["o3A5RO", "G3LK2"])`.

- [ ] **Step 2: Build the view** (REQ-ST-20…22) as a grouped `Form`:
  - **"Your voices" section,** one `VoiceProfileRow` per profile:
    - name;
    - subtitle "recorded <medium date> · <n> s" (`createdAt`, `durationSeconds` rounded);
    - "In use" (accent chip) on the active profile, a "Use" button on the others;
    - a play button (`playRecording`);
    - a "…" `Menu` with "Rename…" (an alert with a text field) and "Delete…" (a confirmation dialog). Deleting the active profile clears it, as `VoiceProfileManager.delete` does today.
  - **The last row** is "+ Record a new voice…", which presents today's `VoiceProfileListView` sheet (the `MainSetupView.voiceProfilesSheet` pattern).
  - **The section footer:** "The voice used when “Use my voice” is on. Voices are stored only on this Mac.".
  - **"Without my voice" section,** one `StandardVoicePicker` per language of the current pair: their language first, then mine, as in the prototype.
    - Its label is "Standard voice for <language>". The first row also gets the subtitle "Used when “Use my voice” is off."
    - The engine in effect comes from `ttsSelector.resolvedEngine`: their language → `.outgoing`, mine → `.incoming`. With the voice clone on, the outgoing side resolves to `.voiceClone`; then use the engine `ModelChoice.tts` gives with `voiceCloneReady: false`. Add a small helper on `TTSEngineSelector`, `standardEngine(for:direction:)`, with a test.
    - **Apple** → a `Picker` over `StandardVoices.appleOptions(for:installed: SystemVoice.installed)`, bound to `SystemVoicePreference`.
    - **Kokoro** → over `StandardVoices.kokoroOptions`, bound to `@AppStorage(KokoroConfiguration.voiceDefaultsKey)`.
    - **Edge** → a read-only `Text(StandardVoices.edgeVoiceName(for:) ?? "—")`.
  - **The preview service:** create it lazily in the view (`try? VoicePreviewService(profileStore: voiceProfileManager.profileStore)`), the `VoiceProfileDetailView` pattern.

- [ ] **Step 3: Write the test for `standardEngine`** in `TTSEngineSelectorTests`, then implement it. With the voice clone ready and Kokoro cached for ES ↔ EN:
  - `standardEngine(for: en, .outgoing)` is `.avSpeech`, because Kokoro is blocked while the clone is ready;
  - `standardEngine(for: es, .outgoing)` is `.avSpeech`;
  - with the clone off, `standardEngine(for: en, .outgoing)` is `.kokoro`.

  Run `just test-only TTSEngineSelectorTests`.

- [ ] **Step 4: Previews and comparison.**
  - **Previews** (light and dark): two profiles with one in use; none; a Kokoro language; an Edge language.
  - **Compare** with `o3A5RO` / `G3LK2`.
  - Then `just build`, `just lint`.

- [ ] **Step 5: Commit** — `feat(settings): the Voices tab (REQ-ST-20…22)`.

---

### Task 13: Advanced-tab logic — voice detector, log export, pairs list (pi)

**Files:**
- Create: `TranslateCall/Core/VAD/VADPreference.swift`, `TranslateCall/Core/Diagnostics/LogExporter.swift`, `TranslateCall/Features/Settings/AdvancedPairs.swift`
- Modify: `TranslateCall/Core/VAD/VADProvider.swift`
- Test: `TranslateCallTests/AdvancedSettingsLogicTests.swift` (the existing `VADProviderTests` must stay green)

**Interfaces:**
- Consumes: Task 1 (`PairKey`, `PairModelChoice`), Task 8 (`PairModelsModel.name`).
- Produces:
  - `enum VADPreference` (main-actor, P15): `key = "tlk.vad.engine"`, `engine(in:) -> VADEngine` and `set(_:in:)`;
  - `VADProvider.init(loadSilero:preferred: @escaping () -> VADEngine = { VADPreference.engine() })`. `makeVAD` returns the energy VAD at once when `preferred() == .energy`;
  - `LogLine`, and `LogExporter`: `subsystem`, `entries() throws -> [LogLine]`, `text(_:timeZone:)` and `fileName(on:timeZone:)`;
  - `AdvancedPairs`: `priority`, `titleOrder`, `list(current:customized:)`, `ordered(_:currentSource:) -> (mine: String, theirs: String)` and `value(for:) -> String`.

- [ ] **Step 1: Write the failing tests** — `TranslateCallTests/AdvancedSettingsLogicTests.swift`:

```swift
import Foundation
import Testing
@testable import TranslateCall

@Suite("Settings › Advanced logic (M9 UI settings REQ-ST-30…35)") @MainActor
struct AdvancedSettingsLogicTests {

    @Test("pairs: the three priority pairs, then the current one, then customised ones, no duplicates")
    func pairsList() {
        let list = AdvancedPairs.list(current: PairKey("fr", "es"),
                                      customized: [PairKey("en", "es"), PairKey("uk", "en")])
        #expect(list == [PairKey("es", "de"), PairKey("es", "en"), PairKey("de", "en"), PairKey("es", "fr"),
                         PairKey("en", "uk")])
        #expect(AdvancedPairs.list(current: PairKey("de", "es"), customized: []).count == 3)
    }

    @Test("a pair's title names my language first, else Spanish, German, English, else alphabetical")
    func titleOrder() {
        #expect(AdvancedPairs.ordered(PairKey("de", "es"), currentSource: "de") == ("de", "es"))
        #expect(AdvancedPairs.ordered(PairKey("de", "es"), currentSource: "fr") == ("es", "de"))
        #expect(AdvancedPairs.ordered(PairKey("en", "de"), currentSource: "fr") == ("de", "en"))
        #expect(AdvancedPairs.ordered(PairKey("uk", "fr"), currentSource: "es") == ("fr", "uk"))
    }

    @Test("the row value: Recommended, or Custom · the chosen engine (speech recognition first)")
    func rowValue() {
        #expect(AdvancedPairs.value(for: PairModelChoice()) == "Recommended")
        #expect(AdvancedPairs.value(for: PairModelChoice(stt: .appleSpeech, voice: .kokoro)) == "Custom · Apple Speech")
        #expect(AdvancedPairs.value(for: PairModelChoice(voice: .avSpeech)) == "Custom · Apple voices")
    }

    @Test("the voice detector: Silero by default; Basic makes the next session use the energy VAD (REQ-ST-33)")
    func voiceDetector() async {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        #expect(VADPreference.engine(in: defaults) == .silero)
        VADPreference.set(.energy, in: defaults)
        #expect(VADPreference.engine(in: defaults) == .energy)
        let provider = VADProvider(loadSilero: { _ in MockVADService(engine: .silero) },
                                   preferred: { VADPreference.engine(in: defaults) })
        #expect(await provider.makeVAD(config: VADConfiguration()).engine == .energy)
        VADPreference.set(.silero, in: defaults)
        #expect(await provider.makeVAD(config: VADConfiguration()).engine == .silero)
    }

    @Test("exported logs: one line per entry with time and category; the file name carries the date")
    func logText() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_792_256_662.5)   // 2026-10-17 17:04:22.500 UTC
        let text = LogExporter.text([LogLine(date: date, category: "VADProvider", message: "Silero VAD model ready")],
                                    timeZone: utc)
        #expect(text == "2026-10-17 17:04:22.500 [VADProvider] Silero VAD model ready\n")
        #expect(LogExporter.text([]) == "")
        #expect(LogExporter.fileName(on: date, timeZone: utc) == "TranslateCall-logs-2026-10-17.txt")
    }
}
```

- [ ] **Step 2: Run, expect failure** — `just test-only AdvancedSettingsLogicTests` → "cannot find 'AdvancedPairs' in scope".

- [ ] **Step 3: Implement** — full code:

```swift
import Foundation

/// "Voice detector" in Settings › Advanced (REQ-ST-33): Silero (default) or Basic (energy).
enum VADPreference {
    static let key = "tlk.vad.engine"

    static func engine(in defaults: UserDefaults = .standard) -> VADEngine {
        defaults.string(forKey: key) == "energy" ? .energy : .silero
    }

    static func set(_ engine: VADEngine, in defaults: UserDefaults = .standard) {
        defaults.set(engine == .energy ? "energy" : "silero", forKey: key)
    }
}
```

```swift
import Foundation
import OSLog

/// One exported log line.
nonisolated struct LogLine: Equatable, Sendable {
    let date: Date
    let category: String
    let message: String
}

/// "Export logs…" (REQ-ST-35, S-8): the app's own entries since this launch, as text.
nonisolated enum LogExporter {
    static let subsystem = "com.spbarber.TranslateCall"

    /// This process's entries of the app's subsystem. `.currentProcessIdentifier` needs no privileges.
    static func entries() throws -> [LogLine] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        return try store.getEntries(matching: predicate).compactMap { entry in
            (entry as? OSLogEntryLog).map { LogLine(date: $0.date, category: $0.category, message: $0.composedMessage) }
        }
    }

    /// `2026-10-17 20:31:02.123 [Category] message`, one line per entry, local time.
    static func text(_ lines: [LogLine], timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return lines.map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.message)" }
            .joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// `TranslateCall-logs-2026-10-17.txt`.
    static func fileName(on date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "TranslateCall-logs-\(formatter.string(from: date)).txt"
    }
}
```

```swift
import Foundation

/// The "Models per language pair" list of Settings › Advanced (REQ-ST-30, 31).
nonisolated enum AdvancedPairs {
    /// ES ↔ DE, ES ↔ EN, DE ↔ EN, in the prototype's order.
    static let priority = [PairKey("es", "de"), PairKey("es", "en"), PairKey("de", "en")]
    /// Which language a pair's title names first when the current source is not in it.
    static let titleOrder = ["es", "de", "en"]

    /// The priority pairs, the current pair, then the customised pairs by key, without duplicates.
    static func list(current: PairKey, customized: [PairKey]) -> [PairKey] {
        var seen = Set<PairKey>()
        return (priority + [current] + customized.sorted { $0.storageKey < $1.storageKey })
            .filter { seen.insert($0).inserted }
    }

    /// The pair's two codes, "mine" first: the current source language when it is in the pair, else by
    /// `titleOrder`, else alphabetical. The sheet opens with this order.
    static func ordered(_ pair: PairKey, currentSource: String) -> (mine: String, theirs: String) {
        let codes = [pair.first, pair.second]
        if let mine = codes.first(where: { $0 == currentSource }) {
            return (mine, codes.first { $0 != mine } ?? mine)
        }
        let rank = { (code: String) in titleOrder.firstIndex(of: code) ?? titleOrder.count }
        let sorted = codes.sorted { (rank($0), $0) < (rank($1), $1) }
        return (sorted[0], sorted[1])
    }

    /// "Recommended", or "Custom · <engine>" naming the speech-recognition choice, else the voice.
    static func value(for choice: PairModelChoice) -> String {
        if let stt = choice.stt { return String(localized: "Custom · \(PairModelsModel.name(.stt(stt)))") }
        if let voice = choice.voice { return String(localized: "Custom · \(PairModelsModel.name(.tts(voice)))") }
        return String(localized: "Recommended")
    }
}
```

  `VADProvider` stores `preferred`. In `makeVAD`, right after `let config = config.validated()`, add `if preferred() == .energy { return energy(config) }`.

- [ ] **Step 4: Run** — `just test-only AdvancedSettingsLogicTests VADProviderTests`; `just lint`.

- [ ] **Step 5: Commit** — `feat(settings): voice detector setting, log export and the pairs list (REQ-ST-31, 33, 35)`.

---

### Task 14: Settings › Advanced (sonnet)

**Files:**
- Create: `TranslateCall/Features/Settings/AdvancedSettingsView.swift`, `PairRow.swift`
- Move (`git mv`): `Features/Settings/Legacy/{STTMetricsView,TTSMetricsView,TTSMonitorRow}.swift` → `Features/Settings/Diagnostics/`. Remove the empty `Legacy/`.
- Modify: `TranslateCall/Features/Settings/SettingsView.swift` (the Advanced tab, `Label("Advanced", systemImage: "slider.horizontal.3")`, tag `.advanced`; order General, Voices, Advanced)

**Interfaces:**
- Consumes:
  - Task 9 (`PairModelsSheet`, `PairModelsSheet.makeModel`);
  - Task 13 (`AdvancedPairs`, `VADPreference`, `LogExporter`);
  - Task 3 (`CloudPolicy`), Task 1 (`PairModelChoices`);
  - `SetupWizardView`.
- Produces: `AdvancedSettingsView` and a fixture-friendly `AdvancedSettingsContent`, plus `PairRow(title:value:isCustom:onOpen:)`.

- [ ] **Step 1: Screenshot the frames** — `TakeScreenshot(["PFRn8", "T2mCTh"])`.

- [ ] **Step 2: Build the view** (REQ-ST-30…36) as a grouped `Form` with four sections:
  1. **"Models per language pair":**
     - one `PairRow` per `AdvancedPairs.list(current:customized: Array(choices.all.keys))`;
     - the title is "<mine> ↔ <theirs>" by `AdvancedPairs.ordered` and `LanguagePairManager.displayName`;
     - the value is `AdvancedPairs.value(for:)`, orange (`Theme.Status.orange`) when custom;
     - a chevron; clicking presents `PairModelsSheet`, its model built with that order (P13);
     - the footer reads "Recommended models are tested for each pair. Change them only if something doesn't sound right."
  2. **"Cloud":** a `Toggle` "Allow cloud models" bound to `cloud.allowed`, with the subtitle "Off: everything runs on this Mac. On: cloud models appear in the model lists, and each one asks for your consent the first time."
  3. **"Speech detection":** a `Picker` "Voice detector", with "Silero (recommended)" / "Basic (energy)", bound through `VADPreference`.
  4. **"Diagnostics":**
     - `Toggle` "Show speech and voice metrics", with the subtitle "Timings for each sentence, for troubleshooting.", on `@AppStorage("ui.showMetrics")` (default off). When on, `STTMetricsView()`, `TTSMetricsView()` and `TTSMonitorRow()` show below it;
     - "Logs", with the subtitle "Logs since TranslateCall started." and the button "Export logs…". It runs `LogExporter.entries()`, then an `NSSavePanel` with `nameFieldStringValue = LogExporter.fileName(on: .now)`, then writes `LogExporter.text(_:)`. An error goes to an inline red caption;
     - "Setup", with the subtitle "Permissions, audio cable and call app microphone." and "Run setup again…", which presents `SetupWizardView` as a sheet.

- [ ] **Step 3: Previews and comparison.**
  - **Previews** (light and dark): all Recommended; one pair Custom; metrics on.
  - **Compare** with `PFRn8` / `T2mCTh`.
  - Then `just build`, `just lint`, `just test`.

- [ ] **Step 4: Commit** — `feat(settings): the Advanced tab (REQ-ST-30…36)`.

---

### Task 15: Docs, backlog and the full gate (sonnet)

**Files:** `specs/m9-product/backlog.md`, `docs/ARCHITECTURE.md` (the models section), `specs/m9-product/ui-settings/tasks.md` (tick the steps)

- [ ] **Step 1: Update the backlog.**
  - Close UI-L2 and UI-B9.
  - Narrow UI-B4 to the Qwen/Whisper part (unload during load; the corrupt Whisper cache).
  - Narrow UI-B5 to what is left after Tasks 5–7.
  - Add a row for A27's fix PR: "flip `engines.edgeTTS.unavailable`".
  - Add a row for real download progress (Whisper `downloadProgress` is never updated).
  - Add the sub-feature line `UI settings | m9-product/ui-settings/ | …`.

- [ ] **Step 2: Update `docs/ARCHITECTURE.md`.** Describe:
  - per-pair choices → `ModelChoice` → `resolvedEngine`;
  - `ModelServices`;
  - `ModelDownloads`;
  - the preloader triggers.

- [ ] **Step 3: Run the gate.** `just pr` runs build, lint, scan, the unit and integration tiers, then pushes and opens the PR.
  - A known flake, A28 (the integration host exiting) or A27 (Edge 403), may show up. Re-run once and report the outcome.
  - Never mark tests as known issues without asking.

- [ ] **Step 4: Commit** — `docs(m9): UI settings architecture and backlog`.

---

### Task 16: Manual checklist (user, before merge)

Design §10, items S1–S10:
- S1: "Advanced…" opens the ES ↔ DE sheet. Parakeet is disabled with its reason, and Edge does not show while the cloud is off.
- S2: Pick Apple Speech and press Done → "Models: Custom", and a call uses Apple Speech. Reset to recommended → "Models: Recommended".
- S3: Pick a model that is not on disk → the download runs in its row with progress and Cancel, and the model is selected when it finishes. Close the sheet mid-download and reopen it → still downloading.
- S4: Turn on "Allow cloud models" → Edge appears disabled with "Temporarily unavailable".
- S5: Voices: play, rename and delete a profile; "Use" switches the active one. Change the standard voice for Deutsch → the next call uses it.
- S6: Advanced: the pairs list shows Custom in orange, and the chevron opens the sheet for that pair. Set the voice detector to Basic → the next call works.
- S7: Show metrics → the metrics appear. "Export logs…" writes a file with this launch's entries.
- S8: ⌘, after upgrading from feature 1 with the legacy tab stored → Settings opens on Advanced.
- S9: Dark mode on every new screen, compared with the dark frames.
- S10: During a call, the sheet's download buttons are disabled with "Available after the call".

---

## Replay notes

Replayed on 2026-10-17 in a throwaway clone of `spec/m9-ui-settings` at 2f6029b (branch `replay/ui-settings`, deleted afterwards).

**Replayed (code and tests as in this plan):**
- the logic of Tasks 1–8, 10, 11 and 13;
- the main-window wiring of Tasks 5 and 6: `ModelServices`, `ModelsLabel`, `LanguageSection`, `VoiceSection`, the Help menu, the legacy removal.

**Checks run, all green:**
- `build-for-testing`;
- every new and affected suite;
- `ModelPreloaderTests`, `ModelDownloadsTests` and `PairModelsModelTests` repeated;
- the full unit tier (`just test`, 709 ✔ lines in the log, 0 failures);
- `just lint` (strict), `just scan`.

**Not replayed:**
- the views of Tasks 9, 12 and 14 (prose-specified; reviewers enforce previews and the pencil comparison);
- `TTSEngineSelector.standardEngine` (Task 12);
- Task 15.

**Fixed in the plan while replaying:**
- `ModelCatalog` / `EngineInfo` / `EngineMetrics` need explicit `CodingKeys` once `init(from:)` is custom on a `Decodable`-only type;
- `init(from:)` goes in extensions, to keep the memberwise init;
- `await` in a `for … where` clause does not compile, and a lone `if` trips `for_where`: bind the result first;
- `WhisperModelManager.ensureReady()` returns a non-`Sendable` `WhisperKit`: use `loadIfNeeded()`;
- `VADPreference` cannot be `nonisolated` (`VADEngine`'s `Equatable` is main-actor isolated);
- `PairModelsModel.name` must be `nonisolated static` (`AdvancedPairs.value` calls it);
- a 3-tuple in `PairModelsModel` trips `large_tuple`: use the private `Side` struct;
- the preloader's voice-clone test needs a profile store (resolution maps a store-less clone to the system voice);
- `ModelServices` gained an injected init, so `MainSetupModelTests` never touches `UserDefaults.standard` or the real Edge consent;
- `StandardVoicesTests` imports AVFoundation (`MemberImportVisibility`);
- a `Mutex` can't be a stored property of a copyable test struct: the sheet harness uses a captured `var`.
