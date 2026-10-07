# F8.5.4 — Translation — Design

> Status: DRAFT — pending user review (2026-10-07)
> Requirements: `requirements.md` (REQ-TR-*, D-1…D-7)

## 1. Overview

```
STT result ──► AudioCoordinator.handle{Outgoing,Incoming}Translation
                     │ await service.translate(text, from, to)
                     ▼
            AppleTranslationService (Sendable, holds its bridge model)
                     │ await model.translate(text, source, target)
                     ▼
     TranslationBridgeModel (@MainActor, one per direction)
        FIFO queue · per-request timeout · one retry · rebuild
                     │ configuration (changes only on pair change / warm-up / rebuild)
                     ▼
     TranslationBridge view ── .translationTask(config) { session in
                                    await model.run(session: session) }   ← stays alive
                     ▲
     TranslationHostWindow (off-screen NSWindow, owned by AppContainer)

LanguagePairView ── .translationTask(downloadConfig) { prepareTranslation() }   (visible window)
```

Units and their single purpose:

| Unit | Purpose | Depends on |
|------|---------|-----------|
| `TranslationSessioning` (protocol) | The one call the bridge needs from a session: `translate(_:) async throws -> String`. `TranslationSession` conforms via extension. | Translation |
| `TranslationBridgeModel` | Queue, timeout, retry, session lifecycle for one direction. | `TranslationSessioning`, `Clock` |
| `TranslationBridge` (view) | Anchors `.translationTask` and hands the session to `model.run`. | SwiftUI, model |
| `TranslationHostWindow` | Keeps both bridge views alive off-screen for the app's lifetime. | AppKit |
| `AppleTranslationService` | `TranslationService` façade over a bridge model + `LanguageAvailability`. | model |
| `AudioCoordinator` (changed) | Warm-up at start; maps per-sentence errors to notice vs alert. | services |
| `LanguagePairView` (changed) | User-initiated download via its own `.translationTask`. | Translation |

## 2. TranslationBridgeModel

### 2.1 State

```swift
@MainActor
final class TranslationBridgeModel: ObservableObject {
    @Published private(set) var configuration: TranslationSession.Configuration?

    struct Pair: Equatable { let source: Locale.Language; let target: Locale.Language }

    private final class Request {
        let id: UInt64
        let text: String
        let pair: Pair
        var attempts = 0                       // 0 = first try, 1 = retry
        var continuation: CheckedContinuation<String, Error>?   // nil once resumed (exactly-once)
        var timeoutTask: Task<Void, Never>?
    }

    private var queue: [Request] = []          // FIFO; head may be in flight
    private var inFlight: Request?
    private var livePair: Pair?                // pair of `configuration`
    private var sessionWaiter: CheckedContinuation<Void, Never>?   // run loop parked on empty queue

    init(timeout: Duration = .seconds(5), clock: any Clock<Duration> = ContinuousClock())
}
```

### 2.2 Public API

- `func translate(_ text: String, from: Locale.Language, to: Locale.Language) async throws -> String`
  Wrapped in `withTaskCancellationHandler`; appends a `Request`, starts its timeout task, calls `ensureSession(for: pair)`, wakes the run loop. Cancellation removes the request (if not in flight) and resumes it with `CancellationError` (REQ-TR-13).
- `func warmUp(from:to:)` — `ensureSession(for:)` only; no request (REQ-TR-05). Non-async, returns at once.
- `func run(session: some TranslationSessioning) async` — called by the view (§3).

### 2.3 Session lifecycle

`ensureSession(for pair)`:
- `livePair == pair` and `configuration != nil` → nothing.
- otherwise → `livePair = pair; configuration = .init(source:target:)` (SwiftUI cancels the old task, starts a new one).

`rebuild()` → `configuration?.invalidate()` (rare path: failure/timeout only).

The queue holds requests of any pair; the run loop serves the head only if it matches `livePair`. When the head's pair differs, `ensureSession(for: head.pair)` is called and the loop returns (its task is about to be cancelled). Per direction the pair changes only between calls, so this is not a hot path (REQ-TR-04).

### 2.4 Run loop

```swift
func run(session: some TranslationSessioning) async {
    while !Task.isCancelled {
        guard let head = queue.first else { await parkUntilWork(); continue }   // cancellation-aware
        guard head.pair == livePair else { ensureSession(for: head.pair); return }
        inFlight = head
        do {
            let text = try await session.translate(head.text)
            complete(head, with: .success(text))          // no-op if already resumed (timed out)
        } catch is CancellationError {
            // session replaced mid-flight: leave head queued for the next session (REQ-TR-03)
        } catch {
            fail(head, error)                             // retry or throw, §2.5
        }
        if inFlight === head { inFlight = nil }
    }
}
```

`complete` removes the request from `queue`, cancels its timeout task, resumes the continuation and nils it. A late answer from a session that was already given up on finds `continuation == nil` and is ignored. `parkUntilWork` stores `sessionWaiter`; `translate`/`ensureSession` resume it; a cancellation handler resumes it too, so no continuation is left hanging (NFR-TR-02).

### 2.5 Timeout and retry (D-1, D-5)

Each request's timeout task sleeps `timeout` on the injected clock, then on the main actor:

- `attempts == 0` → `attempts = 1`, move the request to the queue head, restart its timeout, `rebuild()`.
- `attempts == 1` → remove and resume with `TranslationError.timedOut`.

A thrown session error follows the same rule (`attempts == 0` → retry on rebuilt session; else `TranslationError.sessionError`). The timer covers the "task never fires" case: with no view, nothing runs, both attempts time out, the caller gets `timedOut` after 2 × timeout (REQ-TR-10). Worst case per sentence: 10 s, then the direction moves on (REQ-TR-12).

Rebuild cancels the old `.translationTask`; whatever was in flight is still at the queue head and is served first by the new session (FIFO kept).

## 3. Views and hosting (D-2, D-3)

### 3.1 TranslationBridge

```swift
struct TranslationBridge: View {
    @ObservedObject var model: TranslationBridgeModel
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(model.configuration) { session in await model.run(session: session) }
    }
}
```

### 3.2 TranslationHostWindow

`@MainActor final class TranslationHostWindow` — built by `AppContainer.init` with both models:
`NSWindow(contentRect: (-10_000, -10_000, 10, 10), styleMask: .borderless, backing: .buffered, defer: false)`, `isReleasedWhenClosed = false`, `ignoresMouseEvents = true`, `collectionBehavior = [.transient, .ignoresCycle, .stationary]`, `contentView = NSHostingView(rootView: HStack { TranslationBridge(out); TranslationBridge(in) })`, `orderBack(nil)`. Same shape as the integration helper `hostTranslationBridge()`, which is rewritten to use this type. The `WindowGroup` no longer contains bridges. The window is excluded from the Window menu and never becomes key/main.

Verified on hardware by the integration test of §6.2 and manual check M2. If `.translationTask` turns out not to run in an ordered-back off-screen window inside the app (it does in the test host), fallback: `orderFrontRegardless()` with `alphaValue = 0` — decided during Task 1.

### 3.3 Download (REQ-TR-40…42)

`LanguagePairView` owns `@State private var downloadConfig: TranslationSession.Configuration?`. "Download" sets it to the current pair; the modifier
`.translationTask(downloadConfig) { session in await viewModel.download(using: session) ; downloadConfig = nil }`
calls `try await session.prepareTranslation()`, then `languagePairManager.checkAvailability()`; an error becomes the existing modal alert. `AudioCoordinator.downloadLanguages()` and `TranslationService.prepare` are removed.

## 4. Services

### 4.1 AppleTranslationService

```swift
final class AppleTranslationService: TranslationService, Sendable {
    let model: TranslationBridgeModel            // @MainActor class → Sendable; strong ref, owned by AppContainer anyway
    nonisolated var engineName: String { "Apple Translation" }
    func translate(text:from:to:) async throws -> String { try await model.translate(text, from: from, to: to) }
    func warmUp(from:to:) async { await model.warmUp(from: from, to: to) }
    func supports(source:target:) async -> Bool {
        let s = await LanguageAvailability().status(from: source, to: target)
        return s == .installed || s == .supported
    }
}
```

No continuation hop and no `nonisolated(unsafe)` (REQ-TR-60). Protocol: `prepare` removed, `warmUp(from:to:)` added with an empty default for `PassthroughTranslationService` and test fakes, default `supports` removed (REQ-TR-50). `TranslationEngineSelector.supports` builds the service for the preferred engine and asks it (REQ-TR-51).

### 4.2 TranslationError

Add `case timedOut` (description "Translation took too long."), equatable. Remove `case bridgeUnavailable` and its alert mapping (REQ-TR-22).

## 5. AudioCoordinator

- `start(...)`: after services are set, fire-and-forget `await outgoingTranslationService.warmUp(source→target)` and `incomingTranslationService.warmUp(target→source)` (REQ-TR-05); reset `alertedTranslationErrors`.
- `handle{Outgoing,Incoming}Translation` catch block → `handleTranslationFailure(error, direction:)`:

| Error | Action |
|-------|--------|
| `CancellationError` | ignore (session stopping) |
| `TranslationError.timedOut`, `.sessionError` | `showTTSNotice(…)` → "Couldn't translate a sentence (you / them)"; sentence skipped; loop continues (REQ-TR-20) |
| `.unsupportedPair`, `.modelNotLoaded` | `errorAlert` once per session per kind (REQ-TR-21) |
| other | treated like `.sessionError` |

`showTTSNotice` is reused as-is (it is the app's single notice line); renaming it is out of scope.

## 6. Concurrency hygiene (A10)

### 6.1 STT `locale`

`AppleSpeechService`, `WhisperSpeechService`, `ParakeetSpeechService`:
`private let localeBox: Mutex<Locale>` (Synchronization, macOS 15) and
`nonisolated var locale: Locale { localeBox.withLock { $0 } }`; `setLocale` writes via `withLock`. The protocol requirement `nonisolated var locale: Locale { get }` is unchanged.

### 6.2 opengrep

New rule `no-nonisolated-unsafe-core-stt-translation` in `.opengrep/rules/swift-concurrency.yml` (regex `nonisolated\(unsafe\)`, `paths.include: TranslateCall/Core/STT/**, TranslateCall/Core/Translation/**`, ERROR) with sample cases in `swift-concurrency.swift`.

## 7. Testing

### 7.1 Unit (Swift Testing, `TestClock`, fake session — no real Translation)

`FakeTranslationSession: TranslationSessioning` with scripted per-call behaviour (answer, throw, hang until cancelled) and a call log. Tests drive `model.run(session:)` directly in a task, standing in for the view; a helper observes `configuration` changes to simulate SwiftUI cancelling/restarting the task.

- persistent session: 3 requests → 1 `run`, 3 calls, configuration unchanged (REQ-TR-01).
- FIFO order with concurrent submitters (REQ-TR-03).
- pair change → new configuration; queued request served by the new run (REQ-TR-02a, 04).
- warm-up sets configuration without requests (REQ-TR-05).
- timeout once → rebuild + retry succeeds (REQ-TR-11).
- timeout twice → `timedOut`; next request succeeds (REQ-TR-11, 12).
- task never fires (no `run`) → `timedOut` after 2 × timeout (REQ-TR-10).
- session error once → retry; twice → `sessionError`.
- late answer after timeout is ignored, no double resume (NFR-TR-02).
- cancellation of the caller removes only its request (REQ-TR-13).
- run cancelled with a request in flight → served by the next run (REQ-TR-03).
- `AppleTranslationService.supports` mirrors `LanguageAvailability` (REQ-TR-50).
- coordinator: `timedOut` → notice, no alert, next sentence still translated; `unsupportedPair` twice → one alert (REQ-TR-20, 21); `start` warms up both directions (REQ-TR-05).
- STT services: `locale` set/read under `Mutex` (existing locale tests keep passing).

### 7.2 Integration (Mac, installed ES↔EN pack)

- **Latency (Task 1, D-6):** 10 short sentences through the old per-call path (invalidate each) vs the persistent model; record median/p90 of both in `build/reports/latency.json`; assert warm median ≤ 150 ms (NFR-TR-01). Written first against the current code for the baseline.
- **Hosting:** a `TranslationHostWindow` created in the test host (no other window) translates a sentence end to end. Closing the main window is covered by manual check M2.
- Existing `TranslationFixtureTests` / `OutgoingPipelineFixtureTests` move to `TranslationHostWindow`.

### 7.3 Manual (user): M1–M5 in requirements.md.

## 8. Files touched

| File | Change |
|------|--------|
| `App/TranslationBridge.swift` | rewritten model + view; `TranslationSessioning` |
| `App/TranslationHostWindow.swift` | new |
| `App/AppContainer.swift` | owns `TranslationHostWindow` |
| `App/TranslateCallApp.swift` | bridges removed from `WindowGroup` |
| `Core/Translation/AppleTranslationService.swift` | §4.1 |
| `Core/Translation/TranslationService.swift` | `timedOut`; `prepare` → `warmUp`; no default `supports` |
| `Core/Translation/TranslationEngineSelector.swift` | delegate `supports` |
| `Core/Audio/AudioCoordinator.swift`, `+Pipeline.swift` | warm-up, error mapping; `downloadLanguages` removed |
| `Features/Main/AudioViewModel.swift`, `LanguagePairView.swift` | download via `.translationTask` |
| `Core/STT/{Apple,Whisper,Parakeet}SpeechService.swift` | `Mutex<Locale>` |
| `.opengrep/rules/swift-concurrency.{yml,swift}` | new rule |
| `specs/m8.5-stabilization/backlog.md` | A8, T4, T5, A10 rows updated |
| tests | as §7 |
