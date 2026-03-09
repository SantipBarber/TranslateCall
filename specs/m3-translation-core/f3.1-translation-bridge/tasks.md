# F3.1: TranslationBridge — Tasks

**Feature**: Apple Translation Framework Integration
**Milestone**: M3 — Translation Core
**Status**: DRAFT — awaiting Gate 3 review
**Date**: 2026-03-08
**Prerequisites**: design.md (Gate 2 approved)

---

## Dependency Order

```
T1 (types + protocol)
  └──▶ T2 (TranslationBridgeModel + Bridge view)
         └──▶ T3 (AppleTranslationService)
                └──▶ T4 (AppContainer + TranslateCallApp)
                       └──▶ T5 (tests)
```

All tasks follow TDD: write failing test → implement → green → refactor.

---

## T1 — Define `TranslationError` and `TranslationService` protocol

**Maps to**: REQ-TB-01, REQ-TB-02, REQ-TB-03, REQ-TB-40, REQ-TB-41
**File**: `TranslateCall/Core/Translation/TranslationService.swift` *(new directory + file)*
**Depends on**: nothing

### What to implement

1. `TranslationError` enum:
   ```swift
   enum TranslationError: LocalizedError {
       case bridgeUnavailable
       case sessionError(Error)
       case unsupportedPair(Locale.Language, Locale.Language)

       var errorDescription: String? { ... }
   }
   ```

2. `TranslationService` protocol:
   ```swift
   protocol TranslationService: AnyObject {
       func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
       func prepare(source: Locale.Language, target: Locale.Language) async throws
   }
   ```

### Tests (RED first) — `TranslateCallTests/TranslationBridgeTests.swift` *(new file)*

- `testTranslationErrorBridgeUnavailableHasDescription()` — assert `TranslationError.bridgeUnavailable.errorDescription` is non-nil and non-empty
- `testTranslationErrorSessionErrorHasDescription()` — wrap a dummy error, assert description includes it
- `testTranslationErrorUnsupportedPairHasDescription()` — assert description includes both language identifiers

### Done when
- File compiles with zero warnings under Swift 6 strict concurrency
- Tests green

---

## T2 — Implement `TranslationBridgeModel` and rewrite `TranslationBridge` view

**Maps to**: REQ-TB-10 through REQ-TB-23
**Files**: `TranslateCall/App/TranslationBridge.swift` *(rewrite)* — contains `PendingOperation` enum, `TranslationBridgeModel` class, and `TranslationBridge` view
**Depends on**: T1

### What to implement

1. `PendingOperation` enum (file-level, before `TranslationBridgeModel`):
   ```swift
   enum PendingOperation {
       case translate(text: String, continuation: CheckedContinuation<String, Error>)
       case prepare(continuation: CheckedContinuation<Void, Error>)
   }
   ```

2. `TranslationBridgeModel: @MainActor final class ObservableObject`:
   - `@Published var configuration: TranslationSession.Configuration?`
   - `private var pendingOperation: PendingOperation?`
   - `private var currentPair: (Locale.Language, Locale.Language)?`
   - `func enqueue(_ operation: PendingOperation, from:to:)`:
     - Fail any existing `pendingOperation` with `.bridgeUnavailable`
     - Store new operation
     - If same language pair: `configuration?.invalidate()`
     - If different pair or first time: assign new `TranslationSession.Configuration(source:target:)`, update `currentPair`
   - `func sessionFired(_ session: TranslationSession) async`:
     - Guard `pendingOperation != nil`, set to `nil`
     - Switch on operation type:
       - `.translate`: call `session.translate(text)`, resume continuation with `response.targetText` or error
       - `.prepare`: call `session.prepareTranslation()`, resume continuation or error
   - `private func failOperation(_:with:)` helper that resumes the continuation with an error

3. `TranslationBridge: View` (rewrite existing stub):
   ```swift
   struct TranslationBridge: View {
       @EnvironmentObject private var model: TranslationBridgeModel
       var body: some View {
           Color.clear
               .frame(width: 0, height: 0)
               .translationTask(model.configuration) { session in
                   await model.sessionFired(session)
               }
       }
   }
   ```

### Tests

- `testEnqueueSetsConfiguration()` — call `enqueue(.translate(...))`, assert `configuration != nil`
- `testEnqueueSamePairInvalidates()` — enqueue twice with same pair, assert `configuration` is same object (not replaced), `invalidate()` was effectively called
- `testEnqueueDifferentPairReplacesConfiguration()` — enqueue EN→ES, then EN→FR, assert `configuration` is new instance
- `testSecondEnqueueFailsFirst()` — enqueue request A (hold continuation), enqueue request B before session fires; assert A's continuation throws `.bridgeUnavailable`
- `testFailOperationResumesTranslateContinuation()` — call `failOperation(.translate(_, cont), with: error)`, assert continuation received the error

### Done when
- `TranslationBridgeModel` and `TranslationBridge` compile with zero warnings
- Tests green

---

## T3 — Implement `AppleTranslationService` actor

**Maps to**: REQ-TB-30 through REQ-TB-34
**File**: `TranslateCall/Core/Translation/AppleTranslationService.swift` *(new)*
**Depends on**: T1, T2

### What to implement

```swift
actor AppleTranslationService: TranslationService {
    nonisolated(unsafe) private weak var model: TranslationBridgeModel?

    init(model: TranslationBridgeModel) {
        self.model = model
    }

    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let capturedModel = model
            Task { @MainActor in
                guard let model = capturedModel else {
                    continuation.resume(throwing: TranslationError.bridgeUnavailable)
                    return
                }
                model.enqueue(.translate(text: text, continuation: continuation), from: source, to: target)
            }
        }
    }

    func prepare(source: Locale.Language, target: Locale.Language) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let capturedModel = model
            Task { @MainActor in
                guard let model = capturedModel else {
                    continuation.resume(throwing: TranslationError.bridgeUnavailable)
                    return
                }
                model.enqueue(.prepare(continuation: continuation), from: source, to: target)
            }
        }
    }
}
```

### Tests

- `testTranslateThrowsBridgeUnavailableWhenModelDeallocated()`:
  - Create `AppleTranslationService` with a weak model
  - Let model deallocate
  - Call `translate()`, assert throws `.bridgeUnavailable`
- `testPrepareThrowsBridgeUnavailableWhenModelDeallocated()` — same as above for `prepare()`
- `testTranslateEnqueuesOnMainActor()` — verify `model.enqueue` is called (using a spy/mock `TranslationBridgeModel` subclass or checking `configuration != nil` after calling `translate()`)

> **Note**: Full end-to-end test (actual translation result) requires the Translation framework session and is a manual / integration test (AC-01).

### Done when
- `AppleTranslationService` conforms to `TranslationService` with zero warnings
- Unit tests green (bridge-unavailable and enqueue paths)

---

## T4 — Implement `AppContainer` and update `TranslateCallApp`

**Maps to**: REQ-TB-20 (TranslateCallApp update), design section 7
**Files**:
- `TranslateCall/App/AppContainer.swift` *(new)*
- `TranslateCall/App/TranslateCallApp.swift` *(update)*
**Depends on**: T2, T3

### What to implement

1. `AppContainer.swift`:
   ```swift
   @MainActor
   final class AppContainer: ObservableObject {
       let translationBridgeModel: TranslationBridgeModel
       let audioViewModel: AudioViewModel

       init() {
           let bridge = TranslationBridgeModel()
           let lpm = LanguagePairManager()
           let ts = AppleTranslationService(model: bridge)
           translationBridgeModel = bridge
           audioViewModel = AudioViewModel(translationService: ts, languagePairManager: lpm)
       }
   }
   ```
   > `LanguagePairManager` is imported from F3.2. Add `LanguagePairManager()` stub if F3.2 is not yet merged — replace when F3.2 lands.

2. `TranslateCallApp.swift` — replace existing `@StateObject` body:
   ```swift
   @main
   struct TranslateCallApp: App {
       @StateObject private var container = AppContainer()

       var body: some Scene {
           WindowGroup {
               ZStack {
                   ContentView()
                   TranslationBridge()
               }
               .environmentObject(container.audioViewModel)
               .environmentObject(container.translationBridgeModel)
           }
           .windowResizability(.contentSize)
       }
   }
   ```

### Done when
- App builds and launches without crash
- `TranslationBridge` is in the view hierarchy (verify via Xcode View Debugger — `Color.clear` frame at (0,0))
- Console shows no `environmentObject` missing warnings

---

## T5 — Tests

**Maps to**: All REQ-TB + AC-01 through AC-06
**File**: `TranslateCallTests/TranslationBridgeTests.swift`
**Depends on**: T1–T4

### Additional tests

- `testSequentialTranslations()` — call `translate()` five times sequentially via `AppleTranslationService` with a mock bridge model that immediately returns a stub result; assert all five complete without error or hang (AC-05)
- `testContinuationResumedExactlyOnce()` — instrument `CheckedContinuation` wrapper; call `sessionFired` twice for the same operation; assert no `preconditionFailure` or double-resume (AC-04)
- `testAppContainerWiresObjects()` — instantiate `AppContainer`, assert `audioViewModel.translationServiceIsSet` (via a test-only accessor) and `translationBridgeModel` is non-nil (AC-06 build check)

### Integration test (manual)

> AC-01: Say a phrase in English with source=EN, target=ES.
> Expected: `latestTranslation` contains Spanish text within 2500ms.
> Run on device — requires Apple Translation models downloaded.

### Done when
- All unit tests green
- AC-01 through AC-06 covered by test or documented as manual integration

---

## Task Summary

| Task | File(s) | Effort | Blocks |
|------|---------|--------|--------|
| T1 — Types + protocol | `Core/Translation/TranslationService.swift` | XS | T2, T3 |
| T2 — BridgeModel + Bridge view | `App/TranslationBridge.swift` | M | T3, T4 |
| T3 — AppleTranslationService | `Core/Translation/AppleTranslationService.swift` | S | T4 |
| T4 — AppContainer + App | `App/AppContainer.swift`, `App/TranslateCallApp.swift` | S | T5 |
| T5 — Tests | `TranslateCallTests/TranslationBridgeTests.swift` | S | — |

---

*Gate 3 Review: human must approve this document before implementation begins.*
