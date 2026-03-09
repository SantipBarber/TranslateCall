# F3.2: Language Pair Management — Requirements

**Feature**: Language pair selection, availability checking, model download, and persistence
**Milestone**: M3 — Translation Core
**Status**: DRAFT — awaiting Gate 1 review
**Date**: 2026-03-08
**Author**: Claude + Sergio

---

## 1. Context

The Translation framework supports a fixed set of language pairs. Before translation can happen (F3.1), the app must know which languages the user wants to translate between and whether the corresponding models are installed. Language selection must be persistent across app restarts, and if a requested pair is not installed, the user must be guided through the download.

This feature provides the data layer (`LanguagePairManager`) and UI (`LanguagePairView` / settings panel) that configure the one-way translation pipeline in F3.3.

---

## 2. Definitions

| Term | Definition |
|------|-----------|
| **Language pair** | A (source, target) tuple of `Locale.Language` values used for translation |
| **Source language** | The spoken language detected by STT (e.g. Spanish) |
| **Target language** | The language into which text is translated for TTS output (e.g. English) |
| **LanguageAvailability** | Apple Translation framework class that checks and lists supported languages |
| **Status.installed** | Models for this pair are already downloaded on-device |
| **Status.supported** | Pair is supported but models must be downloaded |
| **Status.unsupported** | Pair is not supported by the framework |
| **prepareTranslation()** | `TranslationSession` method that shows the system download sheet |

---

## 3. Functional Requirements

### 3.1 LanguagePairManager

**REQ-LPM-01**: `LanguagePairManager` SHALL be a `@MainActor final class ObservableObject` responsible for language selection state, availability checks, and persistence.

**REQ-LPM-02**: `LanguagePairManager` SHALL expose:
```swift
@Published private(set) var sourceLanguage: Locale.Language
@Published private(set) var targetLanguage: Locale.Language
@Published private(set) var pairStatus: LanguagePairStatus
@Published private(set) var supportedLanguages: [Locale.Language]
@Published private(set) var isCheckingAvailability: Bool
```

**REQ-LPM-03**: `LanguagePairStatus` SHALL be an enum:
```swift
enum LanguagePairStatus {
    case installed          // ready to translate immediately
    case supported          // supported but needs download
    case unsupported        // cannot be used
    case unknown            // not yet checked
}
```

**REQ-LPM-04**: WHEN `LanguagePairManager` is initialized THEN it SHALL:
1. Load persisted `sourceLanguage` and `targetLanguage` from `UserDefaults` (keys: `tlk.source.language`, `tlk.target.language`).
2. Fall back to defaults: source = `Locale.current.language`, target = `Locale.Language(identifier: "en")` if current is not English, otherwise `Locale.Language(identifier: "es")`.
3. Asynchronously load `supportedLanguages` via `LanguageAvailability().supportedLanguages(as: .translation)`.
4. Asynchronously check `pairStatus` for the loaded pair.

**REQ-LPM-05**: `LanguagePairManager` SHALL expose `func setSourceLanguage(_ lang: Locale.Language) async` and `func setTargetLanguage(_ lang: Locale.Language) async` that:
1. Update the respective published property.
2. Persist the new value to `UserDefaults`.
3. Re-check `pairStatus` for the updated pair.
4. Notify observers (via Combine / `@Published`).

**REQ-LPM-06**: `LanguagePairManager` SHALL expose `func swapLanguages() async` that atomically swaps source and target, persists both, and re-checks `pairStatus`.

**REQ-LPM-07**: `LanguagePairManager` SHALL expose `func checkAvailability() async` that calls `LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)` and maps the result to `LanguagePairStatus`.

### 3.2 Language Availability Checking

**REQ-LPM-10**: WHEN `checkAvailability()` is called THEN `isCheckingAvailability` SHALL be set to `true` until the check completes.

**REQ-LPM-11**: The system SHALL use `LanguageAvailability().supportedLanguages(as: .translation)` to populate `supportedLanguages`. This list SHALL be the data source for language pickers in the UI.

**REQ-LPM-12**: WHEN `pairStatus == .supported` THEN the UI SHALL display a "Download" button. The actual download is triggered by the bridge (F3.1 `session.prepareTranslation()`).

**REQ-LPM-13**: WHEN `pairStatus == .unsupported` THEN the language pair controls SHALL indicate the pair is unavailable, and the start-capture button SHALL be disabled.

**REQ-LPM-14**: WHEN `pairStatus == .installed` THEN no additional action is needed; the pipeline can proceed.

### 3.3 Model Download

**REQ-LPM-20**: `LanguagePairManager` SHALL expose `func prepareTranslation(using session: TranslationSession) async throws` that calls `session.prepareTranslation()`, showing the system download sheet if models are not present.

**REQ-LPM-21**: AFTER `prepareTranslation()` completes successfully THEN `LanguagePairManager` SHALL call `checkAvailability()` to refresh `pairStatus` to `.installed`.

**REQ-LPM-22**: The download flow SHALL be triggered from `TranslationBridge` (which has access to the session), not from `LanguagePairManager` directly. `LanguagePairManager` signals the need via `pairStatus == .supported`; the bridge acts.

**REQ-LPM-23**: IF `prepareTranslation()` is called for a `.unsupported` pair THEN it SHALL throw `TranslationError.unsupportedPair`.

### 3.4 Persistence

**REQ-LPM-30**: Selected `sourceLanguage` and `targetLanguage` SHALL be persisted in `UserDefaults` using BCP-47 language identifier strings (e.g. `"es"`, `"en-US"`).

**REQ-LPM-31**: Persistence keys SHALL be namespaced: `tlk.source.language` and `tlk.target.language`.

**REQ-LPM-32**: IF a persisted language identifier is no longer in `supportedLanguages` (e.g. framework removed it) THEN the system SHALL fall back to the default language for that slot.

### 3.5 UI — Language Pair View

**REQ-LPM-40**: The app SHALL display source and target language pickers in the main window (integrated into `ContentView` or a settings sheet, TBD in design.md).

**REQ-LPM-41**: Each picker SHALL list all languages from `supportedLanguages`, sorted alphabetically by localized display name.

**REQ-LPM-42**: The UI SHALL display a status indicator for the current pair:
- Green checkmark: `.installed`
- Orange download icon: `.supported` (needs download)
- Red X: `.unsupported`
- Spinner: `.unknown` / `isCheckingAvailability`

**REQ-LPM-43**: WHEN `pairStatus == .supported` THEN a "Download languages" button SHALL be visible. Tapping it SHALL trigger the download flow (via `TranslationBridge`).

**REQ-LPM-44**: A swap button (⇄) between the two pickers SHALL call `swapLanguages()`.

**REQ-LPM-45**: Language pickers SHALL be disabled while `isCapturing == true` (language cannot change mid-session).

---

## 4. Non-Functional Requirements

### 4.1 Startup Performance

**REQ-NFR-01**: `LanguageAvailability` checks SHALL run asynchronously on init — the app SHALL NOT block the main thread waiting for the language list.

**REQ-NFR-02**: `supportedLanguages` SHALL be available within 500 ms of app launch on Apple Silicon (the check is an on-device API call, not a network request).

### 4.2 Privacy

**REQ-NFR-03**: Language selection preferences are stored locally in `UserDefaults`. No language data is sent to any server.

**REQ-NFR-04**: `LanguageAvailability` queries are purely on-device.

### 4.3 Swift 6 / Concurrency

**REQ-NFR-05**: `LanguagePairManager` SHALL compile with Swift 6 strict concurrency without warnings.

**REQ-NFR-06**: `LanguageAvailability` calls SHALL be `await`-ed from `@MainActor` context; they are `async` in the Apple API.

---

## 5. Constraints

| Constraint | Value |
|-----------|-------|
| Platform | macOS 15.0+ |
| Framework | Translation (LanguageAvailability, TranslationSession) |
| Language | Swift 6.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` |
| Persistence | `UserDefaults` (no CloudKit/CoreData) |
| Language set | Determined by `LanguageAvailability().supportedLanguages(as: .translation)` |
| No new SPM dependencies | Standard library + Translation framework only |

---

## 6. Out of Scope (F3.2)

- Automatic language detection from audio (always explicit selection in M3)
- Per-session language overrides (always uses persisted pair in M3)
- Multiple simultaneous language pairs — M4
- iCloud sync of language preferences — M6+
- The actual download sheet UI (provided by system via `session.prepareTranslation()`)

---

## 7. Acceptance Criteria (Gate 4 — Validation)

| ID | Criterion | Test |
|----|-----------|------|
| AC-01 | `supportedLanguages` is non-empty after init | `testSupportedLanguagesLoaded()` |
| AC-02 | `setSourceLanguage("fr")` persists to UserDefaults and updates `pairStatus` | `testSetSourceLanguagePersists()` |
| AC-03 | `setTargetLanguage("de")` persists to UserDefaults and updates `pairStatus` | `testSetTargetLanguagePersists()` |
| AC-04 | `swapLanguages()` exchanges source↔target atomically and persists both | `testSwapLanguages()` |
| AC-05 | On fresh init, UserDefaults missing → defaults to `current` → `"en"` pair | `testDefaultLanguagePair()` |
| AC-06 | `checkAvailability()` returns `.installed` for EN↔ES (common pair, usually pre-installed on macOS 15) | `testAvailabilityInstalledPair()` |
| AC-07 | `checkAvailability()` returns `.unsupported` for a known unsupported pair | `testAvailabilityUnsupportedPair()` |
| AC-08 | Language pickers disabled when `isCapturing == true` (UI test or view model test) | `testPickersDisabledWhileCapturing()` |
| AC-09 | All code compiles with 0 warnings under Swift 6 strict concurrency | CI build check |

---

## 8. Open Questions (to resolve before design.md)

1. **Where do language pickers live in the UI?** Options:
   - (A) Inline in `ContentView` below the level meters
   - (B) In a popover/sheet triggered by a settings gear icon
   - **Preferred**: Option A for M3 — simpler, always visible. Can move to settings sheet in M5 polish pass.

2. **`LanguagePairManager` ownership**: Should it be owned by `AudioViewModel` or be a separate `@StateObject` in `TranslateCallApp`?
   - **Preferred**: Owned by `AudioViewModel` — it already orchestrates the pipeline and needs to know the pair for F3.3.

3. **Display names for languages**: `Locale.Language` → display name requires `Locale.current.localizedString(forLanguageCode:)` or `Locale(identifier:).localizedString(forIdentifier:)`. Is this the right API?
   - **Preferred**: Use `Locale.current.localizedString(forLanguageCode: lang.languageCode?.identifier ?? "")` — simple and correct.

4. **`supportedLanguages(as:)` API**: Confirm the correct call is `LanguageAvailability().supportedLanguages(as: .translation)` (returns `[Locale.Language]`).
   - Verify in Cupertino MCP during design phase.

---

*Gate 1 Review: human must approve this document before design.md is written.*
