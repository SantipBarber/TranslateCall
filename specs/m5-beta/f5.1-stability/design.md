# F5.1 – Stability & Bug Fixes: Design

**Milestone**: M5 – Beta Release
**Feature**: F5.1 – Stability & Bug Fixes
**Status**: DRAFT – Pending Gate 2 Review
**Date**: 2026-03-10

---

## 1. Architecture Overview

F5.1 introduces no new types. All changes are localized modifications to existing components:

```
SetupManager              ← B1: dedup SCShareableContent calls
  ├─ captureAppsLoaded: Bool          (new session-cache flag)
  ├─ capturePermissionDenied: Bool    (new error state)
  ├─ loadCaptureApps()               (add dual guard)
  ├─ refreshCaptureApps()            (new: explicit cache bust)
  └─ openScreenRecordingSettings()   (new: deep link to System Settings)

Step3_CaptureAppSelectView           ← B1: use refreshCaptureApps() on Refresh tap

LanguagePairManager       ← B2: deferred Locale resolution
  ├─ savedSourceIdentifier: String?  (new: raw string from UserDefaults)
  ├─ savedTargetIdentifier: String?  (new: raw string from UserDefaults)
  ├─ init()                          (read identifiers only — no Locale yet)
  ├─ validateOrRestoreLanguages()    (renamed; resolves Locale AFTER load)
  └─ localeMatches(_:identifier:)    (new: flexible prefix match)

AudioCoordinator          ← Audit/fix: cancellable cleanup in stop()
HalfDuplexManager         ← Audit/fix: task cancellation on deinit
```

---

## 2. B1 Fix — SetupManager SCShareableContent Deduplication

### Root Cause Analysis

`loadCaptureApps()` is triggered from multiple sites in the same session:
1. `SetupWizardView` — `.task { await setupManager.loadCaptureApps() }` on `.onAppear`
2. `Step3_CaptureAppSelectView` — Refresh button
3. Potentially `ContentView.onAppear` (if wired in future features)

macOS re-presents the Screen Recording permission dialog if the app calls `SCShareableContent.current` before permission is fully granted and cached by the system. The fix prevents multiple in-flight and redundant session calls.

### Fix: Dual Guard + Refresh Separation

```swift
// Core/Setup/SetupManager.swift (MODIFY)

@MainActor
final class SetupManager: ObservableObject {

    // MARK: - New state

    /// True once SCShareableContent has been fetched successfully this session.
    /// Reset only by an explicit refresh call.
    private var captureAppsLoaded: Bool = false

    /// True if SCShareableContent threw an authorization error.
    @Published private(set) var capturePermissionDenied: Bool = false

    // MARK: - loadCaptureApps (modified)

    func loadCaptureApps() async {
        // Guard 1: in-flight dedup — another call is already executing
        guard !isLoadingCaptureApps else { return }
        // Guard 2: session cache — already fetched this session, no need to re-call SCKit
        guard !captureAppsLoaded else { return }

        isLoadingCaptureApps = true
        defer { isLoadingCaptureApps = false }

        do {
            let content = try await SCShareableContent.current
            capturePermissionDenied = false
            let all = content.applications
            // ... existing filtering logic unchanged ...
            captureAppsLoaded = true  // mark success AFTER processing
        } catch {
            // Heuristic: authorization errors have domain SCStreamError
            let nsError = error as NSError
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
                capturePermissionDenied = true
            }
            availableCaptureApps = []
            captureAppsLoaded = true  // cache even on error — prevents retry spam
        }
    }

    // MARK: - refreshCaptureApps (new)

    /// Explicit user-initiated refresh. Discards session cache and re-fetches.
    func refreshCaptureApps() async {
        captureAppsLoaded = false
        capturePermissionDenied = false
        await loadCaptureApps()
    }

    // MARK: - openScreenRecordingSettings (new)

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
```

### Caller changes

**`Step3_CaptureAppSelectView`** — Refresh button:
```swift
// BEFORE:
Button("Refresh") { Task { await setupManager.loadCaptureApps() } }

// AFTER:
Button("Refresh") { Task { await setupManager.refreshCaptureApps() } }
```

**`SetupWizardView`** — `.task` on appear: no change needed (idempotent due to guard).

**`Step3_CaptureAppSelectView`** — permission denied state:
```swift
if setupManager.capturePermissionDenied {
    VStack(spacing: 8) {
        Text("Screen Recording permission required")
            .foregroundStyle(.secondary)
        Button("Open Screen Recording Settings") {
            setupManager.openScreenRecordingSettings()
        }
    }
}
```

---

## 3. B2 Fix — LanguagePairManager Race Condition

### Root Cause Analysis

Current init flow:

```
init()
  ├─ selectedSource = Locale(identifier: UserDefaults["tlk.source.language"])  ← e.g., Locale("es")
  ├─ selectedTarget = Locale(identifier: UserDefaults["tlk.target.language"])  ← e.g., Locale("en")
  └─ Task { await loadSupportedLanguages() }
         └─ validateOrResetLanguages()
              ├─ supportedLanguages contains Locale("es-419"), NOT Locale("es")
              └─ selectedSource not found → RESET to supportedLanguages[0]  ← BUG
```

The saved `Locale("es")` does not `.==` compare to `Locale("es-419")` even though they share the same language code. So validation always resets to defaults.

### Fix: Deferred Locale Resolution

```swift
// Core/Translation/LanguagePairManager.swift (MODIFY)

@MainActor
final class LanguagePairManager: ObservableObject {

    // MARK: - New private state

    /// Raw identifier strings saved during init, resolved to Locale after loadSupportedLanguages().
    private var savedSourceIdentifier: String?
    private var savedTargetIdentifier: String?

    // MARK: - Modified init

    init(defaults: UserDefaults = .standard, languageLoader: (() async -> [Locale])? = nil) {
        self.defaults = defaults
        self.languageLoader = languageLoader

        // Read raw identifiers only — do NOT construct Locale objects yet.
        // selectedSource and selectedTarget remain nil until validateOrRestoreLanguages() runs.
        savedSourceIdentifier = defaults.string(forKey: Self.sourceLanguageKey)
        savedTargetIdentifier = defaults.string(forKey: Self.targetLanguageKey)

        Task { await loadSupportedLanguages() }
    }

    // MARK: - Modified loadSupportedLanguages

    private func loadSupportedLanguages() async {
        let languages: [Locale]
        if let loader = languageLoader {
            languages = await loader()
        } else {
            languages = await LanguageAvailability().supportedLanguages
        }
        supportedLanguages = languages
        validateOrRestoreLanguages()  // renamed; runs with full language list available
    }

    // MARK: - Renamed + rewritten: validateOrRestoreLanguages

    private func validateOrRestoreLanguages() {
        guard !supportedLanguages.isEmpty else { return }

        // Restore source language
        if let savedID = savedSourceIdentifier,
           let match = supportedLanguages.first(where: { localeMatches($0, identifier: savedID) }) {
            selectedSource = match
        } else {
            // Default: first Spanish, then first available
            selectedSource = supportedLanguages.first(where: {
                $0.language.languageCode?.identifier == "es"
            }) ?? supportedLanguages[0]
        }

        // Restore target language
        if let savedID = savedTargetIdentifier,
           let match = supportedLanguages.first(where: { localeMatches($0, identifier: savedID) }) {
            selectedTarget = match
        } else {
            // Default: first English, then first available (excluding source)
            selectedTarget = supportedLanguages.first(where: {
                $0.language.languageCode?.identifier == "en"
            }) ?? supportedLanguages[0]
        }

        // Clear saved identifiers — no longer needed
        savedSourceIdentifier = nil
        savedTargetIdentifier = nil
    }

    // MARK: - New helper: flexible locale matching

    private func localeMatches(_ locale: Locale, identifier: String) -> Bool {
        // Exact match first
        if locale.identifier == identifier { return true }
        // Language code prefix match: "es" matches "es-419", "es-ES", etc.
        let savedCode = Locale(identifier: identifier).language.languageCode?.identifier ?? ""
        let localeCode = locale.language.languageCode?.identifier ?? ""
        return !savedCode.isEmpty && savedCode == localeCode
    }
}
```

### `selectedSource`/`selectedTarget` as Optional

To avoid the "transient default" flicker (where subscribers see a brief default value before the real one loads), change the published properties to `Optional<Locale>`:

```swift
// BEFORE:
@Published var selectedSource: Locale = Locale(identifier: "es")
@Published var selectedTarget: Locale = Locale(identifier: "en")

// AFTER:
@Published var selectedSource: Locale?
@Published var selectedTarget: Locale?
```

UI consumers already guard on `LanguagePairManager.supportedLanguages.isEmpty` to disable the picker. Making these optional aligns the types with actual loading behavior. Views should use `?? Locale(identifier: "es")` as a display fallback, not a functional default.

> **Note**: This is a breaking change to the `LanguagePairManager` API. Callers of `selectedSource`/`selectedTarget` must be updated to handle `Optional<Locale>`. The `LanguagePairView`, `AudioViewModel`, and `AudioCoordinator` are the primary consumers — update all at this step.

### Testability: `languageLoader` injection

The new `languageLoader: (() async -> [Locale])?` init parameter lets tests provide a fake language list without depending on `LanguageAvailability` (which cannot be mocked). Example:

```swift
let manager = LanguagePairManager(
    defaults: UserDefaults(suiteName: "test-\(UUID())")!,
    languageLoader: { [Locale(identifier: "es-419"), Locale(identifier: "en-US"), Locale(identifier: "fr-FR")] }
)
```

---

## 4. Memory Audit

### AudioCoordinator — `stop()` Cleanup

Review `AudioCoordinator.stop()` against this checklist. Add any missing lines:

```swift
func stop() {
    // Cancel all VAD/STT/TTS tasks
    outgoingVADTask?.cancel()
    outgoingVADTask = nil
    incomingTask?.cancel()
    incomingTask = nil

    // Cancel all Combine subscriptions
    outgoingCancellables.removeAll()   // cancels and releases AnyCancellable objects
    incomingCancellables.removeAll()

    // Release half-duplex
    halfDuplexCancellable = nil
    halfDuplexManager = nil

    // Stop audio capture
    audioCapture.stopCapture()
}
```

### HalfDuplexManager — `deinit`

Verify that the `AnyCancellable?` properties and the buffer `Task` are cancelled in `deinit`:

```swift
deinit {
    bufferTask?.cancel()
    // AnyCancellable properties auto-cancel on dealloc if stored as optionals or in a Set
}
```

If buffer `Task` is stored as `Task<Void, Never>?`, confirm it is cancelled on `deinit`. If not, add explicit cancellation.

---

## 5. CPU Profiling Plan

Manual Instruments session (Time Profiler + CPU Report):

1. Launch TranslateCall, open Instruments → Time Profiler
2. **Idle measurement**: Start session with no speech for 2 minutes → note average CPU%
3. **Active measurement**: Speak continuously for 2 minutes → note average CPU%
4. If CPU > 15%: identify top frames using Call Tree → Heavy stack view
5. Document result in commit message regardless of outcome

Expected non-issues (already optimized):
- VAD: actor-isolated, event-driven (not polled)
- Translation: 12ms, driven by STT completion events
- Combine chain: no tight loops

Potential hotspot to investigate if CPU is high:
- `AudioManager` tap closure running at 16kHz — already `nonisolated`, but verify buffer conversion cost

---

## 6. File Map

| File | Change | Notes |
|------|--------|-------|
| `Core/Setup/SetupManager.swift` | **MODIFY** | Add `captureAppsLoaded`, `capturePermissionDenied`, `refreshCaptureApps()`, `openScreenRecordingSettings()` |
| `Features/Setup/Step3_CaptureAppSelectView.swift` | **MODIFY** | Use `refreshCaptureApps()` on refresh; show permission-denied UI |
| `Core/Translation/LanguagePairManager.swift` | **MODIFY** | `savedSourceIdentifier`, `savedTargetIdentifier`, `languageLoader`, `localeMatches()`, `validateOrRestoreLanguages()`, optional `selectedSource`/`selectedTarget` |
| `Features/Main/LanguagePairView.swift` | **MODIFY** | Handle `Optional<Locale>` for `selectedSource`/`selectedTarget` |
| `Features/Main/AudioViewModel.swift` | **MODIFY** | Handle optional locale when passing to `AudioCoordinator.start()` |
| `Core/Audio/AudioCoordinator.swift` | **AUDIT + MODIFY** | Verify/fix `stop()` cleanup of tasks and cancellables |
| `Core/Audio/HalfDuplexManager.swift` | **AUDIT + MODIFY** | Verify/fix buffer task cancellation in `deinit` |
| `TranslateCallTests/SetupManagerTests.swift` | **MODIFY** | Add dedup tests, permission-denied tests |
| `TranslateCallTests/LanguagePairManagerTests.swift` | **MODIFY** | Add restore tests using `languageLoader` injection |

---

## 7. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| `selectedSource`/`selectedTarget` Optional breaks many callers | Medium | Medium | Audit all consumers before writing code; update in one pass |
| `captureAppsLoaded` flag causes stale list when new apps launch during session | Low | Low | `refreshCaptureApps()` is available; wizard re-open calls it |
| `localeMatches` prefix logic causes false positives (e.g., `"zh"` matching `"zh-Hant"` unintentionally) | Low | Low | Apple `supportedLanguages` uses specific identifiers; prefix match on 2-letter codes is safe for Apple's language set |
| `languageLoader` injection adds complexity to production init | Low | None | Default `nil` → falls back to `LanguageAvailability()` — no change to prod behavior |

---

*End of F5.1 Design — Gate 2 Review Pending*
