# F3.2: Language Pair Management — Technical Design

**Feature**: Language pair selection, availability checking, model download, and persistence
**Milestone**: M3 — Translation Core
**Status**: DRAFT — awaiting Gate 2 review
**Date**: 2026-03-08
**Prerequisites**: requirements.md (Gate 1 approved)

---

## 1. Key Design Decisions

### 1.1 `LanguagePairManager` owned by `AudioViewModel`

All pipeline components (VAD, STT, Translation, TTS) are orchestrated by `AudioViewModel`. `LanguagePairManager` provides the language configuration for the translation step and belongs with the pipeline. It is constructed in `AppContainer` and passed to `AudioViewModel.init`.

### 1.2 `LanguageAvailability` checks run async in `init`

`LanguageAvailability` is not `@MainActor` but its methods are `async`. A `Task { await ... }` in `init` loads supported languages and checks the initial pair status. This avoids blocking the main thread; `@Published` properties update when the checks complete.

### 1.3 Persistence via `UserDefaults` with BCP-47 string identifiers

`Locale.Language` can be round-tripped through `minimalIdentifier` (e.g. `"es"`, `"en"`) and `Locale.Language(identifier:)`. This is simpler than encoding the full language struct.

```swift
// Save
defaults.set(language.minimalIdentifier, forKey: "tlk.source.language")

// Load
if let id = defaults.string(forKey: "tlk.source.language") {
    sourceLanguage = Locale.Language(identifier: id)
}
```

### 1.4 Download triggered via `AppleTranslationService.prepare()` — not directly from `LanguagePairManager`

`LanguagePairManager` has no access to `TranslationSession`. When `pairStatus == .supported` and the user taps "Download", `AudioViewModel.downloadLanguages()` calls `translationService.prepare(source:target:)` (F3.1). After completion, `languagePairManager.checkAvailability()` refreshes `pairStatus`.

### 1.5 Language display names via `Locale.current.localizedString(forLanguageCode:)`

`Locale.Language` exposes `languageCode: Locale.LanguageCode?` which has an `identifier: String`. Use `Locale.current.localizedString(forLanguageCode: lang.languageCode?.identifier ?? "")` to get a human-readable name for pickers.

---

## 2. Architecture Overview

```
AppContainer
  └── LanguagePairManager (@MainActor ObservableObject)
        ├── @Published sourceLanguage: Locale.Language
        ├── @Published targetLanguage: Locale.Language
        ├── @Published pairStatus: LanguagePairStatus
        ├── @Published supportedLanguages: [Locale.Language]
        └── @Published isCheckingAvailability: Bool

AudioViewModel (@MainActor ObservableObject)
  ├── private let languagePairManager: LanguagePairManager
  └── func downloadLanguages() async throws
        → translationService.prepare(source: lpm.sourceLanguage, target: lpm.targetLanguage)
        → languagePairManager.checkAvailability()

ContentView / LanguagePairView
  └── @EnvironmentObject audioViewModel
        ├── languagePairManager.supportedLanguages  → Picker items
        ├── languagePairManager.sourceLanguage       → Picker selection
        ├── languagePairManager.targetLanguage       → Picker selection
        └── languagePairManager.pairStatus           → Status indicator
```

---

## 3. Type Definitions

### 3.1 `LanguagePairStatus`

```swift
// Core/Translation/LanguagePairManager.swift
enum LanguagePairStatus: Equatable {
    case installed      // models on-device, ready
    case supported      // supported, needs download
    case unsupported    // not available for this pair
    case unknown        // initial state, check not yet run
}
```

---

## 4. `LanguagePairManager` — Implementation Design

```swift
// Core/Translation/LanguagePairManager.swift
@MainActor
final class LanguagePairManager: ObservableObject {
    @Published private(set) var sourceLanguage: Locale.Language
    @Published private(set) var targetLanguage: Locale.Language
    @Published private(set) var pairStatus: LanguagePairStatus = .unknown
    @Published private(set) var supportedLanguages: [Locale.Language] = []
    @Published private(set) var isCheckingAvailability = false

    private let defaults = UserDefaults.standard
    private static let sourceKey = "tlk.source.language"
    private static let targetKey = "tlk.target.language"

    init() {
        // Load persisted or compute defaults
        let currentLang = Locale.current.language
        let defaultTarget = Locale.Language(
            identifier: (currentLang.languageCode?.identifier == "en") ? "es" : "en"
        )
        sourceLanguage = defaults.string(forKey: Self.sourceKey)
            .map { Locale.Language(identifier: $0) } ?? currentLang
        targetLanguage = defaults.string(forKey: Self.targetKey)
            .map { Locale.Language(identifier: $0) } ?? defaultTarget

        Task {
            await loadSupportedLanguages()
            await checkAvailability()
        }
    }

    func setSourceLanguage(_ lang: Locale.Language) async {
        sourceLanguage = lang
        defaults.set(lang.minimalIdentifier, forKey: Self.sourceKey)
        await checkAvailability()
    }

    func setTargetLanguage(_ lang: Locale.Language) async {
        targetLanguage = lang
        defaults.set(lang.minimalIdentifier, forKey: Self.targetKey)
        await checkAvailability()
    }

    func swapLanguages() async {
        let (src, tgt) = (sourceLanguage, targetLanguage)
        sourceLanguage = tgt
        targetLanguage = src
        defaults.set(tgt.minimalIdentifier, forKey: Self.sourceKey)
        defaults.set(src.minimalIdentifier, forKey: Self.targetKey)
        await checkAvailability()
    }

    func checkAvailability() async {
        isCheckingAvailability = true
        defer { isCheckingAvailability = false }
        let availability = LanguageAvailability()
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        pairStatus = LanguagePairStatus(from: status)
    }

    // MARK: - Private

    private func loadSupportedLanguages() async {
        let availability = LanguageAvailability()
        let langs = await availability.supportedLanguages(as: .translation)
        supportedLanguages = langs.sorted {
            displayName(for: $0) < displayName(for: $1)
        }
        // Validate persisted languages are still supported
        if !supportedLanguages.isEmpty {
            validateOrResetLanguages()
        }
    }

    private func validateOrResetLanguages() {
        let ids = Set(supportedLanguages.map { $0.minimalIdentifier })
        if !ids.contains(sourceLanguage.minimalIdentifier) {
            sourceLanguage = Locale.current.language
            defaults.removeObject(forKey: Self.sourceKey)
        }
        if !ids.contains(targetLanguage.minimalIdentifier) {
            targetLanguage = Locale.Language(identifier: "en")
            defaults.removeObject(forKey: Self.targetKey)
        }
    }
}

// MARK: - Helpers

extension LanguagePairManager {
    func displayName(for language: Locale.Language) -> String {
        Locale.current.localizedString(forLanguageCode: language.languageCode?.identifier ?? "")
            ?? language.minimalIdentifier
    }
}

private extension LanguagePairStatus {
    init(from status: LanguageAvailability.Status) {
        switch status {
        case .installed:   self = .installed
        case .supported:   self = .supported
        case .unsupported: self = .unsupported
        @unknown default:  self = .unsupported
        }
    }
}
```

---

## 5. `AudioViewModel` Changes for F3.2

### 5.1 New property and init parameter

```swift
// AudioViewModel.swift additions
private let languagePairManager: LanguagePairManager

init(
    audioManager: AudioManager = AudioManager(),
    vadFactory: VADServiceFactory = VADServiceFactory(),
    translationService: (any TranslationService)? = nil,
    languagePairManager: LanguagePairManager = LanguagePairManager()
) {
    self.languagePairManager = languagePairManager
    // ... existing setup
}
```

### 5.2 Download action

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

`ContentView` exposes `audioViewModel.languagePairManager` to the language pair UI components.

---

## 6. UI Design — `LanguagePairView`

A compact horizontal bar embedded in `ContentView`, below the level meters and above the status badge:

```
┌─────────────────────────────────────────────┐
│  [Spanish ▾]  ⇄  [English ▾]  ● Installed  │
│                                [Download]    │  ← only when .supported
└─────────────────────────────────────────────┘
```

```swift
// Features/Main/LanguagePairView.swift (new file)
struct LanguagePairView: View {
    @EnvironmentObject private var viewModel: AudioViewModel

    private var manager: LanguagePairManager { viewModel.languagePairManager }

    var body: some View {
        HStack(spacing: 8) {
            languagePicker(selection: manager.sourceLanguage) { lang in
                Task { await manager.setSourceLanguage(lang) }
            }
            swapButton
            languagePicker(selection: manager.targetLanguage) { lang in
                Task { await manager.setTargetLanguage(lang) }
            }
            statusIndicator
            if manager.pairStatus == .supported {
                downloadButton
            }
        }
        .disabled(viewModel.isCapturing)
    }

    private var swapButton: some View {
        Button { Task { await manager.swapLanguages() } } label: {
            Image(systemName: "arrow.left.arrow.right")
        }
        .buttonStyle(.plain)
    }

    private var statusIndicator: some View {
        Group {
            switch manager.pairStatus {
            case .installed:  Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .supported:  Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
            case .unsupported: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .unknown:    ProgressView().scaleEffect(0.6)
            }
        }
    }

    private var downloadButton: some View {
        Button("Download") { Task { await viewModel.downloadLanguages() } }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
        .disabled(viewModel.isCapturing)
    }
}
```

---

## 7. File Structure

```
TranslateCall/
├── Core/
│   └── Translation/
│       ├── TranslationService.swift        // (F3.1) protocol + TranslationError
│       ├── AppleTranslationService.swift   // (F3.1) actor
│       ├── LanguagePairManager.swift       // NEW — LanguagePairStatus + LanguagePairManager
│       └── (future: LanguageDetector.swift for M4)
└── Features/
    └── Main/
        ├── LanguagePairView.swift          // NEW — compact language pair UI
        └── ContentView.swift               // UPDATE — embed LanguagePairView
```

---

## 8. Threading and Swift 6 Compliance

| Concern | Solution |
|---------|---------|
| `LanguageAvailability` is not Sendable | Constructed locally inside `async` method (no capture) |
| `LanguageAvailability.status(from:to:)` is `async` | `await`-ed from `@MainActor` Task in `init` and `checkAvailability()` |
| `supportedLanguages(as:)` returns `[Locale.Language]` | `Locale.Language` is `Sendable` — safe to pass across isolation |
| `UserDefaults` access | All on `@MainActor` (same thread as LanguagePairManager) |
| `Picker` binding mutates `@MainActor` state | `Binding.set` closure dispatches `Task { await manager.set... }` — safe |

---

## 9. Error Handling

| Error | Behavior |
|-------|---------|
| `supportedLanguages(as:)` returns empty | `validateOrResetLanguages()` skipped; pickers show empty list; log warning |
| Persisted language no longer supported | `validateOrResetLanguages()` resets to defaults silently |
| `checkAvailability()` called with `.unsupported` pair | `pairStatus = .unsupported`; UI disables start button (F3.3) |
| `downloadLanguages()` throws | `errorAlert` set with localized description |

---

## 10. Future Extensibility (M4)

- **Auto-detection**: Add `detectedSourceLanguage: Locale.Language?` — STT confidence determines the actual source, overriding the picker selection.
- **Multiple pairs**: Replace `sourceLanguage`/`targetLanguage` with `languagePairs: [LanguagePair]` for bidirectional mode.
- **iCloud sync**: Swap `UserDefaults` for `NSUbiquitousKeyValueStore` — same keys, same logic.

---

*Gate 2 Review: human must approve this document before tasks.md is written.*
