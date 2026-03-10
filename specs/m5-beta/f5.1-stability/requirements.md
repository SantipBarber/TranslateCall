# F5.1 – Stability & Bug Fixes

**Milestone**: M5 – Beta Release
**Feature**: F5.1 – Stability & Bug Fixes
**Status**: DRAFT – Pending Gate 1 Review
**Date**: 2026-03-10
**Depends on**: M4 (completed)

---

## 1. Context & Motivation

M4 delivered a complete bidirectional translation pipeline with setup wizard and video call integration. Manual testing revealed two critical bugs that must be fixed before distributing to beta testers:

1. **B1 – Screen Recording permission re-prompted**: `SCShareableContent.current` is called from multiple code paths (`SetupWizardView` `.task`, Step3 refresh button, possibly ContentView), causing macOS to show the Screen Recording permission dialog more than once per session in some scenarios.

2. **B2 – Language selection not persisted**: `LanguagePairManager` saves language choices to `UserDefaults`, but an async validation task called during `init` can overwrite persisted choices with defaults before the UI renders, making language selection feel unreliable between app launches. Root cause: `validateOrResetLanguages()` runs after `loadSupportedLanguages()` and resets any saved `Locale` that does not compare equal to the objects returned by `LanguageAvailability().supportedLanguages` (e.g., saved `"es"` vs supported `"es-419"`).

Additionally, M5 establishes minimum resource constraints for sustained production use (CPU, memory growth) and validates that all session lifecycle objects are released correctly between start/stop cycles.

---

## 2. Scope

**In scope for F5.1**:
- Fix B1: Deduplicate `SCShareableContent.current` calls; prevent concurrent or redundant calls that trigger permission prompts
- Fix B2: Fix `LanguagePairManager` init race so persisted language selections survive across launches
- Memory audit: verify Combine cancellable cleanup in `AudioCoordinator.stop()` and `HalfDuplexManager.deinit`
- CPU baseline: manual measurement with Instruments; document result; fix only if above budget

**Out of scope for F5.1**:
- New features or UI changes (F5.2)
- Distribution packaging (F5.3)
- Crash reporting framework (no external dependencies in M5)
- New performance instrumentation shown to users (future milestone)

---

## 3. Functional Requirements

### 3.1 Screen Recording Permission Deduplication (B1)

**FR-5.1.1** WHEN `SetupManager.loadCaptureApps()` is called AND a previous call is already in progress THEN the second call SHALL return immediately without calling `SCShareableContent.current` again.

**FR-5.1.2** WHEN `SetupManager.loadCaptureApps()` has already succeeded in the current app session AND no explicit refresh was requested THEN subsequent calls SHALL reuse the cached result without calling `SCShareableContent.current` again.

**FR-5.1.3** WHEN the user explicitly requests a refresh (e.g., taps "Refresh" in Step 3 of the wizard) THEN `SetupManager` SHALL discard the session cache and call `SCShareableContent.current` exactly once.

**FR-5.1.4** WHEN `SCShareableContent.current` throws an authorization error THEN `SetupManager` SHALL set a `capturePermissionDenied` flag to `true` and expose a method to open System Settings → Privacy → Screen Recording.

**FR-5.1.5** WHEN `capturePermissionDenied` is `true` THEN Step 3 of the setup wizard SHALL show a "Grant Permission" button that opens Screen Recording settings, rather than an empty list.

### 3.2 Language Persistence Fix (B2)

**FR-5.1.6** WHEN the app launches AND a source language identifier was previously saved to `UserDefaults` THEN `LanguagePairManager` SHALL restore that language as `selectedSource` after `supportedLanguages` is loaded, using flexible locale matching (language code prefix match, not strict identifier equality).

**FR-5.1.7** WHEN the app launches AND a target language identifier was previously saved to `UserDefaults` THEN `LanguagePairManager` SHALL restore that language as `selectedTarget` after `supportedLanguages` is loaded, using the same flexible matching.

**FR-5.1.8** IF a persisted language identifier has no match in `supportedLanguages` (truly unsupported) THEN `LanguagePairManager` SHALL silently fall back to the language default (Spanish → English), preserving existing behavior.

**FR-5.1.9** WHEN `loadSupportedLanguages()` has not yet completed THEN `LanguagePairManager` SHALL NOT publish any language value to `@Published` subscribers; `selectedSource` and `selectedTarget` SHALL remain unset (no transient default flicker).

**FR-5.1.10** WHEN the user changes language in the UI THEN `LanguagePairManager` SHALL persist the new selection immediately to `UserDefaults` (existing behavior, unchanged).

### 3.3 Memory Stability

**FR-5.1.11** WHEN a translation session is stopped via `AudioCoordinator.stop()` THEN all `AnyCancellable` subscriptions created during `start()` SHALL be cancelled and deallocated.

**FR-5.1.12** WHEN `AudioCoordinator.stop()` is called THEN all active `Task` handles it owns (VAD loops, incoming pipeline, half-duplex) SHALL be cancelled and set to `nil`.

**FR-5.1.13** WHEN `HalfDuplexManager` is released THEN its Combine subscriptions and any pending `Task.sleep` buffer task SHALL be cancelled before deallocation.

**FR-5.1.14** AFTER 5 consecutive start/stop cycles the app SHALL NOT crash and memory usage SHALL NOT grow unboundedly (validated manually; no automated test).

### 3.4 CPU Budget

**FR-5.1.15** WHILE a translation session is idle (VAD detecting silence) the app SHALL consume less than 5% CPU on Apple M-series hardware.

**FR-5.1.16** WHILE a translation session is actively processing speech the app SHALL consume less than 15% CPU on average on Apple M-series hardware.

**FR-5.1.17** IF any CPU hotspot above 15% sustained is identified via Instruments THEN it SHALL be investigated and fixed as part of F5.1 if a low-risk optimization is available; otherwise documented in ROADMAP for a future milestone.

---

## 4. Non-Functional Requirements

**NFR-5.1.1** All fixes SHALL maintain backward compatibility with existing `UserDefaults` keys (`tlk.source.language`, `tlk.target.language`, `tlk.setupCompleted`, `tlk.captureApp.bundleID`).

**NFR-5.1.2** B1 and B2 fixes SHALL NOT require new entitlements or permissions.

**NFR-5.1.3** All existing tests SHALL continue to pass after bug fixes.

**NFR-5.1.4** New unit tests SHALL be added for B1 (dedup logic) and B2 (language restore); they shall run in the existing `xcodebuild test` pipeline without device or SCKit dependency.

---

## 5. Constraints

**C-5.1.1** `SCShareableContent` is a final class and cannot be mocked. B1 tests SHALL verify the caching/guard logic via `SetupManager` state inspection, not by observing SCKit calls directly.

**C-5.1.2** CPU and memory validation SHALL be performed manually with Instruments (Time Profiler, Leaks, Allocations) — not via unit tests. Results SHALL be documented in the commit message and memory file.

**C-5.1.3** `LanguageAvailability().supportedLanguages` cannot be mocked (Apple private framework). B2 tests SHALL inject a list of fake `Locale` objects via a testable `LanguagePairManager` initializer that accepts a custom language loader closure.

---

## 6. Acceptance Criteria

| ID | Criterion | Test Method |
|----|-----------|-------------|
| AC-5.1.1 | Second concurrent `loadCaptureApps()` call returns without executing | Unit: verify `captureAppsLoaded` / `isLoadingCaptureApps` guards |
| AC-5.1.2 | Second sequential call reuses cache (no new SCKit call) | Unit: call once (mock succeeds), call again — assert loading state never changes |
| AC-5.1.3 | `refreshCaptureApps()` discards cache and re-fetches | Unit: call load, call refresh, assert `isLoadingCaptureApps` transitions again |
| AC-5.1.4 | Source language `"es"` restored from UserDefaults | Unit: write `"es"`, init with fake languages including `Locale("es-419")`, assert `selectedSource.languageCode == "es"` |
| AC-5.1.5 | Target language `"en"` restored from UserDefaults | Same for target |
| AC-5.1.6 | Unknown saved language falls back to first supported | Unit: write `"xx"`, assert `selectedSource` is first fake language |
| AC-5.1.7 | No language published before `loadSupportedLanguages()` completes | Unit: inspect `selectedSource` immediately after init (before task resumes) — assert `nil` or no change signal |
| AC-5.1.8 | `stop()` cancels all tasks and empties cancellable sets | Unit: start coordinator with mocks, stop, assert task handles nil |
| AC-5.1.9 | 5 start/stop cycles produce no crash | Manual |
| AC-5.1.10 | CPU < 15% during active speech | Instruments manual measurement |

---

## 7. Open Questions

| # | Question | Owner | Status |
|---|----------|-------|--------|
| OQ-1 | Should `loadCaptureApps()` auto-refresh every time the setup wizard is re-opened (after initial completion)? | Engineering | **Tentative: yes — call `refreshCaptureApps()` on wizard `.onAppear` to pick up newly launched apps** |
| OQ-2 | Should `selectedSource`/`selectedTarget` remain `nil` (optional) until languages load, or have a sentinel "loading" state? | UX | **Tentative: keep `Optional<Locale>` and suppress UI picker until loaded — avoids flicker** |
| OQ-3 | Is Instruments-based CPU measurement sufficient for M5 acceptance? | Engineering | **Yes — runtime CPU metrics deferred to M6** |

---

## 8. Dependencies

| Component | Dependency Type | Notes |
|-----------|----------------|-------|
| F4.3 `SetupManager` | Modify | B1 fix adds caching + `refreshCaptureApps()` + `capturePermissionDenied` |
| F3.2 `LanguagePairManager` | Modify | B2 fix defers Locale resolution until after `loadSupportedLanguages()` |
| F4.1 `AudioCoordinator` | Audit + possibly Modify | Verify/fix cancellable cleanup in `stop()` |
| F4.2 `HalfDuplexManager` | Audit + possibly Modify | Verify task/subscription cleanup |

---

*End of F5.1 Requirements — Gate 1 Review Pending*
