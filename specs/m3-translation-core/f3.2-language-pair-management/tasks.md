# F3.2: Language Pair Management — Tasks

**Feature**: Language pair selection, availability checking, model download, persistence
**Milestone**: M3 — Translation Core
**Status**: DRAFT — awaiting Gate 3 review
**Date**: 2026-03-08
**Prerequisites**: design.md (Gate 2 approved), F3.1 T1 complete (`TranslationService.swift` exists)

---

## Dependency Order

```
T1 (LanguagePairManager)
  ├──▶ T2 (AudioViewModel wiring)
  │       └──▶ T4 (ContentView integration + start button guard)
  └──▶ T3 (LanguagePairView)
              └──▶ T4
T1 + T2 ──▶ T5 (tests)
```

All tasks follow TDD: write failing test → implement → green → refactor.

---

## T1 — Implement `LanguagePairStatus` and `LanguagePairManager`

**Maps to**: REQ-LPM-01 through REQ-LPM-14, REQ-LPM-30 through REQ-LPM-32
**File**: `TranslateCall/Core/Translation/LanguagePairManager.swift` *(new)*
**Depends on**: nothing

### What to implement

1. `LanguagePairStatus` enum:
   ```swift
   enum LanguagePairStatus: Equatable {
       case installed, supported, unsupported, unknown
   }
   ```

2. `LanguagePairManager: @MainActor final class ObservableObject`:
   - `@Published private(set) var sourceLanguage: Locale.Language`
   - `@Published private(set) var targetLanguage: Locale.Language`
   - `@Published private(set) var pairStatus: LanguagePairStatus = .unknown`
   - `@Published private(set) var supportedLanguages: [Locale.Language] = []`
   - `@Published private(set) var isCheckingAvailability = false`
   - `private let defaults = UserDefaults.standard`
   - `private static let sourceKey = "tlk.source.language"`
   - `private static let targetKey = "tlk.target.language"`

3. `init()`:
   - Load `sourceLanguage` from `defaults.string(forKey: Self.sourceKey)` → `Locale.Language(identifier:)`, fallback to `Locale.current.language`
   - Load `targetLanguage` from `defaults.string(forKey: Self.targetKey)`, fallback to `"en"` (or `"es"` if current is English)
   - `Task { await loadSupportedLanguages(); await checkAvailability() }`

4. `func setSourceLanguage(_ lang: Locale.Language) async`:
   - Set `sourceLanguage`, persist `lang.minimalIdentifier`, call `await checkAvailability()`

5. `func setTargetLanguage(_ lang: Locale.Language) async`:
   - Set `targetLanguage`, persist `lang.minimalIdentifier`, call `await checkAvailability()`

6. `func swapLanguages() async`:
   - Swap `sourceLanguage` ↔ `targetLanguage` atomically, persist both, call `await checkAvailability()`

7. `func checkAvailability() async`:
   - Set `isCheckingAvailability = true`
   - `let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)`
   - Map to `LanguagePairStatus` (`.installed`/`.supported`/`.unsupported` → same; `@unknown default` → `.unsupported`)
   - Set `pairStatus`, set `isCheckingAvailability = false`

8. `private func loadSupportedLanguages() async`:
   - `let langs = await LanguageAvailability().supportedLanguages(as: .translation)`
   - Sort by `displayName(for:)` alphabetically
   - Set `supportedLanguages`
   - Call `validateOrResetLanguages()` if non-empty

9. `private func validateOrResetLanguages()`:
   - Build `Set<String>` of `minimalIdentifier` from `supportedLanguages`
   - If `sourceLanguage.minimalIdentifier` not in set → reset to `Locale.current.language`, remove from defaults
   - If `targetLanguage.minimalIdentifier` not in set → reset to `Locale.Language(identifier: "en")`, remove from defaults

10. `func displayName(for language: Locale.Language) -> String`:
    - `Locale.current.localizedString(forLanguageCode: language.languageCode?.identifier ?? "") ?? language.minimalIdentifier`

### Tests (RED first) — `TranslateCallTests/LanguagePairManagerTests.swift` *(new file)*

```swift
@Suite(.serialized) @MainActor
struct LanguagePairManagerTests { ... }
```

- `testDefaultLanguagePairNoDefaults()` — clear UserDefaults keys, init manager, assert `sourceLanguage` == `Locale.current.language` (or non-nil), `targetLanguage` != `sourceLanguage` (AC-05)
- `testSetSourceLanguagePersists()` — call `setSourceLanguage(Locale.Language(identifier: "fr"))`, assert `UserDefaults.standard.string(forKey: "tlk.source.language") == "fr"` (AC-02)
- `testSetTargetLanguagePersists()` — call `setTargetLanguage(Locale.Language(identifier: "de"))`, assert persisted (AC-03)
- `testSwapLanguages()` — set EN→ES, call `swapLanguages()`, assert source is now ES and target is now EN, both persisted (AC-04)
- `testDisplayNameNonNilForCommonLanguage()` — assert `displayName(for: Locale.Language(identifier: "es"))` returns non-empty string

### Done when
- File compiles with zero warnings
- Tests green

---

## T2 — Wire `LanguagePairManager` into `AudioViewModel`

**Maps to**: REQ-LPM-01 (ownership), design section 5
**File**: `TranslateCall/Features/Main/AudioViewModel.swift` *(modify)*
**Depends on**: T1

### What to implement

1. Add new `init` parameters (append to existing signature):
   ```swift
   init(
       audioManager: AudioManager = AudioManager(),
       vadFactory: VADServiceFactory = VADServiceFactory(),
       translationService: (any TranslationService)? = nil,
       languagePairManager: LanguagePairManager = LanguagePairManager()
   )
   ```
   Store as `private let translationService: (any TranslationService)?` and `private let languagePairManager: LanguagePairManager`.

   > `translationService` storage added here; pipeline wiring (`handleTranslation`) comes in F3.3-T1.

2. Add `func downloadLanguages() async`:
   ```swift
   func downloadLanguages() async {
       do {
           try await translationService?.prepare(
               source: languagePairManager.sourceLanguage,
               target: languagePairManager.targetLanguage
           )
           await languagePairManager.checkAvailability()
       } catch {
           errorAlert = AlertItem(title: "Download Failed", message: error.localizedDescription, action: nil)
       }
   }
   ```

3. Update `preview()` factory to pass default `languagePairManager: LanguagePairManager()`.

4. Update `AppContainer.init()` (F3.1 T4) to pass `languagePairManager: lpm` — coordinate with F3.1 if already merged.

### Tests

- `testDownloadLanguagesCallsPrepare()` — inject a mock `TranslationService` spy, call `downloadLanguages()`, assert `prepare()` was called with correct source/target
- `testDownloadLanguagesErrorSetsAlert()` — inject a spy that throws, call `downloadLanguages()`, assert `errorAlert != nil`

### Done when
- `AudioViewModel` compiles with new signature, zero warnings
- Existing tests still pass
- New tests green

---

## T3 — Implement `LanguagePairView`

**Maps to**: REQ-LPM-40 through REQ-LPM-45
**File**: `TranslateCall/Features/Main/LanguagePairView.swift` *(new)*
**Depends on**: T1

### What to implement

```swift
struct LanguagePairView: View {
    @EnvironmentObject private var viewModel: AudioViewModel

    private var manager: LanguagePairManager { viewModel.languagePairManager }

    var body: some View {
        HStack(spacing: 8) {
            languagePicker(
                selection: manager.sourceLanguage,
                onChange: { Task { await manager.setSourceLanguage($0) } }
            )
            Button { Task { await manager.swapLanguages() } } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.plain)
            .help("Swap languages")

            languagePicker(
                selection: manager.targetLanguage,
                onChange: { Task { await manager.setTargetLanguage($0) } }
            )

            pairStatusIndicator

            if manager.pairStatus == .supported {
                Button("Download") { Task { await viewModel.downloadLanguages() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .disabled(viewModel.isCapturing)
    }

    private var pairStatusIndicator: some View {
        Group {
            switch manager.pairStatus {
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .supported:
                Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
            case .unsupported:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .unknown:
                ProgressView().scaleEffect(0.6)
            }
        }
        .help(pairStatusHelp)
    }

    private var pairStatusHelp: String {
        switch manager.pairStatus {
        case .installed:   return "Language models installed"
        case .supported:   return "Models need to be downloaded"
        case .unsupported: return "Language pair not supported"
        case .unknown:     return "Checking availability…"
        }
    }

    private func languagePicker(
        selection: Locale.Language,
        onChange: @escaping (Locale.Language) -> Void
    ) -> some View {
        Picker("", selection: Binding(
            get: { selection },
            set: { onChange($0) }
        )) {
            ForEach(manager.supportedLanguages, id: \.minimalIdentifier) { lang in
                Text(manager.displayName(for: lang)).tag(lang)
            }
        }
        .frame(width: 120)
    }
}
```

### Done when
- View compiles with zero warnings
- SwiftUI Preview renders picker list and status indicator
- Pickers are disabled when `viewModel.isCapturing == true`

---

## T4 — Integrate `LanguagePairView` into `ContentView` and add start button guard

**Maps to**: REQ-LPM-45 (pickers disabled while capturing), REQ-PIPE-43 / design section 4.3
**File**: `TranslateCall/Features/Main/ContentView.swift` *(modify)*
**Depends on**: T2, T3

### What to implement

1. Add `LanguagePairView()` to `ContentView` — place below the level meter row, above the transcription view:
   ```swift
   // In ContentView.body VStack:
   LanguagePairView()
       .padding(.horizontal, 12)
   ```

2. Disable the start/stop button when pair is unsupported:
   ```swift
   Button(viewModel.isCapturing ? "Stop" : "Start") {
       Task { await viewModel.toggleCapture() }
   }
   .disabled(
       viewModel.isStarting ||
       (!viewModel.isCapturing && viewModel.languagePairManager.pairStatus == .unsupported)
   )
   ```
   > Only gate the Start action; Stop should always be available.

### Done when
- App builds and launches; `LanguagePairView` visible in main window
- Start button greys out when an unsupported pair is selected
- Pickers are interactive when not capturing and disabled when capturing

---

## T5 — Tests

**Maps to**: All REQ-LPM + AC-01 through AC-09
**File**: `TranslateCallTests/LanguagePairManagerTests.swift`
**Depends on**: T1–T4

### Additional tests (beyond T1)

- `testSupportedLanguagesLoaded()` — `LanguagePairManager().supportedLanguages` becomes non-empty within 2s (async wait) (AC-01)
- `testAvailabilityInstalledPair()` — call `checkAvailability()` for a common pair (e.g. EN↔ES); on macOS 15 this should return `.installed` or `.supported` — assert `pairStatus != .unknown` (AC-06)
- `testAvailabilityUnsupportedPair()` — create a clearly invalid pair (e.g. `zxx` → `zxx`), assert `pairStatus == .unsupported` (AC-07)
- `testPickersDisabledWhileCapturing()` — observe `viewModel.isCapturing == true`, assert `LanguagePairView` controls are `.disabled` (logic test via ViewModel state — UI test optional)

### Done when
- All unit tests green
- AC-01 through AC-09 covered by test or documented as manual/integration

---

## Task Summary

| Task | File(s) | Effort | Blocks |
|------|---------|--------|--------|
| T1 — LanguagePairManager | `Core/Translation/LanguagePairManager.swift` | M | T2, T3, T5 |
| T2 — AudioViewModel wiring | `Features/Main/AudioViewModel.swift` | S | T4 |
| T3 — LanguagePairView | `Features/Main/LanguagePairView.swift` | S | T4 |
| T4 — ContentView integration | `Features/Main/ContentView.swift` | XS | T5 |
| T5 — Tests | `TranslateCallTests/LanguagePairManagerTests.swift` | S | — |

---

*Gate 3 Review: human must approve this document before implementation begins.*
