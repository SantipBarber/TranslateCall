# F8.5.4 — Translation — Design

> Status: APPROVED (2026-10-07) — matches `tasks.md` (planning decisions folded in)
> Requirements: `requirements.md` (REQ-TR-*, D-1…D-9)

## 1. Overview

```
STT result ──► AudioCoordinator.handle{Outgoing,Incoming}Translation
                     │ await service.translate(text, from, to)
                     ▼
            AppleTranslationService (MainActor, holds its bridge model strongly)
                     │ await model.translate(text, source, target)
                     ▼
     TranslationBridgeModel (@MainActor, one per direction)
        FIFO queue · head-of-queue watchdog · one retry · rebuild
                     │ configuration (changes only on pair change / warm-up / rebuild)
                     ▼
     TranslationBridge view ── .translationTask(config) { session in
                                    await model.run(session: session) }   ← stays alive
                     ▲
     TranslationHostWindow (off-screen NSWindow, owned by AppContainer)

LanguagePairView ── .translationTask(downloadConfiguration) { prepareTranslation() }   (visible window)
```

Units and their single purpose:

| Unit | Purpose | Depends on |
|------|---------|-----------|
| `TranslationSessioning` (protocol) | What the bridge and the download flow need from a session: `translatedText(for:)`, `prepare()`. `TranslationSession` conforms via extension. | Translation |
| `TranslationBridgeModel` | Queue, timeout, retry, session lifecycle for one direction. | `TranslationSessioning`, `Clock` |
| `TranslationBridge` (view) | Anchors `.translationTask` and hands the session to `model.run`. | SwiftUI, model |
| `TranslationHostWindow` | Keeps both bridge views alive off-screen for the app's lifetime. | AppKit |
| `AppleTranslationService` | `TranslationService` façade over a bridge model + `LanguageAvailability` (`supports`, `isInstalled`). | model |
| `AudioCoordinator` (changed) | Pack check and warm-up at start; maps per-sentence errors to notice vs alert. | services, injected pack check |
| `LanguagePairView` (changed) | User-initiated download via its own `.translationTask`. | Translation |

## 2. TranslationBridgeModel

The plan (`tasks.md` Tasks 3–4) carries the exact code; this section states the behaviour.

### 2.1 State

```swift
@MainActor
final class TranslationBridgeModel: ObservableObject {
    struct Pair: Equatable, Sendable { let source: Locale.Language; let target: Locale.Language }

    @Published private(set) var configuration: TranslationSession.Configuration?

    private final class Request {
        let id: UInt64, text: String, pair: Pair
        var attempts = 0                                          // 0 = first try, 1 = retry
        var continuation: CheckedContinuation<String, Error>?    // nil once resumed (exactly-once)
    }

    private var queue: [Request] = []                 // FIFO; the head is being served
    private var livePair: Pair?                       // pair of `configuration`
    private var sessionGeneration: UInt64 = 0         // bumped on every configuration change
    private var waiters: [CheckedContinuation<Void, Never>] = []   // run loops parked on an empty queue
    private var watchdog: Task<Void, Never>?, watchedID: UInt64?    // bounds the head (§2.5)

    init(timeout: Duration = .seconds(5), clock: any Clock<Duration> = ContinuousClock())
    var queuedCount: Int { get }                      // tests
    static let warmUpProbe = "OK"
}
```

### 2.2 Public API

- `func translate(_ text: String, from: Locale.Language, to: Locale.Language) async throws -> String` — wrapped in `withTaskCancellationHandler`; appends a `Request`, opens the session for its pair if it is the only request, arms the watchdog, wakes the run loop. Cancelling the caller removes the request **even when it is in flight** and resumes it with `CancellationError`; the session's late answer finds nothing to resume (REQ-TR-13).
- `func warmUp(from:to:)` — synchronous; no-op while requests are queued. Opens the session for the pair and submits `warmUpProbe` as a request whose result is discarded: opening a session alone does not load the model (D-8, REQ-TR-05).
- `func run(session: some TranslationSessioning) async` — called by the view (§3) with each session SwiftUI creates.

`TranslationSessioning` (`translatedText(for:)`, `prepare()`) is the only surface the model and the download flow use; `TranslationSession` conforms in an extension, unit tests use `FakeTranslationSession`.

### 2.3 Session lifecycle

- `ensureSession(for pair)`: same pair and a configuration exists → nothing; otherwise `livePair = pair`, `configuration = .init(source:target:)`, `sessionGeneration += 1`, wake parked run loops.
- `rebuildSession()`: `configuration?.invalidate()`, `sessionGeneration += 1`, wake parked run loops. Only after a failure (§2.5).
- The run loop serves the head only if its pair is `livePair`; otherwise it calls `ensureSession(for: head.pair)` and returns (REQ-TR-04). Per direction the pair changes only between calls.

### 2.4 Run loop

```swift
func run(session: some TranslationSessioning) async {
    let generation = sessionGeneration
    while generation == sessionGeneration, !Task.isCancelled {
        guard let head = queue.first else { await parkUntilWork(); continue }   // cancellation-aware
        guard head.pair == livePair else { ensureSession(for: head.pair); return }
        do {
            let text = try await session.translatedText(for: head.text)
            finish(head.id, with: .success(text))           // also accepted from a replaced session
        } catch {
            guard generation == sessionGeneration, !Task.isCancelled else { return }   // stays queued (REQ-TR-03)
            attemptFailed(head.id, error: .sessionError(error))                         // §2.5
        }
    }
}
```

`finish` removes the request, resumes its continuation once and re-arms the watchdog for the next head; it ignores an id that is gone (late answers, cancelled callers — NFR-TR-02). A run loop of a replaced session exits at the next check of `sessionGeneration`; a parked one is woken by every configuration change and by its own cancellation, so no continuation is left hanging.

### 2.5 Timeout and retry (D-1, D-5, planning P2/P3)

One watchdog bounds the **head of the queue**: it is armed when a request becomes the head and restarted for its retry. A per-request timer from submission is not used: it would time out a waiting request while the head is being retried and rebuild the session twice. A request therefore completes within 2 × timeout of reaching the head (REQ-TR-10); each direction submits one sentence at a time, so the queue is normally one deep.

`attemptFailed(id, error)` (from the watchdog with `.timedOut`, or from the run loop with `.sessionError`):
- `attempts == 0` → `attempts = 1`, `rebuildSession()`, restart the watchdog: the request stays at the head and the new session serves it first.
- `attempts == 1` → the request throws the error, and the session is rebuilt again so a stuck session cannot hold the next request (REQ-TR-11/12).

With no view, nothing runs: both attempts time out and the caller gets `timedOut` after 2 × timeout. Worst case per sentence: 10 s, then the direction moves on.

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

`@MainActor final class TranslationHostWindow` — built by `AppContainer.init` with both models: borderless `NSWindow` at (-10 000, -10 000, 10 × 10), `isReleasedWhenClosed = false`, `ignoresMouseEvents = true`, `isExcludedFromWindowsMenu = true`, `collectionBehavior = [.transient, .ignoresCycle, .stationary]`, `contentView = NSHostingView(rootView: HStack { TranslationBridge(out); TranslationBridge(in) })`, `orderBack(nil)`. A borderless window never becomes key or main. The integration helper `hostTranslationBridge()` uses this type. The `WindowGroup` no longer contains bridges.

`.translationTask` runs in this ordered-back off-screen window inside the app process (verified by the Task 1 probe and the integration suites while planning), so the `orderFrontRegardless()` + `alphaValue = 0` fallback is **not needed**. Closing the main window: manual check M2.

### 3.3 Download (REQ-TR-40…42, planning P6)

`LanguagePairView` owns `@State private var downloadConfiguration: TranslationSession.Configuration?`. "Download" sets it to the current pair; the modifier
`.translationTask(downloadConfiguration) { session in await viewModel.downloadLanguages(using: session); downloadConfiguration = nil }`
runs `AudioViewModel.downloadLanguages(using: some TranslationSessioning)`: `try await session.prepare()` (→ `prepareTranslation()`), then `languagePairManager.checkAvailability()`. An error becomes a modal alert "Download Failed"; `CancellationError` is silent. `AudioCoordinator.downloadLanguages()` and `TranslationService.prepare` are removed. The language row is disabled during a session, so a download never overlaps a call.

## 4. Services

### 4.1 AppleTranslationService

```swift
final class AppleTranslationService: TranslationService {        // MainActor by default isolation; was an actor
    let model: TranslationBridgeModel                             // strong: AppContainer owns both
    var engineName: String { "Apple Translation" }
    func translate(text:from:to:) async throws -> String          // → model.translate
    func warmUp(from:to:) async                                   // → model.warmUp
    static func isInstalled(from:to:) async -> Bool               // LanguageAvailability == .installed (REQ-TR-06)
    func supports(source:target:) async -> Bool                   // .installed || .supported (REQ-TR-50)
}
```

No continuation hop and no `nonisolated(unsafe)` (REQ-TR-60). Protocol: `prepare` removed; `warmUp(from:to:)` added with an empty default (`PassthroughTranslationService`, test mocks); the default `supports` removed. `TranslationEngineSelector.supports` asks `makeOutgoingService()` (REQ-TR-51).

### 4.2 TranslationError

Add `case timedOut` ("Translation took too long."), equatable. Remove `case bridgeUnavailable` and its alert mapping (REQ-TR-22).

## 5. AudioCoordinator

- **Pack check (REQ-TR-06, D-9).** New init parameter `isTranslationPairInstalled: @escaping (Locale.Language, Locale.Language) async -> Bool = { _, _ in true }`; `AppContainer` passes `AppleTranslationService.isInstalled`. `start(...)` — after the re-entrancy guard and the `sessionGeneration` bump, before anything else — checks source → target and target → source. If either is not installed: `errorAlert = makeAlertItem(for: TranslationError.modelNotLoaded)` ("Languages Not Downloaded", "Download this language pair (the Download button next to the languages), then start again.") and return without capture or warm-up. A `stop()` during the check supersedes the start (`generation` re-checked).
- **Warm-up (REQ-TR-05).** Then `alertedTranslationErrors.removeAll()` and `warmUpTranslation()`: `outgoingTranslationService.warmUp(source→target)` and `incomingTranslationService.warmUp(target→source)`; both return at once.
- **Failures.** `handle{Outgoing,Incoming}Translation` catch → `handleTranslationFailure(error, outgoing:)`:

| Error | Action |
|-------|--------|
| `CancellationError` | ignore (session stopping) |
| `.unsupportedPair`, `.modelNotLoaded` | `errorAlert`, once per session per kind (`alertedTranslationErrors`, REQ-TR-21) |
| `.timedOut`, `.sessionError`, anything else | `showTTSNotice("Couldn't translate your sentence — skipped")` / `"…their sentence…"`; the sentence is skipped and the loop continues (REQ-TR-20) |

`showTTSNotice` is reused as-is (the app's single notice line).

## 6. Concurrency hygiene (A10)

### 6.1 STT `locale`

`AppleSpeechService`, `WhisperSpeechService`, `ParakeetSpeechService`: `private let localeState: Mutex<Locale>` (Synchronization, macOS 15) and `nonisolated var locale: Locale { localeState.withLock { $0 } }`; `setLocale` writes via `withLock`. The protocol requirement `nonisolated var locale: Locale { get }` is unchanged.

### 6.2 opengrep

New rule `no-nonisolated-unsafe-stt-translation` (regex `nonisolated\(unsafe\)`, ERROR, `paths.include: TranslateCall/Core/STT/, TranslateCall/Core/Translation/, .opengrep/rules/`) in its own `.opengrep/rules/swift-isolation.yml`, with its self-test in `swift-isolation.swift`. Not in `swift-concurrency.*`: a `nonisolated(unsafe)` sample there would also be reported by `nonisolated-unsafe-justified` and break that rule's self-test.

## 7. Testing

### 7.1 Unit (Swift Testing, `TestClock`, fakes — no real Translation, no real `LanguageAvailability`)

`FakeTranslationSession` (scripted answer / fail / hang / hang-ignoring-cancel, call log, `prepare` counter) and `TranslationSessionDriver` (plays SwiftUI: every configuration change cancels the running task and calls `run` again).

- `TranslationBridgeModelTests`: persistent session (REQ-TR-01), FIFO (REQ-TR-03), pair change (REQ-TR-02a/04), warm-up loads the model with the probe and is skipped while busy (REQ-TR-05), timeout → retry, timeout twice → `timedOut` then the next request works, never fires → `timedOut` (REQ-TR-10…12), session error retried / twice, late answer ignored (NFR-TR-02), caller cancellation (REQ-TR-13), in-flight request survives a task restart (REQ-TR-03).
- `AppleTranslationServiceTests`, `TranslationHostWindowTests`, `TranslationPipelineTests` (download: success, error alert, cancellation silent).
- `AudioCoordinatorTranslationTests` with an injected pack check: both directions checked, a missing pack (either direction) blocks Start with the alert (REQ-TR-06); warm-up of both directions (REQ-TR-05); failure → notice; configuration error alerts once per session (REQ-TR-20/21); cancellation silent.
- `STTLocaleIsolationTests`: `setLocale` visible to nonisolated reads; concurrent reads see whole values.

### 7.2 Integration (Mac, installed ES/EN/UK packs)

- **Latency probe (Task 1, D-6/D-8):** session per sentence vs kept session, both recorded in `build/reports/latency.json`, nothing asserted.
- **Production path:** `TranslationBridgeIntegrationTests` — the host window translates with no other window; warm median recorded, ≤ 400 ms; first sentence after warm-up (es→uk) ≤ 600 ms (NFR-TR-01).
- `TranslationPackTests`: `AppleTranslationService.isInstalled`, `supports`, selector delegation.
- Existing `TranslationFixtureTests` / `OutgoingPipelineFixtureTests` run through `TranslationHostWindow`.

### 7.3 Manual (user): M1–M6 in requirements.md.

## 8. Files touched

| File | Change |
|------|--------|
| `App/TranslationBridge.swift` | `TranslationSessioning`; rewritten model + view |
| `App/TranslationHostWindow.swift` | new |
| `App/AppContainer.swift` | owns `TranslationHostWindow`; passes `AppleTranslationService.isInstalled` to the coordinator |
| `App/TranslateCallApp.swift` | bridges removed from `WindowGroup` |
| `Core/Translation/AppleTranslationService.swift` | §4.1 |
| `Core/Translation/TranslationService.swift` | `timedOut`, −`bridgeUnavailable`; `prepare` → `warmUp`; no default `supports` |
| `Core/Translation/TranslationEngineSelector.swift` | delegate `supports` |
| `Core/Audio/AudioCoordinator.swift`, `+Pipeline.swift` | pack check, warm-up, error mapping; `downloadLanguages` removed |
| `Features/Main/AudioViewModel.swift`, `LanguagePairView.swift` | download via `.translationTask` |
| `Core/STT/{Apple,Whisper,Parakeet}SpeechService.swift` | `Mutex<Locale>` |
| `.opengrep/rules/swift-isolation.{yml,swift}`, `.opengrep/README.md` | new rule |
| `docs/ARCHITECTURE.md`, `specs/m8.5-stabilization/backlog.md` | translation section; A8, T4, T5, A10 fixed; T7 added |
| tests | as §7 (`AudioCoordinatorTests.CoordinatorMocks` gets a `LanguagePairManager` with an empty language loader, so its pair does not change mid-test) |
