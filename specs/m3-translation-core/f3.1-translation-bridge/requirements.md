# F3.1: TranslationBridge — Requirements

**Feature**: Apple Translation Framework Integration (TranslationBridge pattern)
**Milestone**: M3 — Translation Core
**Status**: DRAFT — awaiting Gate 1 review
**Date**: 2026-03-08
**Author**: Claude + Sergio

---

## 1. Context

Apple's Translation framework requires a SwiftUI view with a `.translationTask()` modifier attached to an active window. `TranslationSession` is provided exclusively through the task closure — there is no way to construct one directly. This means translation cannot be initiated from a non-SwiftUI actor without a bridge.

PoC1 measured ~12 ms steady-state latency (first call slower: model download + session warm-up). The `TranslationBridge` pattern — a hidden `Color.clear` view wired to the app's ZStack — was validated as the correct approach.

The stub `TranslateCall/App/TranslationBridge.swift` exists but has no logic. `TranslateCallApp.swift` already places `TranslationBridge()` inside the `WindowGroup` ZStack alongside `ContentView()`.

---

## 2. Definitions

| Term | Definition |
|------|-----------|
| **TranslationBridge** | Invisible SwiftUI view that anchors `.translationTask()` in the window hierarchy |
| **TranslationBridgeModel** | `@MainActor ObservableObject` that mediates translation requests between actors and the SwiftUI bridge |
| **TranslationService** | Protocol for performing text translation; implemented by `AppleTranslationService` |
| **TranslationSession** | Apple framework object provided by `.translationTask()`; performs actual inference |
| **TranslationSession.Configuration** | Struct holding source/target language pair; `invalidate()` re-triggers the task |
| **Pending request** | A queued translate call, holding a `CheckedContinuation<String, Error>` awaiting the session response |

---

## 3. Functional Requirements

### 3.1 TranslationService Protocol

**REQ-TB-01**: The system SHALL expose a `TranslationService` protocol with a single async method:
```swift
func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
```

**REQ-TB-02**: `TranslationService` SHALL be a Swift protocol (not a class), enabling test doubles and future alternative implementations.

**REQ-TB-03**: `TranslationService` SHALL conform to `AnyObject` so it can be held weakly by the bridge model.

### 3.2 TranslationBridgeModel

**REQ-TB-10**: `TranslationBridgeModel` SHALL be a `@MainActor final class ObservableObject` that acts as the shared state between `TranslationBridge` (SwiftUI) and `AppleTranslationService` (actor).

**REQ-TB-11**: `TranslationBridgeModel` SHALL expose a `@Published var configuration: TranslationSession.Configuration?` that `TranslationBridge` observes to arm the `.translationTask()` modifier.

**REQ-TB-12**: `TranslationBridgeModel` SHALL expose an `enqueue(text: String, from: Locale.Language, to: Locale.Language, continuation: CheckedContinuation<String, Error>)` method that:
1. Stores the pending request (text + continuation).
2. If no configuration is active, creates a new `TranslationSession.Configuration(source:target:)` and assigns it.
3. If a configuration with the same language pair already exists, calls `configuration.invalidate()` to re-trigger the task.

**REQ-TB-13**: WHEN the `.translationTask` closure fires with a `TranslationSession` THEN `TranslationBridgeModel` SHALL call `session.translate(pendingText)`, extract `response.targetText`, and resume the stored continuation with the result.

**REQ-TB-14**: IF `session.translate()` throws THEN `TranslationBridgeModel` SHALL resume the continuation with the error.

**REQ-TB-15**: `TranslationBridgeModel` SHALL handle at most one pending request at a time in M3 (sequential pipeline). Multiple in-flight requests are out of scope until M4.

### 3.3 TranslationBridge View

**REQ-TB-20**: `TranslationBridge` SHALL be rewritten to hold a reference to `TranslationBridgeModel` via `@EnvironmentObject`.

**REQ-TB-21**: `TranslationBridge.body` SHALL attach `.translationTask(model.configuration) { session in ... }` to the `Color.clear` frame, delegating all logic to `TranslationBridgeModel`.

**REQ-TB-22**: `TranslationBridge` SHALL NOT store any state or logic itself — it is a pure SwiftUI adapter.

**REQ-TB-23**: `TranslateCallApp` SHALL inject `TranslationBridgeModel` as an `@EnvironmentObject` on the `WindowGroup`, alongside the existing `AudioViewModel`.

### 3.4 AppleTranslationService

**REQ-TB-30**: `AppleTranslationService` SHALL be an `actor` conforming to `TranslationService`.

**REQ-TB-31**: WHEN `translate(text:from:to:)` is called THEN `AppleTranslationService` SHALL call `await model.enqueue(...)` using `withCheckedThrowingContinuation`, suspending the caller until the bridge delivers the result.

**REQ-TB-32**: `AppleTranslationService` SHALL hold a `weak` reference to `TranslationBridgeModel` (passed at `init`) to avoid retain cycles with the SwiftUI hierarchy.

**REQ-TB-33**: IF `TranslationBridgeModel` has been deallocated WHEN `translate()` is called THEN `AppleTranslationService` SHALL throw a `TranslationError.bridgeUnavailable` error.

**REQ-TB-34**: `AppleTranslationService` SHALL be the only type injected into `AudioViewModel` — the bridge model is an implementation detail.

### 3.5 Error Handling

**REQ-TB-40**: A `TranslationError` enum SHALL define:
- `.bridgeUnavailable` — model deallocated
- `.sessionError(Error)` — `TranslationSession` threw
- `.unsupportedPair(Locale.Language, Locale.Language)` — pair not downloadable

**REQ-TB-41**: `TranslationError` SHALL conform to `LocalizedError` with user-readable descriptions.

---

## 4. Non-Functional Requirements

### 4.1 Latency

**REQ-NFR-01**: Steady-state translation latency (warm session, model installed) SHALL be ≤ 50 ms, consistent with the PoC1 measurement of ~12 ms plus bridge overhead.

**REQ-NFR-02**: First-call latency (cold session, model downloaded) is not bounded; the system SHALL not block the UI thread during this warm-up.

### 4.2 Thread Safety

**REQ-NFR-03**: `TranslationBridgeModel` is `@MainActor` — all calls to it from non-MainActor contexts SHALL use `await`.

**REQ-NFR-04**: The `CheckedContinuation` MUST be resumed exactly once (never zero, never twice). Implementation SHALL ensure this even in error paths.

### 4.3 Privacy

**REQ-NFR-05**: All translation inference runs on-device (Apple Translation models). No text SHALL be sent to any server.

### 4.4 Swift 6 / Concurrency

**REQ-NFR-06**: All new types SHALL compile with Swift 6 strict concurrency (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) without warnings.

**REQ-NFR-07**: `TranslationBridgeModel` MUST be `@MainActor`; `AppleTranslationService` MUST be an `actor`. Cross-boundary calls via `await`.

---

## 5. Constraints

| Constraint | Value |
|-----------|-------|
| Platform | macOS 15.0+ |
| Framework | Translation (Apple, requires SwiftUI context) |
| Language | Swift 6.0 strict concurrency |
| Session access | Only via `.translationTask()` SwiftUI modifier |
| Concurrency | `@MainActor` default isolation active |
| Existing stub | `TranslateCall/App/TranslationBridge.swift` (to be replaced) |
| App entry point | `TranslateCallApp.swift` (ZStack already includes `TranslationBridge()`) |

---

## 6. Out of Scope (F3.1)

- Language pair selection UI — F3.2
- Language availability checking / model download — F3.2
- Full pipeline wiring (STT → translate → TTS) — F3.3
- Batch translation — M4+
- Bidirectional (two simultaneous language pairs) — M4

---

## 7. Acceptance Criteria (Gate 4 — Validation)

| ID | Criterion | Test |
|----|-----------|------|
| AC-01 | `AppleTranslationService.translate(text:from:to:)` returns a non-empty string for a known pair (e.g. EN→ES "hello" → "hola") | `testTranslateEnglishToSpanish()` |
| AC-02 | Calling `translate()` with a language pair not on device triggers `prepareTranslation()` sheet (manual validation) | Manual test |
| AC-03 | `translate()` called after model deallocates throws `.bridgeUnavailable` | `testBridgeUnavailableError()` |
| AC-04 | Continuation is resumed exactly once per call (no double-resume crash, no hang) | `testContinuationResumedOnce()` |
| AC-05 | 5 sequential translations complete without error or session invalidation | `testSequentialTranslations()` |
| AC-06 | All code compiles with 0 warnings under Swift 6 strict concurrency | CI build check |

---

## 8. Open Questions (to resolve before design.md)

1. **Configuration re-use vs. per-request**: Should a single `TranslationSession.Configuration` be created for the app lifetime (invalidated per request), or a new one per language-pair change?
   - **Preferred**: one configuration per language pair, invalidated per request within the same pair. New configuration when pair changes.

2. **Weak vs. strong reference to TranslationBridgeModel in AppleTranslationService**: Weak avoids retain cycles but adds `guard let model = model else` boilerplate.
   - **Preferred**: Weak reference; bridge model is owned by `@StateObject` in `TranslateCallApp`.

3. **Where does `TranslationBridgeModel` live in the object graph?**
   - Option A: `@StateObject` in `TranslateCallApp`, passed via `@EnvironmentObject`
   - Option B: Owned by `AudioViewModel`
   - **Preferred**: Option A — keeps the bridge as an app-level concern, decoupled from the audio pipeline.

4. **Pending request queue for M3**: Single pending request (last wins) vs. FIFO queue of 1?
   - **Preferred**: Queue of 1. If a second request arrives before the bridge fires, the first continuation is failed with `.bridgeUnavailable` and the new request takes its place.

---

*Gate 1 Review: human must approve this document before design.md is written.*
