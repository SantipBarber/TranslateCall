# F5.1 – Stability & Bug Fixes: Tasks

**Milestone**: M5 – Beta Release
**Feature**: F5.1 – Stability & Bug Fixes
**Status**: DRAFT – Pending Gate 3 Review
**Date**: 2026-03-10

---

## Task Summary

| ID | Title | Files | Depends |
|----|-------|-------|---------|
| T1 | Fix B2 — `LanguagePairManager` race condition + Optional Locale | `Core/Translation/LanguagePairManager.swift` | — |
| T2 | Update callers of `selectedSource`/`selectedTarget` (Optional migration) | `LanguagePairView`, `AudioViewModel`, `AudioCoordinator` | T1 |
| T3 | Add `LanguagePairManager` tests for language restoration (B2) | `TranslateCallTests/LanguagePairManagerTests.swift` | T1 |
| T4 | Fix B1 — `SetupManager` SCShareableContent deduplication | `Core/Setup/SetupManager.swift` | — |
| T5 | Update Step3 to use `refreshCaptureApps()` + permission-denied UI | `Features/Setup/Step3_CaptureAppSelectView.swift` | T4 |
| T6 | Add `SetupManager` tests for dedup and permission denied (B1) | `TranslateCallTests/SetupManagerTests.swift` | T4 |
| T7 | Audit and fix `AudioCoordinator.stop()` cleanup | `Core/Audio/AudioCoordinator.swift` | — |
| T8 | Audit and fix `HalfDuplexManager` deinit cleanup | `Core/Audio/HalfDuplexManager.swift` | — |
| T9 | CPU baseline measurement (manual Instruments) | — | T1–T8 |
| T10 | Full test suite run + ROADMAP update + commit | — | T1–T9 |

---

## T1 — Fix `LanguagePairManager` Race Condition (B2)

**File**: `TranslateCall/Core/Translation/LanguagePairManager.swift` (MODIFY)

### Checklist

- [ ] Add `private var savedSourceIdentifier: String?` property
- [ ] Add `private var savedTargetIdentifier: String?` property
- [ ] Add `languageLoader: (() async -> [Locale])? = nil` parameter to `init(defaults:)` (becomes `init(defaults:languageLoader:)`)
- [ ] In `init`: read `UserDefaults` identifier strings into `savedSourceIdentifier` / `savedTargetIdentifier` — do NOT construct `Locale` or set `selectedSource`/`selectedTarget` here
- [ ] Change `@Published var selectedSource: Locale` → `@Published var selectedSource: Locale?` (default `nil`)
- [ ] Change `@Published var selectedTarget: Locale` → `@Published var selectedTarget: Locale?` (default `nil`)
- [ ] Rename `validateOrResetLanguages()` → `validateOrRestoreLanguages()`
- [ ] Rewrite `validateOrRestoreLanguages()`:
  - Guard `!supportedLanguages.isEmpty`
  - For source: find match using `localeMatches(_:identifier:)` on `savedSourceIdentifier`; fallback to first "es" or first supported
  - For target: same for `savedTargetIdentifier`; fallback to first "en" or first supported
  - Clear `savedSourceIdentifier = nil`, `savedTargetIdentifier = nil` after resolution
- [ ] Add `private func localeMatches(_ locale: Locale, identifier: String) -> Bool`:
  - Exact `locale.identifier == identifier` check first
  - Language code prefix: `Locale(identifier: identifier).language.languageCode?.identifier == locale.language.languageCode?.identifier`
- [ ] In `loadSupportedLanguages()`: call `validateOrRestoreLanguages()` instead of old name
- [ ] If `languageLoader != nil`, use it instead of `LanguageAvailability().supportedLanguages` in `loadSupportedLanguages()`
- [ ] Build passes

---

## T2 — Update Callers of Optional `selectedSource`/`selectedTarget`

**Files**: `Features/Main/LanguagePairView.swift`, `Features/Main/AudioViewModel.swift`, `Core/Audio/AudioCoordinator.swift` (MODIFY)

### Checklist

**`LanguagePairView.swift`**:
- [ ] Update `Picker` bindings: `selectedSource` is now `Locale?` — use `Binding<Locale>` that maps through `?? Locale(identifier: "es")` display fallback, but writes back the real optional
- [ ] Disable pickers while `languagePairManager.selectedSource == nil` (languages still loading)
- [ ] Build passes

**`AudioViewModel.swift`**:
- [ ] Any reference to `languagePairManager.selectedSource!` → use guard/if-let pattern
- [ ] If `selectedSource == nil` when start is requested, show alert: "Languages are still loading, please wait"
- [ ] Build passes

**`AudioCoordinator.swift`**:
- [ ] If `start()` receives `nil` source/target locale, use sensible fallback (`Locale(identifier: "es")` / `"en"`) or throw a non-fatal error (log and continue with defaults)
- [ ] Build passes

---

## T3 — `LanguagePairManager` Tests for Language Restoration

**File**: `TranslateCallTests/LanguagePairManagerTests.swift` (MODIFY — add new test cases)

### New test cases checklist

All new tests use `languageLoader` injection to avoid depending on `LanguageAvailability`:

```swift
private let fakeLanguages: [Locale] = [
    Locale(identifier: "es-419"),   // Spanish
    Locale(identifier: "en-US"),    // English
    Locale(identifier: "fr-FR"),    // French
]
private func makeManager(defaults: UserDefaults) -> LanguagePairManager {
    LanguagePairManager(defaults: defaults, languageLoader: { self.fakeLanguages })
}
```

- [ ] `savedSourceLanguageRestoredWithPrefix` — write `"es"` to UserDefaults, init, await task yield, assert `selectedSource?.language.languageCode?.identifier == "es"`
- [ ] `savedTargetLanguageRestoredWithPrefix` — write `"en"`, assert target restores to `"en-US"`
- [ ] `exactIdentifierMatch` — write `"fr-FR"`, assert exact match to `Locale("fr-FR")`
- [ ] `unknownSavedLanguageFallsBackToDefault` — write `"xx"`, assert `selectedSource?.language.languageCode?.identifier == "es"` (first Spanish in fake list)
- [ ] `noSavedLanguageUsesDefaults` — write nothing, assert defaults are Spanish/English
- [ ] `selectedSourceNilBeforeLoadCompletes` — inspect `selectedSource` immediately after sync init (before async task yields) — assert `nil`
- [ ] Build passes, all tests green

> **Note**: To reliably test async init task completion, use `await Task.yield()` + a small sleep (`try await Task.sleep(for: .milliseconds(50))`) after `makeManager()`. The `languageLoader` closure is synchronous, so the task completes quickly.

---

## T4 — Fix `SetupManager` SCShareableContent Deduplication (B1)

**File**: `TranslateCall/Core/Setup/SetupManager.swift` (MODIFY)

### Checklist

- [ ] Add `private var captureAppsLoaded: Bool = false` property
- [ ] Add `@Published private(set) var capturePermissionDenied: Bool = false` property
- [ ] In `loadCaptureApps()`: add guard `!isLoadingCaptureApps` at top (already exists — verify it's correct)
- [ ] In `loadCaptureApps()`: add guard `!captureAppsLoaded` after the in-flight guard
- [ ] In the `do` block success path: set `captureAppsLoaded = true` after processing content and `capturePermissionDenied = false`
- [ ] In the `catch` block: detect authorization error (check `NSError.domain` for `SCStreamErrorDomain` or error description); if auth error, set `capturePermissionDenied = true`; always set `captureAppsLoaded = true` (prevent retry spam on persistent denial)
- [ ] Add `func refreshCaptureApps() async`: sets `captureAppsLoaded = false`, `capturePermissionDenied = false`, calls `await loadCaptureApps()`
- [ ] Add `func openScreenRecordingSettings()`: opens `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` via `NSWorkspace`
- [ ] Build passes

---

## T5 — Update Step3 for `refreshCaptureApps()` + Permission UI

**File**: `TranslateCall/Features/Setup/Step3_CaptureAppSelectView.swift` (MODIFY)

### Checklist

- [ ] Replace Refresh button action from `loadCaptureApps()` to `refreshCaptureApps()`:
  ```swift
  Button("Refresh") { Task { await setupManager.refreshCaptureApps() } }
  ```
- [ ] Add conditional `capturePermissionDenied` UI branch:
  ```swift
  if setupManager.capturePermissionDenied {
      VStack(spacing: 12) {
          Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(.orange)
          Text("Screen Recording permission required")
              .font(.headline)
          Text("TranslateCall needs Screen Recording permission to detect which video call apps are running.")
              .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
          Button("Open Screen Recording Settings") {
              setupManager.openScreenRecordingSettings()
          }
          .buttonStyle(.borderedProminent)
      }
      .padding()
  }
  ```
- [ ] Show this branch INSTEAD of the app list (use `if/else`)
- [ ] Build passes

---

## T6 — `SetupManager` Tests for Dedup and Permission (B1)

**File**: `TranslateCallTests/SetupManagerTests.swift` (MODIFY — add new test cases)

### New test cases checklist

> **Note**: `SCShareableContent` cannot be mocked. These tests verify the caching flags by inspecting `SetupManager` state, not by observing SCKit internals.

- [ ] `loadCaptureAppsIdempotentWhileLoading` — set `isLoadingCaptureApps` via a test hook and call `loadCaptureApps()` concurrently; verify second call returns without changing state (or use `Task` race — check `isLoadingCaptureApps` remains `true` throughout)

  > Practical approach: call `loadCaptureApps()` twice concurrently via two `async let` tasks; verify `availableCaptureApps` count is consistent (not doubled)

- [ ] `loadCaptureAppsSessionCacheSkipsSecondCall` — Since we can't mock SCKit, test via `captureAppsLoaded` flag: set `captureAppsLoaded = true` via a testable extension or test helper method, call `loadCaptureApps()`, assert `isLoadingCaptureApps` was never `true` (no loading transition)

  > Alternative: expose `captureAppsLoaded` as `internal` for testing (not `private`) and check it

- [ ] `refreshCaptureAppsResetsCacheFlag` — set `captureAppsLoaded = true`, call `refreshCaptureApps()`, assert `captureAppsLoaded = false` before SCKit is called (observe `isLoadingCaptureApps` transition)

- [ ] `capturePermissionDeniedExposedOnError` — test directly: call `openScreenRecordingSettings()` with no crash assertion (can't verify URL opening in unit tests, but verify it doesn't throw)

- [ ] Build passes, all existing + new tests green

---

## T7 — Audit and Fix `AudioCoordinator.stop()` Cleanup

**File**: `TranslateCall/Core/Audio/AudioCoordinator.swift` (AUDIT + MODIFY if needed)

### Checklist

Read `AudioCoordinator.swift` and verify `stop()` (or equivalent teardown method) contains:

- [ ] `outgoingVADTask?.cancel()` + `outgoingVADTask = nil`
- [ ] `incomingTask?.cancel()` (or equivalent incoming pipeline task) + `= nil`
- [ ] Any additional `Task` handles (e.g., from `handleOutgoingTranslation` spawned tasks) cancelled
- [ ] `outgoingCancellables.removeAll()` — empties and cancels all outgoing Combine subscriptions
- [ ] `incomingCancellables.removeAll()` — empties and cancels all incoming Combine subscriptions
- [ ] `halfDuplexCancellable = nil`
- [ ] `halfDuplexManager = nil` (or equivalent handle)
- [ ] `audioCapture.stopCapture()` called

For each missing item found:
- [ ] Add the missing cancellation/cleanup line
- [ ] Verify no strong reference cycles: factory closures in `start()` capture `[weak self]` or are non-capturing

- [ ] Build passes, existing `AudioCoordinatorTests` pass

---

## T8 — Audit and Fix `HalfDuplexManager` Cleanup

**File**: `TranslateCall/Core/Audio/HalfDuplexManager.swift` (AUDIT + MODIFY if needed)

### Checklist

Read `HalfDuplexManager.swift` and verify:

- [ ] The buffer delay `Task` (which uses `Task.sleep`) is stored as `private var bufferTask: Task<Void, Never>?`
- [ ] On `deinit` or when a new suppression starts, the previous `bufferTask?.cancel()` is called before replacing it
- [ ] `AnyCancellable` properties (the `sink` subscriptions on `isOutgoingSpeaking`/`isIncomingSpeaking`) are stored as `AnyCancellable?` or in a `Set<AnyCancellable>` — verify they auto-cancel on dealloc (Swift guarantees this)
- [ ] No `Task.detached` calls that escape ownership

For each missing item found:
- [ ] Add cancellation as needed
- [ ] Verify `Task.sleep` catch `CancellationError { return }` pattern already in place (from F4.2 notes)

- [ ] Build passes, existing `HalfDuplexManagerTests` pass

---

## T9 — CPU Baseline Measurement (Manual)

**This task is manual — no code changes unless a hotspot is found.**

### Procedure

1. Build and run TranslateCall on device (not Simulator)
2. Open Instruments → Time Profiler
3. Start a translation session (mic: built-in, output: built-in or BlackHole)
4. **Idle test**: Sit silently for 2 minutes; note CPU% in Xcode energy gauge + Instruments
5. **Active test**: Speak in bursts for 2 minutes (VAD triggers, pipeline runs); note CPU%
6. If any measurement exceeds budget (>5% idle, >15% active):
   - Open Time Profiler → Call Tree → Heavy Stack
   - Identify top frames
   - Evaluate fix: if < 1 hour effort and low risk → fix now; else → document in ROADMAP risk registry
7. Document results:
   - [ ] CPU idle: \_\_\_% (target: < 5%)
   - [ ] CPU active: \_\_\_% (target: < 15%)
   - [ ] Memory start: \_\_\_ MB
   - [ ] Memory after 30 min: \_\_\_ MB (target: growth < 10 MB)

---

## T10 — Integration + Commit

### Checklist

- [ ] Run full test suite: `xcodebuild test -scheme TranslateCall -destination "platform=macOS" CODE_SIGN_IDENTITY="-"` → `** TEST SUCCEEDED **`
  - Note: Pre-existing flaky tests (`SileroVADServiceTests/sileroVADMaxDuration`, `LanguagePairManagerTests/displayNameNonEmptyForCommonLanguage`) may need isolation — run again if they fail
- [ ] Manual smoke test:
  - [ ] Launch app: verify language picker shows correct restored languages
  - [ ] Stop and relaunch: verify same languages shown (B2 fixed)
  - [ ] Open wizard, reach Step 3: verify "Refresh" button works; no duplicate permission prompt (B1 fixed)
  - [ ] Start → Stop → Start (3 times): no crash, no audio glitch
- [ ] `git add` all modified files
- [ ] `git commit`: `"Fix F5.1 — language persistence (B2), SCKit dedup (B1), session cleanup audit"`
- [ ] Update `ROADMAP.md`: mark F5.1 as COMPLETED with date
- [ ] Update `memory/MEMORY.md`: add F5.1 key decisions (language loader injection, `captureAppsLoaded` guard, Optional Locale, CPU baseline result)

---

## Implementation Notes

### Testing `LanguagePairManager` async init

The `Task { await loadSupportedLanguages() }` launched in `init` completes asynchronously. In tests, yield control with:

```swift
let manager = makeManager(defaults: testDefaults)
// Give the init Task a chance to run (languageLoader is synchronous, so one yield suffices)
await Task.yield()
// Now selectedSource should be set
#expect(manager.selectedSource != nil)
```

If `Task.yield()` is insufficient (flaky), add `try await Task.sleep(for: .milliseconds(50))`.

### `captureAppsLoaded` visibility for tests

The flag `captureAppsLoaded` is `private`. To test without making it `internal`, use one of:
1. Make it `internal` — acceptable for small codebases
2. Test indirectly: observe `isLoadingCaptureApps` never becoming `true` on a second call
3. Add a `resetSessionCache()` method (for tests only) that clears `captureAppsLoaded`

Recommended: make it `internal` (not `public`) — test target can access it directly.

### SCStreamError authorization code

The exact error domain/code for Screen Recording denial varies by macOS version. Use a string search on `error.localizedDescription.lowercased().contains("permission")` as a reliable cross-version heuristic, rather than hardcoding an error code.

---

*End of F5.1 Tasks — Gate 3 Review Pending*
