# F3.1: TranslationBridge — Technical Design

**Feature**: Apple Translation Framework Integration (TranslationBridge pattern)
**Milestone**: M3 — Translation Core
**Status**: DRAFT — awaiting Gate 2 review
**Date**: 2026-03-08
**Prerequisites**: requirements.md (Gate 1 approved)

---

## 1. Key Design Decisions

### 1.1 `TranslationSession` is only available via `.translationTask()` — requires a bridge

Apple Translation's `TranslationSession` has no public initializer. It is exclusively provided by the closure of `.translationTask(_:action:)` attached to a SwiftUI view. This means any actor-based service that needs to translate must suspend and wait for the SwiftUI layer to deliver the session.

The bridge pattern (validated in PoC1):
1. `TranslationBridgeModel` (`@MainActor ObservableObject`) holds a queue of pending operations and a `TranslationSession.Configuration`.
2. `TranslationBridge` (SwiftUI view, invisible) observes `configuration` via `.translationTask`, receives the session, and calls back to the model.
3. `AppleTranslationService` (actor) suspends the caller via `withCheckedThrowingContinuation`, then resumes it when the bridge delivers the result.

### 1.2 `AppContainer` replaces bare `@StateObject` properties in `TranslateCallApp`

`AppleTranslationService` needs a reference to `TranslationBridgeModel` at construction time, and `AudioViewModel` needs `AppleTranslationService`. This dependency chain cannot be expressed with independent `@StateObject` declarations. An `AppContainer: @MainActor ObservableObject` constructs everything in the correct order.

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

### 1.3 `PendingOperation` enum unifies translation and preparation in one queue slot

The bridge handles two kinds of operations: `translate` (used by the pipeline) and `prepare` (triggers model download). Both require a session. A single `pendingOperation: PendingOperation?` slot covers M3's sequential use case.

```swift
enum PendingOperation {
    case translate(text: String, continuation: CheckedContinuation<String, Error>)
    case prepare(continuation: CheckedContinuation<Void, Error>)
}
```

If a second operation arrives while one is pending, the first continuation is resumed with `.bridgeUnavailable` before the new operation takes its place. This guarantees continuation is resumed exactly once.

### 1.4 `nonisolated(unsafe) private weak var model` for cross-isolation weak reference

`TranslationBridgeModel` is `@MainActor`. `AppleTranslationService` is an actor. A `weak var` to a `@MainActor` object from inside an actor would normally require `await` to access — but `weak var` requires a special pattern.

Use `nonisolated(unsafe) private weak var model: TranslationBridgeModel?` (consistent with existing project patterns for `nonisolated(unsafe)`). Capture the value before launching `Task { @MainActor in }`:

```swift
func translate(...) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        let capturedModel = model   // nonisolated(unsafe) — safe single read
        Task { @MainActor in
            guard let model = capturedModel else {
                continuation.resume(throwing: TranslationError.bridgeUnavailable)
                return
            }
            model.enqueue(.translate(text: text, continuation: continuation), from: source, to: target)
        }
    }
}
```

### 1.5 Configuration strategy: invalidate for same pair, replace for different pair

`TranslationSession.Configuration` stores the language pair. The `.translationTask` re-fires when:
- The configuration changes from `nil` to a non-nil value.
- `configuration.invalidate()` is called on the existing instance.

Strategy in `TranslationBridgeModel.enqueue`:
- First operation (or different language pair): assign a new `Configuration(source:target:)`.
- Subsequent operations with the **same** language pair: call `configuration.invalidate()`.
- This avoids unnecessary session recreation between consecutive utterances.

---

## 2. Architecture Overview

```
TranslateCallApp
  └── AppContainer (@MainActor ObservableObject)
        ├── TranslationBridgeModel (@MainActor ObservableObject)
        │     ├── pendingOperation: PendingOperation?
        │     └── @Published configuration: TranslationSession.Configuration?
        │
        └── AudioViewModel (@MainActor ObservableObject)
              └── translationService: AppleTranslationService (actor)
                    └── nonisolated(unsafe) weak var model → TranslationBridgeModel

SwiftUI hierarchy (WindowGroup ZStack):
  ├── ContentView
  └── TranslationBridge (invisible Color.clear)
        .translationTask(model.configuration) { session in
            await model.sessionFired(session)  ←── session delivered here
        }
        .environmentObject(container.translationBridgeModel)

Data flow (translate call):
  AudioViewModel.handleTranslation(text)
    → AppleTranslationService.translate(text, from:, to:)  [suspends]
      → Task @MainActor { model.enqueue(.translate, ...) }
        → configuration = new / invalidate
          → .translationTask fires → model.sessionFired(session)
            → session.translate(text) → response.targetText
              → continuation.resume(returning: translated)
                → AppleTranslationService.translate returns ✓
```

---

## 3. Type Definitions

### 3.1 `TranslationError`

```swift
// Core/Translation/TranslationService.swift
enum TranslationError: LocalizedError {
    case bridgeUnavailable
    case sessionError(Error)
    case unsupportedPair(Locale.Language, Locale.Language)

    var errorDescription: String? {
        switch self {
        case .bridgeUnavailable:
            return "Translation bridge is unavailable. Restart the app."
        case .sessionError(let e):
            return "Translation failed: \(e.localizedDescription)"
        case .unsupportedPair(let src, let tgt):
            return "Translation from \(src.minimalIdentifier) to \(tgt.minimalIdentifier) is not supported."
        }
    }
}
```

### 3.2 `TranslationService` protocol

```swift
// Core/Translation/TranslationService.swift
protocol TranslationService: AnyObject {
    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
    func prepare(source: Locale.Language, target: Locale.Language) async throws
}
```

### 3.3 `PendingOperation`

```swift
// App/TranslationBridge.swift (file-level, before TranslationBridgeModel)
enum PendingOperation {
    case translate(text: String, continuation: CheckedContinuation<String, Error>)
    case prepare(continuation: CheckedContinuation<Void, Error>)
}
```

---

## 4. `TranslationBridgeModel` — Implementation Design

```swift
// App/TranslationBridge.swift
@MainActor
final class TranslationBridgeModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?

    private var pendingOperation: PendingOperation?
    private var currentPair: (Locale.Language, Locale.Language)?

    // Called by AppleTranslationService (via Task @MainActor)
    func enqueue(_ operation: PendingOperation, from source: Locale.Language, to target: Locale.Language) {
        // Fail any existing pending operation
        if let existing = pendingOperation {
            failOperation(existing, with: TranslationError.bridgeUnavailable)
        }
        pendingOperation = operation

        let newPair = (source, target)
        if currentPair.map({ $0 == newPair.0 && $1 == newPair.1 }) == true {
            configuration?.invalidate()
        } else {
            currentPair = newPair
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    // Called by TranslationBridge view's .translationTask closure
    func sessionFired(_ session: TranslationSession) async {
        guard let op = pendingOperation else { return }
        pendingOperation = nil

        switch op {
        case .translate(let text, let continuation):
            do {
                let response = try await session.translate(text)
                continuation.resume(returning: response.targetText)
            } catch {
                continuation.resume(throwing: TranslationError.sessionError(error))
            }

        case .prepare(let continuation):
            do {
                try await session.prepareTranslation()
                continuation.resume()
            } catch {
                continuation.resume(throwing: TranslationError.sessionError(error))
            }
        }
    }

    private func failOperation(_ op: PendingOperation, with error: Error) {
        switch op {
        case .translate(_, let continuation): continuation.resume(throwing: error)
        case .prepare(let continuation):      continuation.resume(throwing: error)
        }
    }
}
```

---

## 5. `TranslationBridge` View — Implementation Design

```swift
// App/TranslationBridge.swift
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

---

## 6. `AppleTranslationService` — Implementation Design

```swift
// Core/Translation/AppleTranslationService.swift
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

---

## 7. `TranslateCallApp` Update

```swift
// App/TranslateCallApp.swift
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

`AppContainer` is new file `TranslateCall/App/AppContainer.swift`.

---

## 8. File Structure

```
TranslateCall/
├── App/
│   ├── AppContainer.swift              // NEW — wires the object graph
│   ├── TranslationBridge.swift         // REWRITE — PendingOperation + TranslationBridgeModel + TranslationBridge view
│   └── TranslateCallApp.swift          // UPDATE — @StateObject container, inject translationBridgeModel
└── Core/
    └── Translation/                    // NEW directory
        ├── TranslationService.swift    // TranslationService protocol + TranslationError
        └── AppleTranslationService.swift // actor implementation
```

---

## 9. Threading and Swift 6 Compliance

| Concern | Solution |
|---------|---------|
| `TranslationBridgeModel` is `@MainActor` | All methods called via `Task { @MainActor in }` from actor context |
| Weak reference to `@MainActor` class from actor | `nonisolated(unsafe) private weak var model` — captured before Task, read once |
| Continuation safety (exactly 1 resume) | `pendingOperation = nil` before calling session; existing operation failed before replacement |
| `TranslationSession.Configuration` mutability | `@Published var` on `@MainActor` — mutations on main actor only |
| `sessionFired` called from `.translationTask` closure | Closure is `async`, SwiftUI calls it on `@MainActor` (`.translationTask` is a SwiftUI modifier) |

---

## 10. Error Handling

| Error | Behavior |
|-------|---------|
| `model` deallocated when `translate()` called | `continuation.resume(throwing: .bridgeUnavailable)` |
| Second operation arrives while first is pending | First resumed with `.bridgeUnavailable`, new operation enqueued |
| `session.translate()` throws | Wrapped in `.sessionError(e)`, continuation resumed with error |
| `session.prepareTranslation()` throws | Wrapped in `.sessionError(e)`, continuation resumed with error |
| `.unsupportedPair` | Thrown by LanguagePairManager check before enqueuing (F3.2) |

---

## 11. Future Extensibility (M4)

- **Batch translation**: Replace single `PendingOperation` with an array and use `session.translate(batch:)`.
- **Concurrent bidirectional**: Two `TranslationBridgeModel` instances with different configurations (one per direction).
- **Configuration caching**: The `currentPair` check already minimizes session recreation overhead.

---

*Gate 2 Review: human must approve this document before tasks.md is written.*
