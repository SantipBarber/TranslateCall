# F8.5.4 Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Translation never hangs a direction, never loses a sentence without telling the user, keeps working with the main window closed, and the first sentence of a call no longer pays the ~1 s cold start. Removes the last unchecked concurrency escapes in STT and Translation.

**Architecture:** Each direction's `TranslationBridgeModel` keeps one Apple `TranslationSession` open (the `.translationTask` closure stays alive in `run(session:)`) and serves a FIFO queue; the configuration changes only on a pair change, on warm-up at call start, or to rebuild after a failure. A watchdog bounds the request at the head of the queue (5 s, one retry on a rebuilt session, then `timedOut`). Both bridges live in an off-screen `TranslationHostWindow` owned by `AppContainer`; "Download" uses its own `.translationTask` in the visible `LanguagePairView`. The coordinator warms both directions up at Start and turns a failed sentence into a notice (alerts only for configuration errors, once per session). STT `locale` moves behind a `Mutex`.

**Tech Stack:** Swift 6 (app target: default MainActor isolation + approachable concurrency), Apple Translation (`TranslationSession`, `.translationTask`, `LanguageAvailability`), SwiftUI + AppKit (`NSWindow`, `NSHostingView`), Combine, `Synchronization.Mutex`, Swift Testing, `just`, opengrep, SwiftLint.

**Spec:** `specs/m8.5-stabilization/f8.5.4-translation/requirements.md`, `specs/m8.5-stabilization/f8.5.4-translation/design.md`

## Global Constraints

- Branch `feat/f8.5.4-translation`, created from `spec/f8.5.4-translation`: spec and code ship in one PR (F8.5.1–F8.5.3 practice). Never commit to `main`; `just pr` must pass before the PR. Execution: subagent-driven (the user's choice in F8.5.1–F8.5.3).
- Commits: Conventional Commits; end every message with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```
- `SWIFT_VERSION = 6.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0` (stays; macOS 26 `TranslationSession(installedSource:target:)` is out of scope, D-7). The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency and `MemberImportVisibility`; the test target has approachable concurrency but no default isolation.
- **Translation imports (P8):** every file that names `TranslationSession` or calls `translate`/`prepareTranslation` imports it as `@preconcurrency import Translation` (the SDK marks `translate` `@concurrent`; without `@preconcurrency` the MainActor call is a "sending risks data races" error). A test file that imports Translation must spell the app's error type `TranslateCall.TranslationError` (Translation declares its own `TranslationError`).
- New files are picked up automatically (`PBXFileSystemSynchronizedRootGroup`): never edit `project.pbxproj`.
- Unit tests: no Translation session, no ML model, no network, no audio device. Translation is faked with `FakeTranslationSession` + `TranslationSessionDriver` (Task 2/3). No fixed sleeps: `waitUntil` (`TranslateCallTests/Support/AsyncTestHelpers.swift`) or a `TestClock` (`TranslateCallTests/Support/TestClock.swift`: wait on `sleeperCount`, then `advance(by:)`).
- Run one unit suite: `just test-only <SuiteTypeName> […]` (the Swift `struct` name). Unit tier: `just test`. Integration tier: `just test-integration`. **One integration suite (P11):** nested suites *are* reachable by identifier:
  ```bash
  xcodebuild -project TranslateCall.xcodeproj -scheme TranslateCall -destination platform=macOS \
    -derivedDataPath build/DerivedData test -testPlan Integration \
    -only-testing:TranslateCallTests/IntegrationTests/<SuiteTypeName> 2>&1 | xcbeautify
  ```
  Integration translation tests need the ES/EN/UK Translation packs installed (`requireTranslationPack` fails with the pack name otherwise).
- Lint (strict): `just lint`. Static analysis: `just scan`. `just pr` is the gate (clean tree; publishes `local/just-pr` on HEAD).
- SwiftLint (app target only): lines ≤ 120, function bodies ≤ 50 lines, type bodies ≤ 250 lines (extensions do not count), **files ≤ 400 lines** (`AudioViewModel.swift` is at 399 after Task 7 — P12), no force unwraps, sorted imports.
- UI strings are English like the rest of the app.

## Review Focus

- **The Apple session hangs for good in the middle of a call** → that sentence is skipped with a notice after at most 10 s and the following sentences are translated by a rebuilt session (pinned in Task 4 `timeoutTwice`; Task 6 `outgoingFailureIsANotice`).
- **No session is ever delivered** (bridge view not in a window, e.g. the old main-window hosting closed) → the request fails with `timedOut`, it does not hang the direction (pinned in Task 4 `neverFires`; Task 5 moves the bridges out of the main window).
- **A replaced session answers late, after the retry already answered** → no second resume (crash) and no wrong sentence (pinned in Task 4 `lateAnswerIgnored`).
- **Stop is pressed while a sentence is being translated** → no alert, no notice, nothing left queued (pinned in Task 3 `callerCancellation`, Task 6 `cancellationIsSilent`).
- **"Download" is dismissed or the view goes away mid-download** → no error alert (pinned in Task 2 `downloadCancelledIsSilent`).

## Decisions made while planning (spec ambiguities resolved, measurements)

| # | Point | Choice |
|---|-------|--------|
| P1 | **D-6 measured while planning (Mac16,10, ES→EN, 10 short sentences, Task 1 tests run on the current code)** | Session per sentence (pre-F8.5.4): median **266–282 ms**, p90 306–323. Kept session: median **261–262 ms**, p90 296–318; its first sentence 323–344 ms. macOS 26 `TranslationSession(installedSource:target:)`: median 258 ms, first call 1 521 ms. One-word input: 62 ms. After an idle pause (3 / 10 / 30 s) kept vs fresh session: 379/307, 391/378, 458/434 ms — **no difference**. Cold first sentence of a pair (no warm-up): **1 103–1 166 ms**; after a session-only warm-up: **181–302 ms**; after a warm-up that also translates one word: 144–248 ms. **Conclusion:** the per-sentence cost is model inference (~250–450 ms, grows with sentence length), not session creation (~10–20 ms). NFR-TR-01 (≤ 150 ms warm median) is **not reachable** with Apple Translation by any session strategy. The real latency win is the warm-up at Start (first sentence −0.8 to −1 s). **The Task 1 STOP GATE will therefore trigger**: the user decides between (a) keep the plan as written — robustness (A8) + warm-up gain; NFR-TR-01 becomes "recorded, regression ceiling 400 ms" (Task 5 asserts that); (b) keep a session per sentence but add queue/timeout/host window/warm-up (simpler bridge, same gains); (c) drop the latency goal and do only A8/T5/A10. Tasks 2–9 implement (a). |
| P2 | Timeout scope (REQ-TR-10) | The watchdog bounds the **head** of the queue (the request being served), not each request from submission: a per-request timer would time out the second request while the first is being retried and rebuild the session twice. A request completes within 2 × 5 s of reaching the head. Each direction translates one sentence at a time (the coordinator awaits each), so the queue is normally one deep. |
| P3 | Rebuild after the final failure (REQ-TR-12) | After the second failure the session is rebuilt too, so a stuck session cannot hold the next request (verified by `timeoutTwice`). |
| P4 | Caller cancellation (REQ-TR-13) | Removes the request even when it is in flight; the session's late answer is ignored (`finish` finds nothing). |
| P5 | opengrep rule file (design §6.2) | New pair `.opengrep/rules/swift-isolation.{yml,swift}` instead of adding to `swift-concurrency.*`: a `nonisolated(unsafe)` sample in the shared file would also be reported by `nonisolated-unsafe-justified` and break that rule's self-test. Rule id `no-nonisolated-unsafe-stt-translation`. |
| P6 | Download API (design §3.3) | `TranslationSessioning` also has `prepare()` (wraps `prepareTranslation()`), so the download flow is unit-testable with the same fake. The view-model method is `downloadLanguages(using:)` (design said `download(using:)`). `CancellationError` from the sheet is silent. |
| P7 | Manual check M5 | The language row is `.disabled` during a session, so "Download during a call" cannot happen. M5 becomes "Download an uninstalled pair, then Start: the first sentence is translated". |
| P8 | `@preconcurrency import Translation` | See Global Constraints. |
| P9 | Pair not downloaded at Start | Out of the spec: the hidden bridge cannot show the download sheet, so each sentence times out (2 × 5 s) and shows the failure notice. Recorded as backlog **A26** (Task 9); a Start-time check of `pairStatus` is the likely fix. |
| P10 | Host window creation | `AppContainer.init` creates `TranslationHostWindow` (the test host *is* the app, and the integration tests translate through it). Real-app check: manual M2. |
| P11 | Integration suite selection | `-only-testing:TranslateCallTests/IntegrationTests/<Suite>` works with Xcode 27 (verified while planning); the F8.5.3 note saying otherwise is outdated. |
| P12 | `AudioViewModel.swift` line budget | `downloadLanguages(using:)` lives in an extension at the end of the file (type body ≤ 250), with a one-line doc comment (file ≤ 400). |
| P13 | Notice texts | Outgoing: "Couldn't translate your sentence — skipped"; incoming: "Couldn't translate their sentence — skipped". `modelNotLoaded` alert: title "Languages Not Downloaded". Download failure alert: title "Download Failed". |
| P14 | `TranslationError` | `timedOut` is added and `bridgeUnavailable` removed in Task 3 (one enum edit; the model's retry in Task 4 is the first producer of `timedOut`). |

## File Structure

```
TranslateCall/App/
  TranslationBridge.swift            MOD  T2 TranslationSessioning; T3 persistent-session model (queue, run loop, warm-up);
                                          T4 watchdog, retry, rebuild
  TranslationHostWindow.swift        NEW  T5
  AppContainer.swift                 MOD  T5 owns TranslationHostWindow
  TranslateCallApp.swift             MOD  T5 bridges out of the WindowGroup
TranslateCall/Core/Translation/
  TranslationService.swift           MOD  T2 −prepare; T3 +warmUp, +timedOut, −bridgeUnavailable; T7 no default supports
  AppleTranslationService.swift      MOD  T2 −prepare; T3 strong model ref, translate/warmUp via model; T7 supports
  TranslationEngineSelector.swift    MOD  T7 supports delegates to the service
TranslateCall/Core/Audio/
  AudioCoordinator.swift             MOD  T2 −downloadLanguages; T6 warm-up at start, alerted kinds
  AudioCoordinator+Pipeline.swift    MOD  T3 −bridgeUnavailable alert; T6 failure → notice / alert once, warmUpTranslation
TranslateCall/Features/Main/
  AudioViewModel.swift               MOD  T2 downloadLanguages(using:); T7 passthrough supports
  LanguagePairView.swift             MOD  T2 own .translationTask for Download
TranslateCall/Core/STT/{Apple,Whisper,Parakeet}SpeechService.swift   MOD T8 Mutex<Locale>
.opengrep/rules/swift-isolation.{yml,swift}, .opengrep/README.md     NEW/MOD T8
docs/ARCHITECTURE.md, specs/m8.5-stabilization/backlog.md, this file  MOD T9
TranslateCallTests/
  Integration/TranslationLatencyTests.swift                           NEW T1 (probe, D-6)
  Support/TranslationFakes.swift                                      NEW T2 (session fake), T3 (driver)
  TranslationPipelineTests.swift                                      MOD T2 download tests; T3, T6, T7 mock
  TranslationBridgeTests.swift                                        MOD T2, T3
  TranslationBridgeModelTests.swift                                   NEW T3, MOD T4
  TranslationHostWindowTests.swift                                    NEW T5
  Integration/{Prerequisites,TranslationBridgeIntegrationTests}.swift MOD/NEW T5
  Integration/OutgoingPipelineFixtureTests.swift                      MOD T2, T3
  AudioCoordinatorTranslationTests.swift                              NEW T6
  Integration/TranslationPackTests.swift                              MOD T7
  STTLocaleIsolationTests.swift                                       NEW T8
```

Dependency order: T1 (gate) → T2 → T3 → T4 → T5 → T6 → T7 → T8 → T9. T7 and T8 only need T3.

Everything below was implemented task by task on a throwaway clone while planning: each task's state built (`build-for-testing`), passed lint, and passed its suites; the final state passed the whole unit tier (575 tests), `just scan`, and the integration suites `TranslationLatencyTests`, `TranslationBridgeIntegrationTests`, `TranslationFixtureTests`, `OutgoingPipelineFixtureTests`, `TranslationPackTests`. The unit suites of Tasks 3, 4 and 6 passed 5 runs in a row.

---

### Task 1: Measure first — session per sentence vs kept session (D-6) — STOP GATE

**Files:**
- Create: `TranslateCallTests/Integration/TranslationLatencyTests.swift`

**Interfaces:**
- Consumes: `LatencyReport.shared`, `requireTranslationPack(from:to:)`, `Duration.milliseconds` (existing test support).
- Produces (used by Task 5): `latencySentences: [String]`, `median(_:) -> Double`, `percentile90(_:) -> Double`, `hostOffscreen(_:) -> NSWindow`, `TranslationProbe`, `TranslationProbeView`.

This task touches no production code: the probe stands in for the bridge, so the measurement runs against the code as it is today and stays valid after the rewrite.

- [ ] **Step 1: Write the measurement suite**

`TranslateCallTests/Integration/TranslationLatencyTests.swift`:
```swift
import AppKit
import Combine
import SwiftUI
import Testing
@preconcurrency import Translation
@testable import TranslateCall

/// Test-only stand-in for the bridge (F8.5.4 D-6): runs a job inside `.translationTask`, either on a
/// fresh session (the configuration is invalidated first, as the pre-F8.5.4 bridge did per sentence)
/// or on the session the previous job left open.
@MainActor
final class TranslationProbe: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    private var job: (@MainActor (TranslationSession) async -> Void)?
    private var done: CheckedContinuation<Void, Never>?

    /// Runs `job` inside a `.translationTask` session. `freshSession` invalidates the configuration
    /// first (one session per job); otherwise the first call opens the session and `job` keeps it.
    func run(source: Locale.Language, target: Locale.Language, freshSession: Bool,
             _ job: @escaping @MainActor (TranslationSession) async -> Void) async {
        await withCheckedContinuation { continuation in
            self.job = job
            self.done = continuation
            if configuration == nil {
                configuration = .init(source: source, target: target)
            } else if freshSession {
                configuration?.invalidate()
            }
        }
    }

    func fired(_ session: TranslationSession) async {
        guard let job else { return }
        self.job = nil
        await job(session)
        done?.resume()
        done = nil
    }
}

struct TranslationProbeView: View {
    @ObservedObject var probe: TranslationProbe
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(probe.configuration) { session in await probe.fired(session) }
    }
}

/// Short ES sentences (≤ 15 words), like what the VAD hands over after each pause.
let latencySentences = [
    "Hola, ¿me oyes bien?",
    "Vamos a revisar el presupuesto del próximo trimestre.",
    "Creo que la reunión puede durar media hora.",
    "¿Puedes compartir la pantalla, por favor?",
    "El equipo de ventas ha cerrado tres contratos.",
    "Necesitamos una decisión antes del viernes.",
    "Te envío el documento después de la llamada.",
    "No estoy de acuerdo con esa cifra.",
    "Perfecto, lo hablamos mañana por la mañana.",
    "Gracias a todos por venir.",
]

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let mid = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

func percentile90(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)]
}

/// Hosts a view off-screen the same way the app hosts its bridges (`orderBack`, borderless, far away).
@MainActor
func hostOffscreen(_ view: some View) -> NSWindow {
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 10, height: 10),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: view)
    window.orderBack(nil)
    return window
}

extension IntegrationTests {
    /// F8.5.4 D-6: is the translation latency the session start-up (one session per sentence) or the
    /// translation itself? Both numbers go to build/reports/latency.json; nothing is asserted here.
    @Suite("Translation latency (session reuse)", .serialized) @MainActor
    struct TranslationLatencyTests {
        @Test("one session per sentence (pre-F8.5.4 bridge)")
        func sessionPerSentence() async throws {
            try await requireTranslationPack(from: "es", to: "en")
            let probe = TranslationProbe()
            let window = hostOffscreen(TranslationProbeView(probe: probe))
            defer { window.close() }
            let src = Locale.Language(identifier: "es"), dst = Locale.Language(identifier: "en")

            var samples: [Double] = []
            for sentence in latencySentences {
                let start = ContinuousClock.now
                await probe.run(source: src, target: dst, freshSession: true) { session in
                    _ = try? await session.translate(sentence)
                }
                samples.append(start.duration(to: .now).milliseconds)
            }
            await LatencyReport.shared.record(fixture: "es→en session per sentence (median)", stage: .translate,
                                              ms: median(samples))
            await LatencyReport.shared.record(fixture: "es→en session per sentence (p90)", stage: .translate,
                                              ms: percentile90(samples))
            #expect(samples.count == latencySentences.count)
        }

        @Test("one session kept open (F8.5.4 bridge), first sentence excluded")
        func persistentSession() async throws {
            try await requireTranslationPack(from: "es", to: "en")
            let probe = TranslationProbe()
            let window = hostOffscreen(TranslationProbeView(probe: probe))
            defer { window.close() }
            let src = Locale.Language(identifier: "es"), dst = Locale.Language(identifier: "en")

            var first: Double = 0
            var samples: [Double] = []
            let opened = ContinuousClock.now
            await probe.run(source: src, target: dst, freshSession: false) { session in
                for (index, sentence) in latencySentences.enumerated() {
                    let start = index == 0 ? opened : ContinuousClock.now
                    _ = try? await session.translate(sentence)
                    let elapsed = start.duration(to: .now).milliseconds
                    if index == 0 { first = elapsed } else { samples.append(elapsed) }
                }
            }
            await LatencyReport.shared.record(fixture: "es→en kept session, first sentence", stage: .translate,
                                              ms: first)
            await LatencyReport.shared.record(fixture: "es→en kept session (median)", stage: .translate,
                                              ms: median(samples))
            await LatencyReport.shared.record(fixture: "es→en kept session (p90)", stage: .translate,
                                              ms: percentile90(samples))
            #expect(samples.count == latencySentences.count - 1)
        }
    }
}
```

- [ ] **Step 2: Run it (this also answers design §3.2: `.translationTask` runs in an ordered-back off-screen borderless window inside the app process)**

Run:
```bash
mkdir -p build/reports && rm -f build/reports/latency.json
xcodebuild -project TranslateCall.xcodeproj -scheme TranslateCall -destination platform=macOS \
  -derivedDataPath build/DerivedData test -testPlan Integration \
  -only-testing:TranslateCallTests/IntegrationTests/TranslationLatencyTests 2>&1 | xcbeautify
cat build/reports/latency.json
```
Expected: 2 tests PASS; `latency.json` has the five `es→en …` rows. Both tests passing proves `.translationTask` fires in the off-screen window, so the design §3.2 fallback (`orderFrontRegardless` + `alphaValue = 0`) is not needed.

- [ ] **Step 3: Commit**

```bash
git add TranslateCallTests/Integration/TranslationLatencyTests.swift
git commit -m "test(translation): measure session-per-sentence vs kept-session latency (F8.5.4 D-6)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 4: STOP GATE — report to the user before Task 2**

Compare `es→en kept session (median)` with `es→en session per sentence (median)` and with NFR-TR-01 (≤ 150 ms). Continue **only** if the kept median is ≤ 150 ms **and** at least 50 ms below the per-sentence median. Otherwise stop and report to the user, in Spanish, with the measured rows and the options of P1 ((a) as planned with NFR-TR-01 relaxed to a recorded value + 400 ms ceiling, (b) session per sentence + queue/timeout/host/warm-up, (c) only A8/T5/A10).

While planning, this gate **triggered** (P1: kept 261–262 ms vs per sentence 266–282 ms). Tasks 2–9 implement option (a); if the user picks (b) or (c), re-plan Tasks 3–5 before continuing. Record the user's decision and the measured rows in this file under P1 and in `requirements.md` (NFR-TR-01) in a `docs(spec)` commit.

---

### Task 2: Download from the visible window; `prepare` leaves `TranslationService` (D-3, REQ-TR-40…42)

**Files:**
- Modify: `TranslateCall/App/TranslationBridge.swift` (add `TranslationSessioning`; drop the `.prepare` operation)
- Modify: `TranslateCall/Core/Translation/TranslationService.swift:45`, `TranslateCall/Core/Translation/AppleTranslationService.swift:32-43`
- Modify: `TranslateCall/Core/Audio/AudioCoordinator.swift:337-348`
- Modify: `TranslateCall/Features/Main/AudioViewModel.swift:291-293,376` and end of file
- Modify: `TranslateCall/Features/Main/LanguagePairView.swift`
- Modify: `TranslateCallTests/Integration/OutgoingPipelineFixtureTests.swift:19`, `TranslateCallTests/TranslationBridgeTests.swift:91-103`
- Create: `TranslateCallTests/Support/TranslationFakes.swift`
- Test: `TranslateCallTests/TranslationPipelineTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `protocol TranslationSessioning { func translatedText(for text: String) async throws -> String; func prepare() async throws }`, with `extension TranslationSession: TranslationSessioning`.
  - `AudioViewModel.downloadLanguages(using session: some TranslationSessioning) async`.
  - Test support: `@MainActor final class FakeTranslationSession: TranslationSessioning` with `enum Step { case answer(String), fail(Error), hang, hangIgnoringCancel }`, `var script: [Step]`, `var prepareError: Error?`, `private(set) var translated: [String]`, `private(set) var prepareCount: Int`, `var hungCount: Int`, `func release(with answer: String)`.
  - `TranslationService` no longer has `prepare(source:target:)`; `AudioCoordinator.downloadLanguages()` and `AudioViewModel.downloadLanguages()` are gone.

- [ ] **Step 1: Write the failing tests**

Create `TranslateCallTests/Support/TranslationFakes.swift`:
```swift
import Foundation
@testable import TranslateCall

/// Scripted `TranslationSessioning` (F8.5.4 NFR-TR-03): no Translation framework in unit tests.
/// Each `translatedText` call takes the next step of `script`; with no step left it answers "EN:<text>".
@MainActor
final class FakeTranslationSession: TranslationSessioning {
    enum Step {
        case answer(String)
        case fail(Error)
        /// Waits for `release(with:)`; a cancelled caller gets `CancellationError` (like a real session).
        case hang
        /// Waits for `release(with:)` even when cancelled (a session that answers late).
        case hangIgnoringCancel
    }

    var script: [Step] = []
    var prepareError: Error?
    private(set) var translated: [String] = []
    private(set) var prepareCount = 0
    private var hung: [UInt64: CheckedContinuation<String, Error>] = [:]
    private var nextHungID: UInt64 = 0

    var hungCount: Int { hung.count }

    func translatedText(for text: String) async throws -> String {
        translated.append(text)
        let step = script.isEmpty ? .answer("EN:\(text)") : script.removeFirst()
        switch step {
        case .answer(let answer):
            return answer
        case .fail(let error):
            throw error
        case .hang:
            nextHungID += 1
            let id = nextHungID
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { hung[id] = $0 }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.hung.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
        case .hangIgnoringCancel:
            nextHungID += 1
            let id = nextHungID
            return try await withCheckedThrowingContinuation { hung[id] = $0 }
        }
    }

    /// Answers every call still waiting.
    func release(with answer: String) {
        let waiting = hung
        hung.removeAll()
        waiting.values.forEach { $0.resume(returning: answer) }
    }

    func prepare() async throws {
        prepareCount += 1
        if let prepareError { throw prepareError }
    }
}
```

In `TranslateCallTests/TranslationPipelineTests.swift`, in `MockTranslationService` delete
```swift
    private(set) var prepareCallCount = 0
```
and
```swift

    func prepare(source: Locale.Language, target: Locale.Language) async throws {
        prepareCallCount += 1
        if let error = shouldThrow { throw error }
    }
```
Then in `TranslationPipelineTests` replace the four tests `downloadLanguagesCallsPrepare`, `downloadLanguagesErrorSetsAlert`, `downloadLanguagesSuccessChecksAvailability` and `nilTranslationServiceDownloadIsNoop` (everything from `    @Test func downloadLanguagesCallsPrepare() async {` up to, not including, `    @Test func initialStateIsClean() {`) with:
```swift
    @Test("Download prepares the pair with the view's session (REQ-TR-40)")
    func downloadUsesSession() async {
        let viewModel = AudioViewModel(translationService: MockTranslationService(), conversationSettings: .forTesting())
        let session = FakeTranslationSession()

        await viewModel.downloadLanguages(using: session)

        #expect(session.prepareCount == 1)
        #expect(viewModel.errorAlert == nil)
    }

    @Test("a failed download shows an alert (REQ-TR-41)")
    func downloadErrorSetsAlert() async {
        let viewModel = AudioViewModel(translationService: MockTranslationService(), conversationSettings: .forTesting())
        let session = FakeTranslationSession()
        session.prepareError = TranslationError.networkUnavailable

        await viewModel.downloadLanguages(using: session)

        #expect(viewModel.errorAlert?.title == "Download Failed")
    }

    @Test("a cancelled download is silent")
    func downloadCancelledIsSilent() async {
        let viewModel = AudioViewModel(translationService: MockTranslationService(), conversationSettings: .forTesting())
        let session = FakeTranslationSession()
        session.prepareError = CancellationError()

        await viewModel.downloadLanguages(using: session)

        #expect(viewModel.errorAlert == nil)
    }

```

In `TranslateCallTests/TranslationBridgeTests.swift`, delete the test `prepareThrowsBridgeUnavailableWhenModelDeallocated` (the whole `@Test func prepareThrowsBridgeUnavailableWhenModelDeallocated() async { … }` block, and the blank line before it).

- [ ] **Step 2: Run the tests to see them fail**

Run: `just test-only TranslationPipelineTests`
Expected: build FAILS — `cannot find type 'TranslationSessioning'`, `value of type 'AudioViewModel' has no member 'downloadLanguages(using:)'`.

- [ ] **Step 3: Implement**

`TranslateCall/App/TranslationBridge.swift`: replace
```swift
// MARK: - PendingOperation

enum PendingOperation {
    case translate(text: String, continuation: CheckedContinuation<String, Error>)
    case prepare(continuation: CheckedContinuation<Void, Error>)
}
```
with
```swift
// MARK: - TranslationSessioning

/// What the bridge and the download flow need from a `TranslationSession` (F8.5.4 design §1).
/// Unit tests fake it, so they never touch the Translation framework (NFR-TR-03).
protocol TranslationSessioning {
    func translatedText(for text: String) async throws -> String
    /// Downloads the pair's models if needed; may show the system sheet in the hosting window.
    func prepare() async throws
}

extension TranslationSession: TranslationSessioning {
    func translatedText(for text: String) async throws -> String {
        try await translate(text).targetText
    }

    func prepare() async throws {
        try await prepareTranslation()
    }
}

// MARK: - PendingOperation

enum PendingOperation {
    case translate(text: String, continuation: CheckedContinuation<String, Error>)
}
```
In `sessionFired(_:)` delete the whole `case .prepare(let continuation):` branch (from the blank line before `        case .prepare(let continuation):` through its closing `            }`), and in `failOperation` delete
```swift
        case .prepare(let cont):      cont.resume(throwing: error)
```

`TranslateCall/Core/Translation/TranslationService.swift`, in `protocol TranslationService` delete
```swift
    func prepare(source: Locale.Language, target: Locale.Language) async throws
```

`TranslateCall/Core/Translation/AppleTranslationService.swift`: delete the method `func prepare(source: Locale.Language, target: Locale.Language) async throws { … }` and the blank line before it.

`TranslateCall/Core/Audio/AudioCoordinator.swift`: delete
```swift
    /// Prepare the language pair (download translation models if needed).
    func downloadLanguages() async {
        do {
            try await outgoingTranslationService.prepare(
                source: languagePairManager.sourceLanguage,
                target: languagePairManager.targetLanguage
            )
            await languagePairManager.checkAvailability()
        } catch {
            errorAlert = makeAlertItem(for: error)
        }
    }

```

`TranslateCall/Features/Main/AudioViewModel.swift`: delete
```swift
    func downloadLanguages() async {
        await coordinator.downloadLanguages()
    }

```
in `PassthroughTranslationService` delete
```swift
    func prepare(source: Locale.Language, target: Locale.Language) async throws {}
```
and append at the end of the file (an extension keeps the class body under 250 lines; the one-line doc comment keeps the file ≤ 400 lines — P12):
```swift

// MARK: - Language download (F8.5.4)

extension AudioViewModel {
    /// Downloads the pair with `LanguagePairView`'s own session: the sheet shows there (F8.5.4 REQ-TR-40/41).
    func downloadLanguages(using session: some TranslationSessioning) async {
        do {
            try await session.prepare()
        } catch is CancellationError {   // the view went away: nothing to report
        } catch {
            errorAlert = AlertItem(title: "Download Failed", message: error.localizedDescription, action: nil)
        }
        await languagePairManager.checkAvailability()
    }
}
```

`TranslateCall/Features/Main/LanguagePairView.swift`: replace
```swift
import SwiftUI
```
with
```swift
import SwiftUI
@preconcurrency import Translation
```
after `    @EnvironmentObject private var ttsSelector: TTSEngineSelector` add
```swift
    /// Set by "Download"; drives this view's own `.translationTask` (F8.5.4 D-3). Nil when idle.
    @State private var downloadConfiguration: TranslationSession.Configuration?
```
replace
```swift
                    Button("Download") {
                        Task { await viewModel.downloadLanguages() }
                    }
```
with
```swift
                    Button("Download") {
                        downloadConfiguration = .init(source: manager.sourceLanguage, target: manager.targetLanguage)
                    }
```
and replace the end of `body`
```swift
        .disabled(viewModel.isCapturing)
    }
```
with
```swift
        .disabled(viewModel.isCapturing)
        // Runs in the visible window so the system download sheet appears here (REQ-TR-40).
        .translationTask(downloadConfiguration) { session in
            await viewModel.downloadLanguages(using: session)
            downloadConfiguration = nil
        }
    }
```

`TranslateCallTests/Integration/OutgoingPipelineFixtureTests.swift`: delete
```swift
            try await translator.prepare(source: src, target: dst)
```

- [ ] **Step 4: Run the tests and lint**

Run: `just test-only TranslationPipelineTests AppleTranslationServiceTests TranslationErrorTests` → PASS (12 tests). `just lint` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall TranslateCallTests
git commit -m "feat(translation): download from LanguagePairView's own translationTask; prepare leaves TranslationService (F8.5.4 REQ-TR-40…42)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 3: Persistent-session bridge — FIFO queue, run loop, pair change, warm-up (T4, A8 slot, REQ-TR-01…05, 13, 22)

**Files:**
- Modify (rewrite): `TranslateCall/App/TranslationBridge.swift`
- Modify (rewrite): `TranslateCall/Core/Translation/AppleTranslationService.swift`
- Modify: `TranslateCall/Core/Translation/TranslationService.swift`
- Modify: `TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift` (`makeAlertItem`)
- Modify: `TranslateCallTests/Integration/OutgoingPipelineFixtureTests.swift`
- Modify: `TranslateCallTests/Support/TranslationFakes.swift`, `TranslateCallTests/TranslationBridgeTests.swift`, `TranslateCallTests/TranslationPipelineTests.swift`
- Test: `TranslateCallTests/TranslationBridgeModelTests.swift`

**Interfaces:**
- Consumes: `TranslationSessioning`, `FakeTranslationSession` (Task 2).
- Produces:
  - `@MainActor final class TranslationBridgeModel: ObservableObject` with `@Published private(set) var configuration: TranslationSession.Configuration?`, `var queuedCount: Int`, `func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String`, `func warmUp(from:to:)` (synchronous), `func run(session: some TranslationSessioning) async`. `init()` (Task 4 adds `init(timeout:clock:)` with defaults).
  - `final class AppleTranslationService: TranslationService` (MainActor by default isolation; was an `actor`) with `let model: TranslationBridgeModel` (strong), `translate`, `warmUp(from:to:)`.
  - `TranslationService.warmUp(from:to:) async` with an empty default; `TranslationError.timedOut`; `TranslationError.bridgeUnavailable` removed (P14).
  - Test support: `@MainActor final class TranslationSessionDriver` — `init(model:session:)`, `let session: FakeTranslationSession`, `private(set) var runs: Int`, `func restart()`, `func stop()`.

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/Support/TranslationFakes.swift`: replace the first line
```swift
import Foundation
```
with
```swift
import Combine
import Foundation
```
and append at the end of the file:
```swift

/// Plays SwiftUI's part in `.translationTask`: every new configuration cancels the running task and
/// calls `run(session:)` again. `runs` counts the sessions opened.
@MainActor
final class TranslationSessionDriver {
    let model: TranslationBridgeModel
    let session: FakeTranslationSession
    private(set) var runs = 0
    private var task: Task<Void, Never>?
    private var subscription: AnyCancellable?

    init(model: TranslationBridgeModel, session: FakeTranslationSession = FakeTranslationSession()) {
        self.model = model
        self.session = session
        subscription = model.$configuration.sink { [weak self] configuration in
            guard configuration != nil else { return }
            self?.restart()
        }
    }

    /// Cancels the running task and starts a new one, as SwiftUI does on a configuration change.
    func restart() {
        task?.cancel()
        runs += 1
        let model = model
        let session = session
        task = Task { await model.run(session: session) }
    }

    func stop() {
        subscription = nil
        task?.cancel()
    }
}
```

Create `TranslateCallTests/TranslationBridgeModelTests.swift`:
```swift
import Foundation
import Testing
@preconcurrency import Translation
@testable import TranslateCall

// `Translation` also declares a `TranslationError`: the app's is spelled `TranslateCall.TranslationError` here.

private let esLanguage = Locale.Language(identifier: "es")
private let enLanguage = Locale.Language(identifier: "en")

private struct SessionFailure: Error {}

@Suite("TranslationBridgeModel (F8.5.4)", .serialized) @MainActor
struct TranslationBridgeModelTests {

    private func makeModel() -> (TranslationBridgeModel, TranslationSessionDriver) {
        let model = TranslationBridgeModel()
        return (model, TranslationSessionDriver(model: model))
    }

    @Test("sentences share one session: the configuration is set once (REQ-TR-01, T4)")
    func persistentSession() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        for text in ["uno", "dos", "tres"] {
            #expect(try await model.translate(text, from: esLanguage, to: enLanguage) == "EN:\(text)")
        }
        #expect(driver.runs == 1)
        #expect(driver.session.translated == ["uno", "dos", "tres"])
    }

    @Test("concurrent requests are answered in submission order (REQ-TR-03)")
    func fifoOrder() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        driver.session.script = [.hang]
        let first = Task { try await model.translate("uno", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.hungCount == 1 })
        let second = Task { try await model.translate("dos", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { model.queuedCount == 2 })
        let third = Task { try await model.translate("tres", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { model.queuedCount == 3 })

        driver.session.release(with: "EN:uno")
        #expect(try await first.value == "EN:uno")
        #expect(try await second.value == "EN:dos")
        #expect(try await third.value == "EN:tres")
        #expect(driver.session.translated == ["uno", "dos", "tres"])
    }

    @Test("a new pair opens a new session that serves the request (REQ-TR-02a, REQ-TR-04)")
    func pairChange() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        _ = try await model.translate("hola", from: esLanguage, to: enLanguage)
        #expect(try await model.translate("hello", from: enLanguage, to: esLanguage) == "EN:hello")
        #expect(driver.runs == 2)
        #expect(model.configuration?.source == enLanguage)
    }

    @Test("warm-up opens the session before the first sentence, which then reuses it (REQ-TR-05)")
    func warmUp() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        model.warmUp(from: esLanguage, to: enLanguage)
        #expect(model.configuration?.source == esLanguage)
        #expect(driver.runs == 1)
        _ = try await model.translate("hola", from: esLanguage, to: enLanguage)
        #expect(driver.runs == 1)
    }

    @Test("a session error fails that request only; the next one is translated")
    func sessionErrorFailsOne() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        driver.session.script = [.fail(SessionFailure())]
        await #expect(throws: TranslateCall.TranslationError.sessionError(SessionFailure())) {
            try await model.translate("hola", from: esLanguage, to: enLanguage)
        }
        #expect(try await model.translate("adiós", from: esLanguage, to: enLanguage) == "EN:adiós")
    }

    @Test("cancelling a caller removes only its request (REQ-TR-13)")
    func callerCancellation() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        driver.session.script = [.hang]
        let first = Task { try await model.translate("uno", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.hungCount == 1 })
        let second = Task { try await model.translate("dos", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { model.queuedCount == 2 })

        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(model.queuedCount == 1)
        driver.session.release(with: "EN:uno")
        #expect(try await first.value == "EN:uno")
        #expect(driver.session.translated == ["uno"])
    }

    @Test("a request in flight when the session's task is cancelled is served by the next session (REQ-TR-03)")
    func inFlightSurvivesSessionRestart() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        driver.session.script = [.hang]
        let result = Task { try await model.translate("hola", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.hungCount == 1 })

        driver.restart()   // SwiftUI cancelled and restarted the task (e.g. the view re-appeared)
        #expect(try await result.value == "EN:hola")
        #expect(driver.session.translated == ["hola", "hola"])
    }

    @Test("AppleTranslationService.warmUp opens the model's session for the pair (REQ-TR-05)")
    func serviceWarmUpOpensSession() async {
        let model = TranslationBridgeModel()
        let service = AppleTranslationService(model: model)
        await service.warmUp(from: esLanguage, to: enLanguage)
        #expect(model.configuration?.source == esLanguage)
        #expect(model.configuration?.target == enLanguage)
    }
}
```

`TranslateCallTests/TranslationBridgeTests.swift`:
- replace
  ```swift
      @Test func bridgeUnavailableHasDescription() {
          let error = TranslationError.bridgeUnavailable
          #expect(error.errorDescription != nil)
          #expect(!error.errorDescription!.isEmpty)
      }
  ```
  with
  ```swift
      @Test func timedOutHasDescription() {
          #expect(TranslationError.timedOut.errorDescription == "Translation took too long.")
      }
  ```
- in `allCasesHaveNonEmptyDescription` replace `            .bridgeUnavailable,` with `            .timedOut,`;
- in `equatableSameCasesAreEqual` replace `#expect(TranslationError.bridgeUnavailable == TranslationError.bridgeUnavailable)` with `#expect(TranslationError.timedOut == TranslationError.timedOut)`;
- in `equatableDifferentCasesNotEqual` replace `TranslationError.bridgeUnavailable != ` with `TranslationError.timedOut != `;
- replace everything from `// MARK: - AppleTranslationService (bridgeUnavailable path — no window needed)` to the end of the file with:
  ```swift
  // MARK: - AppleTranslationService

  @Suite("AppleTranslationService (F8.5.4)", .serialized) @MainActor
  struct AppleTranslationServiceTests {

      @Test("translate goes through the direction's bridge model")
      func translateUsesModel() async throws {
          let model = TranslationBridgeModel()
          let driver = TranslationSessionDriver(model: model)
          defer { driver.stop() }
          let service = AppleTranslationService(model: model)
          let output = try await service.translate(text: "hola", from: Locale.Language(identifier: "es"),
                                                   to: Locale.Language(identifier: "en"))
          #expect(output == "EN:hola")
          #expect(service.engineName == "Apple Translation")
      }
  }
  ```

`TranslateCallTests/TranslationPipelineTests.swift`, in `TranslationErrorMatchingTests` replace
```swift
    @Test func bridgeUnavailableMatchesInSwitch() {
        let error: Error = TranslationError.bridgeUnavailable
        var matched = false
        switch error {
        case TranslationError.bridgeUnavailable: matched = true
```
with
```swift
    @Test func timedOutMatchesInSwitch() {
        let error: Error = TranslationError.timedOut
        var matched = false
        switch error {
        case TranslationError.timedOut: matched = true
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `just test-only TranslationBridgeModelTests AppleTranslationServiceTests`
Expected: build FAILS — `TranslationBridgeModel` has no `translate(_:from:to:)`, `run(session:)`, `warmUp`, `queuedCount`; `TranslationError` has no `timedOut`.

- [ ] **Step 3: Implement**

Replace the whole of `TranslateCall/App/TranslationBridge.swift` with:
```swift
import Combine
import OSLog
import SwiftUI
@preconcurrency import Translation

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TranslationBridge")

// MARK: - TranslationSessioning

/// What the bridge and the download flow need from a `TranslationSession` (F8.5.4 design §1).
/// Unit tests fake it, so they never touch the Translation framework (NFR-TR-03).
protocol TranslationSessioning {
    func translatedText(for text: String) async throws -> String
    /// Downloads the pair's models if needed; may show the system sheet in the hosting window.
    func prepare() async throws
}

extension TranslationSession: TranslationSessioning {
    func translatedText(for text: String) async throws -> String {
        try await translate(text).targetText
    }

    func prepare() async throws {
        try await prepareTranslation()
    }
}

// MARK: - TranslationBridgeModel

/// One translation direction's link to Apple Translation (F8.5.4 design §2).
///
/// `TranslationSession` only exists inside `.translationTask`, so `TranslationBridge` hands each
/// session to `run(session:)`, which keeps it and serves queued requests in order until the
/// configuration changes. The configuration changes only when the pair changes or on `warmUp` —
/// never per sentence (T4).
@MainActor
final class TranslationBridgeModel: ObservableObject {
    struct Pair: Equatable, Sendable {
        let source: Locale.Language
        let target: Locale.Language
    }

    @Published private(set) var configuration: TranslationSession.Configuration?

    private final class Request {
        let id: UInt64
        let text: String
        let pair: Pair
        /// Nil once resumed: every request is resumed exactly once (NFR-TR-02).
        var continuation: CheckedContinuation<String, Error>?

        init(id: UInt64, text: String, pair: Pair, continuation: CheckedContinuation<String, Error>) {
            self.id = id
            self.text = text
            self.pair = pair
            self.continuation = continuation
        }
    }

    /// FIFO; the head is the request being served (REQ-TR-03).
    private var queue: [Request] = []
    private var nextID: UInt64 = 0
    /// Pair of `configuration`.
    private var livePair: Pair?
    /// Bumped whenever `configuration` changes; a run loop of an older session stops.
    private var sessionGeneration: UInt64 = 0
    /// Run loops parked on an empty queue.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Requests waiting or in flight (tests).
    var queuedCount: Int { queue.count }

    // MARK: - API

    /// Translates `text` once a session for its pair is running. Cancelling the calling task removes
    /// the request and throws `CancellationError` (REQ-TR-13).
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        try Task.checkCancellation()
        nextID &+= 1
        let id = nextID
        let pair = Pair(source: source, target: target)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Request(id: id, text: text, pair: pair, continuation: continuation))
                if queue.count == 1 { ensureSession(for: pair) }
                wakeRunLoops()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(id) }
        }
    }

    /// Opens a session for `pair` ahead of the first sentence (REQ-TR-05). No-op while requests are queued.
    func warmUp(from source: Locale.Language, to target: Locale.Language) {
        guard queue.isEmpty else { return }
        ensureSession(for: Pair(source: source, target: target))
    }

    /// Called by `TranslationBridge` with each session SwiftUI creates. Returns when the session is
    /// replaced (pair change) or its task is cancelled.
    func run(session: some TranslationSessioning) async {
        let generation = sessionGeneration
        while generation == sessionGeneration, !Task.isCancelled {
            guard let head = queue.first else {
                await parkUntilWork()
                continue
            }
            guard head.pair == livePair else {
                ensureSession(for: head.pair)   // REQ-TR-04: the next session serves it
                return
            }
            do {
                let text = try await session.translatedText(for: head.text)
                finish(head.id, with: .success(text))   // also accepted from a replaced session
            } catch {
                // Replaced or cancelled mid-flight: the request stays queued for the next session (REQ-TR-03).
                guard generation == sessionGeneration, !Task.isCancelled else { return }
                logger.error("Translation failed — \(error.localizedDescription, privacy: .public)")
                finish(head.id, with: .failure(TranslationError.sessionError(error)))
            }
        }
    }

    // MARK: - Session lifecycle

    private func ensureSession(for pair: Pair) {
        guard pair != livePair || configuration == nil else { return }
        livePair = pair
        configuration = TranslationSession.Configuration(source: pair.source, target: pair.target)
        sessionGeneration &+= 1
        wakeRunLoops()
    }

    private func parkUntilWork() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append($0) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wakeRunLoops() }
        }
    }

    private func wakeRunLoops() {
        let parked = waiters
        waiters.removeAll()
        parked.forEach { $0.resume() }
    }

    // MARK: - Completion

    private func finish(_ id: UInt64, with result: Result<String, Error>) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let request = queue.remove(at: index)
        request.continuation?.resume(with: result)
        request.continuation = nil
    }

    private func cancelRequest(_ id: UInt64) {
        finish(id, with: .failure(CancellationError()))
    }
}

// MARK: - TranslationBridge View

/// Invisible view anchoring `.translationTask()`; `TranslationSession` has no public initializer on
/// macOS 15. Each new configuration makes SwiftUI cancel the running task and call `run` again.
struct TranslationBridge: View {
    @ObservedObject private var model: TranslationBridgeModel

    init(model: TranslationBridgeModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(model.configuration) { session in
                await model.run(session: session)
            }
    }
}
```

Replace the whole of `TranslateCall/Core/Translation/AppleTranslationService.swift` with:
```swift
import Foundation

/// `TranslationService` over Apple's Translation framework. Requests go through this direction's
/// `TranslationBridgeModel`, which owns the session, the queue, the timeout and the retry (F8.5.4).
/// The model is held strongly: `AppContainer` owns both for the app's lifetime (REQ-TR-22, REQ-TR-60).
final class AppleTranslationService: TranslationService {
    let model: TranslationBridgeModel

    init(model: TranslationBridgeModel) {
        self.model = model
    }

    var engineName: String { "Apple Translation" }

    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        try await model.translate(text, from: source, to: target)
    }

    func warmUp(from source: Locale.Language, to target: Locale.Language) async {
        model.warmUp(from: source, to: target)
    }
}
```
(This removes the `nonisolated(unsafe) weak var model` — REQ-TR-60 for Core/Translation.)

`TranslateCall/Core/Translation/TranslationService.swift`:
- replace
  ```swift
      case bridgeUnavailable
      case sessionError(Error)
  ```
  with
  ```swift
      case sessionError(Error)
      case timedOut
  ```
- replace
  ```swift
          case .bridgeUnavailable:
              return "Translation bridge is unavailable. Restart the app."
          case .sessionError(let error):
              return "Translation failed: \(error.localizedDescription)"
  ```
  with
  ```swift
          case .sessionError(let error):
              return "Translation failed: \(error.localizedDescription)"
          case .timedOut:
              return "Translation took too long."
  ```
- replace
  ```swift
          case (.bridgeUnavailable, .bridgeUnavailable): return true
          case (.sessionError, .sessionError): return true
  ```
  with
  ```swift
          case (.sessionError, .sessionError): return true
          case (.timedOut, .timedOut): return true
  ```
- in `protocol TranslationService`, after the `translate` requirement add
  ```swift
      /// Opens the session for a pair ahead of the first sentence (F8.5.4 REQ-TR-05). Must return at once.
      func warmUp(from source: Locale.Language, to target: Locale.Language) async
  ```
- in `extension TranslationService`, after `    var engineName: String { "Unknown" }` add
  ```swift
      func warmUp(from source: Locale.Language, to target: Locale.Language) async {}
  ```

`TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift`, in `makeAlertItem(for:)` delete
```swift
        case TranslationError.bridgeUnavailable:
            return AlertItem(
                title: "Translation Unavailable",
                message: "Translation bridge unavailable. Restart the app.",
                action: nil
            )
```

`TranslateCallTests/Integration/OutgoingPipelineFixtureTests.swift`: after
```swift
            try await requireTranslationPack(from: "es", to: "en")
```
add
```swift
            await translator.warmUp(from: src, to: dst)
```

- [ ] **Step 4: Run the tests, grep and lint**

Run: `just test-only TranslationBridgeModelTests AppleTranslationServiceTests TranslationErrorTests TranslationBridgeModelStateTests TranslationPipelineTests TranslationErrorMatchingTests TranslationEngineSelectorTests`
Expected: PASS (26 tests).
Run: `grep -rn "bridgeUnavailable\|PendingOperation" TranslateCall TranslateCallTests; grep -rn "invalidate()" TranslateCall`
Expected: no output (the per-sentence `invalidate()` is gone from the app — T4; the Task 1 probe keeps its own).
Run: `just lint` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall TranslateCallTests
git commit -m "feat(translation): keep one session per direction and serve a FIFO queue; warm-up; no bridgeUnavailable (F8.5.4 T4, REQ-TR-01…05, 13, 22)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Watchdog — timeout, one retry on a rebuilt session, then fail (A8, D-1, D-5, REQ-TR-10…12, NFR-TR-02)

**Files:**
- Modify: `TranslateCall/App/TranslationBridge.swift` (the `TranslationBridgeModel` section)
- Test: `TranslateCallTests/TranslationBridgeModelTests.swift`

**Interfaces:**
- Consumes: Task 3's model, `TestClock`.
- Produces: `TranslationBridgeModel.init(timeout: Duration = .seconds(5), clock: any Clock<Duration> = ContinuousClock())`. Behaviour: the head of the queue is bounded by `timeout`; first failure (timeout or session error) → rebuild (`configuration?.invalidate()`) and retry; second failure → the request throws `TranslationError.timedOut` / `.sessionError` and the session is rebuilt again (P2, P3).

- [ ] **Step 1: Write the failing tests**

In `TranslateCallTests/TranslationBridgeModelTests.swift` replace
```swift
    private func makeModel() -> (TranslationBridgeModel, TranslationSessionDriver) {
        let model = TranslationBridgeModel()
        return (model, TranslationSessionDriver(model: model))
    }
```
with
```swift
    private func makeModel(_ clock: TestClock = TestClock()) -> (TranslationBridgeModel, TranslationSessionDriver) {
        let model = TranslationBridgeModel(timeout: .seconds(5), clock: clock)
        return (model, TranslationSessionDriver(model: model))
    }
```
and replace the test `sessionErrorFailsOne` (from `    @Test("a session error fails that request only; the next one is translated")` through its closing `    }`) with:
```swift
    @Test("a timeout rebuilds the session and the retry answers (REQ-TR-11)")
    func timeoutThenRetry() async throws {
        let clock = TestClock()
        let (model, driver) = makeModel(clock)
        defer { driver.stop() }
        driver.session.script = [.hang, .answer("retried")]
        let result = Task { try await model.translate("hola", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.hungCount == 1 && clock.sleeperCount == 1 })

        clock.advance(by: .seconds(5))
        #expect(try await result.value == "retried")
        #expect(driver.runs == 2)
    }

    @Test("two timeouts fail with timedOut; the next request is served by a rebuilt session (REQ-TR-11/12)")
    func timeoutTwice() async throws {
        let clock = TestClock()
        let (model, driver) = makeModel(clock)
        defer { driver.stop() }
        driver.session.script = [.hang, .hang]
        let result = Task { try await model.translate("hola", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.translated.count == 1 && clock.sleeperCount == 1 })
        clock.advance(by: .seconds(5))
        #expect(await waitUntil { driver.session.translated.count == 2 && clock.sleeperCount == 1 })
        clock.advance(by: .seconds(5))

        await #expect(throws: TranslateCall.TranslationError.timedOut) { try await result.value }
        #expect(try await model.translate("adiós", from: esLanguage, to: enLanguage) == "EN:adiós")
        #expect(driver.runs == 3)
    }

    @Test("with no session ever delivered (no view), the request times out (REQ-TR-10, A8)")
    func neverFires() async throws {
        let clock = TestClock()
        let model = TranslationBridgeModel(timeout: .seconds(5), clock: clock)
        let result = Task { try await model.translate("hola", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(5))
        #expect(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(5))
        await #expect(throws: TranslateCall.TranslationError.timedOut) { try await result.value }
        #expect(model.queuedCount == 0)
    }

    @Test("a session error is retried once on a rebuilt session (D-1)")
    func sessionErrorRetried() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        driver.session.script = [.fail(SessionFailure()), .answer("ok")]
        #expect(try await model.translate("hola", from: esLanguage, to: enLanguage) == "ok")
        #expect(driver.runs == 2)
    }

    @Test("a second session error fails with sessionError; later requests still work")
    func sessionErrorTwice() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        driver.session.script = [.fail(SessionFailure()), .fail(SessionFailure())]
        await #expect(throws: TranslateCall.TranslationError.sessionError(SessionFailure())) {
            try await model.translate("hola", from: esLanguage, to: enLanguage)
        }
        #expect(try await model.translate("adiós", from: esLanguage, to: enLanguage) == "EN:adiós")
    }

    @Test("an answer from a replaced session after the retry answered is ignored (NFR-TR-02)")
    func lateAnswerIgnored() async throws {
        let clock = TestClock()
        let (model, driver) = makeModel(clock)
        defer { driver.stop() }
        driver.session.script = [.hangIgnoringCancel, .answer("retried")]
        let result = Task { try await model.translate("hola", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.hungCount == 1 && clock.sleeperCount == 1 })
        clock.advance(by: .seconds(5))
        #expect(try await result.value == "retried")

        driver.session.release(with: "late")   // a second resume would trap
        #expect(try await model.translate("adiós", from: esLanguage, to: enLanguage) == "EN:adiós")
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `just test-only TranslationBridgeModelTests`
Expected: build FAILS — `extra arguments 'timeout', 'clock' in call` to `TranslationBridgeModel(...)`.

- [ ] **Step 3: Implement**

In `TranslateCall/App/TranslationBridge.swift`, replace everything from `// MARK: - TranslationBridgeModel` up to (not including) `// MARK: - TranslationBridge View` with:
```swift
// MARK: - TranslationBridgeModel

/// One translation direction's link to Apple Translation (F8.5.4 design §2).
///
/// `TranslationSession` only exists inside `.translationTask`, so `TranslationBridge` hands each
/// session to `run(session:)`, which keeps it and serves queued requests in order until the
/// configuration changes. The configuration changes only when the pair changes, on `warmUp`, or to
/// rebuild the session after a failure — never per sentence (T4). A watchdog bounds the request at
/// the head of the queue: one retry on a rebuilt session, then `timedOut` (A8, REQ-TR-10…12).
@MainActor
final class TranslationBridgeModel: ObservableObject {
    struct Pair: Equatable, Sendable {
        let source: Locale.Language
        let target: Locale.Language
    }

    @Published private(set) var configuration: TranslationSession.Configuration?

    private final class Request {
        let id: UInt64
        let text: String
        let pair: Pair
        /// 0 = first try, 1 = the retry on a rebuilt session.
        var attempts = 0
        /// Nil once resumed: every request is resumed exactly once (NFR-TR-02).
        var continuation: CheckedContinuation<String, Error>?

        init(id: UInt64, text: String, pair: Pair, continuation: CheckedContinuation<String, Error>) {
            self.id = id
            self.text = text
            self.pair = pair
            self.continuation = continuation
        }
    }

    private let timeout: Duration
    private let clock: any Clock<Duration>
    /// FIFO; the head is the request being served (REQ-TR-03).
    private var queue: [Request] = []
    private var nextID: UInt64 = 0
    /// Pair of `configuration`.
    private var livePair: Pair?
    /// Bumped whenever `configuration` changes; a run loop of an older session stops.
    private var sessionGeneration: UInt64 = 0
    /// Run loops parked on an empty queue.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var watchdog: Task<Void, Never>?
    private var watchedID: UInt64?

    init(timeout: Duration = .seconds(5), clock: any Clock<Duration> = ContinuousClock()) {
        self.timeout = timeout
        self.clock = clock
    }

    /// Requests waiting or in flight (tests).
    var queuedCount: Int { queue.count }

    // MARK: - API

    /// Translates `text`; completes within 2 × timeout once the request reaches the head of the queue.
    /// Cancelling the calling task removes the request and throws `CancellationError` (REQ-TR-13).
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        try Task.checkCancellation()
        nextID &+= 1
        let id = nextID
        let pair = Pair(source: source, target: target)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Request(id: id, text: text, pair: pair, continuation: continuation))
                if queue.count == 1 { ensureSession(for: pair) }
                armWatchdog()
                wakeRunLoops()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(id) }
        }
    }

    /// Opens a session for `pair` ahead of the first sentence (REQ-TR-05). No-op while requests are queued.
    func warmUp(from source: Locale.Language, to target: Locale.Language) {
        guard queue.isEmpty else { return }
        ensureSession(for: Pair(source: source, target: target))
    }

    /// Called by `TranslationBridge` with each session SwiftUI creates. Returns when the session is
    /// replaced (pair change, rebuild) or its task is cancelled.
    func run(session: some TranslationSessioning) async {
        let generation = sessionGeneration
        while generation == sessionGeneration, !Task.isCancelled {
            guard let head = queue.first else {
                await parkUntilWork()
                continue
            }
            guard head.pair == livePair else {
                ensureSession(for: head.pair)   // REQ-TR-04: the next session serves it
                return
            }
            do {
                let text = try await session.translatedText(for: head.text)
                finish(head.id, with: .success(text))   // also accepted from a replaced session
            } catch {
                // Replaced or cancelled mid-flight: the request stays queued for the next session (REQ-TR-03).
                guard generation == sessionGeneration, !Task.isCancelled else { return }
                attemptFailed(head.id, error: TranslationError.sessionError(error))
            }
        }
    }

    // MARK: - Session lifecycle

    private func ensureSession(for pair: Pair) {
        guard pair != livePair || configuration == nil else { return }
        livePair = pair
        configuration = TranslationSession.Configuration(source: pair.source, target: pair.target)
        sessionGeneration &+= 1
        wakeRunLoops()
    }

    private func rebuildSession() {
        configuration?.invalidate()
        sessionGeneration &+= 1
        wakeRunLoops()
    }

    private func parkUntilWork() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append($0) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wakeRunLoops() }
        }
    }

    private func wakeRunLoops() {
        let parked = waiters
        waiters.removeAll()
        parked.forEach { $0.resume() }
    }

    // MARK: - Completion, retry, timeout

    private func finish(_ id: UInt64, with result: Result<String, Error>) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let request = queue.remove(at: index)
        request.continuation?.resume(with: result)
        request.continuation = nil
        armWatchdog()
    }

    /// First failure → retry on a rebuilt session; second → the request fails (D-1, REQ-TR-11/12).
    private func attemptFailed(_ id: UInt64, error: TranslationError) {
        guard let head = queue.first, head.id == id else { return }
        if head.attempts == 0 {
            head.attempts = 1
            logger.warning("Translation attempt failed (\(error.localizedDescription, privacy: .public)) — retrying")
            rebuildSession()
            armWatchdog(restart: true)
        } else {
            logger.error("Translation failed twice — \(error.localizedDescription, privacy: .public)")
            finish(id, with: .failure(error))
            rebuildSession()   // a stuck session must not hold up the next request (REQ-TR-12)
        }
    }

    private func cancelRequest(_ id: UInt64) {
        finish(id, with: .failure(CancellationError()))
    }

    /// Bounds the head of the queue. Restarted for a new head or a retry; stopped when the queue is empty.
    private func armWatchdog(restart: Bool = false) {
        guard let head = queue.first else {
            watchdog?.cancel()
            watchdog = nil
            watchedID = nil
            return
        }
        guard restart || watchedID != head.id else { return }
        watchdog?.cancel()
        watchedID = head.id
        let id = head.id
        let clock = clock
        let timeout = timeout
        watchdog = Task { [weak self] in
            do { try await clock.sleep(for: timeout) } catch { return }
            self?.attemptFailed(id, error: .timedOut)
        }
    }
}

```
(Compared with Task 3: `Request.attempts`; `timeout`, `clock`, `watchdog`, `watchedID`; `armWatchdog` called on enqueue and after every completion; `attemptFailed` replaces the direct failure in `run`; `rebuildSession()`. The doc comment now names the watchdog.)

- [ ] **Step 4: Run the tests (several times: they drive timing through `TestClock`, so they must be deterministic) and lint**

Run: `just test-only TranslationBridgeModelTests AppleTranslationServiceTests` three times → PASS every time (14 tests).
Run: `just lint` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/App/TranslationBridge.swift TranslateCallTests/TranslationBridgeModelTests.swift
git commit -m "feat(translation): bound each request — 5 s watchdog, one retry on a rebuilt session, then timedOut (F8.5.4 A8, REQ-TR-10…12)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `TranslationHostWindow` — bridges off screen, independent of the main window (D-2, REQ-TR-30/31, NFR-TR-01)

**Files:**
- Create: `TranslateCall/App/TranslationHostWindow.swift`
- Modify: `TranslateCall/App/AppContainer.swift`, `TranslateCall/App/TranslateCallApp.swift:11-15`, `TranslateCall/App/TranslationBridge.swift` (view doc comment)
- Modify: `TranslateCallTests/Integration/Prerequisites.swift:45-55`
- Test: `TranslateCallTests/TranslationHostWindowTests.swift`, `TranslateCallTests/Integration/TranslationBridgeIntegrationTests.swift`

**Interfaces:**
- Consumes: `TranslationBridge`, `TranslationBridgeModel` (Tasks 3–4); `latencySentences`, `median`, `percentile90` (Task 1).
- Produces: `@MainActor final class TranslationHostWindow` — `init(outgoing: TranslationBridgeModel, incoming: TranslationBridgeModel)`, `let window: NSWindow`, `func close()`. `AppContainer.translationHost: TranslationHostWindow`. `hostTranslationBridge() -> (TranslationBridgeModel, TranslationHostWindow)` (the call sites' `window.close()` keep compiling).

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/TranslationHostWindowTests.swift`:
```swift
import AppKit
import Testing
@testable import TranslateCall

@Suite("TranslationHostWindow (F8.5.4)") @MainActor
struct TranslationHostWindowTests {

    @Test("off screen, never key or main, hidden from the Window menu, kept when closed (REQ-TR-30)")
    func invisibleAndInert() {
        let host = TranslationHostWindow(outgoing: TranslationBridgeModel(), incoming: TranslationBridgeModel())
        defer { host.close() }
        let window = host.window
        #expect(window.frame.maxX < 0 && window.frame.maxY < 0)
        #expect(!window.canBecomeKey)
        #expect(!window.canBecomeMain)
        #expect(window.isExcludedFromWindowsMenu)
        #expect(window.ignoresMouseEvents)
        #expect(!window.isReleasedWhenClosed)
        #expect(window.contentView != nil)
    }
}
```

`TranslateCallTests/Integration/TranslationBridgeIntegrationTests.swift`:
```swift
import AppKit
import Foundation
import Testing
@testable import TranslateCall

extension IntegrationTests {
    /// The production path (F8.5.4): `AppleTranslationService` → `TranslationBridgeModel` →
    /// `TranslationHostWindow`, with the session kept open between sentences.
    @Suite("Translation bridge (kept session)", .serialized) @MainActor
    struct TranslationBridgeIntegrationTests {
        @Test("the off-screen host window translates with no other window involved (REQ-TR-30)")
        func hostWindowTranslates() async throws {
            try await requireTranslationPack(from: "es", to: "en")
            let (model, host) = hostTranslationBridge()
            defer { host.close() }
            let service = AppleTranslationService(model: model)
            let output = try await service.translate(text: "Gracias a todos por venir.",
                                                     from: Locale.Language(identifier: "es"),
                                                     to: Locale.Language(identifier: "en"))
            #expect(output.lowercased().contains("thank"), "“\(output)”")
        }

        @Test("warm session latency is recorded and stays under the regression ceiling (NFR-TR-01)")
        func keptSessionLatency() async throws {
            try await requireTranslationPack(from: "es", to: "en")
            let (model, host) = hostTranslationBridge()
            defer { host.close() }
            let service = AppleTranslationService(model: model)
            let src = Locale.Language(identifier: "es"), dst = Locale.Language(identifier: "en")
            await service.warmUp(from: src, to: dst)
            _ = try await service.translate(text: "Hola.", from: src, to: dst)   // first call loads the model

            var samples: [Double] = []
            for sentence in latencySentences {
                let start = ContinuousClock.now
                _ = try await service.translate(text: sentence, from: src, to: dst)
                samples.append(start.duration(to: .now).milliseconds)
            }
            let typical = median(samples)
            await LatencyReport.shared.record(fixture: "es→en AppleTranslationService warm (median)", stage: .translate,
                                              ms: typical)
            await LatencyReport.shared.record(fixture: "es→en AppleTranslationService warm (p90)", stage: .translate,
                                              ms: percentile90(samples))
            #expect(typical <= 400, "warm median \(typical) ms")
        }
    }
}
```
The 400 ms ceiling is option (a) of P1 (measured while planning: 246 ms median, p90 288). If the user chose another NFR-TR-01 at the Task 1 gate, put that value here.

`TranslateCallTests/Integration/Prerequisites.swift`: replace
```swift
/// Hosts a TranslationBridge in an offscreen window so `.translationTask` runs inside the test host.
/// Keep the returned window alive for the duration of the test.
@MainActor
func hostTranslationBridge() -> (TranslationBridgeModel, NSWindow) {
    let model = TranslationBridgeModel()
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 10, height: 10),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: TranslationBridge(model: model))
    window.orderBack(nil)
    return (model, window)
}
```
with
```swift
/// Hosts a bridge the way the app does (`TranslationHostWindow`, F8.5.4 D-2) so `.translationTask`
/// runs inside the test host. Keep the returned host alive for the duration of the test; close it after.
@MainActor
func hostTranslationBridge() -> (TranslationBridgeModel, TranslationHostWindow) {
    let model = TranslationBridgeModel()
    let host = TranslationHostWindow(outgoing: model, incoming: TranslationBridgeModel())
    return (model, host)
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `just test-only TranslationHostWindowTests`
Expected: build FAILS — `cannot find 'TranslationHostWindow' in scope`.

- [ ] **Step 3: Implement**

`TranslateCall/App/TranslationHostWindow.swift`:
```swift
import AppKit
import SwiftUI

/// Keeps both call-time translation bridges alive for the app's lifetime in an off-screen window,
/// so translation does not depend on the main window being open (F8.5.4 D-2, REQ-TR-30/31).
/// Borderless windows never become key or main; this one is also hidden from the Window menu.
@MainActor
final class TranslationHostWindow {
    let window: NSWindow

    init(outgoing: TranslationBridgeModel, incoming: TranslationBridgeModel) {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = NSHostingView(rootView: HStack(spacing: 0) {
            TranslationBridge(model: outgoing)
            TranslationBridge(model: incoming)
        })
        window.orderBack(nil)
        self.window = window
    }

    /// Tests only: the app keeps its host window until it quits.
    func close() {
        window.close()
    }
}
```

`TranslateCall/App/AppContainer.swift`:
- replace
  ```swift
  /// 4. `TranslationBridgeModel` × 2 (outgoing + incoming, no deps)
  ```
  with
  ```swift
  /// 4. `TranslationBridgeModel` × 2 (outgoing + incoming, no deps), hosted off-screen by `TranslationHostWindow`
  ```
- after `    let incomingBridgeModel: TranslationBridgeModel` add
  ```swift
      /// Keeps both bridges running with the main window closed (F8.5.4 REQ-TR-30/31).
      let translationHost: TranslationHostWindow
  ```
- after `        let inBridge = TranslationBridgeModel()` add
  ```swift
          translationHost = TranslationHostWindow(outgoing: outBridge, incoming: inBridge)
  ```

`TranslateCall/App/TranslateCallApp.swift`: replace
```swift
            ZStack {
                ContentView()
                TranslationBridge(model: container.outgoingBridgeModel)
                TranslationBridge(model: container.incomingBridgeModel)
            }
```
with
```swift
            // Translation bridges live in AppContainer's TranslationHostWindow, not here (F8.5.4 D-2).
            ContentView()
```
(the `.environmentObject(…)` modifiers that followed the `ZStack` now apply to `ContentView()`).

`TranslateCall/App/TranslationBridge.swift`, in the `TranslationBridge` view's doc comment replace
```swift
/// macOS 15. Each new configuration makes SwiftUI cancel the running task and call `run` again.
```
with
```swift
/// macOS 15. Lives in `TranslationHostWindow`, never in the main window (F8.5.4 D-2).
```

- [ ] **Step 4: Run the unit test, the translation integration suites and lint**

Run: `just test-only TranslationHostWindowTests` → PASS.
Run (one command per suite, see Global Constraints): `TranslationBridgeIntegrationTests`, `TranslationFixtureTests`, `OutgoingPipelineFixtureTests` → PASS; `build/reports/latency.json` gains `es→en AppleTranslationService warm (median)` and `(p90)`.
Run: `just lint` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/App TranslateCallTests
git commit -m "feat(translation): host both bridges in an off-screen TranslationHostWindow owned by AppContainer (F8.5.4 D-2, REQ-TR-30/31)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Coordinator — warm-up at Start; a failed sentence is a notice, configuration errors alert once (D-1, REQ-TR-05, REQ-TR-20/21)

**Files:**
- Modify: `TranslateCall/Core/Audio/AudioCoordinator.swift:61` (state), `:186-188` (`start`)
- Modify: `TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift` (translation handlers, `makeAlertItem`, end of file)
- Modify: `TranslateCallTests/TranslationPipelineTests.swift` (`MockTranslationService`)
- Test: `TranslateCallTests/AudioCoordinatorTranslationTests.swift`

**Interfaces:**
- Consumes: `TranslationService.warmUp(from:to:)`, `TranslationError.timedOut` (Task 3), `showTTSNotice(_:)` (F8.5.2), `CoordinatorMocks` (`AudioCoordinatorTests.swift`).
- Produces: `AudioCoordinator.alertedTranslationErrors: Set<String>` (reset by `start`), `func warmUpTranslation() async`, `func handleTranslationFailure(_ error: Error, outgoing: Bool)`. `MockTranslationService.errors: [Error]` (thrown one per call before `shouldThrow`) and `warmUpCalls: [(source: Locale.Language, target: Locale.Language)]`.

- [ ] **Step 1: Write the failing tests**

In `TranslateCallTests/TranslationPipelineTests.swift` replace the whole `MockTranslationService` (from `// MARK: - Mock TranslationService` up to, not including, `// MARK: - Pipeline tests`) with:
```swift
// MARK: - Mock TranslationService

/// Returns "TRANSLATED: <input>" at once. `errors` are thrown one per call, in order, before
/// `shouldThrow` (thrown on every call) is considered.
final class MockTranslationService: TranslationService {
    var shouldThrow: Error?
    var errors: [Error] = []
    private(set) var translateCallCount = 0
    private(set) var lastTranslatedText: String?
    private(set) var warmUpCalls: [(source: Locale.Language, target: Locale.Language)] = []

    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        translateCallCount += 1
        lastTranslatedText = text
        if !errors.isEmpty { throw errors.removeFirst() }
        if let error = shouldThrow { throw error }
        return "TRANSLATED: \(text)"
    }

    func warmUp(from source: Locale.Language, to target: Locale.Language) async {
        warmUpCalls.append((source, target))
    }
}

```

`TranslateCallTests/AudioCoordinatorTranslationTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

@MainActor
private func makeCoordinator(_ mocks: CoordinatorMocks) -> AudioCoordinator {
    AudioCoordinator(
        audioCapture: mocks.mockAudioCapture,
        systemCapture: mocks.mockSystemCapture,
        outgoingVADFactory: { mocks.mockVADFactory },
        incomingVADFactory: { mocks.mockIncomingVAD },
        outgoingSTTFactory: { _ in mocks.mockOutgoingSTT },
        incomingSTTFactory: { _ in mocks.mockIncomingSTT },
        outgoingTranslationService: mocks.mockOutgoingTranslation,
        incomingTranslationService: mocks.mockIncomingTranslation,
        outgoingTTSFactory: { _, _ in mocks.mockOutgoingTTS },
        incomingTTSFactory: { _, _ in mocks.mockIncomingTTS },
        languagePairManager: mocks.languagePairManager,
        noticeClock: TestClock()
    )
}

private func transcript(_ text: String) -> TranscriptionResult {
    TranscriptionResult(text: text, confidence: 1, locale: Locale(identifier: "es-ES"), capturedAt: .now, audioDuration: 1)
}

@Suite("AudioCoordinator translation (F8.5.4)", .serialized) @MainActor
struct AudioCoordinatorTranslationTests {

    @Test("start warms up both directions with their own pair (REQ-TR-05)")
    func startWarmsUpBothDirections() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()

        // LanguagePairManager may still be settling its pair in the background: compare the two calls.
        let outgoing = mocks.mockOutgoingTranslation.warmUpCalls
        let incoming = mocks.mockIncomingTranslation.warmUpCalls
        #expect(outgoing.count == 1 && incoming.count == 1)
        #expect(outgoing.first?.source == incoming.first?.target)
        #expect(outgoing.first?.target == incoming.first?.source)
        #expect(outgoing.first?.source != outgoing.first?.target)
        await coordinator.stop()
    }

    @Test("a sentence that cannot be translated is skipped with a notice, no alert; the next one is spoken (REQ-TR-20)")
    func outgoingFailureIsANotice() async {
        let mocks = CoordinatorMocks()
        mocks.mockOutgoingTranslation.errors = [TranslationError.timedOut]
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("uno"))
        #expect(await waitUntil { coordinator.ttsNotice == "Couldn't translate your sentence — skipped" })
        await mocks.mockOutgoingSTT.injectTranscription(transcript("dos"))
        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 1 })
        #expect(await mocks.mockOutgoingTTS.speakCalls.first?.text == "TRANSLATED: dos")
        #expect(coordinator.errorAlert == nil)
        await coordinator.stop()
    }

    @Test("an incoming failure names the other side (REQ-TR-20)")
    func incomingFailureIsANotice() async {
        let mocks = CoordinatorMocks()
        mocks.mockIncomingTranslation.errors = [TranslationError.sessionError(CancellationError())]
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { coordinator.isIncomingActive })

        await mocks.mockIncomingSTT.injectTranscription(transcript("hello"))
        #expect(await waitUntil { coordinator.ttsNotice == "Couldn't translate their sentence — skipped" })
        #expect(coordinator.errorAlert == nil)
        await coordinator.stop()
    }

    @Test("a configuration error alerts once per session; the next session starts clean (REQ-TR-21)")
    func configurationErrorAlertsOncePerSession() async {
        let mocks = CoordinatorMocks()
        let unsupported = TranslationError.unsupportedPair(Locale.Language(identifier: "es"),
                                                           Locale.Language(identifier: "tlh"))
        mocks.mockOutgoingTranslation.shouldThrow = unsupported
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("uno"))
        #expect(await waitUntil { coordinator.errorAlert?.title == "Language Pair Unsupported" })
        coordinator.errorAlert = nil
        await mocks.mockOutgoingSTT.injectTranscription(transcript("dos"))
        #expect(await waitUntil { mocks.mockOutgoingTranslation.translateCallCount == 2 })
        #expect(coordinator.errorAlert == nil)
        #expect(coordinator.ttsNotice == nil)

        await coordinator.stop()
        await coordinator.start()   // the mock STT stream ended with the first session: check the reset directly
        #expect(coordinator.alertedTranslationErrors.isEmpty)
        await coordinator.stop()
    }

    @Test("a cancelled translation (session stopping) is silent")
    func cancellationIsSilent() async {
        let mocks = CoordinatorMocks()
        mocks.mockOutgoingTranslation.errors = [CancellationError()]
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("uno"))
        #expect(await waitUntil { mocks.mockOutgoingTranslation.translateCallCount == 1 })
        await mocks.mockOutgoingSTT.injectTranscription(transcript("dos"))
        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 1 })
        #expect(coordinator.errorAlert == nil)
        #expect(coordinator.ttsNotice == nil)
        await coordinator.stop()
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `just test-only AudioCoordinatorTranslationTests`
Expected: build FAILS — `value of type 'AudioCoordinator' has no member 'alertedTranslationErrors'`. (With that line commented out, `startWarmsUpBothDirections`, `outgoingFailureIsANotice` and `incomingFailureIsANotice` fail: no warm-up, and failures still raise `errorAlert`.)

- [ ] **Step 3: Implement**

`TranslateCall/Core/Audio/AudioCoordinator.swift`: after
```swift
    @Published var errorAlert: AlertItem?
```
add
```swift
    /// Translation errors already alerted in this session: each kind is alerted once (F8.5.4 REQ-TR-21).
    var alertedTranslationErrors: Set<String> = []
```
and in `start(captureTarget:blackHoleDeviceID:)` replace
```swift
        self.captureTarget = captureTarget
        micEchoGate = makeMicEchoGate()
```
with
```swift
        self.captureTarget = captureTarget
        micEchoGate = makeMicEchoGate()
        alertedTranslationErrors.removeAll()
        await warmUpTranslation()   // returns at once: the sessions open while capture starts (REQ-TR-05)
```

`TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift`:
- in `handleOutgoingTranslation(of:)` replace
  ```swift
              await outgoingTTS?.speak(text: translated, locale: locale)
          } catch {
              errorAlert = makeAlertItem(for: error)
          }
      }
  ```
  with
  ```swift
              await outgoingTTS?.speak(text: translated, locale: locale)
          } catch {
              handleTranslationFailure(error, outgoing: true)
          }
      }
  ```
- in `handleIncomingTranslation(of:)` replace
  ```swift
              await incomingTTS?.speak(text: translated, locale: locale)
          } catch {
              errorAlert = makeAlertItem(for: error)
          }
      }
  ```
  with
  ```swift
              await incomingTTS?.speak(text: translated, locale: locale)
          } catch {
              handleTranslationFailure(error, outgoing: false)
          }
      }

      /// Opens both directions' translation sessions ahead of the first sentence (F8.5.4 REQ-TR-05).
      func warmUpTranslation() async {
          let source = languagePairManager.sourceLanguage
          let target = languagePairManager.targetLanguage
          await outgoingTranslationService.warmUp(from: source, to: target)
          await incomingTranslationService.warmUp(from: target, to: source)
      }

      /// A sentence could not be translated (F8.5.4 D-1). The bridge already retried once, so the
      /// sentence is skipped with a notice and the direction moves on (REQ-TR-20). Errors that will
      /// repeat for every sentence raise the alert, once per session per kind (REQ-TR-21).
      func handleTranslationFailure(_ error: Error, outgoing: Bool) {
          if error is CancellationError { return }   // the session is stopping
          if let kind = (error as? TranslationError)?.configurationKind {
              guard alertedTranslationErrors.insert(kind).inserted else { return }
              errorAlert = makeAlertItem(for: error)
              return
          }
          logger.warning("Translation failed — \(error.localizedDescription, privacy: .public)")
          showTTSNotice(outgoing ? "Couldn't translate your sentence — skipped"
                                 : "Couldn't translate their sentence — skipped")
      }
  ```
- in `makeAlertItem(for:)`, before `        case TranslationError.unsupportedPair(_, _):` add
  ```swift
          case TranslationError.modelNotLoaded:
              return AlertItem(
                  title: "Languages Not Downloaded",
                  message: "Download this language pair (the Download button next to the languages), then start again.",
                  action: nil
              )
  ```
- append at the end of the file:
  ```swift

  // MARK: - Translation error kinds

  private extension TranslationError {
      /// Errors that repeat for every sentence until the user changes the setup (F8.5.4 REQ-TR-21).
      var configurationKind: String? {
          switch self {
          case .unsupportedPair: "unsupportedPair"
          case .modelNotLoaded: "modelNotLoaded"
          case .sessionError, .timedOut, .networkUnavailable: nil
          }
      }
  }
  ```

- [ ] **Step 4: Run the tests and lint**

Run: `just test-only AudioCoordinatorTranslationTests AudioCoordinatorTests AudioCoordinatorTTSTests TranslationPipelineTests` → PASS (49 tests).
Run: `just lint` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/Audio TranslateCallTests
git commit -m "feat(pipeline): warm translation up at Start; a failed sentence is a notice, configuration errors alert once (F8.5.4 REQ-TR-05, 20, 21)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `supports` is the engine's answer, not a default (T5, REQ-TR-50/51)

**Files:**
- Modify: `TranslateCall/Core/Translation/TranslationService.swift`, `TranslateCall/Core/Translation/AppleTranslationService.swift`, `TranslateCall/Core/Translation/TranslationEngineSelector.swift:1-59`
- Modify: `TranslateCall/Features/Main/AudioViewModel.swift` (`PassthroughTranslationService`)
- Modify: `TranslateCallTests/TranslationPipelineTests.swift` (`MockTranslationService`)
- Test: `TranslateCallTests/Integration/TranslationPackTests.swift`

**Interfaces:**
- Consumes: Task 3 services.
- Produces: `TranslationService.supports(source:target:) async -> Bool` with **no default**; `AppleTranslationService.supports` = `LanguageAvailability` status `.installed` or `.supported`; `TranslationEngineSelector.supports` delegates to `makeOutgoingService()`; `MockTranslationService.supportsResult: Bool`.

- [ ] **Step 1: Write the failing tests**

In `TranslateCallTests/Integration/TranslationPackTests.swift` replace the doc comment
```swift
    /// `TranslationService.supports` defaults to `true`, so tests must ask the framework directly
    /// whether a pack is installed (review finding: missing packs hung until the 300 s allowance).
```
with
```swift
    /// Prerequisites ask the framework whether a pack is *installed*; `supports` also accepts packs that
    /// are only downloadable (review finding: missing packs hung until the 300 s allowance).
```
and after the test `installedPairIsDetected` add:
```swift

        @Test("AppleTranslationService.supports is the framework's answer (T5, REQ-TR-50)") @MainActor
        func appleSupportsMirrorsAvailability() async {
            let service = AppleTranslationService(model: TranslationBridgeModel())
            #expect(await service.supports(source: Locale.Language(identifier: "es"),
                                           target: Locale.Language(identifier: "en")))
            #expect(await service.supports(source: Locale.Language(identifier: "en"),
                                           target: Locale.Language(identifier: "tlh")) == false)
        }

        @Test("TranslationEngineSelector.supports asks the engine's service (REQ-TR-51)") @MainActor
        func selectorDelegatesToService() async {
            let selector = TranslationEngineSelector(outgoingBridge: TranslationBridgeModel(),
                                                     incomingBridge: TranslationBridgeModel())
            #expect(await selector.supports(source: Locale.Language(identifier: "es"),
                                            target: Locale.Language(identifier: "en")))
            #expect(await selector.supports(source: Locale.Language(identifier: "en"),
                                            target: Locale.Language(identifier: "tlh")) == false)
        }
```

- [ ] **Step 2: Run the tests to see them fail**

Run the integration suite `TranslationPackTests` (Global Constraints command).
Expected: `appleSupportsMirrorsAvailability` FAILS (`en → tlh` returns `true`: the protocol default).

- [ ] **Step 3: Implement**

`TranslateCall/Core/Translation/TranslationService.swift`: in `protocol TranslationService` replace
```swift
    func supports(source: Locale.Language, target: Locale.Language) async -> Bool
```
with
```swift
    /// Whether the engine can translate this pair; no default, so every engine answers for itself (T5).
    func supports(source: Locale.Language, target: Locale.Language) async -> Bool
```
and in `extension TranslationService` delete
```swift
    func supports(source: Locale.Language, target: Locale.Language) async -> Bool { true }
```

`TranslateCall/Core/Translation/AppleTranslationService.swift`: replace
```swift
import Foundation
```
with
```swift
import Foundation
@preconcurrency import Translation
```
and after `warmUp(from:to:)` add
```swift

    /// `.installed` or `.supported` (downloadable) — the framework's answer, not a default (T5, REQ-TR-50).
    func supports(source: Locale.Language, target: Locale.Language) async -> Bool {
        let status = await LanguageAvailability().status(from: source, to: target)
        return status == .installed || status == .supported
    }
```

`TranslateCall/Core/Translation/TranslationEngineSelector.swift`: delete the import line `@preconcurrency import Translation` and replace the body of `supports(source:target:)`
```swift
        switch preferredEngine {
        case .appleTranslation:
            let status = await LanguageAvailability().status(
                from: source, to: target
            )
            return status == .installed || status == .supported
        }
```
with
```swift
        await makeOutgoingService().supports(source: source, target: target)   // one source of truth (REQ-TR-51)
```

`TranslateCall/Features/Main/AudioViewModel.swift`, in `PassthroughTranslationService` after
```swift
    ) async throws -> String { text }
```
add
```swift
    func supports(source: Locale.Language, target: Locale.Language) async -> Bool { true }
```

`TranslateCallTests/TranslationPipelineTests.swift`, in `MockTranslationService` after `    var errors: [Error] = []` add
```swift
    var supportsResult = true
```
and after its `warmUp` method add
```swift

    func supports(source: Locale.Language, target: Locale.Language) async -> Bool { supportsResult }
```

- [ ] **Step 4: Run the tests and lint**

Run the integration suite `TranslationPackTests` → PASS (4 tests). `just test-only TranslationEngineSelectorTests TranslationPipelineTests` → PASS. `just lint` → exit 0 (`AudioViewModel.swift` is now 399 lines — P12).

- [ ] **Step 5: Commit**

```bash
git add TranslateCall TranslateCallTests
git commit -m "fix(translation): supports has no default; Apple asks LanguageAvailability; the selector delegates (F8.5.4 T5)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: No `nonisolated(unsafe)` in Core/STT and Core/Translation — `Mutex<Locale>` and an opengrep rule (A10, REQ-TR-60/61)

**Files:**
- Create: `.opengrep/rules/swift-isolation.yml`, `.opengrep/rules/swift-isolation.swift` (P5)
- Modify: `.opengrep/README.md` (severity table)
- Modify: `TranslateCall/Core/STT/AppleSpeechService.swift`, `TranslateCall/Core/STT/WhisperSpeechService.swift`, `TranslateCall/Core/STT/ParakeetSpeechService.swift`
- Test: `TranslateCallTests/STTLocaleIsolationTests.swift`

**Interfaces:**
- Consumes: Task 3 (the `nonisolated(unsafe)` in `AppleTranslationService` is already gone).
- Produces: in each STT service `private let localeState: Mutex<Locale>` and `nonisolated var locale: Locale { localeState.withLock { $0 } }` (the protocol requirement `nonisolated var locale: Locale { get }` is unchanged); rule `no-nonisolated-unsafe-stt-translation` (ERROR).

- [ ] **Step 1: Add the rule first (it fails the scan on today's code) and the locale tests**

`.opengrep/rules/swift-isolation.swift`:
```swift
actor SpeechService {
    // ruleid: no-nonisolated-unsafe-stt-translation
    nonisolated(unsafe) private(set) var locale: Locale
    // ok: no-nonisolated-unsafe-stt-translation
    private let localeState: Mutex<Locale>
    // ok: no-nonisolated-unsafe-stt-translation
    nonisolated var current: Locale { localeState.withLock { $0 } }
}
```

`.opengrep/rules/swift-isolation.yml`:
```yaml
rules:
  - id: no-nonisolated-unsafe-stt-translation
    languages: [regex]
    severity: ERROR
    message: "F8.5.4: no nonisolated(unsafe) in Core/STT or Core/Translation. Guard cross-isolation state with a Mutex or keep it actor-isolated (see specs/m8.5-stabilization/f8.5.4-translation)."
    metadata: { audit_ref: "F8.5.4 / A10" }
    pattern-regex: 'nonisolated\(unsafe\)'
    paths:
      include: ["TranslateCall/Core/STT/", "TranslateCall/Core/Translation/", ".opengrep/rules/"]
```

`.opengrep/README.md`: replace the row
```markdown
| `nonisolated-unsafe-justified` | WARNING | `nonisolated(unsafe)` without a `// SAFETY:` comment on the previous line | clean in Core/Audio, Core/TTS, Core/VoiceCloning; 4 left in Core/STT and Core/Translation |
```
with
```markdown
| `nonisolated-unsafe-justified` | WARNING | `nonisolated(unsafe)` without a `// SAFETY:` comment on the previous line | clean in Core/Audio, Core/TTS, Core/VoiceCloning, Core/STT, Core/Translation (F8.5.4) |
| `no-nonisolated-unsafe-stt-translation` | ERROR (F8.5.4) | `nonisolated(unsafe)` in Core/STT or Core/Translation; use a `Mutex` or actor isolation | A10 — the last 4 removed in F8.5.4 |
```

`TranslateCallTests/STTLocaleIsolationTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

private struct NoModel: Error {}

/// `locale` is read without `await` and written by `setLocale` on the actor (F8.5.4 REQ-TR-60).
/// No model is loaded: the factories are never called before `activate`.
@Suite("STT locale isolation (F8.5.4)")
struct STTLocaleIsolationTests {

    private static func services() -> [any SpeechRecognizerService] {
        [
            AppleSpeechService(locale: Locale(identifier: "es-ES")),
            WhisperSpeechService(locale: Locale(identifier: "es-ES"), pipeFactory: { throw NoModel() }),
            ParakeetSpeechService(locale: Locale(identifier: "es-ES"), transcriberFactory: { throw NoModel() }),
        ]
    }

    @Test("setLocale is visible to nonisolated reads")
    func setLocaleVisible() async {
        for service in Self.services() {
            #expect(service.locale == Locale(identifier: "es-ES"))
            await service.setLocale(Locale(identifier: "uk-UA"))
            #expect(service.locale == Locale(identifier: "uk-UA"), "\(type(of: service))")
        }
    }

    @Test("reads from other tasks while the actor writes always see a whole value")
    func concurrentReads() async {
        let locales = [Locale(identifier: "es-ES"), Locale(identifier: "en-US"), Locale(identifier: "uk-UA")]
        for service in Self.services() {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for index in 0..<300 { await service.setLocale(locales[index % 3]) }
                    return true
                }
                for _ in 0..<4 {
                    group.addTask { (0..<300).allSatisfy { _ in locales.contains(service.locale) } }
                }
                for await allValid in group { #expect(allValid) }
            }
        }
    }
}
```
(These tests pass on today's code too — `nonisolated(unsafe)` is unchecked, not wrong in practice; they pin the behaviour across the change. The failing check of this task is the scan.)

- [ ] **Step 2: Scan to see it fail**

Run: `just scan`
Expected: `✓ opengrep rule tests`, then FAIL in the ERROR pass with 3 findings of `no-nonisolated-unsafe-stt-translation` (`AppleSpeechService.swift`, `WhisperSpeechService.swift`, `ParakeetSpeechService.swift`).

- [ ] **Step 3: Implement**

`TranslateCall/Core/STT/AppleSpeechService.swift`:
- after `import Speech` add `import Synchronization`;
- replace
  ```swift
      // nonisolated(unsafe): locale is a value type written only from actor context (setLocale),
      // read nonisolated to satisfy protocol without requiring await at call site.
      nonisolated(unsafe) private(set) var locale: Locale
  ```
  with
  ```swift
      /// Read without `await` (protocol requirement); written by `setLocale` on the actor. The lock makes
      /// the cross-isolation read race-free (F8.5.4 REQ-TR-60).
      private let localeState: Mutex<Locale>
      nonisolated var locale: Locale { localeState.withLock { $0 } }
  ```
- in `init(locale:config:)` replace `        self.locale = locale` with `        self.localeState = Mutex(locale)`;
- in `setLocale(_:)` replace `        locale = newLocale` with `        localeState.withLock { $0 = newLocale }`.

`TranslateCall/Core/STT/WhisperSpeechService.swift`:
- after `import OSLog` add `import Synchronization`;
- replace
  ```swift
      nonisolated(unsafe) private(set) var locale: Locale
  ```
  with
  ```swift
      /// Read without `await` (protocol requirement); written by `setLocale` on the actor. The lock makes
      /// the cross-isolation read race-free (F8.5.4 REQ-TR-60).
      private let localeState: Mutex<Locale>
      nonisolated var locale: Locale { localeState.withLock { $0 } }
  ```
- in `init(locale:config:whisperConfig:pipeFactory:)` replace `        self.locale = locale` with `        self.localeState = Mutex(locale)`;
- in `setLocale(_:)` replace `        locale = newLocale` with `        localeState.withLock { $0 = newLocale }`.

`TranslateCall/Core/STT/ParakeetSpeechService.swift`:
- after `import OSLog` add `import Synchronization`;
- replace
  ```swift
      // nonisolated(unsafe): value type written only from actor context (setLocale);
      // read nonisolated to satisfy protocol without requiring await at call site.
      nonisolated(unsafe) private(set) var locale: Locale
  ```
  with
  ```swift
      /// Read without `await` (protocol requirement); written by `setLocale` on the actor. The lock makes
      /// the cross-isolation read race-free (F8.5.4 REQ-TR-60).
      private let localeState: Mutex<Locale>
      nonisolated var locale: Locale { localeState.withLock { $0 } }
  ```
- in `init(locale:config:parakeetConfig:transcriberFactory:)` replace `        self.locale = locale` with `        self.localeState = Mutex(locale)`;
- in `setLocale(_:)` replace `        locale = newLocale` with `        localeState.withLock { $0 = newLocale }`.

Every other read of `locale` in these files (`SFSpeechRecognizer(locale: locale)`, `WhisperLanguages.whisperCode(for: locale)`, `TranscriptionResult(… locale: locale …)`, the Parakeet guard and log) now goes through the computed property unchanged.

- [ ] **Step 4: Scan, test, lint**

Run: `just scan` → `✓ opengrep rule tests`, `✓ no blocking findings`.
Run: `grep -rn "nonisolated(unsafe)" TranslateCall/Core/STT TranslateCall/Core/Translation` → no output.
Run: `just test-only STTLocaleIsolationTests ParakeetSpeechServiceTests AppleSpeechServiceTests` → PASS (24 tests).
Run: `just lint` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add .opengrep TranslateCall/Core/STT TranslateCallTests/STTLocaleIsolationTests.swift
git commit -m "fix(stt): locale behind a Mutex; opengrep bans nonisolated(unsafe) in Core/STT and Core/Translation (F8.5.4 A10)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Docs, backlog, manual verification and the PR gate

**Files:**
- Modify: `docs/ARCHITECTURE.md:452-502` (TranslationBridge section), `docs/ARCHITECTURE.md:882-888`
- Modify: `specs/m8.5-stabilization/backlog.md`, this file (manual checklist results)

**Interfaces:**
- Consumes: the finished feature (Tasks 1–8).
- Produces: backlog rows fixed with their pinning tests; new rows A26, T7; manual results recorded.

- [ ] **Step 1: Architecture docs**

`docs/ARCHITECTURE.md`: replace everything from `#### TranslationBridge (SwiftUI Workaround)` up to (not including) the `---` line before `### 5. Speech Synthesis Layer` with:
````markdown
#### TranslationBridge (F8.5.4)

`TranslationSession` has no public initializer on macOS 15: it only exists inside SwiftUI's
`.translationTask`. Each direction has a `TranslationBridgeModel` whose `TranslationBridge` view lives in
`TranslationHostWindow`, an off-screen borderless window owned by `AppContainer` — translation keeps
working with the main window closed.

```
AudioCoordinator ─► AppleTranslationService ─► TranslationBridgeModel (FIFO queue, watchdog)
                                                   │ configuration: pair change / warm-up / rebuild only
                                                   ▼
                    TranslationHostWindow ─► TranslationBridge ─ .translationTask { run(session:) }
```

- **One session per direction, kept open.** `run(session:)` serves queued requests until the
  configuration changes; it never invalidates per sentence.
- **Warm-up at Start.** The first translation of a pair costs ~1.1 s (model load); opening the session
  at Start brings the first sentence down to ~0.2–0.3 s. Later sentences cost ~250–450 ms: that is
  model inference, not session set-up (measured in F8.5.4, `TranslationLatencyTests`).
- **Bounded.** The request being served has a 5 s watchdog: one retry on a rebuilt session, then
  `TranslationError.timedOut`. The coordinator skips that sentence with a notice; only configuration
  errors (unsupported pair, models not downloaded) raise an alert, once per session.
- **Downloads** use a separate `.translationTask` on `LanguagePairView`, so the system sheet appears
  in the main window.
````

and replace
```markdown
**Solution**: Use `TranslationBridge` pattern (see Section 4).

**PoC Required**: Test before development to confirm workaround works.
```
with
```markdown
**Solution**: `TranslationBridge` in an off-screen `TranslationHostWindow`, one kept session per direction (see Section 4, F8.5.4).
```

- [ ] **Step 2: Backlog**

In `specs/m8.5-stabilization/backlog.md`:
- sub-features table: replace the row `| F8.5.4 Translation | — | A8, T4 (`invalidate()`), T5 |` with `| F8.5.4 Translation | `f8.5.4-translation/` | A8, T4 (translation), T5, A10 (Core/STT, Core/Translation) |`;
- set the "Guard in place" column:

| # | Guard in place |
|---|---|
| A8 | fixed in F8.5.4 (PR #…) — FIFO queue, 5 s watchdog + one retry, bridges in `TranslationHostWindow`, downloads on their own `.translationTask`: `TranslationBridgeModelTests.fifoOrder`, `.timeoutTwice`, `.neverFires`, `.lateAnswerIgnored`, `TranslationHostWindowTests`, `TranslationBridgeIntegrationTests.hostWindowTranslates`, `TranslationPipelineTests.downloadUsesSession` |
| A10 | Core/Audio, Core/TTS, Core/VoiceCloning clean (F8.5.1–F8.5.2); Core/STT and Core/Translation clean (F8.5.4): `STTLocaleIsolationTests`; opengrep `no-nonisolated-unsafe-stt-translation` (ERROR); `asyncstream-*` ERROR |
| T4 | VAD part fixed in F8.5.3 (716 ms); translation part fixed in F8.5.4 — no per-sentence `invalidate()`, warm-up at Start (cold first sentence ~1.1 s → ~0.2–0.3 s); steady state ~250–450 ms is model inference (see T7): `TranslationBridgeModelTests.persistentSession`, `.warmUp`, `TranslationBridgeIntegrationTests.keptSessionLatency` (latency.json) |
| T5 | fixed in F8.5.4 — no default; Apple asks `LanguageAvailability`, the selector delegates: `TranslationPackTests.appleSupportsMirrorsAvailability`, `.selectorDelegatesToService` |

- append a section:
```markdown

## Found in F8.5.4 (2026-10-07)

| # | Finding | Where | Guard in place |
|---|---------|-------|----------------|
| A26 | Starting a call with a language pair that is not downloaded: the hidden bridge cannot show the download sheet, so every sentence times out (2 × 5 s) and shows "Couldn't translate…". Likely fix: check `pairStatus` at Start and point to Download (`modelNotLoaded` alert exists). Owner: unassigned | `AudioCoordinator.start`, `LanguagePairManager.pairStatus` | — |
| T7 | Apple Translation costs ~250–450 ms per short sentence (model inference; 62 ms for one word), the same with a kept or a fresh session and with macOS 26 `TranslationSession(installedSource:target:)`. Further cuts need another engine or translating partial STT results. Owner: unassigned | `build/reports/latency.json` (`TranslationLatencyTests`) | recorded, ceiling 400 ms: `TranslationBridgeIntegrationTests.keptSessionLatency` |
```

Fill in the PR number once the PR exists (Step 6).

- [ ] **Step 3: Lint, scan and the whole unit tier**

Run: `just lint` → exit 0. `just scan` → `✓ no blocking findings`. `just test` → PASS (575 tests while planning).

- [ ] **Step 4: Commit**

```bash
git add docs/ARCHITECTURE.md specs/m8.5-stabilization/backlog.md
git commit -m "docs: F8.5.4 translation bridge in ARCHITECTURE; backlog A8, A10, T4, T5 fixed; A26, T7

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Manual checklist (done by the user; needs BlackHole, a call app or a browser, ES/EN packs)**

Build and run the app (`just build`, then open `build/DerivedData/Build/Products/Debug/TranslateCall.app`). Record the date and result of each line here:

| # | Check | Expected | Result |
|---|-------|----------|--------|
| M1 | Normal session ES↔EN (headphones; browser as capture app for the remote side) | Both directions translate and speak; the first sentence after Start comes noticeably faster than before F8.5.4 | |
| M2 | During a session, close the main window (the app stays in the menu bar); speak and play remote speech; reopen the window from the menu bar | Translation continues with the window closed; on reopening, state is consistent | |
| M3 | Stop; change the language pair; Start | The next session translates in the new pair from the first sentence | |
| M4 | Pick a pair that is not downloaded; press "Download" | The system sheet appears in the main window; after downloading, the pair shows as installed | |
| M5 | (P7) Right after M4, Start a session in that pair | The first sentence is translated (no "Couldn't translate…" notice) | |

- [ ] **Step 6: Full gate (done by the controller with the user)**

Run: `just pr`
Expected: build → check → test → test-integration all pass; `local/just-pr` status = success on HEAD; PR created against `main` with the template filled in (spec + this plan, tests, `just pr`, manual checklist M1–M5, the P1 measurements and the user's NFR-TR-01 decision). Then put the PR number into the backlog rows of Step 2 (follow-up commit, and run `just pr` again).

---

## Spec coverage

| Requirement | Task | Pinned by |
|---|---|---|
| D-6 measure first, stop gate | 1 | `TranslationLatencyTests` (latency.json); Task 1 Step 4 |
| REQ-TR-01 one session serves the queue | 3 | `TranslationBridgeModelTests.persistentSession`; Task 3 Step 4 grep (`invalidate()` gone) |
| REQ-TR-02 configuration only on pair change / warm-up / rebuild | 3, 4 | `.pairChange`, `.warmUp`, `.timeoutThenRetry` (`driver.runs`) |
| REQ-TR-03 FIFO; in-flight survives a session change | 3 | `.fifoOrder`, `.inFlightSurvivesSessionRestart` |
| REQ-TR-04 request of another pair switches the session | 3 | `.pairChange` |
| REQ-TR-05 warm-up at Start, non-blocking | 3, 6 | `.warmUp`, `.serviceWarmUpOpensSession`, `AudioCoordinatorTranslationTests.startWarmsUpBothDirections` |
| REQ-TR-10 bounded completion, also with no session | 4 | `.neverFires`, `.timeoutTwice` (P2: bound applies from the head) |
| REQ-TR-11 retry once on a rebuilt session, then throw | 4 | `.timeoutThenRetry`, `.timeoutTwice`, `.sessionErrorRetried`, `.sessionErrorTwice` |
| REQ-TR-12 a failure does not affect later requests | 4 | `.timeoutTwice`, `.sessionErrorTwice` (P3) |
| REQ-TR-13 caller cancellation | 3 | `.callerCancellation`; `AudioCoordinatorTranslationTests.cancellationIsSilent` |
| REQ-TR-20 failed sentence → notice, pipeline continues | 6 | `.outgoingFailureIsANotice`, `.incomingFailureIsANotice` |
| REQ-TR-21 configuration errors alert once per session | 6 | `.configurationErrorAlertsOncePerSession` |
| REQ-TR-22 `bridgeUnavailable` removed | 3 | Task 3 Step 4 grep; `TranslationErrorTests` |
| REQ-TR-30 off-screen host window owned by AppContainer | 5 | `TranslationHostWindowTests.invisibleAndInert`, `TranslationBridgeIntegrationTests.hostWindowTranslates` |
| REQ-TR-31 works with the main window closed | 5 | manual M2 (bridges no longer in the `WindowGroup`) |
| REQ-TR-40 Download from the visible view's `.translationTask` | 2 | `TranslationPipelineTests.downloadUsesSession`; manual M4 |
| REQ-TR-41 availability re-checked; error alert | 2 | `.downloadErrorSetsAlert`, `.downloadCancelledIsSilent`; manual M4 |
| REQ-TR-42 `prepare` out of `TranslationService` | 2 | build (no conformer implements it) |
| REQ-TR-50 no default `supports`; Apple asks `LanguageAvailability` | 7 | `TranslationPackTests.appleSupportsMirrorsAvailability` |
| REQ-TR-51 selector delegates | 7 | `TranslationPackTests.selectorDelegatesToService` |
| REQ-TR-60 no `nonisolated(unsafe)` in Core/STT, Core/Translation | 3, 8 | `STTLocaleIsolationTests`; Task 8 Step 4 grep |
| REQ-TR-61 opengrep rule | 8 | `no-nonisolated-unsafe-stt-translation` + rule self-test |
| NFR-TR-01 warm median | 1, 5 | `TranslationBridgeIntegrationTests.keptSessionLatency` — 400 ms ceiling pending the user's decision (P1); 150 ms not reachable |
| NFR-TR-02 no continuation left unresumed | 3, 4 | `.lateAnswerIgnored`, `.callerCancellation`, `.neverFires` (exactly-once `finish`) |
| NFR-TR-03 unit tests without a real session | 2, 3 | `FakeTranslationSession`, `TranslationSessionDriver` |
| Manual M1–M5 | 9 | Task 9 Step 5 |
