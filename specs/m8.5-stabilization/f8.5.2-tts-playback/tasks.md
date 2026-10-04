# F8.5.2 TTS Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every utterance, on every engine (AVSpeech, Kokoro, Qwen voice clone, Edge), is heard in full and in order or skipped with a visible reason within bounded time; `isSpeaking` is truthful; MLX inferences never overlap.

**Architecture:** Synthesis is split from playback. Four small `UtteranceSynthesizer`s turn text into an `AsyncThrowingStream<AVAudioPCMBuffer, Error>` and own no audio engine. One `TTSPlaybackService` actor per direction (the only `SynthesisService` the coordinator sees) owns the bounded queue, the single worker, generation-based cancellation, the watchdog, the per-utterance fallback with a circuit breaker, metrics and an `events` stream; it plays through an `AudioOutputting` (`TTSOutput`: one AVAudioEngine player at the hardware rate, `.dataPlayedBack` handles). Qwen inference goes through a process-wide `MLXInferenceGate`; Edge sits on an injectable `EdgeTransport`.

**Tech Stack:** Swift 6 (app target: default MainActor isolation + approachable concurrency), AVFoundation/AVAudioEngine, AVSpeechSynthesizer, AudioToolbox (AudioFile/ExtAudioFile), Starscream 4.0.8, MLX (via `QwenCloneClient`), FluidAudio Kokoro, `Synchronization.Mutex`, Swift Testing, `just`, opengrep, SwiftLint.

**Spec:** `specs/m8.5-stabilization/f8.5.2-tts-playback/requirements.md`, `specs/m8.5-stabilization/f8.5.2-tts-playback/design.md`

## Global Constraints

- Branch `feat/f8.5.2-tts-playback`, created from `spec/f8.5.2-tts-playback`: spec and code ship in one PR (the F8.5.1 practice). Never commit to `main`; `just pr` must pass before the PR.
- Commits: Conventional Commits; end every message with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```
- `SWIFT_VERSION = 6.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`. The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: every type used off the main actor is declared `nonisolated` (project convention: `nonisolated enum/struct/final class …`); members of protocol extensions that must be nonisolated are marked `nonisolated` one by one. The test target has no default isolation.
- New files are picked up automatically (`PBXFileSystemSynchronizedRootGroup`): never edit `project.pbxproj`.
- Streams: `AsyncStream.makeStream(of:bufferingPolicy:)` / `AsyncThrowingStream.makeStream(of:throwing:bufferingPolicy:)` with an explicit **bounded** policy in app code (REQ-T-50). No `cont!`. Every `nonisolated(unsafe)` that stays has a `// SAFETY:` comment on the line directly above.
- `AVAudioPCMBuffer` is `@unchecked Sendable` project-wide (`AudioManager.swift:8`); `AVAudioFormat`, `AVAudioEngine` and `AVAudioPlayerNode` are `Sendable` in the macOS 27 SDK.
- Unit tests: no network, no real Kokoro/CoreML or Qwen/MLX model (overlapping MLX inferences crash the test host; the models are cached on this Mac: never load them), no audio device. No fixed sleeps: wait on a condition with `waitUntil` (`TranslateCallTests/Support/AsyncTestHelpers.swift`) or move a `TestClock` (Task 1). A negative check ("this must not happen") uses a bounded `waitUntil` and says so in a comment.
- Audio safety: never write `kAudioUnitProperty_StreamFormat` or any HAL/AU property except `kAudioOutputUnitProperty_CurrentDevice` (writing formats wedged coreaudiod, F8.5.1). Wrap any manual audio probe in `perl -e 'alarm 60; exec @ARGV' …`; stop and report if `AVAudioEngine.inputNode` hangs.
- AVAudioEngine lesson from F8.5.1: never trust a node's client format after rebinding a device; derive formats from the hardware side (`outputNode.outputFormat(forBus: 0)` for output) and convert.
- Integration tests fail (never skip) on a missing prerequisite via `requirePrerequisite` (REQ-W-23).
- Run one unit suite: `just test-only <SuiteTypeName> […]` (the Swift `struct` name). Full unit tier: `just test`. Integration tier: `just test-integration`. Lint (strict, warnings fail): `just lint`. Static analysis: `just scan`. `just pr` is the gate: it needs a clean tree and publishes `local/just-pr` on the HEAD SHA.
- SwiftLint (app target only): lines ≤ 120, function bodies ≤ 50 lines, type bodies ≤ 250 lines, no force unwraps, identifiers ≥ 3 characters, sorted imports.

## Review Focus

- **The output never reports playback** (device unplugged mid-sentence, engine stalled, `.dataPlayedBack` never fires) → the utterance ends as `.utteranceSkipped(.outputUnavailable)` and `isSpeaking` returns to `false` within the audio's length + 5 s; half-duplex is never muted forever (pinned in Task 2 `stalledOutput`).
- **An Edge-only locale (Ukrainian without a system voice) while Edge is down** → the breaker must not turn into 30 s of "No voice" skips: with no usable fallback every sentence still tries Edge and is skipped with a visible reason (pinned in Task 3 `breakerNeedsAFallback`).
- **A sentence longer than 30 s of audio (M3)** → the watchdog bounds synthesis only; once the stream is finished the audio plays to the end (pinned in Task 2 `watchdogSparesLongPlayback`).
- **TTS monitor on while the service falls back mid-session** (Edge 24 kHz → AVSpeech 22.05 kHz) → the monitor reconnects its player for the new format instead of raising the format-mismatch exception that crashes the app (pinned in Task 3 `reconnectsOnNewFormat`).
- **Edge answers `turn.end` with no audio** (the A3b symptom on a live socket) → a failure, so the fallback speaks; never a silent "success" (pinned in Task 7 `emptyTurnFallsBack`).

## Decisions made while planning (spec ambiguities resolved)

| # | Point | Choice |
|---|-------|--------|
| P1 | REQ-T-16 bounds every utterance, but the 30 s watchdog would cut long sentences (M3) | The watchdog covers synthesis only. Waiting for playback is bounded separately by the scheduled audio length + `TTSPlaybackLimits.playbackGrace` (5 s); on expiry the utterance is skipped with `.outputUnavailable`. |
| P2 | Breaker with no usable fallback | The breaker only diverts when the fallback can speak the locale; otherwise the primary keeps being tried. After the cooldown the breaker is half-open: one more failure reopens it at once. |
| P3 | When `.fellBack` is emitted | Every time the fallback speaks an utterance (primary failed, breaker open, or primary cannot speak the locale). |
| P4 | When `isSpeaking(true)` is emitted | When an attempt starts (synthesis included, as before F8.5.2). A `.noVoice` skip never touches `isSpeaking`. |
| P5 | REQ-T-26 reconnect vs. design §4 "≤ 5 s before audio" | Reconnect once only when the connection was lost before any audio (`connectionClosed`, `connectionFailed`, `notConnected`). Timeouts are not retried, so the fallback speaks within 5 s. |
| P6 | `EdgeTransport.events` (design §3.4) | `connect(request:)` returns the new connection's `AsyncStream<EdgeSocketEvent>`; `EdgeSocketEvent` is a `Sendable` mirror of Starscream's non-Sendable `WebSocketEvent`. |
| P7 | "`deactivate` disconnects" (design §5.2) | `UtteranceSynthesizer` gains `func shutdown() async` (default no-op); `TTSPlaybackService.deactivate()` calls it; Edge disconnects there. |
| P8 | Selector factories (design §3.6) | `makeOutgoingService`/`makeIncomingService` return the concrete `TTSPlaybackService` (it exposes `primaryEngine`/`fallbackEngine` for tests). The device id moves to a new `outputFactory`; `edgeFactory` is added. |
| P9 | NFR-T-02 measurement in the integration test | The capture path delivers a buffer up to ~60 ms after it was played, so the test asserts `falseAt ≥ lastAudio − 60 ms` and `falseAt − lastAudio ≤ 150 ms + trailing digital silence of the synthesized audio`; "tail not cut" is the first→last captured signal span ≥ 80 % of the scheduled audio. |
| P10 | In-memory MP3 decoding (REQ-T-05, design §6) | `AudioFileOpenWithCallbacks` over the `Data` + `ExtAudioFile` (verified while planning: decodes Edge-format MP3, truncated streams included). The committed fixture is generated with `say` + `ffmpeg` in Edge's format (24 kHz mono 48 kbit/s, no ID3/Xing), not captured from Edge. |
| P11 | Qwen sample rate (design §3.1 "client.sampleRate") | The client stays private; the gated inferrer reports `QwenCloneConfiguration.outputSampleRate` (24 000, what the legacy code assumed). |
| P12 | AVSpeech synthesizer ownership | One `AVSpeechSynthesizer` per `AVSpeechUtteranceSynthesizer` (as design §3.1 says); a delegate router finishes the stream of the utterance a callback is about, so a late `didCancel` cannot end the next utterance. |
| P13 | Utterance stream bound | 8 192 buffers: AVSpeech yields ~86 buffers per second of speech, faster than real time; a smaller bound could drop audio of long sentences. |
| P14 | opengrep scope (REQ-T-50/51) | `asyncstream-unbounded` also covers `TranslateCall/Core/VoiceCloning/`. `nonisolated-unsafe-justified` stays WARNING: 4 findings remain repo-wide (Core/STT ×3, Core/Translation ×1), outside this feature. |

---
**Resolved open point (user, 2026-10-04 → D-7, REQ-T-43):** `AudioCoordinator.handleIncomingTranslation` used to drop a remote sentence while incoming TTS was speaking (`guard … !isIncomingSpeaking`), so incoming never queued, contradicting D-3. Task 9 removes that guard (it is not echo protection: SCStream captures only the call app) and keeps `!incomingCaptureSuppressed` (A6, F8.5.3).

## File Structure

```
TranslateCall/Core/TTS/
  UtteranceSynthesizer.swift          NEW  T1  protocol (+ shutdown), TTSEvent, TTSSkipReason, UtteranceStream, PCMBufferFactory, UtteranceText
  AudioOutputting.swift               NEW  T1  AudioOutputting protocol + PlaybackHandle (resolved once: played / cancelled)
  TTSPlaybackService.swift            NEW  T2  the SynthesisService: queue, worker, generation, watchdog, drain, metrics, events; T3 fallback + breaker
  TTSOutput.swift                     NEW  T4  AVAudioEngine output (CurrentDevice only, .dataPlayedBack, config-change restart) + PCMFormatConverter
  AVSpeechUtteranceSynthesizer.swift  NEW  T4  write() → stream, shared synthesizer + per-utterance completion router, hasVoice/bestVoice
  KokoroUtteranceSynthesizer.swift    NEW  T6
  EdgeTransport.swift                 NEW  T7  EdgeSocketEvent, EdgeTransport, StarscreamTransport
  EdgeTTSWebSocket.swift              REWRITE T7  event-derived isConnected, pump, timeouts, chunk stream
  EdgeMP3Decoder.swift                NEW  T7  in-memory MP3 → PCM
  EdgeUtteranceSynthesizer.swift      NEW  T7  reconnect-once, decode
  TTSEvent+Notice.swift               NEW  T9  notice texts
  SynthesisService.swift              MOD  T2 ttsEvents accessor; T4 nonisolated config/error, STSError.outputUnavailable
  TTSAudioMonitor.swift               MOD  T3  reconnect on format change
  TTSEngine.swift, TTSMetrics.swift   MOD  T1  nonisolated
  KokoroConfiguration.swift           MOD  T6  nonisolated
  EdgeTTSHelpers.swift                MOD  T7  EdgeTTSError cases, Equatable
  TTSEngineSelector.swift             MOD  T5 gated inferrer, T7 Edge via playback service, T8 rewrite (primary/fallback/output)
  KokoroModelManager.swift, EdgeTTSConsentManager.swift, KokoroTtsManaging.swift   MOD  T8/T10 hygiene
  AVSpeechService.swift, KokoroSpeechService.swift, EdgeTTSService.swift            DELETED (T8, T8, T7)
TranslateCall/Core/VoiceCloning/
  MLXInferenceGate.swift              NEW  T5
  QwenUtteranceSynthesizer.swift      NEW  T5
  QwenCloneModelManager.swift         MOD  T5  gate-only access (no raw client), async unload waits for the gate
  QwenCloneConfiguration.swift        MOD  T5  outputSampleRate, QwenCloneError.gateBusy (LocalizedError)
  VoicePreviewService.swift           MOD  T5  gated inferrer, makeStream, SAFETY
  QwenCloneClient.swift               MOD  T5  doc comment
  VoiceProfileRecorder.swift          MOD  T10 hygiene
  QwenCloneSpeechService.swift        DELETED (T8)
TranslateCall/Core/Audio/AudioCoordinator(+Pipeline).swift   MOD T9  no pre-emptive stopSpeaking; ttsEvents → ttsNotice
TranslateCall/Core/Setup/RouteTestService.swift              MOD T8
TranslateCall/Features/Main/{AudioViewModel,TTSNoticeLine}.swift, Features/ContentView.swift,
  Features/VoiceCloning/{VoicePreviewSection,VoiceProfileListView}.swift                MOD/NEW T8–T9
TranslateCallTests/Support/{TestClock,TTSFakes,TTSPlaybackHarness,RecordingOutput,FakeEdgeTransport}.swift   NEW
TranslateCallTests/Support/BufferLog.swift                   MOD T4  entry duration, first/last entry
TranslateCallTests/Fixtures/MP3/hello-24k-mono.mp3           NEW T7
TranslateCallTests/*Tests.swift                              NEW/MOD/DELETED per task (mapping in Task 8)
TranslateCallTests/Integration/{TTSPlaybackIntegrationTests,EdgeTTSIntegrationTests}.swift   NEW T4, T7
.opengrep/rules/{swift-audio,swift-concurrency}.yml, .opengrep/README.md                     MOD T10
specs/m8.5-stabilization/backlog.md, this file                                               MOD T10
```

Dependency order: T1 → T2 → T3 → T4 → (T5, T6, T7 in any order) → T8 → T9 → T10.

---

### Task 1: Core types, playback handle and test fakes

**Files:**
- Create: `TranslateCall/Core/TTS/UtteranceSynthesizer.swift`
- Create: `TranslateCall/Core/TTS/AudioOutputting.swift`
- Modify: `TranslateCall/Core/TTS/TTSEngine.swift:10`, `TranslateCall/Core/TTS/TTSMetrics.swift:6,19` (`nonisolated`)
- Create: `TranslateCallTests/Support/TestClock.swift`, `TranslateCallTests/Support/TTSFakes.swift`
- Test: `TranslateCallTests/TTSPlaybackPrimitivesTests.swift`

**Interfaces:**
- Consumes: `makePCMBuffer(frames:sampleRate:fill:)` (`TranslateCallTests/Support/PCMBuffers.swift`), `waitUntil` (`AsyncTestHelpers.swift`).
- Produces:
  - `nonisolated protocol UtteranceSynthesizer: Sendable { var engine: TTSEngine { get }; func canSpeak(_ locale: Locale) -> Bool; func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>; func shutdown() async }` (`shutdown` defaults to a no-op)
  - `nonisolated enum TTSSkipReason: Sendable, Equatable { case noVoice, primaryFailed(String), interrupted, timeout, outputUnavailable }`
  - `nonisolated enum TTSEvent: Sendable, Equatable { case utteranceDropped, utteranceSkipped(TTSSkipReason), fellBack(from: TTSEngine, to: TTSEngine) }`
  - `nonisolated enum UtteranceStream { static let bufferLimit = 8_192; static func make() -> (stream:continuation:) }`
  - `nonisolated enum PCMBufferFactory { static func mono(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? }`
  - `nonisolated enum UtteranceText { static func truncated(_ text: String, limit: Int) -> String }`
  - `nonisolated protocol AudioOutputting: AnyObject, Sendable { func schedule(_ buffer: AVAudioPCMBuffer) throws -> PlaybackHandle; func stop(); func shutdown() }`
  - `nonisolated final class PlaybackHandle: Sendable { init(); var isResolved: Bool; var isPlayed: Bool; func markPlayed(); func markCancelled(); func wait() async throws }`
  - Test support: `final class TestClock: Clock` (`advance(by:)`, `sleeperCount`, `pendingDeadlines: [Duration]`), `AsyncGate` (`wait()`, `open()`, `waiterCount`), `LockedArray<Element>`, `StreamRecorder<Element>` (`values`, `timed`, `isFinished`), `collect(_:within:) async throws -> [AVAudioPCMBuffer]?`, `FakeSynthError.boom`, `FakeSynthesizer` (`Script(buffers:failAfter:hang:holdBefore:)`, `gate`, `texts`, `cancelledCount`, `completedCount`, `shutdownCount`), `FakeOutput(autoComplete:)` (`scheduled`, `scheduledCount`, `stopCount`, `shutdownCount`, `failSchedules(with:)`, `completeAll()`, `complete(index:)`)

- [ ] **Step 1: Write the test support and the failing tests**

`TranslateCallTests/Support/TestClock.swift`:
```swift
import Synchronization

/// Manual `Clock` (design §5.1): time moves only on `advance(by:)`, so watchdogs, breakers and
/// timeouts are tested without sleeping. Wait on `sleeperCount` / `pendingDeadlines` before advancing.
final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        let offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var cancelledEarly: Set<UInt64> = []
    }

    private enum Registration { case waiting, due, cancelled }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Swift.Duration { .zero }

    /// Tasks currently suspended in `sleep`.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// Deadlines of the suspended sleepers, as offsets from the clock's start, earliest first.
    var pendingDeadlines: [Swift.Duration] { state.withLock { $0.sleepers.map(\.deadline.offset).sorted() } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        let id: UInt64 = state.withLock { current in
            current.nextID += 1
            return current.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let registration: Registration = self.state.withLock { current in
                    if current.cancelledEarly.remove(id) != nil { return .cancelled }
                    if deadline <= current.now { return .due }
                    current.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .waiting
                }
                switch registration {
                case .waiting: break
                case .due: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = self.state.withLock { current in
                if let index = current.sleepers.firstIndex(where: { $0.id == id }) {
                    return current.sleepers.remove(at: index)
                }
                current.cancelledEarly.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has been reached.
    func advance(by duration: Swift.Duration) {
        let due: [Sleeper] = state.withLock { current in
            current.now = current.now.advanced(by: duration)
            let now = current.now
            let due = current.sleepers.filter { $0.deadline <= now }
            current.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}
```

`TranslateCallTests/Support/TTSFakes.swift`:
```swift
import AVFoundation
import Synchronization
@testable import TranslateCall

// MARK: - AsyncGate

/// Suspends callers of `wait()` until `open()`; once open, later waits return at once.
final class AsyncGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var waiterCount: Int { state.withLock { $0.waiters.count } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = state.withLock { current in
                if current.isOpen { return true }
                current.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { current in
            current.isOpen = true
            defer { current.waiters.removeAll() }
            return current.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

// MARK: - LockedArray

/// Thread-safe append-only list for `@Sendable` callbacks in tests.
final class LockedArray<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    var values: [Element] { storage.withLock { $0 } }

    func append(_ element: Element) { storage.withLock { $0.append(element) } }
}

// MARK: - StreamRecorder

/// Collects everything an `AsyncStream` emits, with arrival times, until it finishes.
final class StreamRecorder<Element: Sendable>: Sendable {
    struct Item: Sendable {
        let value: Element
        let at: ContinuousClock.Instant
    }

    private let items = Mutex<[Item]>([])
    private let finished = Mutex(false)

    init(_ stream: AsyncStream<Element>) {
        Task { [self] in
            for await value in stream {
                items.withLock { $0.append(Item(value: value, at: .now)) }
            }
            finished.withLock { $0 = true }
        }
    }

    var values: [Element] { items.withLock { $0.map(\.value) } }
    var timed: [Item] { items.withLock { $0 } }
    var isFinished: Bool { finished.withLock { $0 } }
}

// MARK: - collect

/// Every buffer of one utterance stream, or nil if it did not finish within `timeout`.
func collect(_ stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>,
             within timeout: Duration = .seconds(10)) async throws -> [AVAudioPCMBuffer]? {
    try await withThrowingTaskGroup(of: [AVAudioPCMBuffer]?.self) { group in
        group.addTask {
            var buffers: [AVAudioPCMBuffer] = []
            for try await buffer in stream { buffers.append(buffer) }
            return buffers
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
}

// MARK: - FakeSynthesizer

enum FakeSynthError: Error, Equatable {
    case boom
}

/// Scripted `UtteranceSynthesizer` (design §5.1). Each `synthesize` call uses the next script
/// (the last one repeats) and records the text, cancellations, completions and shutdowns.
final class FakeSynthesizer: UtteranceSynthesizer, Sendable {
    struct Script: Sendable {
        var buffers: [AVAudioPCMBuffer] = [makePCMBuffer(frames: 1_600, fill: 0.5)]
        /// Throw `FakeSynthError.boom` after yielding this many buffers (nil = never).
        var failAfter: Int? = nil
        /// After the buffers, never finish (until the consumer goes away).
        var hang = false
        /// Before yielding the buffer at this index, wait for `gate.open()`.
        var holdBefore: Int? = nil
    }

    private struct Record {
        var scripts: [Script]
        var texts: [String] = []
        var cancelledCount = 0
        var completedCount = 0
        var shutdownCount = 0
    }

    let engine: TTSEngine
    let gate = AsyncGate()
    private let speakable: @Sendable (Locale) -> Bool
    private let record: Mutex<Record>

    init(engine: TTSEngine = .avSpeech,
         canSpeak: @escaping @Sendable (Locale) -> Bool = { _ in true },
         scripts: [Script] = [Script()]) {
        self.engine = engine
        speakable = canSpeak
        record = Mutex(Record(scripts: scripts))
    }

    var texts: [String] { record.withLock { $0.texts } }
    var cancelledCount: Int { record.withLock { $0.cancelledCount } }
    var completedCount: Int { record.withLock { $0.completedCount } }
    var shutdownCount: Int { record.withLock { $0.shutdownCount } }

    func canSpeak(_ locale: Locale) -> Bool { speakable(locale) }

    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let script: Script = record.withLock { current in
            current.texts.append(text)
            let next = current.scripts.first ?? Script()
            if current.scripts.count > 1 { current.scripts.removeFirst() }
            return next
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: AVAudioPCMBuffer.self, throwing: Error.self, bufferingPolicy: .unbounded
        )
        let producer = Task { [gate] in
            for (index, buffer) in script.buffers.enumerated() {
                if script.failAfter == index {
                    continuation.finish(throwing: FakeSynthError.boom)
                    return
                }
                if script.holdBefore == index { await gate.wait() }
                continuation.yield(buffer)
            }
            if script.failAfter == script.buffers.count {
                continuation.finish(throwing: FakeSynthError.boom)
                return
            }
            if script.hang {
                await Self.waitUntilCancelled()
                return
            }
            self.record.withLock { $0.completedCount += 1 }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { self?.record.withLock { $0.cancelledCount += 1 } }
            producer.cancel()
        }
        return stream
    }

    func shutdown() async { record.withLock { $0.shutdownCount += 1 } }

    private static func waitUntilCancelled() async {
        let (never, keepAlive) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        for await _ in never {}
        withExtendedLifetime(keepAlive) {}
    }
}

// MARK: - FakeOutput

/// Recording `AudioOutputting` (design §5.1). Handles complete when the test says so
/// (`completeAll`, `complete(index:)`), or at once with `autoComplete`.
final class FakeOutput: AudioOutputting, Sendable {
    private struct State {
        var scheduled: [AVAudioPCMBuffer] = []
        var handles: [PlaybackHandle] = []
        var stopCount = 0
        var shutdownCount = 0
        var scheduleError: Error?
    }

    private let state = Mutex(State())
    private let autoComplete: Bool

    init(autoComplete: Bool = false) {
        self.autoComplete = autoComplete
    }

    var scheduled: [AVAudioPCMBuffer] { state.withLock { $0.scheduled } }
    var scheduledCount: Int { state.withLock { $0.scheduled.count } }
    var stopCount: Int { state.withLock { $0.stopCount } }
    var shutdownCount: Int { state.withLock { $0.shutdownCount } }

    /// Every later `schedule` throws `error`; nil restores normal behaviour.
    func failSchedules(with error: Error?) { state.withLock { $0.scheduleError = error } }

    func schedule(_ buffer: AVAudioPCMBuffer) throws -> PlaybackHandle {
        let handle = PlaybackHandle()
        try state.withLock { current in
            if let error = current.scheduleError { throw error }
            current.scheduled.append(buffer)
            current.handles.append(handle)
        }
        if autoComplete { handle.markPlayed() }
        return handle
    }

    func completeAll() { state.withLock { $0.handles }.forEach { $0.markPlayed() } }

    func complete(index: Int) { state.withLock { $0.handles[index] }.markPlayed() }

    func stop() {
        let handles: [PlaybackHandle] = state.withLock { current in
            current.stopCount += 1
            return current.handles
        }
        handles.forEach { $0.markCancelled() }
    }

    func shutdown() {
        let handles: [PlaybackHandle] = state.withLock { current in
            current.shutdownCount += 1
            return current.handles
        }
        handles.forEach { $0.markCancelled() }
    }
}
```

`TranslateCallTests/TTSPlaybackPrimitivesTests.swift`:
```swift
import AVFoundation
import Testing
@testable import TranslateCall

@Suite("PlaybackHandle")
struct PlaybackHandleTests {
    @Test("wait returns once the buffer has played back, whether marked before or after the wait")
    func playedResumesWaiters() async throws {
        let early = PlaybackHandle()
        early.markPlayed()
        try await early.wait()

        let late = PlaybackHandle()
        let waiter = Task { try await late.wait() }
        late.markPlayed()
        try await waiter.value
        #expect(late.isPlayed)
    }

    @Test("a cancelled handle throws CancellationError to its waiters; the first resolution wins")
    func cancelThrowsAndFirstWins() async {
        let handle = PlaybackHandle()
        handle.markCancelled()
        handle.markPlayed()
        #expect(!handle.isPlayed)
        await #expect(throws: CancellationError.self) { try await handle.wait() }
    }

    @Test("cancelling the waiting task ends the wait but leaves the handle unresolved")
    func waiterCancellation() async {
        let handle = PlaybackHandle()
        let waiter = Task { try await handle.wait() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(!handle.isResolved)
    }
}

@Suite("TestClock")
struct TestClockTests {
    @Test("a sleeper resumes only when time reaches its deadline")
    func advanceResumesDueSleepers() async throws {
        let clock = TestClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(5)) }
        #expect(await waitUntil { clock.sleeperCount == 1 })
        #expect(clock.pendingDeadlines == [.seconds(5)])
        clock.advance(by: .seconds(4))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(1))
        try await sleeper.value
        #expect(clock.sleeperCount == 0)
    }

    @Test("cancelling a sleeper throws CancellationError and unregisters it")
    func cancellation() async {
        let clock = TestClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(5)) }
        #expect(await waitUntil { clock.sleeperCount == 1 })
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test("a deadline already reached does not suspend")
    func pastDeadline() async throws {
        let clock = TestClock()
        clock.advance(by: .seconds(10))
        try await clock.sleep(until: clock.now.advanced(by: .seconds(-1)), tolerance: nil)
    }
}

@Suite("Utterance helpers")
struct UtteranceHelpersTests {
    @Test("truncation keeps text up to the limit and cuts at the last word boundary (REQ-T-04)")
    func truncation() {
        let long = String(repeating: "hello ", count: 92)            // 552 characters
        let cut = UtteranceText.truncated(long, limit: 500)
        #expect(cut.count <= 500)
        #expect(!cut.hasSuffix(" "))
        #expect(long.hasPrefix(cut))
        let exact = String(repeating: "a", count: 500)
        #expect(UtteranceText.truncated(exact, limit: 500) == exact)
        #expect(UtteranceText.truncated(String(repeating: "a", count: 600), limit: 500).count == 500)
    }

    @Test("mono buffers carry the samples at the given rate; empty samples give nil")
    func monoBuffers() throws {
        let buffer = try #require(PCMBufferFactory.mono([0.1, 0.2, 0.3], sampleRate: 24_000))
        #expect(buffer.format.sampleRate == 24_000)
        #expect(buffer.format.channelCount == 1)
        #expect(buffer.frameLength == 3)
        #expect(buffer.floatChannelData?[0][2] == 0.3)
        #expect(PCMBufferFactory.mono([], sampleRate: 24_000) == nil)
    }

    @Test("events compare by case and payload")
    func eventEquality() {
        #expect(TTSEvent.fellBack(from: .edgeTTS, to: .avSpeech) == .fellBack(from: .edgeTTS, to: .avSpeech))
        #expect(TTSEvent.utteranceSkipped(.primaryFailed("a")) != .utteranceSkipped(.primaryFailed("b")))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-only PlaybackHandleTests TestClockTests UtteranceHelpersTests`
Expected: build FAILS — `cannot find type 'UtteranceSynthesizer' in scope`, `cannot find 'PlaybackHandle' in scope`.

- [ ] **Step 3: Implement the core types**

`TranslateCall/Core/TTS/UtteranceSynthesizer.swift`:
```swift
import AVFoundation

// MARK: - UtteranceSynthesizer

/// Text → PCM for one engine (F8.5.2 REQ-T-01/02). A synthesizer owns no audio engine or player
/// node: `TTSPlaybackService` schedules what it yields.
///
/// The stream yields one utterance's buffers in playback order, finishes when the utterance is
/// complete and throws on failure or timeout. When the consumer stops iterating, the stream's
/// `onTermination` cancels the producing work (for MLX: abandons it, see `MLXInferenceGate`).
nonisolated protocol UtteranceSynthesizer: Sendable {
    var engine: TTSEngine { get }
    func canSpeak(_ locale: Locale) -> Bool
    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
    /// Releases long-lived resources (Edge closes its socket). Called by `TTSPlaybackService.deactivate()`.
    func shutdown() async
}

extension UtteranceSynthesizer {
    nonisolated func shutdown() async {}
}

// MARK: - Events

/// Why an utterance was not heard in full (REQ-T-18).
nonisolated enum TTSSkipReason: Sendable, Equatable {
    case noVoice
    case primaryFailed(String)
    case interrupted
    case timeout
    case outputUnavailable
}

/// What `TTSPlaybackService.events` reports (REQ-T-18).
nonisolated enum TTSEvent: Sendable, Equatable {
    case utteranceDropped
    case utteranceSkipped(TTSSkipReason)
    // swiftlint:disable:next identifier_name
    case fellBack(from: TTSEngine, to: TTSEngine)   // labels fixed by REQ-T-18
}

// MARK: - Helpers shared by the synthesizers

/// The stream every synthesizer returns.
nonisolated enum UtteranceStream {
    /// Bounded like every stream in Core/TTS (REQ-T-50), but never reached in practice: the consumer
    /// schedules each buffer at once, and AVSpeech's burst (~86 buffers per second of speech, rendered
    /// faster than real time) stays far below this for any sentence (> 90 s of speech).
    static let bufferLimit = 8_192

    static func make() -> (
        stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>,
        continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
    ) {
        AsyncThrowingStream.makeStream(
            of: AVAudioPCMBuffer.self, throwing: Error.self, bufferingPolicy: .bufferingNewest(bufferLimit)
        )
    }
}

/// Builds the buffers Kokoro, Qwen and the Edge decoder hand to the playback service.
nonisolated enum PCMBufferFactory {
    /// Mono Float32 buffer holding `samples` at `sampleRate`; nil when `samples` is empty.
    static func mono(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        return buffer
    }
}

/// Text limits of the on-device engines (REQ-T-04).
nonisolated enum UtteranceText {
    /// Cuts `text` to at most `limit` characters at the last word boundary (Kokoro: 500,
    /// Qwen: `QwenCloneConfiguration.textTruncationLimit`). A text with no space is cut hard.
    static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = String(text.prefix(limit))
        let words = prefix.components(separatedBy: " ").dropLast()
        return words.isEmpty ? prefix : words.joined(separator: " ")
    }
}
```

`TranslateCall/Core/TTS/AudioOutputting.swift`:
```swift
import AVFoundation
import Synchronization

// MARK: - AudioOutputting

/// Where `TTSPlaybackService` sends PCM (design §3.2). `TTSOutput` is the device implementation;
/// tests use `FakeOutput`.
nonisolated protocol AudioOutputting: AnyObject, Sendable {
    /// Schedules a buffer. The handle completes when the buffer has been played back
    /// (`.dataPlayedBack`) or is cancelled by `stop()`, `shutdown()` or a lost device.
    func schedule(_ buffer: AVAudioPCMBuffer) throws -> PlaybackHandle
    /// Cancels everything scheduled.
    func stop()
    /// `stop()` and release the device.
    func shutdown()
}

// MARK: - PlaybackHandle

/// Completion of one scheduled buffer, resolved exactly once: played back, or cancelled.
/// The first resolution wins.
nonisolated final class PlaybackHandle: Sendable {
    private enum Resolution { case played, cancelled }

    private struct State {
        var resolution: Resolution?
        var waiters: [UInt64: CheckedContinuation<Void, Error>] = [:]
        var abandoned: Set<UInt64> = []
        var nextWaiterID: UInt64 = 0
    }

    private let state = Mutex(State())

    init() {}

    var isResolved: Bool { state.withLock { $0.resolution != nil } }
    var isPlayed: Bool { state.withLock { $0.resolution == .played } }

    func markPlayed() { resolve(.played) }
    func markCancelled() { resolve(.cancelled) }

    /// Returns once the buffer has played back. Throws `CancellationError` when the handle was
    /// cancelled, or when the waiting task is cancelled (the handle itself then stays unresolved).
    func wait() async throws {
        let waiterID: UInt64 = state.withLock { current in
            current.nextWaiterID += 1
            return current.nextWaiterID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let known: Resolution? = self.state.withLock { current in
                    if let resolution = current.resolution { return resolution }
                    if current.abandoned.remove(waiterID) != nil { return .cancelled }
                    current.waiters[waiterID] = continuation
                    return nil
                }
                switch known {
                case .played?: continuation.resume()
                case .cancelled?: continuation.resume(throwing: CancellationError())
                case nil: break
                }
            }
        } onCancel: {
            let waiting: CheckedContinuation<Void, Error>? = self.state.withLock { current in
                if let continuation = current.waiters.removeValue(forKey: waiterID) { return continuation }
                if current.resolution == nil { current.abandoned.insert(waiterID) }
                return nil
            }
            waiting?.resume(throwing: CancellationError())
        }
    }

    private func resolve(_ resolution: Resolution) {
        let waiters: [CheckedContinuation<Void, Error>] = state.withLock { current in
            guard current.resolution == nil else { return [] }
            current.resolution = resolution
            defer { current.waiters.removeAll() }
            return Array(current.waiters.values)
        }
        for waiter in waiters {
            if resolution == .played {
                waiter.resume()
            } else {
                waiter.resume(throwing: CancellationError())
            }
        }
    }
}
```

In `TranslateCall/Core/TTS/TTSEngine.swift` line 10, make the enum usable from actors and nonisolated synthesizers (its `Equatable`/`Codable` conformances must not be MainActor-isolated):
```swift
nonisolated enum TTSEngine: String, Codable, Sendable, CaseIterable {
```
In `TranslateCall/Core/TTS/TTSMetrics.swift`, line 6 becomes `nonisolated struct TTSMetrics: Sendable {` and line 19 becomes `nonisolated struct TTSMetricsSummary: Sendable, Equatable {`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `just test-only PlaybackHandleTests TestClockTests UtteranceHelpersTests`
Expected: PASS (9 tests). Then `just lint` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/TTS/UtteranceSynthesizer.swift TranslateCall/Core/TTS/AudioOutputting.swift \
        TranslateCall/Core/TTS/TTSEngine.swift TranslateCall/Core/TTS/TTSMetrics.swift \
        TranslateCallTests/Support/TestClock.swift TranslateCallTests/Support/TTSFakes.swift \
        TranslateCallTests/TTSPlaybackPrimitivesTests.swift
git commit -m "feat(tts): UtteranceSynthesizer, TTSEvent, PlaybackHandle and test fakes (F8.5.2)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `TTSPlaybackService` — queue, worker, generation, truthful `isSpeaking`, watchdog, events, metrics

**Files:**
- Create: `TranslateCall/Core/TTS/TTSPlaybackService.swift`
- Modify: `TranslateCall/Core/TTS/SynthesisService.swift:46-66` (protocol: `ttsEvents` accessor with a nil default)
- Create: `TranslateCallTests/Support/TTSPlaybackHarness.swift`
- Test: `TranslateCallTests/TTSPlaybackServiceTests.swift`

**Interfaces:**
- Consumes: everything Task 1 produces; `TTSMetricsCollector(cap:)`, `TTSMetricsCollector.recent`, `TTSAudioMonitor.process(_:)`.
- Produces:
  - `protocol SynthesisService` gains `nonisolated var ttsEvents: AsyncStream<TTSEvent>? { get }` (default `nil`).
  - `nonisolated struct TTSPlaybackLimits: Sendable { var maxPending = 3; var utteranceWatchdog: Duration = .seconds(30); var breakerThreshold = 3; var breakerCooldown: Duration = .seconds(30); var playbackGrace: Duration = .seconds(5); static let default }`
  - `actor TTSPlaybackService: SynthesisService { init(primary: any UtteranceSynthesizer, fallback: (any UtteranceSynthesizer)? = nil, output: any AudioOutputting, limits: TTSPlaybackLimits = .default, clock: any Clock<Duration> = ContinuousClock(), metrics: TTSMetricsCollector = .shared); nonisolated let isSpeakingStream: AsyncStream<Bool> /* .bufferingNewest(8) */; nonisolated let events: AsyncStream<TTSEvent> /* .bufferingNewest(16) */; nonisolated let primaryEngine: TTSEngine; nonisolated let fallbackEngine: TTSEngine?; var pendingCount: Int; func setBufferObserver(_ observer: (@Sendable (AVAudioPCMBuffer) -> Void)?) }`
  - Test support: `let english: Locale`, `struct TTSPlaybackHarness { primary, fallback, output, clock, metrics, service, speaking: StreamRecorder<Bool>, events: StreamRecorder<TTSEvent> }`

How the service works (read before coding): `speak` drops blank text, drops the oldest pending utterance when 3 are waiting (`.utteranceDropped`), appends and wakes the single worker. The worker takes one utterance at a time: `runAttempt` emits `isSpeaking(true)` if idle, starts the synthesizer's stream in a consumer task raced against `clock.sleep(for: utteranceWatchdog)`; the consumer schedules each buffer the moment it arrives, after checking `gen == generation` on the actor (so nothing from before a `stopSpeaking` is ever scheduled), and passes it to the monitor. `conclude` then waits only for the last buffer's handle, bounded by the audio length + `playbackGrace`, and names the outcome. `isSpeaking(false)` is emitted when the queue is empty after an utterance ends, or at once by `stopSpeaking`. Task 3 adds the fallback and the breaker to `perform`.

- [ ] **Step 1: Write the harness and the failing tests**

`TranslateCallTests/Support/TTSPlaybackHarness.swift`:
```swift
import Foundation
@testable import TranslateCall

let english = Locale(identifier: "en-US")

/// A `TTSPlaybackService` wired to fakes, with recorders on both of its streams.
struct TTSPlaybackHarness {
    let primary: FakeSynthesizer
    let fallback: FakeSynthesizer?
    let output: FakeOutput
    let clock = TestClock()
    let metrics = TTSMetricsCollector(cap: 10)
    let service: TTSPlaybackService
    let speaking: StreamRecorder<Bool>
    let events: StreamRecorder<TTSEvent>

    init(primary: FakeSynthesizer = FakeSynthesizer(),
         fallback: FakeSynthesizer? = nil,
         output: FakeOutput = FakeOutput(),
         limits: TTSPlaybackLimits = .default) {
        self.primary = primary
        self.fallback = fallback
        self.output = output
        service = TTSPlaybackService(primary: primary, fallback: fallback, output: output,
                                     limits: limits, clock: clock, metrics: metrics)
        speaking = StreamRecorder(service.isSpeakingStream)
        events = StreamRecorder(service.events)
    }
}
```

`TranslateCallTests/TTSPlaybackServiceTests.swift`:
```swift
import AVFoundation
import Testing
@testable import TranslateCall

@Suite("TTSPlaybackService")
struct TTSPlaybackServiceTests {

    @Test("utterances run one at a time, in FIFO order (REQ-T-11)")
    func fifoOneAtATime() async {
        let harness = TTSPlaybackHarness()
        for text in ["one", "two", "three"] { await harness.service.speak(text: text, locale: english) }
        for played in 1...3 {
            #expect(await waitUntil { harness.output.scheduledCount == played })
            #expect(harness.primary.texts.count == played, "the next utterance started before this one was heard")
            harness.output.completeAll()
        }
        #expect(harness.primary.texts == ["one", "two", "three"])
        await harness.service.deactivate()
    }

    @Test("a 4th pending utterance drops the oldest pending one and reports it (REQ-T-12)")
    func capDropsOldest() async {
        let primary = FakeSynthesizer(scripts: [FakeSynthesizer.Script(holdBefore: 0), FakeSynthesizer.Script()])
        let harness = TTSPlaybackHarness(primary: primary, output: FakeOutput(autoComplete: true))
        await harness.service.speak(text: "in flight", locale: english)
        #expect(await waitUntil { primary.gate.waiterCount == 1 })

        for text in ["p1", "p2", "p3", "p4"] { await harness.service.speak(text: text, locale: english) }

        #expect(await harness.service.pendingCount == 3)
        #expect(await waitUntil { harness.events.values == [.utteranceDropped] })
        primary.gate.open()
        #expect(await waitUntil { primary.texts.count == 4 })
        #expect(primary.texts == ["in flight", "p2", "p3", "p4"])
        await harness.service.deactivate()
    }

    @Test("blank text is ignored (REQ-T-12)")
    func blankIgnored() async {
        let harness = TTSPlaybackHarness(output: FakeOutput(autoComplete: true))
        await harness.service.speak(text: "   ", locale: english)
        await harness.service.speak(text: "\n\t", locale: english)
        await harness.service.speak(text: "real", locale: english)
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(harness.primary.texts == ["real"])
        await harness.service.deactivate()
    }

    @Test("buffers are scheduled as they arrive and only the last one is awaited (REQ-T-13)")
    func schedulesAheadAwaitsLast() async {
        let script = FakeSynthesizer.Script(buffers: (0..<3).map { _ in makePCMBuffer(frames: 1_600, fill: 0.5) })
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(scripts: [script]))
        await harness.service.speak(text: "three buffers", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 3 }, "later buffers waited for earlier ones")
        harness.output.complete(index: 2)
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("isSpeaking: true while the queue plays, false after the last buffer, no flicker in between (REQ-T-14)")
    func truthfulSpeaking() async {
        let harness = TTSPlaybackHarness()
        await harness.service.speak(text: "first", locale: english)
        await harness.service.speak(text: "second", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 && harness.speaking.values == [true] })
        harness.output.completeAll()
        #expect(await waitUntil { harness.output.scheduledCount == 2 })
        #expect(harness.speaking.values == [true])
        harness.output.completeAll()
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("stopSpeaking: isSpeaking false at once, queue cleared, playback stopped (REQ-T-14/15)")
    func stopIsImmediate() async {
        let harness = TTSPlaybackHarness()
        await harness.service.speak(text: "playing", locale: english)
        await harness.service.speak(text: "queued", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })

        await harness.service.stopSpeaking()

        #expect(harness.output.stopCount == 1)
        #expect(await harness.service.pendingCount == 0)
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(harness.primary.texts == ["playing"])
        #expect(harness.events.values.isEmpty)
        await harness.service.deactivate()
    }

    @Test("stop during synthesis, then a new sentence: only the new one is ever scheduled (REQ-T-15, A9, A3e)")
    func stopDuringSynthesis() async {
        let stale = makePCMBuffer(frames: 1_600, fill: 0.9)
        let fresh = makePCMBuffer(frames: 1_600, fill: 0.1)
        let primary = FakeSynthesizer(scripts: [
            FakeSynthesizer.Script(buffers: [makePCMBuffer(frames: 1_600, fill: 0.5), stale], holdBefore: 1),
            FakeSynthesizer.Script(buffers: [fresh])
        ])
        let harness = TTSPlaybackHarness(primary: primary, output: FakeOutput(autoComplete: true))
        await harness.service.speak(text: "old", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 && primary.gate.waiterCount == 1 })

        await harness.service.stopSpeaking()
        await harness.service.speak(text: "new", locale: english)
        primary.gate.open()                       // the old producer now yields `stale`

        #expect(await waitUntil { harness.output.scheduledCount == 2 })
        #expect(harness.output.scheduled.last === fresh)
        #expect(!harness.output.scheduled.contains { $0 === stale })
        #expect(await waitUntil { primary.cancelledCount == 1 })
        await harness.service.deactivate()
    }

    @Test("the watchdog skips a synthesizer that never finishes and isSpeaking returns to false (REQ-T-16)")
    func watchdog() async {
        let primary = FakeSynthesizer(scripts: [FakeSynthesizer.Script(buffers: [], hang: true)])
        let harness = TTSPlaybackHarness(primary: primary)
        await harness.service.speak(text: "hangs", locale: english)
        #expect(await waitUntil { harness.clock.pendingDeadlines == [.seconds(30)] })

        harness.clock.advance(by: .seconds(30))

        #expect(await waitUntil { harness.events.values == [.utteranceSkipped(.timeout)] })
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(await waitUntil { primary.cancelledCount == 1 })
        await harness.service.deactivate()
    }

    @Test("Review focus: a long utterance is not cut by the watchdog once its synthesis is done (M3)")
    func watchdogSparesLongPlayback() async {
        let forty = makePCMBuffer(frames: 640_000, sampleRate: 16_000, fill: 0.5)   // 40 s of audio
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(scripts: [FakeSynthesizer.Script(buffers: [forty])]))
        await harness.service.speak(text: "long", locale: english)
        #expect(await waitUntil { harness.clock.pendingDeadlines == [.seconds(45)] })   // 40 s + 5 s grace

        harness.clock.advance(by: .seconds(31))                                        // past the watchdog
        harness.output.completeAll()

        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(harness.events.values.isEmpty)
        await harness.service.deactivate()
    }

    @Test("Review focus: an output that never reports playback ends the utterance as outputUnavailable")
    func stalledOutput() async {
        let oneSecond = makePCMBuffer(frames: 16_000, sampleRate: 16_000, fill: 0.5)
        let script = FakeSynthesizer.Script(buffers: [oneSecond])
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(scripts: [script]))
        await harness.service.speak(text: "device vanished", locale: english)
        #expect(await waitUntil { harness.clock.pendingDeadlines == [.seconds(6)] })    // 1 s + 5 s grace

        harness.clock.advance(by: .seconds(6))

        #expect(await waitUntil { harness.events.values == [.utteranceSkipped(.outputUnavailable)] })
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(harness.output.stopCount >= 1)
        await harness.service.deactivate()
    }

    @Test("a buffer the output refuses skips the utterance as outputUnavailable; the next one is tried")
    func scheduleFailure() async {
        let output = FakeOutput(autoComplete: true)
        output.failSchedules(with: FakeSynthError.boom)
        let harness = TTSPlaybackHarness(output: output)
        await harness.service.speak(text: "refused", locale: english)
        #expect(await waitUntil { harness.events.values == [.utteranceSkipped(.outputUnavailable)] })

        output.failSchedules(with: nil)
        await harness.service.speak(text: "accepted", locale: english)

        #expect(await waitUntil { output.scheduledCount == 1 })
        #expect(await waitUntil { harness.speaking.values == [true, false, true, false] })
        await harness.service.deactivate()
    }

    @Test("every scheduled buffer reaches the monitor (REQ-T-17)")
    func observerSeesEveryBuffer() async {
        let script = FakeSynthesizer.Script(buffers: (0..<3).map { _ in makePCMBuffer() })
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(scripts: [script]),
                                         output: FakeOutput(autoComplete: true))
        let seen = LockedArray<AVAudioPCMBuffer>()
        await harness.service.setBufferObserver { seen.append($0) }

        await harness.service.speak(text: "three", locale: english)

        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(seen.values.count == 3)
        #expect(zip(seen.values, harness.output.scheduled).allSatisfy { $0 === $1 })
        #expect(zip(harness.output.scheduled, script.buffers).allSatisfy { $0 === $1 }, "buffers out of order")
        await harness.service.deactivate()
    }

    @Test("one metrics record per heard utterance: engine used, text length, locale (REQ-T-19)")
    func metrics() async {
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(engine: .kokoro), output: FakeOutput(autoComplete: true))
        await harness.service.speak(text: "hello", locale: english)
        #expect(await waitUntil { await harness.metrics.recent.count == 1 })
        let record = await harness.metrics.recent[0]
        #expect(record.engine == .kokoro)
        #expect(record.textLength == 5)
        #expect(record.locale == english)
        #expect(record.synthesisLatencyMs >= 0)
        await harness.service.deactivate()
    }

    @Test("no voice for the locale: skipped with .noVoice, nothing synthesized, isSpeaking untouched")
    func noVoice() async {
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(canSpeak: { _ in false }))
        await harness.service.speak(text: "unspeakable", locale: Locale(identifier: "xx-XX"))
        #expect(await waitUntil { harness.events.values == [.utteranceSkipped(.noVoice)] })
        #expect(harness.primary.texts.isEmpty)
        #expect(harness.speaking.values.isEmpty)
        await harness.service.deactivate()
    }

    @Test("the primary fails and there is no fallback: skipped with .primaryFailed (REQ-T-20)")
    func primaryFailedWithoutFallback() async {
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(scripts: [FakeSynthesizer.Script(failAfter: 0)]))
        await harness.service.speak(text: "fails", locale: english)
        let expected = TTSEvent.utteranceSkipped(.primaryFailed(FakeSynthError.boom.localizedDescription))
        #expect(await waitUntil { harness.events.values == [expected] })
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("deactivate shuts output and synthesizer down, finishes both streams and ignores later speech")
    func deactivate() async {
        let harness = TTSPlaybackHarness()
        await harness.service.deactivate()
        #expect(harness.output.shutdownCount == 1)
        #expect(harness.primary.shutdownCount == 1)
        #expect(await waitUntil { harness.speaking.isFinished && harness.events.isFinished })
        await harness.service.speak(text: "too late", locale: english)
        #expect(harness.primary.texts.isEmpty)
        #expect(await harness.service.pendingCount == 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-only TTSPlaybackServiceTests`
Expected: build FAILS — `cannot find 'TTSPlaybackService' in scope`.

- [ ] **Step 3: Add the events accessor to `SynthesisService`**

In `TranslateCall/Core/TTS/SynthesisService.swift`, inside `protocol SynthesisService`, after `isSpeakingStream`:
```swift
    /// Skips, fallbacks and drops, for the main window's notice line (F8.5.2 REQ-T-41).
    /// `nil` for services that report none.
    nonisolated var ttsEvents: AsyncStream<TTSEvent>? { get }
```
and in `extension SynthesisService`, after `setAudioMonitor`:
```swift
    nonisolated var ttsEvents: AsyncStream<TTSEvent>? { nil }
```

- [ ] **Step 4: Implement the service**

`TranslateCall/Core/TTS/TTSPlaybackService.swift`:
```swift
import AVFoundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSPlaybackService")

// MARK: - TTSPlaybackLimits

/// Tunables of `TTSPlaybackService` (design §3.3); injectable so tests can shrink them.
nonisolated struct TTSPlaybackLimits: Sendable {
    /// Utterances waiting behind the one in flight (REQ-T-12).
    var maxPending = 3
    /// Longest one synthesizer may take to finish one utterance (REQ-T-16).
    var utteranceWatchdog: Duration = .seconds(30)
    /// Consecutive primary failures after which utterances go straight to the fallback (REQ-T-23).
    var breakerThreshold = 3
    var breakerCooldown: Duration = .seconds(30)
    /// Allowed on top of the scheduled audio's own length for the output to report it played (REQ-T-16).
    var playbackGrace: Duration = .seconds(5)

    static let `default` = TTSPlaybackLimits()
}

// MARK: - TTSPlaybackService

/// The one `SynthesisService` the coordinator gets, whatever the engine (F8.5.2 REQ-T-10…19).
///
/// `speak` enqueues (at most `maxPending` waiting, the oldest dropped) and returns. One worker runs
/// utterances strictly one at a time: it starts the synthesizer, schedules each buffer as it arrives
/// and waits only for the last one to be played back. `stopSpeaking` bumps `generation`, so nothing
/// synthesized before it is ever scheduled. `isSpeakingStream` is truthful: `false` only once the
/// last queued audio has been heard, or at once on stop.
actor TTSPlaybackService: SynthesisService {

    // MARK: Public streams

    nonisolated let isSpeakingStream: AsyncStream<Bool>
    nonisolated let events: AsyncStream<TTSEvent>
    nonisolated var ttsEvents: AsyncStream<TTSEvent>? { events }
    nonisolated let primaryEngine: TTSEngine
    nonisolated let fallbackEngine: TTSEngine?

    // MARK: Types

    private struct Utterance: Sendable {
        let text: String
        let locale: Locale
    }

    private enum AttemptEnd: Equatable {
        case finished
        case failed(String)
        case outputFailed
        case timedOut
        case cancelled
    }

    private enum Drain: Sendable {
        case played, stopped, stalled
    }

    private enum Outcome {
        case played
        case skipped(TTSSkipReason)
        case stale
    }

    // MARK: Dependencies

    private let primary: any UtteranceSynthesizer
    private let fallback: (any UtteranceSynthesizer)?
    private let output: any AudioOutputting
    private let limits: TTSPlaybackLimits
    private let clock: any Clock<Duration>
    private let metrics: TTSMetricsCollector

    // MARK: State

    private let speakingContinuation: AsyncStream<Bool>.Continuation
    private let eventsContinuation: AsyncStream<TTSEvent>.Continuation
    private let wakeups: AsyncStream<Void>
    private let wakeupContinuation: AsyncStream<Void>.Continuation

    private var queue: [Utterance] = []
    private var generation: UInt64 = 0
    private var isSpeaking = false
    private var isDeactivated = false
    private var worker: Task<Void, Never>?
    private var attemptTask: Task<AttemptEnd, Never>?
    private var bufferObserver: (@Sendable (AVAudioPCMBuffer) -> Void)?

    // The attempt in flight. Only the worker starts attempts, one at a time.
    private var attemptStartedAt = ContinuousClock.now
    private var attemptFirstBufferAt: ContinuousClock.Instant?
    private var attemptBufferCount = 0
    private var attemptAudioSeconds: Double = 0
    private var attemptLastHandle: PlaybackHandle?

    // MARK: Init

    init(
        primary: any UtteranceSynthesizer,
        fallback: (any UtteranceSynthesizer)? = nil,
        output: any AudioOutputting,
        limits: TTSPlaybackLimits = .default,
        clock: any Clock<Duration> = ContinuousClock(),
        metrics: TTSMetricsCollector = .shared
    ) {
        self.primary = primary
        self.fallback = fallback
        self.output = output
        self.limits = limits
        self.clock = clock
        self.metrics = metrics
        primaryEngine = primary.engine
        fallbackEngine = fallback?.engine
        (isSpeakingStream, speakingContinuation) = AsyncStream.makeStream(
            of: Bool.self, bufferingPolicy: .bufferingNewest(8)
        )
        (events, eventsContinuation) = AsyncStream.makeStream(of: TTSEvent.self, bufferingPolicy: .bufferingNewest(16))
        (wakeups, wakeupContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Utterances waiting behind the one in flight.
    var pendingCount: Int { queue.count }

    // MARK: SynthesisService

    func speak(text: String, locale: Locale) async {
        guard !isDeactivated, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if queue.count >= limits.maxPending {
            queue.removeFirst()
            eventsContinuation.yield(.utteranceDropped)
            logger.info("TTS queue full: dropped the oldest pending sentence")
        }
        queue.append(Utterance(text: text, locale: locale))
        if worker == nil { worker = Task { await self.runWorker() } }
        wakeupContinuation.yield()
    }

    func stopSpeaking() async {
        generation &+= 1
        queue.removeAll()
        attemptTask?.cancel()
        output.stop()
        setSpeaking(false)
    }

    func deactivate() async {
        guard !isDeactivated else { return }
        isDeactivated = true
        await stopSpeaking()
        output.shutdown()
        await primary.shutdown()
        await fallback?.shutdown()
        wakeupContinuation.finish()
        speakingContinuation.finish()
        eventsContinuation.finish()
    }

    func setAudioMonitor(_ monitor: TTSAudioMonitor?) async {
        guard let monitor else {
            bufferObserver = nil
            return
        }
        bufferObserver = { buffer in monitor.process(buffer) }
    }

    /// Receives every buffer right after it is scheduled (`setAudioMonitor` installs the monitor here).
    func setBufferObserver(_ observer: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        bufferObserver = observer
    }

    // MARK: Worker

    private func runWorker() async {
        for await _ in wakeups {
            while !queue.isEmpty {
                let utterance = queue.removeFirst()
                await play(utterance)
            }
        }
    }

    private func play(_ utterance: Utterance) async {
        let gen = generation
        let outcome = await perform(utterance, gen: gen)
        guard gen == generation else { return }   // stopSpeaking already reported and cleared
        if case .skipped(let reason) = outcome {
            eventsContinuation.yield(.utteranceSkipped(reason))
            logger.warning("TTS sentence skipped: \(String(describing: reason), privacy: .public)")
        }
        if queue.isEmpty { setSpeaking(false) }
    }

    private func perform(_ utterance: Utterance, gen: UInt64) async -> Outcome {
        guard primary.canSpeak(utterance.locale) else { return .skipped(.noVoice) }
        let end = await runAttempt(primary, utterance, gen: gen)
        if case .failed(let message) = end, attemptBufferCount == 0 {
            return .skipped(.primaryFailed(message))
        }
        return await conclude(end, engine: primary.engine, utterance: utterance, gen: gen)
    }

    private func setSpeaking(_ speaking: Bool) {
        guard speaking != isSpeaking else { return }
        isSpeaking = speaking
        speakingContinuation.yield(speaking)
    }
}

// MARK: - One attempt

extension TTSPlaybackService {

    /// Runs one synthesizer on one utterance under the watchdog, scheduling each buffer it yields.
    private func runAttempt(
        _ synthesizer: any UtteranceSynthesizer, _ utterance: Utterance, gen: UInt64
    ) async -> AttemptEnd {
        guard gen == generation else { return .cancelled }
        attemptStartedAt = .now
        attemptFirstBufferAt = nil
        attemptBufferCount = 0
        attemptAudioSeconds = 0
        attemptLastHandle = nil
        setSpeaking(true)
        let stream = synthesizer.synthesize(text: utterance.text, locale: utterance.locale)
        let consumer = Task { await self.consume(stream, gen: gen) }
        attemptTask = consumer
        let watchdog = Task { [clock, limit = limits.utteranceWatchdog] in
            do { try await clock.sleep(for: limit) } catch { return false }
            consumer.cancel()
            return true
        }
        let end = await consumer.value
        watchdog.cancel()
        let timedOut = await watchdog.value
        attemptTask = nil
        return end == .cancelled && timedOut && gen == generation ? .timedOut : end
    }

    private func consume(_ stream: AsyncThrowingStream<AVAudioPCMBuffer, Error>, gen: UInt64) async -> AttemptEnd {
        do {
            for try await buffer in stream {
                guard gen == generation, !Task.isCancelled else { return .cancelled }
                guard buffer.frameLength > 0 else { continue }
                do {
                    attemptLastHandle = try output.schedule(buffer)
                } catch {
                    logger.error("TTS output refused a buffer: \(error.localizedDescription, privacy: .public)")
                    return .outputFailed
                }
                bufferObserver?(buffer)
                if attemptFirstBufferAt == nil { attemptFirstBufferAt = .now }
                attemptBufferCount += 1
                attemptAudioSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            }
        } catch {
            guard gen == generation, !Task.isCancelled else { return .cancelled }
            return .failed(error.localizedDescription)
        }
        guard gen == generation, !Task.isCancelled else { return .cancelled }
        return .finished
    }

    /// Waits for the attempt's audio to play out, then names the outcome (REQ-T-13/16/21).
    private func conclude(_ end: AttemptEnd, engine: TTSEngine, utterance: Utterance, gen: UInt64) async -> Outcome {
        if end == .cancelled { return .stale }
        if end == .outputFailed {
            output.stop()
            return .skipped(.outputUnavailable)
        }
        switch await drainPlayback() {
        case .stopped:
            return gen == generation ? .skipped(.outputUnavailable) : .stale
        case .stalled:
            output.stop()
            return .skipped(.outputUnavailable)
        case .played:
            if end == .timedOut { return .skipped(.timeout) }
            guard end == .finished else { return .skipped(.interrupted) }
            await recordMetrics(engine: engine, utterance: utterance)
            return .played
        }
    }

    /// Waits for the attempt's last buffer to be played back, bounded by the audio's length plus
    /// `playbackGrace`, so a device that never reports back cannot keep `isSpeaking` true (REQ-T-16).
    private func drainPlayback() async -> Drain {
        guard let handle = attemptLastHandle else { return .played }
        let bound = Duration.seconds(attemptAudioSeconds) + limits.playbackGrace
        let clock = self.clock
        return await withTaskGroup(of: Drain.self) { group in
            group.addTask {
                do { try await handle.wait() } catch { return .stopped }
                return .played
            }
            group.addTask {
                do { try await clock.sleep(for: bound) } catch { return .stopped }
                return .stalled
            }
            let first = await group.next() ?? .stopped
            group.cancelAll()
            return first
        }
    }

    private func recordMetrics(engine: TTSEngine, utterance: Utterance) async {
        guard let firstBufferAt = attemptFirstBufferAt else { return }   // nothing was heard
        let latency = attemptStartedAt.duration(to: firstBufferAt)
        await metrics.record(TTSMetrics(
            engine: engine,
            synthesisLatencyMs: Int(latency / .milliseconds(1)),
            textLength: utterance.text.count,
            locale: utterance.locale,
            timestamp: Date()
        ))
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `just test-only TTSPlaybackServiceTests PlaybackHandleTests TestClockTests`
Expected: PASS (16 + 6 tests). Run it three times: the suite must be stable (it waits on conditions and on `TestClock`, never on time). Then `just lint` → exit 0.

- [ ] **Step 6: Commit**

```bash
git add TranslateCall/Core/TTS/TTSPlaybackService.swift TranslateCall/Core/TTS/SynthesisService.swift \
        TranslateCallTests/Support/TTSPlaybackHarness.swift TranslateCallTests/TTSPlaybackServiceTests.swift
git commit -m "feat(tts): TTSPlaybackService with bounded queue, generations and truthful isSpeaking (F8.5.2)

REQ-T-10…19: FIFO worker, cap 3 with .utteranceDropped, buffers scheduled as they arrive,
only the last one awaited (.dataPlayedBack handle), stopSpeaking bumps the generation,
watchdog on synthesis, bounded wait on playback, events and metrics.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Fallback, circuit breaker and a format-safe TTS monitor

**Files:**
- Modify: `TranslateCall/Core/TTS/TTSPlaybackService.swift` (state block, `deactivate`, `perform` + three new helpers)
- Modify: `TranslateCall/Core/TTS/TTSAudioMonitor.swift` (`playerFormatConfigured` → `playerFormat`, `process`, `playLastRecording`)
- Test: `TranslateCallTests/TTSPlaybackFallbackTests.swift`

**Interfaces:**
- Consumes: `TTSPlaybackService` internals from Task 2 (`runAttempt`, `conclude`, `attemptBufferCount`, `eventsContinuation`), `TTSPlaybackHarness`, `FakeSynthesizer`.
- Produces: `TTSPlaybackService.isBreakerOpen: Bool` (actor-isolated, read by tests); `static func TTSAudioMonitor.needsReconnect(current: AVAudioFormat?, incoming: AVAudioFormat) -> Bool`.

Rules (REQ-T-20…23, decisions P2/P3): before the first buffer, a primary failure retries the same utterance on the fallback when it can speak the locale (`.fellBack`), else `.primaryFailed`; after the first buffer the rest is dropped (`.interrupted`, no fallback; the audio already scheduled still plays out before `isSpeaking` goes false). Primary failures before audio (thrown or watchdog) count toward the breaker; a primary success resets it. After 3 in a row, utterances go straight to the fallback for `breakerCooldown`; then the breaker is half-open (one more failure reopens it). The breaker never diverts when there is no usable fallback.

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/TTSPlaybackFallbackTests.swift`:
```swift
import AVFoundation
import Testing
@testable import TranslateCall

@Suite("TTSPlaybackService fallback and breaker")
struct TTSPlaybackFallbackTests {
    private let failing = FakeSynthesizer.Script(failAfter: 0)
    private let ukrainian = Locale(identifier: "uk-UA")

    private func edge(_ scripts: [FakeSynthesizer.Script]) -> FakeSynthesizer {
        FakeSynthesizer(engine: .edgeTTS, scripts: scripts)
    }

    @Test("the primary fails before any audio: the fallback speaks the same utterance and .fellBack is emitted (REQ-T-20/22)")
    func fallsBackBeforeAudio() async {
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let harness = TTSPlaybackHarness(primary: edge([failing]), fallback: fallback,
                                         output: FakeOutput(autoComplete: true))
        await harness.service.speak(text: "hola", locale: english)
        #expect(await waitUntil { fallback.texts == ["hola"] })
        #expect(await waitUntil { harness.events.values == [.fellBack(from: .edgeTTS, to: .avSpeech)] })
        #expect(await waitUntil { await harness.metrics.recent.map(\.engine) == [.avSpeech] })
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("the primary fails after audio started: the rest is dropped, .interrupted, no fallback (REQ-T-21)")
    func interruptedAfterAudio() async {
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let harness = TTSPlaybackHarness(primary: edge([FakeSynthesizer.Script(failAfter: 1)]), fallback: fallback)
        await harness.service.speak(text: "half", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 && harness.speaking.values == [true] })

        harness.output.completeAll()                      // the part already heard plays out first

        #expect(await waitUntil { harness.events.values == [.utteranceSkipped(.interrupted)] })
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(fallback.texts.isEmpty)
        await harness.service.deactivate()
    }

    @Test("the fallback cannot speak the locale: skipped with .primaryFailed (REQ-T-20)")
    func fallbackCannotSpeak() async {
        let fallback = FakeSynthesizer(engine: .avSpeech, canSpeak: { _ in false })
        let harness = TTSPlaybackHarness(primary: edge([failing]), fallback: fallback)
        await harness.service.speak(text: "x", locale: ukrainian)
        let expected = TTSEvent.utteranceSkipped(.primaryFailed(FakeSynthError.boom.localizedDescription))
        #expect(await waitUntil { harness.events.values == [expected] })
        #expect(fallback.texts.isEmpty)
        await harness.service.deactivate()
    }

    @Test("neither engine can speak the locale: skipped with .noVoice")
    func neitherCanSpeak() async {
        let primary = FakeSynthesizer(engine: .edgeTTS, canSpeak: { _ in false })
        let fallback = FakeSynthesizer(engine: .avSpeech, canSpeak: { _ in false })
        let harness = TTSPlaybackHarness(primary: primary, fallback: fallback)
        await harness.service.speak(text: "x", locale: Locale(identifier: "xx-XX"))
        #expect(await waitUntil { harness.events.values == [.utteranceSkipped(.noVoice)] })
        #expect(primary.texts.isEmpty && fallback.texts.isEmpty)
        await harness.service.deactivate()
    }

    @Test("the primary cannot speak the locale but the fallback can: the fallback speaks, .fellBack")
    func primaryCannotSpeak() async {
        let primary = FakeSynthesizer(engine: .kokoro, canSpeak: { _ in false })
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let harness = TTSPlaybackHarness(primary: primary, fallback: fallback, output: FakeOutput(autoComplete: true))
        await harness.service.speak(text: "bonjour", locale: Locale(identifier: "fr-FR"))
        #expect(await waitUntil { fallback.texts == ["bonjour"] })
        #expect(await waitUntil { harness.events.values == [.fellBack(from: .kokoro, to: .avSpeech)] })
        #expect(primary.texts.isEmpty)
        await harness.service.deactivate()
    }

    @Test("the fallback fails too: one .primaryFailed skip, and the breaker only counts the primary")
    func fallbackFailsToo() async {
        let fallback = FakeSynthesizer(engine: .avSpeech, scripts: [failing])
        let harness = TTSPlaybackHarness(primary: edge([failing]), fallback: fallback)
        await harness.service.speak(text: "x", locale: english)
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(await waitUntil { harness.events.values.count == 2 })
        #expect(harness.events.values.last == .utteranceSkipped(.primaryFailed(FakeSynthError.boom.localizedDescription)))
        #expect(!(await harness.service.isBreakerOpen))
        await harness.service.deactivate()
    }

    @Test("3 primary failures in a row: fallback only for 30 s, then the primary is tried again (REQ-T-23)")
    func breaker() async {
        let primary = edge([failing])
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let harness = TTSPlaybackHarness(primary: primary, fallback: fallback, output: FakeOutput(autoComplete: true))
        for index in 1...3 {
            await harness.service.speak(text: "s\(index)", locale: english)
            #expect(await waitUntil { fallback.texts.count == index })
        }
        #expect(await harness.service.isBreakerOpen)

        await harness.service.speak(text: "s4", locale: english)
        #expect(await waitUntil { fallback.texts.count == 4 })
        #expect(primary.texts.count == 3, "the open breaker still tried the primary")

        #expect(await waitUntil { harness.clock.pendingDeadlines == [.seconds(30)] })   // only the cooldown sleeps
        harness.clock.advance(by: .seconds(30))
        #expect(await waitUntil { await !harness.service.isBreakerOpen })

        await harness.service.speak(text: "s5", locale: english)
        #expect(await waitUntil { primary.texts.count == 4 && fallback.texts.count == 5 })
        #expect(await harness.service.isBreakerOpen, "one failure after the cooldown reopens the breaker")
        await harness.service.deactivate()
    }

    @Test("a primary success resets the failure count")
    func successResets() async {
        let ok = FakeSynthesizer.Script()
        let primary = edge([failing, failing, ok, failing, failing, ok])
        let harness = TTSPlaybackHarness(primary: primary, fallback: FakeSynthesizer(engine: .avSpeech),
                                         output: FakeOutput(autoComplete: true))
        for index in 1...5 {
            await harness.service.speak(text: "s\(index)", locale: english)
            #expect(await waitUntil { harness.speaking.values.count == 2 * index })
        }
        #expect(primary.texts.count == 5)
        #expect(!(await harness.service.isBreakerOpen))
        await harness.service.deactivate()
    }

    @Test("Review focus: with no usable fallback (Edge-only locale) the breaker never diverts; every sentence tries the primary")
    func breakerNeedsAFallback() async {
        let primary = edge([failing])
        let harness = TTSPlaybackHarness(primary: primary, output: FakeOutput(autoComplete: true))
        for index in 1...4 {
            await harness.service.speak(text: "s\(index)", locale: ukrainian)
            #expect(await waitUntil { harness.speaking.values.count == 2 * index })
        }
        #expect(primary.texts.count == 4)
        #expect(await waitUntil { harness.events.values.count == 4 })
        #expect(harness.events.values.allSatisfy { event in
            if case .utteranceSkipped(.primaryFailed) = event { true } else { false }
        })
        await harness.service.deactivate()
    }
}

@Suite("TTSAudioMonitor format changes")
struct TTSAudioMonitorFormatTests {
    @Test("Review focus: a buffer in a new format (fallback engine mid-session) reconnects the monitor's player")
    func reconnectsOnNewFormat() throws {
        let edge = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let system = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        #expect(TTSAudioMonitor.needsReconnect(current: nil, incoming: edge))
        #expect(!TTSAudioMonitor.needsReconnect(current: edge, incoming: edge))
        #expect(TTSAudioMonitor.needsReconnect(current: edge, incoming: system))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-only TTSPlaybackFallbackTests TTSAudioMonitorFormatTests`
Expected: build FAILS — `value of type 'TTSPlaybackService' has no member 'isBreakerOpen'`, `type 'TTSAudioMonitor' has no member 'needsReconnect'`.

- [ ] **Step 3: Implement fallback and breaker**

In `TranslateCall/Core/TTS/TTSPlaybackService.swift`, after `private var bufferObserver: (@Sendable (AVAudioPCMBuffer) -> Void)?` add:
```swift

    // Circuit breaker on the primary (REQ-T-23).
    private var consecutiveFailures = 0
    private(set) var isBreakerOpen = false
    private var breakerTask: Task<Void, Never>?
```
In `deactivate()`, right after `await stopSpeaking()`, add `breakerTask?.cancel()`.

Replace the whole `perform(_:gen:)` with:
```swift
    private func perform(_ utterance: Utterance, gen: UInt64) async -> Outcome {
        let fallbackReady = fallback?.canSpeak(utterance.locale) ?? false
        // The breaker only diverts when the fallback can take the sentence: with no usable
        // fallback the primary is the only voice there is, so it keeps being tried.
        guard primary.canSpeak(utterance.locale), !(isBreakerOpen && fallbackReady) else {
            guard let fallback, fallbackReady else { return .skipped(.noVoice) }
            return await speakWithFallback(fallback, utterance, gen: gen)
        }
        let end = await runAttempt(primary, utterance, gen: gen)
        let heardNothing = attemptBufferCount == 0
        switch end {
        case .finished: consecutiveFailures = 0
        case .failed, .timedOut: if heardNothing { recordPrimaryFailure() }
        case .outputFailed, .cancelled: break
        }
        if case .failed(let message) = end, heardNothing {
            guard let fallback, fallbackReady else { return .skipped(.primaryFailed(message)) }
            return await speakWithFallback(fallback, utterance, gen: gen)
        }
        return await conclude(end, engine: primary.engine, utterance: utterance, gen: gen)
    }

    /// The same utterance again, on the fallback (REQ-T-20/22). The fallback has no fallback.
    private func speakWithFallback(
        _ fallback: any UtteranceSynthesizer, _ utterance: Utterance, gen: UInt64
    ) async -> Outcome {
        eventsContinuation.yield(.fellBack(from: primary.engine, to: fallback.engine))
        let end = await runAttempt(fallback, utterance, gen: gen)
        if case .failed(let message) = end, attemptBufferCount == 0 {
            return .skipped(.primaryFailed(message))
        }
        return await conclude(end, engine: fallback.engine, utterance: utterance, gen: gen)
    }

    private func recordPrimaryFailure() {
        consecutiveFailures += 1
        guard consecutiveFailures >= limits.breakerThreshold, !isBreakerOpen else { return }
        isBreakerOpen = true
        let failures = consecutiveFailures
        logger.warning("TTS primary failed \(failures) times in a row: fallback only for the cooldown")
        let clock = self.clock
        let cooldown = limits.breakerCooldown
        breakerTask = Task { [weak self] in
            do { try await clock.sleep(for: cooldown) } catch { return }
            await self?.halfOpenBreaker()
        }
    }

    /// Cooldown over: the primary is tried again, and one more failure reopens the breaker at once.
    private func halfOpenBreaker() {
        isBreakerOpen = false
        consecutiveFailures = limits.breakerThreshold - 1
        breakerTask = nil
    }
```

- [ ] **Step 4: Make the monitor follow format changes (Review Focus)**

In `TranslateCall/Core/TTS/TTSAudioMonitor.swift`:

Replace
```swift
    /// Whether playerNode→mixer has been reconnected with the actual TTS buffer format.
    private var playerFormatConfigured = false
```
with
```swift
    /// Format the player is connected with; nil until the first buffer.
    private var playerFormat: AVAudioFormat?
```
In `process(_:)`, replace the `if !playerFormatConfigured { … }` block and its comment with:
```swift
        // The player must be connected with the buffer's format, and that format changes when the
        // playback service falls back to another engine mid-session (F8.5.2): reconnect then, so a
        // mismatched buffer is never scheduled (that raises an exception and crashes the app).
        connectPlayer(for: buffer.format)
```
Insert before `// MARK: - Recording API`:
```swift
    /// True when the player has to be (re)connected before scheduling a buffer of `incoming` format.
    static func needsReconnect(current: AVAudioFormat?, incoming: AVAudioFormat) -> Bool {
        current != incoming
    }

    private func connectPlayer(for format: AVAudioFormat) {
        guard Self.needsReconnect(current: playerFormat, incoming: format) else { return }
        playerNode.stop()
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: mixer, format: format)
        playerFormat = format
        logger.info("Monitor player format configured: \(format.description)")
    }

```
In `playLastRecording()`, between `playerNode.stop()` and `playerNode.scheduleBuffer(buffer, at: nil, options: [])`, add `connectPlayer(for: buffer.format)` (a recording's format can differ from the player's too).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `just test-only TTSPlaybackFallbackTests TTSAudioMonitorFormatTests TTSPlaybackServiceTests`
Expected: PASS (10 + 16 tests). Then `just lint` → exit 0.

- [ ] **Step 6: Commit**

```bash
git add TranslateCall/Core/TTS/TTSPlaybackService.swift TranslateCall/Core/TTS/TTSAudioMonitor.swift \
        TranslateCallTests/TTSPlaybackFallbackTests.swift
git commit -m "feat(tts): per-utterance fallback and circuit breaker; monitor follows format changes (F8.5.2)

REQ-T-20…23. The breaker only diverts when the fallback can speak the locale and is half-open
after the cooldown. TTSAudioMonitor reconnects its player when the format changes (fallback
mid-session), instead of scheduling a mismatched buffer.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `TTSOutput`, `AVSpeechUtteranceSynthesizer` and the BlackHole integration test (A12, NFR-T-02)

**Files:**
- Modify: `TranslateCall/Core/TTS/SynthesisService.swift` (`nonisolated` config and error, `STSError.outputUnavailable`)
- Create: `TranslateCall/Core/TTS/TTSOutput.swift` (`TTSOutput`, `PCMFormatConverter`)
- Create: `TranslateCall/Core/TTS/AVSpeechUtteranceSynthesizer.swift`
- Modify: `TranslateCallTests/TTSServiceTests.swift` (`STSErrorDeviceRoutingTests`)
- Modify: `TranslateCallTests/Support/BufferLog.swift` (entry duration, first/last entry)
- Create: `TranslateCallTests/Support/RecordingOutput.swift`
- Test: `TranslateCallTests/TTSOutputConversionTests.swift`, `TranslateCallTests/AVSpeechUtteranceSynthesizerTests.swift`, `TranslateCallTests/Integration/TTSPlaybackIntegrationTests.swift`

**Interfaces:**
- Consumes: `AudioOutputting`, `PlaybackHandle`, `UtteranceStream`, `TTSPlaybackService` (Tasks 1–3); `CoreAudioDevices.setCurrentDevice(_:on:)`, `.currentDevice(of:)`; `AudioManager`, `BufferLog`, `requireMicrophoneAuthorization()`, `requireBlackHole(in:)` (F8.5.1); `StreamRecorder`, `collect`, `english`.
- Produces:
  - `STSError.outputUnavailable`; `SynthesisConfiguration` and `STSError` become `nonisolated`.
  - `nonisolated final class TTSOutput: AudioOutputting { init(deviceID: AudioDeviceID?) throws }` (throws `STSError.deviceRoutingFailed` / `.engineStartFailed`; `schedule` throws `.outputUnavailable`)
  - `nonisolated final class PCMFormatConverter { init(target: AVAudioFormat); var target: AVAudioFormat { get }; func retarget(_:); func reset(); func convert(_:) throws -> AVAudioPCMBuffer }`
  - `nonisolated final class AVSpeechUtteranceSynthesizer: UtteranceSynthesizer { init(config: SynthesisConfiguration = .default); static func bestVoice(for: Locale) -> AVSpeechSynthesisVoice?; static func hasVoice(for: Locale) -> Bool }`
  - Test support: `RecordingOutput(wrapping:)` (`firstScheduleAt`, `scheduledDuration`, `trailingSilence`), `BufferLog.Entry.duration`, `BufferLog.firstEntry(since:threshold:)`, `.lastEntry(since:threshold:)`

`TTSOutput` in one paragraph: it binds the output unit to the device (the only HAL/AU write, `kAudioOutputUnitProperty_CurrentDevice`), connects one player to the main mixer as mono Float32 at the rate the output's hardware side reports, converts each buffer to that format with one streaming converter per source format (consecutive buffers join without gaps, NFR-T-01), schedules with `.dataPlayedBack`, and cancels handles before `player.stop()` so stop never counts as played. On `AVAudioEngineConfigurationChange` (only while the engine is stopped: a late notice is ignored) it cancels what was scheduled, rebinds the same device if needed and restarts; if that fails, `schedule` throws `.outputUnavailable`.

- [ ] **Step 1: Write the failing unit tests**

`TranslateCallTests/TTSOutputConversionTests.swift`:
```swift
import AVFoundation
import Testing
@testable import TranslateCall

@Suite("PCMFormatConverter")
struct PCMFormatConverterTests {
    private let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    @Test("a buffer already in the target format passes through untouched")
    func passthrough() throws {
        let converter = PCMFormatConverter(target: target)
        let buffer = makePCMBuffer(frames: 480, sampleRate: 48_000, fill: 0.5)
        #expect(try converter.convert(buffer) === buffer)
    }

    @Test("24 kHz Kokoro/Qwen/Edge audio is resampled to the output rate (about twice the frames)")
    func resamples24k() throws {
        let converter = PCMFormatConverter(target: target)
        let out = try converter.convert(makePCMBuffer(frames: 2_400, sampleRate: 24_000, fill: 0.5))
        #expect(out.format == target)
        #expect(abs(Int(out.frameLength) - 4_800) <= 480)
    }

    @Test("consecutive buffers of one utterance stream through one converter without losing audio (NFR-T-01)")
    func streamsConsecutiveBuffers() throws {
        let converter = PCMFormatConverter(target: target)
        var total = 0
        for _ in 0..<10 {
            total += Int(try converter.convert(makePCMBuffer(frames: 2_205, sampleRate: 22_050, fill: 0.5)).frameLength)
        }
        #expect(abs(total - 48_000) <= 480)   // 1 s in, 1 s out, minus the converter's few frames of latency
    }

    @Test("stereo and Int16 sources come out as the mono Float32 target")
    func otherLayouts() throws {
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let stereoBuffer = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4_410))
        stereoBuffer.frameLength = 4_410
        let int16 = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22_050,
                                               channels: 1, interleaved: false))
        let int16Buffer = try #require(AVAudioPCMBuffer(pcmFormat: int16, frameCapacity: 2_205))
        int16Buffer.frameLength = 2_205
        let converter = PCMFormatConverter(target: target)
        #expect(try converter.convert(stereoBuffer).format == target)
        #expect(try converter.convert(int16Buffer).format == target)
    }
}
```

`TranslateCallTests/AVSpeechUtteranceSynthesizerTests.swift`:
```swift
import AVFoundation
import Testing
@testable import TranslateCall

/// `AVSpeechSynthesizer.write` renders offline: no audio device is opened (NFR-T-03).
@Suite("AVSpeechUtteranceSynthesizer", .serialized)
struct AVSpeechUtteranceSynthesizerTests {
    private let synthesizer = AVSpeechUtteranceSynthesizer()

    @Test("an English sentence yields audio and the stream finishes (REQ-T-03)")
    func yieldsAndFinishes() async throws {
        let buffers = try #require(try await collect(synthesizer.synthesize(text: "Hello there", locale: english)),
                                   "the stream did not finish within 10 s")
        #expect(!buffers.isEmpty)
        #expect(buffers.allSatisfy { $0.frameLength > 0 })
    }

    @Test("blank text finishes at once with no buffers (REQ-T-03)")
    func blankFinishesEmpty() async throws {
        let buffers = try await collect(synthesizer.synthesize(text: "  ", locale: english))
        #expect(buffers?.isEmpty == true)
    }

    @Test("a locale without a system voice throws voiceUnavailable and cannot be spoken")
    func unknownLocale() async {
        let locale = Locale(identifier: "xx-XX")
        #expect(!synthesizer.canSpeak(locale))
        await #expect(throws: STSError.voiceUnavailable(locale)) {
            _ = try await collect(synthesizer.synthesize(text: "Test", locale: locale))
        }
    }

    @Test("English has a voice; the best one is premium or enhanced when installed")
    func englishVoice() throws {
        #expect(synthesizer.canSpeak(english))
        #expect(AVSpeechUtteranceSynthesizer.hasVoice(for: Locale(identifier: "en")))
        let voice = try #require(AVSpeechUtteranceSynthesizer.bestVoice(for: english))
        let installedBetter = AVSpeechSynthesisVoice.speechVoices().contains {
            $0.language.hasPrefix("en") && $0.quality != .default
        }
        #expect(!installedBetter || voice.quality != .default)
    }

    @Test("hasVoice matches the voices installed on this machine")
    func hasVoiceMatchesInstalled() {
        let installed = AVSpeechSynthesisVoice.speechVoices().contains { $0.language.hasPrefix("uk") }
        #expect(AVSpeechUtteranceSynthesizer.hasVoice(for: Locale(identifier: "uk")) == installed)
    }
}
```

In `TranslateCallTests/TTSServiceTests.swift`, add to `struct STSErrorDeviceRoutingTests`:
```swift

    @Test func outputUnavailableHasDescription() {
        #expect(STSError.outputUnavailable.errorDescription?.isEmpty == false)
        #expect(STSError.outputUnavailable == .outputUnavailable)
        #expect(STSError.outputUnavailable != .deviceRoutingFailed)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-only PCMFormatConverterTests AVSpeechUtteranceSynthesizerTests STSErrorDeviceRoutingTests`
Expected: build FAILS — `cannot find 'PCMFormatConverter' in scope`, `type 'STSError' has no member 'outputUnavailable'`.

- [ ] **Step 3: Make the configuration and the error nonisolated; add `outputUnavailable`**

In `TranslateCall/Core/TTS/SynthesisService.swift`:
- line 5: `nonisolated struct SynthesisConfiguration: Sendable {`
- line 18: `nonisolated enum STSError: LocalizedError, Equatable {`, and after `case deviceRoutingFailed` add:
```swift
    /// The output device is gone or the engine could not restart (F8.5.2).
    case outputUnavailable
```
- in `errorDescription`, after the `.deviceRoutingFailed` case:
```swift
        case .outputUnavailable:
            return "The audio output device is unavailable."
```
- in `==`, after the `.deviceRoutingFailed` pair: `case (.outputUnavailable, .outputUnavailable): return true`

- [ ] **Step 4: Implement the output and the AVSpeech synthesizer**

`TranslateCall/Core/TTS/TTSOutput.swift`:
```swift
import AVFoundation
import CoreAudio
import OSLog
import Synchronization

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSOutput")

// MARK: - TTSOutput

/// The device side of TTS (design §3.2): one `AVAudioPlayerNode` connected at the output's rate, every
/// buffer converted to that format, completion on `.dataPlayedBack`, restart after a configuration
/// change. The only HAL/AU property it writes is `kAudioOutputUnitProperty_CurrentDevice`
/// (F8.5.1: format writes wedged coreaudiod).
///
/// `@unchecked Sendable`: `engine` and `player` are only driven through calls AVFoundation allows from
/// any thread; every piece of mutable Swift state lives in `state`, a `Mutex`.
nonisolated final class TTSOutput: AudioOutputting, @unchecked Sendable {

    private struct State {
        var converter: PCMFormatConverter
        var pending: [PlaybackHandle] = []
        var isAvailable = true
        var isShutdown = false
    }

    private enum Step: Sendable {
        case play(AVAudioPCMBuffer)
        case alreadyHeard(PlaybackHandle?)
    }

    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private let deviceID: AudioDeviceID?
    private let state: Mutex<State>
    /// Set once at the end of `init`, read by `shutdown()`.
    private var configurationObserver: (any NSObjectProtocol)?

    /// - Parameter deviceID: output device (BlackHole for outgoing TTS); nil = system default output.
    init(deviceID: AudioDeviceID?) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        if let deviceID { try Self.bind(engine, to: deviceID) }
        let format = try Self.playerFormat(of: engine)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            throw STSError.engineStartFailed(error)
        }
        player.play()
        self.engine = engine
        self.player = player
        self.deviceID = deviceID
        state = Mutex(State(converter: PCMFormatConverter(target: format)))
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        shutdown()
    }

    // MARK: AudioOutputting

    func schedule(_ buffer: AVAudioPCMBuffer) throws -> PlaybackHandle {
        guard engine.isRunning else { throw STSError.outputUnavailable }
        let handle = PlaybackHandle()
        let step: Step = try state.withLock { current in
            guard current.isAvailable, !current.isShutdown else { throw STSError.outputUnavailable }
            let converted = try current.converter.convert(buffer)
            current.pending.removeAll { $0.isResolved }
            // Nothing came out of the converter yet (it is priming): this buffer is heard when
            // the audio scheduled before it is.
            guard converted.frameLength > 0 else { return .alreadyHeard(current.pending.last) }
            current.pending.append(handle)
            return .play(converted)
        }
        switch step {
        case .alreadyHeard(let previous):
            if let previous { return previous }
            handle.markPlayed()
            return handle
        case .play(let converted):
            player.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { _ in
                handle.markPlayed()
            }
            if !player.isPlaying { player.play() }
            return handle
        }
    }

    func stop() {
        let cancelled: [PlaybackHandle] = state.withLock { current in
            defer { current.pending.removeAll() }
            current.converter.reset()
            return current.pending
        }
        // Before player.stop(): the completions it fires must not count as played back.
        cancelled.forEach { $0.markCancelled() }
        player.stop()
    }

    func shutdown() {
        let first: Bool = state.withLock { current in
            defer { current.isShutdown = true }
            return !current.isShutdown
        }
        guard first else { return }
        stop()
        engine.stop()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    // MARK: Device

    private static func bind(_ engine: AVAudioEngine, to deviceID: AudioDeviceID) throws {
        guard let unit = engine.outputNode.audioUnit else { throw STSError.deviceRoutingFailed }
        do {
            try CoreAudioDevices.setCurrentDevice(deviceID, on: unit)
        } catch {
            throw STSError.deviceRoutingFailed
        }
    }

    /// Mono Float32 at the rate the output's hardware side reports. The mixer spreads mono over the
    /// device's channels and the output unit resamples if that rate is stale after a device change,
    /// so a stale value costs a resample, never silence (unlike the input side, F8.5.1).
    private static func playerFormat(of engine: AVAudioEngine) throws -> AVAudioFormat {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 1) else {
            throw STSError.outputUnavailable
        }
        return format
    }

    /// The device changed under the engine (unplugged, rate changed, default switched) and AVAudioEngine
    /// stopped. What was scheduled is lost, so its handles are cancelled; then the engine restarts on the
    /// same device. If that fails, `schedule` throws `.outputUnavailable` until the next change.
    private func handleConfigurationChange() {
        guard !engine.isRunning else { return }   // late notice of a change already recovered from
        let lost: [PlaybackHandle]? = state.withLock { current in
            guard !current.isShutdown else { return nil }
            current.isAvailable = false
            defer { current.pending.removeAll() }
            return current.pending
        }
        guard let lost else { return }
        lost.forEach { $0.markCancelled() }
        do {
            if let deviceID, let unit = engine.outputNode.audioUnit,
               CoreAudioDevices.currentDevice(of: unit) != deviceID {
                try CoreAudioDevices.setCurrentDevice(deviceID, on: unit)
            }
            let format = try Self.playerFormat(of: engine)
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            state.withLock { $0.converter.retarget(format) }
            try engine.start()
            player.play()
            state.withLock { $0.isAvailable = true }
            logger.info("TTS output restarted after a configuration change")
        } catch {
            logger.error("TTS output could not restart: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - PCMFormatConverter

/// Converts PCM buffers to one target format, keeping one streaming `AVAudioConverter` per source
/// format so consecutive buffers of an utterance join without gaps (NFR-T-01).
/// Not thread-safe: `TTSOutput` only calls it while holding its lock.
nonisolated final class PCMFormatConverter {
    private static let slackFrames: AVAudioFrameCount = 1_024

    private(set) var target: AVAudioFormat
    private var converters: [AVAudioFormat: AVAudioConverter] = [:]

    init(target: AVAudioFormat) {
        self.target = target
    }

    func retarget(_ format: AVAudioFormat) {
        target = format
        converters.removeAll()
    }

    /// Drops what the converters hold back between buffers (after playback was stopped).
    func reset() {
        converters.values.forEach { $0.reset() }
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == target { return buffer }
        let converter = try converter(for: buffer.format)
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + Self.slackFrames
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw STSError.outputUnavailable
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { throw STSError.outputUnavailable }
        return output
    }

    private func converter(for format: AVAudioFormat) throws -> AVAudioConverter {
        if let existing = converters[format] { return existing }
        guard let made = AVAudioConverter(from: format, to: target) else { throw STSError.outputUnavailable }
        converters[format] = made
        return made
    }
}
```

`TranslateCall/Core/TTS/AVSpeechUtteranceSynthesizer.swift`:
```swift
import AVFoundation
import Synchronization

// MARK: - AVSpeechUtteranceSynthesizer

/// System voices through `AVSpeechSynthesizer.write` (F8.5.2 REQ-T-02/03). Buffers are yielded from the
/// write callback in callback order, with no `Task` per buffer. An utterance's stream finishes on the
/// end marker (a zero-length buffer) or on `didFinish`/`didCancel` for that utterance, whichever first.
///
/// `@unchecked Sendable`: `synthesizer` is AVFoundation's and is driven from whichever thread calls
/// `synthesize` (as `AVSpeechService` did before F8.5.2); the per-utterance state lives in `router`.
nonisolated final class AVSpeechUtteranceSynthesizer: UtteranceSynthesizer, @unchecked Sendable {
    let engine: TTSEngine = .avSpeech
    private let config: SynthesisConfiguration
    private let synthesizer = AVSpeechSynthesizer()
    private let router = SpeechCompletionRouter()

    init(config: SynthesisConfiguration = .default) {
        self.config = config
        synthesizer.delegate = router
    }

    func canSpeak(_ locale: Locale) -> Bool {
        Self.bestVoice(for: locale) != nil
    }

    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let (stream, continuation) = UtteranceStream.make()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continuation.finish()   // no audio to produce (REQ-T-03)
            return stream
        }
        guard let voice = Self.bestVoice(for: locale) else {
            continuation.finish(throwing: STSError.voiceUnavailable(locale))
            return stream
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = config.rate
        utterance.pitchMultiplier = config.pitchMultiplier
        utterance.volume = config.volume
        let id = ObjectIdentifier(utterance)
        router.register(id, continuation)
        continuation.onTermination = { [weak self] termination in
            self?.router.remove(id)
            if case .cancelled = termination { self?.synthesizer.stopSpeaking(at: .immediate) }
        }
        synthesizer.write(utterance) { [router] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                router.finish(id)   // end-of-utterance marker
            } else {
                continuation.yield(pcm)
            }
        }
        return stream
    }

    /// Premium, then enhanced, then any voice whose language matches the locale's first two letters.
    static func bestVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        let lang = String(locale.identifier.replacingOccurrences(of: "_", with: "-").prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? voices.first
    }

    /// True if at least one system voice exists for the locale's language code.
    static func hasVoice(for locale: Locale) -> Bool {
        guard let code = locale.language.languageCode?.identifier, !code.isEmpty else { return false }
        return AVSpeechSynthesisVoice.speechVoices().contains { voice in
            (voice.language.components(separatedBy: "-").first ?? "") == code
        }
    }
}

// MARK: - SpeechCompletionRouter

/// Delegate of the shared `AVSpeechSynthesizer`: finishes the stream of the utterance a callback is
/// about, so a late `didCancel` of a stopped utterance can never end the next one.
nonisolated private final class SpeechCompletionRouter: NSObject, AVSpeechSynthesizerDelegate, Sendable {
    typealias Continuation = AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation

    private let pending = Mutex<[ObjectIdentifier: Continuation]>([:])

    func register(_ id: ObjectIdentifier, _ continuation: Continuation) {
        pending.withLock { $0[id] = continuation }
    }

    func remove(_ id: ObjectIdentifier) {
        _ = pending.withLock { $0.removeValue(forKey: id) }
    }

    func finish(_ id: ObjectIdentifier) {
        pending.withLock { $0.removeValue(forKey: id) }?.finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(ObjectIdentifier(utterance))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(ObjectIdentifier(utterance))
    }
}
```

- [ ] **Step 5: Run the unit tests to verify they pass**

Run: `just test-only PCMFormatConverterTests AVSpeechUtteranceSynthesizerTests STSErrorDeviceRoutingTests`
Expected: PASS (4 + 5 + 2 tests). `AVSpeechSynthesizer.write` renders offline (no audio device). Then `just lint` → exit 0.

- [ ] **Step 6: Commit the unit-tested parts**

```bash
git add TranslateCall/Core/TTS/SynthesisService.swift TranslateCall/Core/TTS/TTSOutput.swift \
        TranslateCall/Core/TTS/AVSpeechUtteranceSynthesizer.swift TranslateCallTests/TTSServiceTests.swift \
        TranslateCallTests/TTSOutputConversionTests.swift TranslateCallTests/AVSpeechUtteranceSynthesizerTests.swift
git commit -m "feat(tts): TTSOutput (.dataPlayedBack, hardware-rate player) and AVSpeech synthesizer (F8.5.2)

A12: buffers are yielded in callback order without a Task per buffer and the stream ends on the
end marker or didFinish/didCancel of that utterance; playback completion comes from
.dataPlayedBack, so the tail is never stopped early.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Integration test through BlackHole**

`TranslateCallTests/Support/RecordingOutput.swift`:
```swift
import AVFoundation
import Synchronization
@testable import TranslateCall

/// Wraps a real output and records what was scheduled: when the first buffer went out, the total
/// audio length and the digital silence at the end of the last buffer (integration tier only).
final class RecordingOutput: AudioOutputting, Sendable {
    private struct State {
        var firstScheduleAt: ContinuousClock.Instant?
        var scheduledSeconds: Double = 0
        var trailingSilenceSeconds: Double = 0
    }

    private let inner: any AudioOutputting
    private let state = Mutex(State())

    init(wrapping inner: any AudioOutputting) {
        self.inner = inner
    }

    var firstScheduleAt: ContinuousClock.Instant? { state.withLock { $0.firstScheduleAt } }
    var scheduledDuration: Duration { .seconds(state.withLock { $0.scheduledSeconds }) }
    var trailingSilence: Duration { .seconds(state.withLock { $0.trailingSilenceSeconds }) }

    func schedule(_ buffer: AVAudioPCMBuffer) throws -> PlaybackHandle {
        let handle = try inner.schedule(buffer)
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let silence = Self.trailingSilence(of: buffer)
        state.withLock { current in
            if current.firstScheduleAt == nil { current.firstScheduleAt = .now }
            current.scheduledSeconds += seconds
            current.trailingSilenceSeconds = silence
        }
        return handle
    }

    func stop() { inner.stop() }
    func shutdown() { inner.shutdown() }

    /// Seconds of near-zero samples (|x| < 1e-4) at the end of a Float32 buffer.
    private static func trailingSilence(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        var silent = 0
        var index = Int(buffer.frameLength) - 1
        while index >= 0, abs(samples[index]) < 1e-4 {
            silent += 1
            index -= 1
        }
        return Double(silent) / buffer.format.sampleRate
    }
}
```

In `TranslateCallTests/Support/BufferLog.swift`:
- replace `struct Entry { let at: ContinuousClock.Instant; let rms: Float }` with
```swift
    struct Entry { let at: ContinuousClock.Instant; let rms: Float; let duration: Duration }
```
- replace `self?.entries.append(Entry(at: .now, rms: MicTap.rms(buffer)))` with
```swift
                let duration = Duration.seconds(Double(buffer.frameLength) / buffer.format.sampleRate)
                self?.entries.append(Entry(at: .now, rms: MicTap.rms(buffer), duration: duration))
```
- insert before `/// Time between the last buffer before …`:
```swift
    /// First / last buffer at or after `start` louder than `threshold` dBFS.
    func firstEntry(since start: ContinuousClock.Instant, threshold: Float) -> Entry? {
        entries.first { $0.at >= start && $0.rms > threshold }
    }

    func lastEntry(since start: ContinuousClock.Instant, threshold: Float) -> Entry? {
        entries.last { $0.at >= start && $0.rms > threshold }
    }

```

`TranslateCallTests/Integration/TTSPlaybackIntegrationTests.swift`:
```swift
import AVFoundation
import CoreAudio
import Testing
@testable import TranslateCall

extension IntegrationTests {
    @Suite("TTS playback through BlackHole", .serialized) @MainActor
    struct TTSPlaybackIntegrationTests {
        private let sentence = "The quick brown fox jumps over the lazy dog, then rests in the warm afternoon sun."

        @Test("TTSOutput opens the default output, and refuses a device that does not exist")
        func outputDevices() throws {
            let output = try TTSOutput(deviceID: nil)
            output.shutdown()
            #expect(throws: STSError.deviceRoutingFailed) { _ = try TTSOutput(deviceID: AudioDeviceID(99_999)) }
        }

        @Test("AVSpeech through TTSPlaybackService into BlackHole: audio arrives, tail not cut, isSpeaking false within 150 ms (A12, NFR-T-02)")
        func avSpeechThroughBlackHole() async throws {
            try await requireMicrophoneAuthorization()
            try requirePrerequisite(AVSpeechUtteranceSynthesizer.hasVoice(for: english), "an English system voice")
            let manager = AudioManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
            let blackHole = try requireBlackHole(in: manager.inputDevices)
            try manager.selectInput(blackHole)
            let log = BufferLog(try await manager.startCapture())
            defer { log.cancel(); manager.stopCapture() }

            let output = RecordingOutput(wrapping: try TTSOutput(deviceID: blackHole.id))
            let service = TTSPlaybackService(primary: AVSpeechUtteranceSynthesizer(), output: output)
            let speaking = StreamRecorder(service.isSpeakingStream)
            let start = ContinuousClock.now
            await service.speak(text: sentence, locale: english)

            #expect(await waitUntil(timeout: .seconds(30)) { speaking.values == [true, false] },
                    "isSpeaking did not go true → false within 30 s")
            let falseAt = try #require(speaking.timed.last?.at)
            // BlackHole keeps delivering (silent) buffers: wait until capture has moved 300 ms past the end.
            #expect(await waitUntil(timeout: .seconds(2)) { (log.entries.last?.at ?? start) > falseAt + .milliseconds(300) })
            await service.deactivate()

            let first = try #require(log.firstEntry(since: start, threshold: -70), "no TTS audio reached BlackHole")
            let last = try #require(log.lastEntry(since: start, threshold: -70))
            let trailing = output.trailingSilence
            // The capture path (1024-frame tap, actor hop) delivers a buffer up to ~60 ms after it was played.
            #expect(falseAt >= last.at - .milliseconds(60),
                    "isSpeaking went false \(last.at - falseAt) before the last captured audio (NFR-T-02)")
            #expect(falseAt - last.at <= .milliseconds(150) + trailing,
                    "isSpeaking went false \(falseAt - last.at) after the last captured audio (NFR-T-02)")
            let heard = last.at - first.at + last.duration
            #expect(heard >= output.scheduledDuration * 0.8,
                    "heard \(heard) of \(output.scheduledDuration) scheduled: the tail was cut (A12)")
        }
    }
}
```

Run: `just test-integration`
Expected: the two `TTSPlaybackIntegrationTests` PASS with the existing integration suites. If `avSpeechThroughBlackHole` fails, do **not** loosen a bound: read the numbers in the message. A gap > 150 ms points at `TTSOutput`'s completion path; a "heard" span < 80 % points at the AVSpeech stream finishing early (if `didFinish` fires before the last buffers on this macOS, remove the `didFinish` path in `SpeechCompletionRouter` and keep the end marker and `didCancel`), then stop and report (design §6).

- [ ] **Step 8: Commit the integration test**

```bash
git add TranslateCallTests/Support/RecordingOutput.swift TranslateCallTests/Support/BufferLog.swift \
        TranslateCallTests/Integration/TTSPlaybackIntegrationTests.swift
git commit -m "test(integration): AVSpeech through TTSPlaybackService into BlackHole (A12, NFR-T-02)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `MLXInferenceGate`, gate-only model access, `QwenUtteranceSynthesizer`, preview through the gate (T6)

**Files:**
- Create: `TranslateCall/Core/VoiceCloning/MLXInferenceGate.swift`
- Create: `TranslateCall/Core/VoiceCloning/QwenUtteranceSynthesizer.swift`
- Modify (rewrite): `TranslateCall/Core/VoiceCloning/QwenCloneModelManager.swift`
- Modify: `TranslateCall/Core/VoiceCloning/QwenCloneConfiguration.swift` (`outputSampleRate`, `QwenCloneError`)
- Modify: `TranslateCall/Core/VoiceCloning/VoicePreviewService.swift:43-76,242,331`
- Modify: `TranslateCall/Core/TTS/TTSEngineSelector.swift:80` (`getInferrerSync` → `gatedInferrer`)
- Modify: `TranslateCall/Core/VoiceCloning/QwenCloneClient.swift:11-16` (doc comment)
- Test: `TranslateCallTests/MLXInferenceGateTests.swift`, `TranslateCallTests/QwenUtteranceSynthesizerTests.swift`, `TranslateCallTests/QwenCloneModelManagerTests.swift` (replace)

**Interfaces:**
- Consumes: `UtteranceStream`, `PCMBufferFactory`, `UtteranceText` (Task 1); `TestClock`, `AsyncGate`, `collect`, `english` (test support); `MockQwenCloneInferrer`, `MockVoiceProfileStore`.
- Produces:
  - `actor MLXInferenceGate { static let shared; init(clock: any Clock<Duration> = ContinuousClock()); func run<T: Sendable>(wait: Duration = .seconds(2), inference: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T; func waitUntilIdle() async; var isBusy: Bool; var waitingCount: Int }`
  - `QwenCloneError` becomes `nonisolated … LocalizedError, Sendable, Equatable` and gains `.gateBusy`; `QwenCloneConfiguration.outputSampleRate = 24_000`.
  - `QwenCloneModelManager`: `typealias ModelLoader = @Sendable (String) async throws -> any QwenCloneInferring`; `init(config:modelLoader:gate: MLXInferenceGate = .shared)`; `func synthesize(text:referenceAudio:referenceTranscript:language:) async throws -> [Float]`; `nonisolated func gatedInferrer() -> any QwenCloneInferring`; `func unload() async`. **Removed:** `getInferrer()`, `getInferrerSync()`, `cachedInferrer`.
  - `nonisolated struct GatedQwenInferrer: QwenCloneInferring`
  - `nonisolated final class QwenUtteranceSynthesizer: UtteranceSynthesizer { init(activeProfileId: UUID, profileStore: any VoiceProfileStoring, inferrer: any QwenCloneInferring, config: QwenCloneConfiguration = .default) }`

The gate (REQ-T-30/32): a caller waits at most `wait` for the gate (`.gateBusy`); the work runs in a **detached** task the gate owns (never on a caller's executor, never cancelled with the caller); past `inference` the caller gets `.inferenceTimeout` while the gate stays closed until MLX really returns, and that late result is discarded. Release hands the gate to the oldest waiter.

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/MLXInferenceGateTests.swift`:
```swift
import Foundation
import Synchronization
import Testing
@testable import TranslateCall

/// Counts how many gated "inferences" run at once.
private final class ConcurrencyProbe: Sendable {
    private let state = Mutex((running: 0, peak: 0, started: 0))

    var peak: Int { state.withLock { $0.peak } }
    var started: Int { state.withLock { $0.started } }

    func enter() {
        state.withLock { current in
            current.running += 1
            current.started += 1
            current.peak = max(current.peak, current.running)
        }
    }

    func leave() { state.withLock { $0.running -= 1 } }
}

@Suite("MLXInferenceGate")
struct MLXInferenceGateTests {

    @Test("at most one inference runs at a time; queued callers run in turn (REQ-T-30)")
    func oneAtATime() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let probe = ConcurrencyProbe()
        let release = AsyncGate()
        let calls = (0..<3).map { index in
            Task {
                try await gate.run(wait: .seconds(2), inference: .seconds(10)) {
                    probe.enter()
                    defer { probe.leave() }
                    await release.wait()
                    return index
                }
            }
        }
        #expect(await waitUntil { await gate.waitingCount == 2 && probe.started == 1 })
        release.open()
        var results: [Int] = []
        for call in calls { results.append(try await call.value) }
        #expect(results.sorted() == [0, 1, 2])
        #expect(probe.peak == 1)
        #expect(!(await gate.isBusy))
    }

    @Test("an inference past its limit returns .inferenceTimeout while the gate stays closed until MLX returns (REQ-T-32)")
    func timeoutKeepsGateClosed() async throws {
        let clock = TestClock()
        let gate = MLXInferenceGate(clock: clock)
        let probe = ConcurrencyProbe()
        let slow = AsyncGate()
        let first = Task {
            try await gate.run(wait: .seconds(2), inference: .seconds(10)) {
                probe.enter()
                defer { probe.leave() }
                await slow.wait()
                return 1
            }
        }
        #expect(await waitUntil { probe.started == 1 && clock.pendingDeadlines == [.seconds(10)] })
        clock.advance(by: .seconds(10))
        await #expect(throws: QwenCloneError.inferenceTimeout) { try await first.value }
        #expect(await gate.isBusy, "the gate opened while MLX was still running")

        let second = Task { try await gate.run(wait: .seconds(2), inference: .seconds(10)) { probe.enter(); probe.leave(); return 2 } }
        #expect(await waitUntil { await gate.waitingCount == 1 })
        #expect(probe.started == 1, "a second inference started on top of the first")

        slow.open()                                   // MLX finally returns; its result is discarded
        #expect(try await second.value == 2)
        #expect(probe.peak == 1)
    }

    @Test("a caller that waits past the wait limit gets .gateBusy and its work never runs (REQ-T-32)")
    func gateBusy() async throws {
        let clock = TestClock()
        let gate = MLXInferenceGate(clock: clock)
        let hold = AsyncGate()
        let ran = ConcurrencyProbe()
        let first = Task { try await gate.run(wait: .seconds(2), inference: .seconds(10)) { await hold.wait(); return 1 } }
        #expect(await waitUntil { clock.sleeperCount == 1 })            // the first inference's limit
        let second = Task { try await gate.run(wait: .seconds(2), inference: .seconds(10)) { ran.enter(); return 2 } }
        #expect(await waitUntil { await gate.waitingCount == 1 && clock.sleeperCount == 2 })

        clock.advance(by: .seconds(2))

        await #expect(throws: QwenCloneError.gateBusy) { try await second.value }
        #expect(ran.started == 0)
        hold.open()
        #expect(try await first.value == 1)
    }

    @Test("waitUntilIdle returns once the running inference is done")
    func waitUntilIdle() async throws {
        let gate = MLXInferenceGate(clock: TestClock())
        let hold = AsyncGate()
        let running = Task { try await gate.run(wait: .seconds(2), inference: .seconds(10)) { await hold.wait(); return 0 } }
        #expect(await waitUntil { await gate.isBusy })
        let idle = Task { await gate.waitUntilIdle() }
        hold.open()
        await idle.value
        _ = try await running.value
        #expect(!(await gate.isBusy))
    }
}
```

`TranslateCallTests/QwenUtteranceSynthesizerTests.swift`:
```swift
import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

@Suite("QwenUtteranceSynthesizer")
struct QwenUtteranceSynthesizerTests {
    private let profileId = UUID()

    private func profile(samples: [Float]? = Array(repeating: 0.5, count: 120_000)) -> VoiceProfile {
        let header = VoiceProfileHeader(
            id: profileId, name: "Test", createdAt: .now, durationSeconds: 5, sampleRate: 24_000,
            sampleCount: 120_000,
            quality: VoiceQualityMetrics(peakRmsDbfs: -20, hasClipping: false, voicedDurationSeconds: 5, grade: .good),
            formatVersion: 1
        )
        return VoiceProfile(header: header, samples: samples, transcript: "Hello world test")
    }

    private func make(_ inferrer: MockQwenCloneInferrer, store: MockVoiceProfileStore) -> QwenUtteranceSynthesizer {
        QwenUtteranceSynthesizer(activeProfileId: profileId, profileStore: store, inferrer: inferrer)
    }

    @Test("passes the profile's reference audio, transcript and language; yields one 24 kHz buffer")
    func synthesizesWithProfile() async throws {
        let inferrer = MockQwenCloneInferrer()
        let store = MockVoiceProfileStore()
        await store.forceStore(profile())
        let buffers = try #require(try await collect(make(inferrer, store: store)
            .synthesize(text: "Bonjour", locale: Locale(identifier: "fr-FR"))))

        #expect(buffers.count == 1)
        #expect(buffers.first?.format.sampleRate == 24_000)
        #expect(buffers.first?.frameLength == 2_400)
        #expect(await inferrer.lastText == "Bonjour")
        #expect(await inferrer.lastLanguage == "french")
        #expect(await inferrer.lastReferenceAudioCount == 120_000)
    }

    @Test("text longer than the limit is cut at a word boundary (REQ-T-04)")
    func truncates() async throws {
        let inferrer = MockQwenCloneInferrer()
        let store = MockVoiceProfileStore()
        await store.forceStore(profile())
        _ = try await collect(make(inferrer, store: store)
            .synthesize(text: String(repeating: "word ", count: 60), locale: english))
        let sent = try #require(await inferrer.lastText)
        #expect(sent.count <= 200)
        #expect(!sent.hasSuffix(" "))
    }

    @Test("an inference error fails the stream (so the playback service can fall back)")
    func inferenceErrorThrows() async {
        let inferrer = MockQwenCloneInferrer()
        await inferrer.setStubError(QwenCloneError.inferenceTimeout)
        let store = MockVoiceProfileStore()
        await store.forceStore(profile())
        await #expect(throws: QwenCloneError.inferenceTimeout) {
            _ = try await collect(make(inferrer, store: store).synthesize(text: "Hello", locale: english))
        }
    }

    @Test("a profile without audio fails with payloadMissing and never calls the model")
    func missingPayload() async {
        let inferrer = MockQwenCloneInferrer()
        let store = MockVoiceProfileStore()
        await store.forceStore(profile(samples: nil))
        await #expect(throws: VoiceProfileError.payloadMissing) {
            _ = try await collect(make(inferrer, store: store).synthesize(text: "Hello", locale: english))
        }
        #expect(await inferrer.callCount == 0)
    }

    @Test("supports the Qwen languages only")
    func canSpeak() {
        let synthesizer = make(MockQwenCloneInferrer(), store: MockVoiceProfileStore())
        #expect(synthesizer.canSpeak(Locale(identifier: "es-ES")))
        #expect(!synthesizer.canSpeak(Locale(identifier: "hi-IN")))
    }
}
```

Replace `TranslateCallTests/QwenCloneModelManagerTests.swift` with (the loader now returns any `QwenCloneInferring`, so the mock stands in for the model; `getInferrerThrowsWhenNotReady` becomes `synthesizeThrowsWhenNotReady`):
```swift
import Foundation
import Testing
@testable import TranslateCall

// MARK: - QwenCloneModelManagerTests

@Suite("QwenCloneModelManager")
@MainActor
struct QwenCloneModelManagerTests {

    private func makeManager(
        inferrer: MockQwenCloneInferrer? = nil,
        gate: MLXInferenceGate = MLXInferenceGate()
    ) -> QwenCloneModelManager {
        let loader: QwenCloneModelManager.ModelLoader = { _ in
            guard let inferrer else { throw QwenCloneError.downloadFailed("test error") }
            return inferrer
        }
        return QwenCloneModelManager(modelLoader: loader, gate: gate)
    }

    @Test("Initial state is idle")
    func initialStateIsIdle() async {
        let manager = makeManager()
        let state = await manager.state
        guard case .idle = state else {
            Issue.record("Expected .idle, got \(state)")
            return
        }
    }

    @Test("synthesize throws modelNotReady before the model is loaded")
    func synthesizeThrowsWhenNotReady() async {
        let manager = makeManager(inferrer: MockQwenCloneInferrer())
        await #expect(throws: QwenCloneError.modelNotReady) {
            _ = try await manager.synthesize(text: "Hi", referenceAudio: [0], referenceTranscript: "x", language: "english")
        }
    }

    @Test("synthesize runs the loaded inferrer through the gate; the gated inferrer forwards to it (REQ-T-31)")
    func synthesizeGoesThroughTheGate() async throws {
        let inferrer = MockQwenCloneInferrer()
        let manager = makeManager(inferrer: inferrer)
        try await manager.ensureReady()

        let gated = manager.gatedInferrer()
        let samples = try await gated.synthesize(text: "Hola", referenceAudio: [0.1], referenceTranscript: "x",
                                                 language: "spanish")

        #expect(!samples.isEmpty)
        #expect(await inferrer.callCount == 1)
        #expect(await inferrer.lastLanguage == "spanish")
        #expect(gated.sampleRate == 24_000)
    }

    @Test("unload transitions to idle; later synthesis fails fast")
    func unloadTransitionsToIdle() async throws {
        let manager = makeManager(inferrer: MockQwenCloneInferrer())
        try await manager.ensureReady()
        await manager.unload()
        let state = await manager.state
        guard case .idle = state else {
            Issue.record("Expected .idle after unload, got \(state)")
            return
        }
        await #expect(throws: QwenCloneError.modelNotReady) {
            _ = try await manager.synthesize(text: "Hi", referenceAudio: [0], referenceTranscript: "x", language: "english")
        }
    }

    @Test("isModelCached returns false for fresh install")
    func isModelCachedReturnsFalseForFreshInstall() async {
        let config = QwenCloneConfiguration(
            modelRepo: "test-nonexistent/model-that-does-not-exist-\(UUID().uuidString)"
        )
        let manager = QwenCloneModelManager(config: config, modelLoader: { _ in MockQwenCloneInferrer() })
        let cached = await manager.isModelCached()
        #expect(!cached)
    }

    @Test("stateStream emits transitions")
    func stateStreamEmitsTransitions() async {
        let manager = makeManager()
        var emitted: [String] = []

        let collectTask = Task {
            for await state in manager.stateStream {
                switch state {
                case .idle: emitted.append("idle")
                case .downloading: emitted.append("downloading")
                case .loading: emitted.append("loading")
                case .ready: emitted.append("ready")
                case .failed: emitted.append("failed")
                }
                if emitted.count >= 3 { break }
            }
        }

        _ = try? await manager.ensureReady()   // the loader throws: downloading → failed
        await manager.unload()

        await finish(collectTask)

        #expect(emitted.contains("downloading"))
        #expect(emitted.contains("idle"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-only MLXInferenceGateTests QwenUtteranceSynthesizerTests QwenCloneModelManagerTests`
Expected: build FAILS — `cannot find 'MLXInferenceGate' in scope`, `cannot find 'QwenUtteranceSynthesizer' in scope`.

- [ ] **Step 3: Implement the gate**

`TranslateCall/Core/VoiceCloning/MLXInferenceGate.swift`:
```swift
import Foundation
import Synchronization

// MARK: - MLXInferenceGate

/// Runs at most one Qwen3-TTS (MLX) inference at a time, process-wide, for session TTS and the voice
/// preview alike (F8.5.2 REQ-T-30/32, backlog T6: overlapping MLX inferences crash the process).
///
/// A caller waits at most `wait` for the gate (then `QwenCloneError.gateBusy`). The inference runs in a
/// task the gate owns, so cancelling the caller never cancels MLX mid-computation; if it takes longer
/// than `inference`, the caller gets `QwenCloneError.inferenceTimeout` while the gate stays closed until
/// the inference really returns. Its late result is discarded.
actor MLXInferenceGate {
    static let shared = MLXInferenceGate()

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let clock: any Clock<Duration>
    private var busy = false
    private var waiters: [Waiter] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextWaiterID: UInt64 = 0

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    var isBusy: Bool { busy }
    var waitingCount: Int { waiters.count }

    func run<T: Sendable>(
        wait: Duration = .seconds(2),
        inference: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(waitLimit: wait)
        let delivery = GateDelivery<T>()
        // Detached: the inference must not run on (or be cancelled with) any caller's executor.
        Task.detached { [weak self] in
            let result: Result<T, Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            delivery.deliver(result)       // ignored if the caller already timed out
            await self?.release()
        }
        let clock = self.clock
        let timer = Task.detached {
            do { try await clock.sleep(for: inference) } catch { return }
            delivery.deliver(.failure(QwenCloneError.inferenceTimeout))
        }
        defer { timer.cancel() }
        return try await delivery.value()
    }

    /// Returns once no inference is running (`QwenCloneModelManager.unload()` waits on this).
    func waitUntilIdle() async {
        guard busy else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: Private

    private func acquire(waitLimit: Duration) async throws {
        guard busy else {
            busy = true
            return
        }
        nextWaiterID &+= 1
        let id = nextWaiterID
        let clock = self.clock
        let timer = Task { [weak self] in
            do { try await clock.sleep(for: waitLimit) } catch { return }
            await self?.expireWaiter(id)
        }
        defer { timer.cancel() }
        // Resumed by `release()` (the gate is handed over, still busy) or by `expireWaiter` (gateBusy).
        try await withCheckedThrowingContinuation { waiters.append(Waiter(id: id, continuation: $0)) }
    }

    private func expireWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: QwenCloneError.gateBusy)
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
            let idle = idleWaiters
            idleWaiters.removeAll()
            idle.forEach { $0.resume() }
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}

// MARK: - GateDelivery

/// One-shot hand-off from the inference (or its timeout) to the waiting caller. The first delivery wins.
nonisolated final class GateDelivery<T: Sendable>: Sendable {
    private struct State {
        var result: Result<T, Error>?
        var waiter: CheckedContinuation<T, Error>?
        var isDelivered = false
    }

    private let state = Mutex(State())

    func deliver(_ result: Result<T, Error>) {
        let waiter: CheckedContinuation<T, Error>? = state.withLock { current in
            guard !current.isDelivered else { return nil }
            current.isDelivered = true
            if let waiting = current.waiter {
                current.waiter = nil
                return waiting
            }
            current.result = result
            return nil
        }
        waiter?.resume(with: result)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let ready: Result<T, Error>? = state.withLock { current in
                if let result = current.result {
                    current.result = nil
                    return result
                }
                current.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
```

- [ ] **Step 4: Configuration and error**

In `TranslateCall/Core/VoiceCloning/QwenCloneConfiguration.swift`, after `var textTruncationLimit: Int = 200` add:
```swift
    /// Qwen3-TTS (12 Hz codec) output rate, as `QwenCloneClient.sampleRate` reports it.
    var outputSampleRate: Int = 24_000
```
and replace the `QwenCloneError` enum with:
```swift
nonisolated enum QwenCloneError: LocalizedError, Sendable, Equatable {
    case modelNotReady
    case inferenceTimeout
    case downloadFailed(String)
    case unsupportedLocale
    /// Another Qwen inference held `MLXInferenceGate` longer than the wait limit (F8.5.2 REQ-T-32).
    case gateBusy

    var errorDescription: String? {
        switch self {
        case .modelNotReady: return "The voice clone model is not loaded."
        case .inferenceTimeout: return "Voice clone synthesis took too long."
        case .downloadFailed(let reason): return "Voice clone model download failed: \(reason)"
        case .unsupportedLocale: return "Voice clone does not support this language."
        case .gateBusy: return "The voice clone model is busy. Try again in a moment."
        }
    }
}
```

- [ ] **Step 5: Gate-only model manager (REQ-T-31)**

Replace `TranslateCall/Core/VoiceCloning/QwenCloneModelManager.swift` with:
```swift
import Foundation
import MLXAudioTTS
import OSLog

nonisolated private let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "QwenCloneModelManager"
)

// MARK: - QwenCloneModelManager

/// Actor singleton managing the Qwen3-TTS model lifecycle.
///
/// Mirrors `KokoroModelManager` pattern:
/// - State machine: .idle → .downloading → .loading → .ready / .failed
/// - Concurrent callers to `ensureReady()` share a single in-flight Task (coalescing)
/// - `modelLoader` is injectable for unit tests (no real model download needed)
///
/// The loaded client is private: inference is only reachable through `synthesize`, which goes through
/// `MLXInferenceGate`, so no two MLX inferences ever overlap (F8.5.2 REQ-T-31, backlog T6).
actor QwenCloneModelManager {

    // MARK: - State machine

    enum ModelState: Sendable {
        case idle
        case downloading
        case loading
        case ready
        case failed(String)
    }

    // MARK: - Singleton

    static let shared = QwenCloneModelManager()

    // MARK: - Internal state

    private(set) var state: ModelState = .idle
    private var loadTask: Task<Void, Error>?
    private var inferrer: (any QwenCloneInferring)?

    private let stateContinuation: AsyncStream<ModelState>.Continuation
    nonisolated let stateStream: AsyncStream<ModelState>

    // MARK: - Factory

    typealias ModelLoader = @Sendable (String) async throws -> any QwenCloneInferring

    nonisolated static let defaultLoader: ModelLoader = { modelRepo in
        let model = try await TTS.loadModel(modelRepo: modelRepo)
        return QwenCloneClient(model: model)
    }

    private let modelLoader: ModelLoader
    private let config: QwenCloneConfiguration
    private let gate: MLXInferenceGate

    // MARK: - Init

    init(
        config: QwenCloneConfiguration = .default,
        modelLoader: @escaping ModelLoader = QwenCloneModelManager.defaultLoader,
        gate: MLXInferenceGate = .shared
    ) {
        self.config = config
        self.modelLoader = modelLoader
        self.gate = gate
        (stateStream, stateContinuation) = AsyncStream.makeStream(
            of: ModelState.self, bufferingPolicy: .bufferingNewest(8)
        )
    }

    // MARK: - Public API

    /// Loads the model if not already ready. Concurrent callers share one in-flight task.
    func ensureReady() async throws {
        switch state {
        case .ready:
            return
        case .downloading, .loading:
            if let task = loadTask {
                try await task.value
                return
            }
            try await startSetup()
        case .idle, .failed:
            try await startSetup()
        }
    }

    /// One Qwen3-TTS inference, through the process-wide gate (REQ-T-30…32): waits at most 2 s for
    /// another inference, and gives up after `config.inferenceTimeoutSeconds` (the gate stays closed
    /// until MLX actually returns).
    func synthesize(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) async throws -> [Float] {
        guard case .ready = state, let inferrer else { throw QwenCloneError.modelNotReady }
        return try await gate.run(inference: .seconds(config.inferenceTimeoutSeconds)) {
            try await inferrer.synthesize(
                text: text,
                referenceAudio: referenceAudio,
                referenceTranscript: referenceTranscript,
                language: language
            )
        }
    }

    /// A `QwenCloneInferring` for `QwenUtteranceSynthesizer` and `VoicePreviewService` whose every
    /// call goes through `synthesize`, i.e. through the gate.
    nonisolated func gatedInferrer() -> any QwenCloneInferring {
        GatedQwenInferrer(manager: self, sampleRate: config.outputSampleRate)
    }

    /// Unloads the model. New inferences fail from the first line on; the client is released only
    /// once the gate is idle, never under a running MLX inference (design §6).
    func unload() async {
        loadTask?.cancel()
        loadTask = nil
        transition(to: .idle)
        await gate.waitUntilIdle()
        if case .idle = state { inferrer = nil }   // a reload during the wait keeps its new client
    }

    /// Checks whether the HuggingFace model cache directory exists.
    func isModelCached() -> Bool {
        let repoPath = config.modelRepo.replacingOccurrences(of: "/", with: "--")
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent("models--\(repoPath)")
        return FileManager.default.fileExists(atPath: cacheDir.path)
    }

    // MARK: - Private

    private func startSetup() async throws {
        transition(to: .downloading)
        let repo = config.modelRepo
        let loader = modelLoader

        let task = Task<Void, Error> {
            let client = try await loader(repo)
            self.inferrer = client
            self.transition(to: .ready)
        }
        loadTask = task
        do {
            try await task.value
        } catch {
            // If unload() was called (state already .idle), don't override with .failed
            if case .idle = state {
                logger.debug("Download cancelled by unload — staying idle")
            } else {
                transition(to: .failed(error.localizedDescription))
            }
            throw error
        }
    }

    private func transition(to newState: ModelState) {
        state = newState
        stateContinuation.yield(newState)
        logger.debug("QwenCloneModelManager → \(String(describing: newState))")
    }
}

// MARK: - GatedQwenInferrer

/// `QwenCloneInferring` over `QwenCloneModelManager.synthesize` (and so over `MLXInferenceGate`).
nonisolated struct GatedQwenInferrer: QwenCloneInferring {
    let manager: QwenCloneModelManager
    let sampleRate: Int

    func synthesize(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) async throws -> [Float] {
        try await manager.synthesize(
            text: text,
            referenceAudio: referenceAudio,
            referenceTranscript: referenceTranscript,
            language: language
        )
    }
}
```

- [ ] **Step 6: The synthesizer**

`TranslateCall/Core/VoiceCloning/QwenUtteranceSynthesizer.swift`:
```swift
import AVFoundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "QwenUtteranceSynthesizer")

// MARK: - QwenUtteranceSynthesizer

/// Qwen3-TTS voice clone (F8.5.2 REQ-T-02/04): the active profile's reference audio and transcript plus
/// the text (cut at `config.textTruncationLimit`) give one buffer at the inferrer's sample rate.
/// Production injects `QwenCloneModelManager.gatedInferrer()`, so inference goes through the gate.
nonisolated final class QwenUtteranceSynthesizer: UtteranceSynthesizer {
    let engine: TTSEngine = .voiceClone
    private let activeProfileId: UUID
    private let profileStore: any VoiceProfileStoring
    private let inferrer: any QwenCloneInferring
    private let config: QwenCloneConfiguration

    init(
        activeProfileId: UUID,
        profileStore: any VoiceProfileStoring,
        inferrer: any QwenCloneInferring,
        config: QwenCloneConfiguration = .default
    ) {
        self.activeProfileId = activeProfileId
        self.profileStore = profileStore
        self.inferrer = inferrer
        self.config = config
    }

    func canSpeak(_ locale: Locale) -> Bool {
        QwenCloneConfiguration.supportsLocale(locale)
    }

    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let (stream, continuation) = UtteranceStream.make()
        let input = UtteranceText.truncated(text, limit: config.textTruncationLimit)
        if input.count < text.count {
            logger.warning("Voice clone text truncated from \(text.count) to \(input.count) characters")
        }
        let language = QwenCloneConfiguration.language(for: locale) ?? "english"
        let producer = Task { [activeProfileId, profileStore, inferrer] in
            do {
                let profile = try await profileStore.load(id: activeProfileId)
                guard let samples = profile.samples, let transcript = profile.transcript else {
                    throw VoiceProfileError.payloadMissing
                }
                let audio = try await inferrer.synthesize(
                    text: input, referenceAudio: samples, referenceTranscript: transcript, language: language
                )
                try Task.checkCancellation()
                if let buffer = PCMBufferFactory.mono(audio, sampleRate: Double(inferrer.sampleRate)) {
                    continuation.yield(buffer)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in producer.cancel() }
        return stream
    }
}
```

- [ ] **Step 7: Move the remaining callers to the gate**

`TranslateCall/Core/TTS/TTSEngineSelector.swift` line 80 (inside `voiceCloneFactory`; the legacy `QwenCloneSpeechService` now also goes through the gate until Task 8 deletes it):
```swift
        let inferrer = QwenCloneModelManager.shared.gatedInferrer()
```
`TranslateCall/Core/VoiceCloning/VoicePreviewService.swift`:
- replace the audio-engine block (lines 43-46) with (both types are `Sendable` in this SDK, so `nonisolated(unsafe)` is unnecessary):
```swift
    // MARK: - Audio engine (the preview's own player: system default output, never BlackHole)

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
```
- extend the doc comment of `typealias InferrerProvider` with a second line:
```swift
    /// The default goes through `MLXInferenceGate`, shared with session TTS (F8.5.2 REQ-T-30, T6).
```
- in the default `inferrerProvider` closure replace `return try await QwenCloneModelManager.shared.getInferrer()` with `return QwenCloneModelManager.shared.gatedInferrer()`
- replace the four `var cont …`/`cont!` lines of `init` (and the blank lines around them) with:
```swift
        (stateStream, stateContinuation) = AsyncStream.makeStream(
            of: PreviewState.self, bufferingPolicy: .bufferingNewest(8)
        )
```
- directly above `nonisolated(unsafe) var retainedSynthesizer` add `// SAFETY: only the write callback touches it, and AVSpeech calls that callback serially.`
- directly above `nonisolated(unsafe) var inputConsumed` add `// SAFETY: the converter calls this input block synchronously, on this thread, within convert().`

`TranslateCall/Core/VoiceCloning/QwenCloneClient.swift`, end of the type comment: replace "by the caller serializing access through `QwenCloneSpeechService` (which is an actor)." with "by `QwenCloneModelManager`, which keeps the client private and runs every inference through `MLXInferenceGate` (one at a time, process-wide)."

- [ ] **Step 8: Run the tests to verify they pass**

Run: `just test-only MLXInferenceGateTests QwenUtteranceSynthesizerTests QwenCloneModelManagerTests VoicePreviewServiceTests QwenCloneSpeechServiceTests`
Expected: PASS (4 + 5 + 6 + 6 + 8 tests). No test loads the real model (every loader/inferrer is a mock). Then `just lint` → exit 0.

- [ ] **Step 9: Commit**

```bash
git add TranslateCall/Core/VoiceCloning TranslateCall/Core/TTS/TTSEngineSelector.swift \
        TranslateCallTests/MLXInferenceGateTests.swift TranslateCallTests/QwenUtteranceSynthesizerTests.swift \
        TranslateCallTests/QwenCloneModelManagerTests.swift
git commit -m "fix(voice-clone): one MLX inference at a time through MLXInferenceGate (F8.5.2, T6)

REQ-T-30…32: session TTS and the voice preview share a process-wide gate; a timeout returns to the
caller while the gate stays closed until MLX returns. QwenCloneModelManager no longer hands out the
raw client (getInferrer/getInferrerSync removed). QwenUtteranceSynthesizer added.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `KokoroUtteranceSynthesizer`

**Files:**
- Create: `TranslateCall/Core/TTS/KokoroUtteranceSynthesizer.swift`
- Modify: `TranslateCall/Core/TTS/KokoroConfiguration.swift:6` (`nonisolated`)
- Test: `TranslateCallTests/KokoroUtteranceSynthesizerTests.swift`

**Interfaces:**
- Consumes: `UtteranceStream`, `PCMBufferFactory`, `UtteranceText` (Task 1); `KokoroModelManager(managerFactory:)`, `.ensureReady(config:)`, `KokoroTtsManaging.synthesizeSamples(text:voice:)`; `MockKokoroTtsManager`, `AsyncGate`, `collect`, `english`.
- Produces: `nonisolated final class KokoroUtteranceSynthesizer: UtteranceSynthesizer { static let truncationLimit = 500; static let sampleRate: Double = 24_000; init(configuration: KokoroConfiguration = .default, modelManager: KokoroModelManager = .shared) }`

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/KokoroUtteranceSynthesizerTests.swift`:
```swift
import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

@Suite("KokoroUtteranceSynthesizer")
struct KokoroUtteranceSynthesizerTests {

    /// A synthesizer over a mock Kokoro model; `loading` (if given) holds the model load open.
    private func make(_ mock: MockKokoroTtsManager, loading: AsyncGate? = nil) -> KokoroUtteranceSynthesizer {
        let manager = KokoroModelManager(managerFactory: { _ in
            if let loading { await loading.wait() }
            return mock
        })
        return KokoroUtteranceSynthesizer(modelManager: manager)
    }

    @Test("yields one 24 kHz mono buffer holding the model's samples")
    func yieldsSamples() async throws {
        let mock = MockKokoroTtsManager()
        await mock.stubResult([0.1, 0.2, 0.3, 0.4])
        let buffers = try #require(try await collect(make(mock).synthesize(text: "Hello", locale: english)))
        #expect(buffers.count == 1)
        #expect(buffers.first?.format.sampleRate == 24_000)
        #expect(buffers.first?.format.channelCount == 1)
        #expect(buffers.first?.frameLength == 4)
    }

    @Test("text over 500 characters is cut at a word boundary; exactly 500 is kept (REQ-T-04)")
    func truncation() async throws {
        let mock = MockKokoroTtsManager()
        let synthesizer = make(mock)
        _ = try await collect(synthesizer.synthesize(text: String(repeating: "hello ", count: 92), locale: english))
        _ = try await collect(synthesizer.synthesize(text: String(repeating: "a", count: 500), locale: english))
        let received = await mock.receivedTexts
        #expect(received.count == 2)
        #expect(received[0].count <= 500)
        #expect(!received[0].hasSuffix(" "))
        #expect(received[1].count == 500)
    }

    @Test("no samples from the model: the stream finishes with no buffers")
    func emptySamples() async throws {
        let mock = MockKokoroTtsManager()
        await mock.stubResult([])
        let buffers = try await collect(make(mock).synthesize(text: "Hello", locale: english))
        #expect(buffers?.isEmpty == true)
    }

    @Test("a model error fails the stream, so the playback service can fall back")
    func modelErrorThrows() async {
        let mock = MockKokoroTtsManager()
        await mock.stubError(FakeSynthError.boom)
        await #expect(throws: FakeSynthError.boom) {
            _ = try await collect(make(mock).synthesize(text: "Hi", locale: english))
        }
    }

    @Test("stopped while the model loads: the sentence is never synthesized (A9)")
    func cancelledWhileLoading() async {
        let mock = MockKokoroTtsManager()
        let loading = AsyncGate()
        let stream = make(mock, loading: loading).synthesize(text: "stale", locale: english)
        let consumer = Task { for try await _ in stream {} }
        #expect(await waitUntil { loading.waiterCount == 1 })

        consumer.cancel()                         // what TTSPlaybackService does on stopSpeaking
        _ = await consumer.result
        loading.open()

        // Bounded wait for something that must not happen.
        #expect(!(await waitUntil(timeout: .milliseconds(300)) { await mock.callCount > 0 }))
    }

    @Test("English only")
    func englishOnly() {
        let synthesizer = make(MockKokoroTtsManager())
        #expect(synthesizer.canSpeak(Locale(identifier: "en-GB")))
        #expect(!synthesizer.canSpeak(Locale(identifier: "fr-FR")))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-only KokoroUtteranceSynthesizerTests`
Expected: build FAILS — `cannot find 'KokoroUtteranceSynthesizer' in scope`.

- [ ] **Step 3: Implement**

`TranslateCall/Core/TTS/KokoroConfiguration.swift` line 6: `nonisolated struct KokoroConfiguration: Sendable {` (read from the nonisolated synthesizer).

`TranslateCall/Core/TTS/KokoroUtteranceSynthesizer.swift`:
```swift
import AVFoundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "KokoroUtteranceSynthesizer")

// MARK: - KokoroUtteranceSynthesizer

/// Kokoro (FluidAudio CoreML, English only) as an `UtteranceSynthesizer` (F8.5.2 REQ-T-02/04): the text,
/// cut at 500 characters on a word boundary, gives one 24 kHz mono buffer.
nonisolated final class KokoroUtteranceSynthesizer: UtteranceSynthesizer {
    static let truncationLimit = 500
    static let sampleRate: Double = 24_000

    let engine: TTSEngine = .kokoro
    private let configuration: KokoroConfiguration
    private let modelManager: KokoroModelManager

    init(configuration: KokoroConfiguration = .default, modelManager: KokoroModelManager = .shared) {
        self.configuration = configuration
        self.modelManager = modelManager
    }

    func canSpeak(_ locale: Locale) -> Bool {
        locale.isEnglish
    }

    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let (stream, continuation) = UtteranceStream.make()
        let input = UtteranceText.truncated(text, limit: Self.truncationLimit)
        if input.count < text.count {
            logger.warning("Kokoro text truncated from \(text.count) to \(input.count) characters")
        }
        let voice = configuration.voiceIdentifier.isEmpty ? nil : configuration.voiceIdentifier
        let producer = Task { [modelManager, configuration] in
            do {
                let manager = try await modelManager.ensureReady(config: configuration)
                try Task.checkCancellation()   // stopped while the model loaded: never synthesize (A9)
                let samples = try await manager.synthesizeSamples(text: input, voice: voice)
                try Task.checkCancellation()
                if let buffer = PCMBufferFactory.mono(samples, sampleRate: Self.sampleRate) {
                    continuation.yield(buffer)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in producer.cancel() }
        return stream
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `just test-only KokoroUtteranceSynthesizerTests KokoroModelManagerTests KokoroSpeechServiceTests`
Expected: PASS (6 + existing). No CoreML model is loaded (the factory returns the mock). Then `just lint` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/TTS/KokoroUtteranceSynthesizer.swift TranslateCall/Core/TTS/KokoroConfiguration.swift \
        TranslateCallTests/KokoroUtteranceSynthesizerTests.swift
git commit -m "feat(tts): Kokoro as an UtteranceSynthesizer (F8.5.2)

REQ-T-02/04: 500-character word-boundary truncation kept; a sentence stopped while the model
loads is never synthesized (A9).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Edge — `EdgeTransport`, event-driven `EdgeTTSWebSocket`, `EdgeUtteranceSynthesizer` (A3, A3b–e, A11)

**Files:**
- Create: `TranslateCall/Core/TTS/EdgeTransport.swift` (`EdgeSocketEvent`, `EdgeTransport`, `StarscreamTransport`)
- Replace: `TranslateCall/Core/TTS/EdgeTTSWebSocket.swift`
- Modify: `TranslateCall/Core/TTS/EdgeTTSHelpers.swift:78-95` (`EdgeTTSError`)
- Create: `TranslateCall/Core/TTS/EdgeMP3Decoder.swift`, `TranslateCall/Core/TTS/EdgeUtteranceSynthesizer.swift`
- Delete: `TranslateCall/Core/TTS/EdgeTTSService.swift` (its `isPlaying` poll is A3; it does not compile against the new socket)
- Modify: `TranslateCall/Core/TTS/TTSEngineSelector.swift:133-195` (the four Edge branches)
- Create: `TranslateCallTests/Fixtures/MP3/hello-24k-mono.mp3`, `TranslateCallTests/Support/FakeEdgeTransport.swift`
- Test: `TranslateCallTests/EdgeTTSWebSocketTests.swift`, `TranslateCallTests/EdgeUtteranceSynthesizerTests.swift`, `TranslateCallTests/Integration/EdgeTTSIntegrationTests.swift`

**Interfaces:**
- Consumes: `UtteranceStream`, `PCMBufferFactory` (Task 1); `TTSPlaybackService`, `AVSpeechUtteranceSynthesizer`, `TTSOutput` (Tasks 2–4); `EdgeTTSVoiceCatalog`, `EdgeTTSMessageBuilder`, `EdgeTTSDRM`, `EdgeTTSConstants`; `TestClock`, `FakeSynthesizer`, `FakeOutput`, `StreamRecorder`, `collect`, `english`.
- Produces:
  - `nonisolated enum EdgeSocketEvent: Sendable, Equatable { case connected, text(String), binary(Data), disconnected(String), cancelled, peerClosed, error(String); static let bufferLimit = 1_024; var isClosing: Bool }`
  - `nonisolated protocol EdgeTransport: AnyObject, Sendable { func connect(request: URLRequest) -> AsyncStream<EdgeSocketEvent>; func write(string: String); func disconnect() }`; `StarscreamTransport`
  - `nonisolated struct EdgeTimeouts: Sendable { connect 5 s; firstChunk 5 s; utterance 20 s }`
  - `actor EdgeTTSWebSocket { init(transport: any EdgeTransport = StarscreamTransport(), timeouts: EdgeTimeouts = .default, clock: any Clock<Duration> = ContinuousClock()); var isConnected: Bool; func connect() async throws; nonisolated func synthesize(text: String, voice: String) -> AsyncThrowingStream<Data, Error>; func disconnect(); nonisolated static func extractAudioData(from: Data) -> Data? }`
  - `nonisolated enum EdgeTTSError: LocalizedError, Equatable { invalidURL, notConnected, connectTimeout, firstChunkTimeout, synthesisTimeout, connectionClosed, connectionFailed(String), emptyAudio, decodeFailed(OSStatus) }` (`handshakeRejected` was unused and goes)
  - `nonisolated enum EdgeMP3Decoder { static func decode(_ mp3: Data) throws -> AVAudioPCMBuffer }`
  - `nonisolated final class EdgeUtteranceSynthesizer: UtteranceSynthesizer { init(socket: EdgeTTSWebSocket = EdgeTTSWebSocket()); func shutdown() async }`
  - Test support: `FakeEdgeTransport(onConnect:onSSML:)` (`written`, `ssmlCount`, `connectCount`, `disconnectCount`, `push(_:)`, `static audioFrame(_:)`, `static turnEnd`), `edgeMP3FixtureURL()`, `edgeMP3Fixture()`

The socket in one paragraph (REQ-T-24…27): `connect()` opens a transport connection and starts a pump task that, for each event, first updates the state (`.connected` sets `isConnected`; a closing event clears it and discards the inbox) and then forwards it to the inbox the reader iterates; the end of the stream also clears `isConnected`. `connect` waits for `.connected` under the 5 s limit, then sends `speech.config`. `synthesize` sends the SSML and reads the inbox: phase 1 until the first audio chunk (5 s), phase 2 until `turn.end`, all within 20 s; any failure or cancellation disconnects, so the next utterance starts on a fresh connection. One utterance at a time is guaranteed by the playback worker.

- [ ] **Step 1: Generate the MP3 fixture (Edge's format: 24 kHz mono 48 kbit/s, no ID3/Xing)**

```bash
mkdir -p TranslateCallTests/Fixtures/MP3 build
say -v Samantha -o build/edge-hello.aiff "Hello, this is a test."
ffmpeg -loglevel error -y -i build/edge-hello.aiff -ar 24000 -ac 1 -codec:a libmp3lame -b:a 48k \
  -map_metadata -1 -id3v2_version 0 -write_xing 0 -f mp3 TranslateCallTests/Fixtures/MP3/hello-24k-mono.mp3
afinfo TranslateCallTests/Fixtures/MP3/hello-24k-mono.mp3 | grep -E "Data format|estimated duration"
```
Expected: `1 ch, 24000 Hz, .mp3 …` and an estimated duration of about 1.7 s (≈ 10 KB file).

- [ ] **Step 2: Write the fake transport and the failing tests**

`TranslateCallTests/Support/FakeEdgeTransport.swift`:
```swift
import Foundation
import Synchronization
@testable import TranslateCall

/// Scripted `EdgeTransport` (design §5.1): no network. After each `connect` it pushes the next list of
/// `onConnect` events, after each SSML write the next list of `onSSML` events (the last list repeats).
/// Tests can also `push` events themselves. Closing events end the connection, as Starscream does.
final class FakeEdgeTransport: EdgeTransport, Sendable {
    private struct State {
        var continuation: AsyncStream<EdgeSocketEvent>.Continuation?
        var written: [String] = []
        var connectCount = 0
        var disconnectCount = 0
        var onConnect: [[EdgeSocketEvent]]
        var onSSML: [[EdgeSocketEvent]]
    }

    private let state: Mutex<State>

    init(onConnect: [[EdgeSocketEvent]] = [[.connected]], onSSML: [[EdgeSocketEvent]] = []) {
        state = Mutex(State(onConnect: onConnect, onSSML: onSSML))
    }

    var written: [String] { state.withLock { $0.written } }
    var ssmlCount: Int { written.filter { $0.contains("Path:ssml") }.count }
    var connectCount: Int { state.withLock { $0.connectCount } }
    var disconnectCount: Int { state.withLock { $0.disconnectCount } }

    func connect(request: URLRequest) -> AsyncStream<EdgeSocketEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: EdgeSocketEvent.self, bufferingPolicy: .unbounded)
        let events: [EdgeSocketEvent] = state.withLock { current in
            current.continuation?.finish()
            current.continuation = continuation
            current.connectCount += 1
            return Self.next(&current.onConnect)
        }
        events.forEach(push)
        return stream
    }

    func write(string: String) {
        let events: [EdgeSocketEvent] = state.withLock { current in
            current.written.append(string)
            return string.contains("Path:ssml") ? Self.next(&current.onSSML) : []
        }
        events.forEach(push)
    }

    func disconnect() {
        let continuation: AsyncStream<EdgeSocketEvent>.Continuation? = state.withLock { current in
            current.disconnectCount += 1
            defer { current.continuation = nil }
            return current.continuation
        }
        continuation?.finish()
    }

    /// Delivers `event` on the current connection; a closing event also ends the connection.
    func push(_ event: EdgeSocketEvent) {
        let continuation: AsyncStream<EdgeSocketEvent>.Continuation? = state.withLock { current in
            defer { if event.isClosing { current.continuation = nil } }
            return current.continuation
        }
        continuation?.yield(event)
        if event.isClosing { continuation?.finish() }
    }

    /// An Edge binary audio frame: 2-byte header length, header, MP3 bytes.
    static func audioFrame(_ audio: Data) -> Data {
        let header = Data("X-RequestId:test\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n".utf8)
        var frame = Data([UInt8(header.count >> 8), UInt8(header.count & 0xFF)])
        frame.append(header)
        frame.append(audio)
        return frame
    }

    static let turnEnd = EdgeSocketEvent.text("X-RequestId:test\r\nPath:turn.end\r\n\r\n{}")

    private static func next(_ queue: inout [[EdgeSocketEvent]]) -> [EdgeSocketEvent] {
        guard let first = queue.first else { return [] }
        if queue.count > 1 { queue.removeFirst() }
        return first
    }
}

/// The committed MP3 fixture (24 kHz mono, 48 kbit/s like Edge's `audio-24khz-48kbitrate-mono-mp3`).
func edgeMP3FixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)            // …/TranslateCallTests/Support/FakeEdgeTransport.swift
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/MP3/hello-24k-mono.mp3")
}

func edgeMP3Fixture() throws -> Data {
    try Data(contentsOf: edgeMP3FixtureURL())
}
```

`TranslateCallTests/EdgeTTSWebSocketTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

@Suite("EdgeTTSWebSocket")
struct EdgeTTSWebSocketTests {
    private let audio = Data([0x01, 0x02, 0x03])

    private func socket(_ transport: FakeEdgeTransport, clock: TestClock = TestClock()) -> EdgeTTSWebSocket {
        EdgeTTSWebSocket(transport: transport, clock: clock)
    }

    @Test("connect waits for .connected, then sends speech.config")
    func connectSendsConfig() async throws {
        let transport = FakeEdgeTransport()
        let ws = socket(transport)
        try await ws.connect()
        #expect(await ws.isConnected)
        #expect(transport.written.first?.contains("Path:speech.config") == true)
    }

    @Test("a closing event while idle clears isConnected (REQ-T-24, A3b)",
          arguments: [EdgeSocketEvent.peerClosed, .cancelled, .disconnected("bye (1000)"), .error("reset")])
    func closingEventDisconnects(_ event: EdgeSocketEvent) async throws {
        let transport = FakeEdgeTransport()
        let ws = socket(transport)
        try await ws.connect()
        transport.push(event)
        #expect(await waitUntil { await !ws.isConnected })
    }

    @Test("synthesize yields the audio chunks in order and finishes on turn.end")
    func streamsChunks() async throws {
        let transport = FakeEdgeTransport(onSSML: [[
            .text("Path:turn.start"),
            .binary(FakeEdgeTransport.audioFrame(Data([1]))),
            .binary(FakeEdgeTransport.audioFrame(Data([2, 3]))),
            FakeEdgeTransport.turnEnd
        ]])
        let ws = socket(transport)
        try await ws.connect()
        var chunks: [Data] = []
        for try await chunk in ws.synthesize(text: "Hi", voice: "en-US-JennyNeural") { chunks.append(chunk) }
        #expect(chunks == [Data([1]), Data([2, 3])])
        #expect(await ws.isConnected)
        #expect(transport.ssmlCount == 1)
    }

    @Test("a close before turn.end throws connectionClosed and leaves the socket disconnected")
    func closeBeforeTurnEnd() async throws {
        let transport = FakeEdgeTransport(onSSML: [[.binary(FakeEdgeTransport.audioFrame(audio)), .peerClosed]])
        let ws = socket(transport)
        try await ws.connect()
        await #expect(throws: EdgeTTSError.connectionClosed) {
            for try await _ in ws.synthesize(text: "Hi", voice: "en-US-JennyNeural") {}
        }
        #expect(await !ws.isConnected)
    }

    @Test("synthesize without a connection throws notConnected")
    func notConnected() async {
        let ws = socket(FakeEdgeTransport())
        await #expect(throws: EdgeTTSError.notConnected) {
            for try await _ in ws.synthesize(text: "Hi", voice: "en-US-JennyNeural") {}
        }
    }

    @Test("connect gives up after 5 s (REQ-T-25, A3c)")
    func connectTimeout() async {
        let clock = TestClock()
        let transport = FakeEdgeTransport(onConnect: [[]])          // the server never answers
        let ws = socket(transport, clock: clock)
        let connecting = Task { try await ws.connect() }
        #expect(await waitUntil { clock.pendingDeadlines == [.seconds(5)] })
        clock.advance(by: .seconds(5))
        await #expect(throws: EdgeTTSError.connectTimeout) { try await connecting.value }
        #expect(await !ws.isConnected)
    }

    @Test("no first audio chunk within 5 s of the SSML throws firstChunkTimeout (REQ-T-25)")
    func firstChunkTimeout() async throws {
        let clock = TestClock()
        let ws = socket(FakeEdgeTransport(), clock: clock)
        try await ws.connect()
        let turn = Task { for try await _ in ws.synthesize(text: "Hi", voice: "en-US-JennyNeural") {} }
        #expect(await waitUntil { clock.pendingDeadlines == [.seconds(5), .seconds(20)] })
        clock.advance(by: .seconds(5))
        await #expect(throws: EdgeTTSError.firstChunkTimeout) { try await turn.value }
    }

    @Test("audio that never reaches turn.end is cut at 20 s (REQ-T-25)")
    func utteranceTimeout() async throws {
        let clock = TestClock()
        let transport = FakeEdgeTransport(onSSML: [[.binary(FakeEdgeTransport.audioFrame(audio))]])
        let ws = socket(transport, clock: clock)
        try await ws.connect()
        let turn = Task { for try await _ in ws.synthesize(text: "Hi", voice: "en-US-JennyNeural") {} }
        #expect(await waitUntil { clock.pendingDeadlines == [.seconds(20)] })   // the first chunk arrived
        clock.advance(by: .seconds(20))
        await #expect(throws: EdgeTTSError.synthesisTimeout) { try await turn.value }
    }

    @Test("extractAudioData skips the header and rejects frames without audio")
    func extractAudioData() {
        #expect(EdgeTTSWebSocket.extractAudioData(from: FakeEdgeTransport.audioFrame(Data([9, 8]))) == Data([9, 8]))
        #expect(EdgeTTSWebSocket.extractAudioData(from: Data([0, 1])) == nil)            // too short
        #expect(EdgeTTSWebSocket.extractAudioData(from: Data([0, 5, 1, 2])) == nil)      // header longer than data
        #expect(EdgeTTSWebSocket.extractAudioData(from: FakeEdgeTransport.audioFrame(Data())) == nil)
    }

    @Test("disconnect closes the transport and clears isConnected")
    func disconnect() async throws {
        let transport = FakeEdgeTransport()
        let ws = socket(transport)
        try await ws.connect()
        let before = transport.disconnectCount
        await ws.disconnect()
        #expect(await !ws.isConnected)
        #expect(transport.disconnectCount == before + 1)
    }
}
```

`TranslateCallTests/EdgeUtteranceSynthesizerTests.swift`:
```swift
import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

@Suite("EdgeUtteranceSynthesizer")
struct EdgeUtteranceSynthesizerTests {

    /// The fixture split into three Edge audio frames, then turn.end.
    private func reply() throws -> [EdgeSocketEvent] {
        let mp3 = try edgeMP3Fixture()
        let third = mp3.count / 3
        let parts = [mp3.prefix(third), mp3.dropFirst(third).prefix(third), mp3.dropFirst(2 * third)]
        return parts.map { .binary(FakeEdgeTransport.audioFrame(Data($0))) } + [FakeEdgeTransport.turnEnd]
    }

    private func synthesizer(_ transport: FakeEdgeTransport, clock: TestClock = TestClock()) -> EdgeUtteranceSynthesizer {
        EdgeUtteranceSynthesizer(socket: EdgeTTSWebSocket(transport: transport, clock: clock))
    }

    @Test("the MP3 chunks of one turn are decoded in memory into one 24 kHz mono buffer (REQ-T-05)")
    func decodesTurn() async throws {
        let transport = FakeEdgeTransport(onSSML: [try reply()])
        let buffers = try #require(try await collect(synthesizer(transport).synthesize(text: "Hello", locale: english)))
        let pcm = try #require(buffers.first)
        #expect(buffers.count == 1)
        #expect(pcm.format.sampleRate == 24_000)
        #expect(pcm.format.channelCount == 1)
        let expected = try AVAudioFile(forReading: edgeMP3FixtureURL()).length   // file-based decode
        #expect(abs(Int64(pcm.frameLength) - expected) <= expected / 20)
    }

    @Test("a connection that died while idle is re-established once, transparently (REQ-T-26)")
    func reconnectsOnce() async throws {
        let transport = FakeEdgeTransport(onSSML: [[.peerClosed], try reply()])
        let buffers = try await collect(synthesizer(transport).synthesize(text: "Hello", locale: english))
        #expect(buffers?.count == 1)
        #expect(transport.connectCount == 2)
    }

    @Test("a second failure in a row throws (REQ-T-26)")
    func secondFailureThrows() async {
        let transport = FakeEdgeTransport(onSSML: [[.peerClosed]])
        await #expect(throws: EdgeTTSError.connectionClosed) {
            _ = try await collect(synthesizer(transport).synthesize(text: "Hello", locale: english))
        }
        #expect(transport.connectCount == 2)
    }

    @Test("a failure after audio arrived is not retried")
    func failureAfterAudioNotRetried() async throws {
        let first = try #require(try reply().first)
        let transport = FakeEdgeTransport(onSSML: [[first, .peerClosed]])
        await #expect(throws: EdgeTTSError.connectionClosed) {
            _ = try await collect(synthesizer(transport).synthesize(text: "Hello", locale: english))
        }
        #expect(transport.connectCount == 1)
    }

    @Test("a timeout is not retried, so the fallback can speak within 5 s (design §4)")
    func timeoutNotRetried() async {
        let clock = TestClock()
        let transport = FakeEdgeTransport(onSSML: [[]])
        let stream = synthesizer(transport, clock: clock).synthesize(text: "Hello", locale: english)
        let consumer = Task { try await collect(stream) }
        #expect(await waitUntil { clock.pendingDeadlines == [.seconds(5), .seconds(20)] })
        clock.advance(by: .seconds(5))
        await #expect(throws: EdgeTTSError.firstChunkTimeout) { _ = try await consumer.value }
        #expect(transport.connectCount == 1)
    }

    @Test("Review focus: turn.end with no audio is a failure, so the playback service falls back (not silence, A3b)")
    func emptyTurnFallsBack() async {
        let transport = FakeEdgeTransport(onSSML: [[FakeEdgeTransport.turnEnd]])
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let service = TTSPlaybackService(primary: synthesizer(transport), fallback: fallback,
                                         output: FakeOutput(autoComplete: true), clock: TestClock())
        let events = StreamRecorder(service.events)
        await service.speak(text: "Hello", locale: english)
        #expect(await waitUntil { events.values == [.fellBack(from: .edgeTTS, to: .avSpeech)] })
        #expect(await waitUntil { fallback.texts == ["Hello"] })
        await service.deactivate()
    }

    @Test("shutdown (TTSPlaybackService.deactivate) disconnects the socket")
    func shutdownDisconnects() async throws {
        let transport = FakeEdgeTransport(onSSML: [try reply()])
        let edge = synthesizer(transport)
        _ = try await collect(edge.synthesize(text: "Hello", locale: english))
        let before = transport.disconnectCount
        await edge.shutdown()
        #expect(transport.disconnectCount == before + 1)
    }

    @Test("bytes that are not MP3 fail to decode; no bytes is emptyAudio")
    func decoderRejectsGarbage() {
        #expect(throws: EdgeTTSError.self) { _ = try EdgeMP3Decoder.decode(Data([1, 2, 3, 4, 5])) }
        #expect(throws: EdgeTTSError.emptyAudio) { _ = try EdgeMP3Decoder.decode(Data()) }
    }

    @Test("speaks the catalog's locales only")
    func canSpeak() {
        let edge = synthesizer(FakeEdgeTransport())
        #expect(edge.canSpeak(Locale(identifier: "uk-UA")))
        #expect(!edge.canSpeak(Locale(identifier: "xx-XX")))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `just test-only EdgeTTSWebSocketTests EdgeUtteranceSynthesizerTests`
Expected: build FAILS — `cannot find type 'EdgeTransport' in scope`, `cannot find 'EdgeUtteranceSynthesizer' in scope`.

- [ ] **Step 4: Transport, socket, error, decoder, synthesizer**

`TranslateCall/Core/TTS/EdgeTransport.swift`:
```swift
import Foundation
import OSLog
import Starscream

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "EdgeTransport")

// MARK: - EdgeSocketEvent

/// What one Edge TTS WebSocket connection reports (a Sendable mirror of Starscream's events).
nonisolated enum EdgeSocketEvent: Sendable, Equatable {
    case connected
    case text(String)
    case binary(Data)
    case disconnected(String)
    case cancelled
    case peerClosed
    case error(String)

    /// Bound of every per-connection event stream. One utterance is a few dozen frames.
    static let bufferLimit = 1_024

    /// The connection is over after this event (REQ-T-24).
    var isClosing: Bool {
        switch self {
        case .disconnected, .cancelled, .peerClosed, .error: return true
        case .connected, .text, .binary: return false
        }
    }
}

// MARK: - EdgeTransport

/// The socket under `EdgeTTSWebSocket` (REQ-T-27): Starscream in production, `FakeEdgeTransport` in tests.
nonisolated protocol EdgeTransport: AnyObject, Sendable {
    /// Opens a new connection (closing any previous one) and returns its events. The stream finishes
    /// after a closing event, or when `disconnect()` is called.
    func connect(request: URLRequest) -> AsyncStream<EdgeSocketEvent>
    func write(string: String)
    func disconnect()
}

// MARK: - StarscreamTransport

/// Starscream lets us set `Origin`, which Apple's WebSocket APIs filter out.
///
/// `@unchecked Sendable`: `socket` and `bridge` are only touched under `lock`.
nonisolated final class StarscreamTransport: EdgeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var socket: WebSocket?
    private var bridge: StarscreamBridge?
    private let callbackQueue = DispatchQueue(label: "com.spbarber.TranslateCall.EdgeTTS.socket")

    func connect(request: URLRequest) -> AsyncStream<EdgeSocketEvent> {
        let (events, continuation) = AsyncStream.makeStream(
            of: EdgeSocketEvent.self, bufferingPolicy: .bufferingNewest(EdgeSocketEvent.bufferLimit)
        )
        let bridge = StarscreamBridge(continuation: continuation)
        let socket = WebSocket(request: request)
        socket.callbackQueue = callbackQueue
        socket.delegate = bridge          // weak in Starscream: `self.bridge` keeps it alive
        let previous = lock.withLock { () -> (WebSocket?, StarscreamBridge?) in
            defer {
                self.socket = socket
                self.bridge = bridge
            }
            return (self.socket, self.bridge)
        }
        previous.0?.disconnect()
        previous.1?.finish()
        socket.connect()
        return events
    }

    func write(string: String) {
        lock.withLock { socket }?.write(string: string)
    }

    func disconnect() {
        let current = lock.withLock { () -> (WebSocket?, StarscreamBridge?) in
            defer {
                socket = nil
                bridge = nil
            }
            return (socket, bridge)
        }
        current.0?.disconnect()
        current.1?.finish()
    }
}

/// Bridges Starscream's delegate callbacks into one connection's event stream.
///
/// `@unchecked Sendable`: it only holds the continuation, which is thread-safe.
nonisolated private final class StarscreamBridge: WebSocketDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<EdgeSocketEvent>.Continuation

    init(continuation: AsyncStream<EdgeSocketEvent>.Continuation) {
        self.continuation = continuation
    }

    func finish() {
        continuation.finish()
    }

    func didReceive(event: WebSocketEvent, client: any WebSocketClient) {
        switch event {
        case .connected:
            continuation.yield(.connected)
        case .disconnected(let reason, let code):
            logger.info("Edge TTS socket disconnected: \(reason, privacy: .public) (\(code))")
            end(with: .disconnected("\(reason) (\(code))"))
        case .text(let text):
            continuation.yield(.text(text))
        case .binary(let data):
            continuation.yield(.binary(data))
        case .cancelled:
            end(with: .cancelled)
        case .peerClosed:
            end(with: .peerClosed)
        case .error(let error):
            let message = error.map { String(describing: $0) } ?? "unknown error"
            logger.error("Edge TTS socket error: \(message, privacy: .public)")
            end(with: .error(message))
        case .ping, .pong, .viabilityChanged, .reconnectSuggested:
            break   // Starscream answers pings; reconnecting is EdgeUtteranceSynthesizer's job
        }
    }

    private func end(with event: EdgeSocketEvent) {
        continuation.yield(event)
        continuation.finish()
    }
}
```

Replace `TranslateCall/Core/TTS/EdgeTTSWebSocket.swift` with:
```swift
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "EdgeTTSWebSocket")

// MARK: - EdgeTimeouts

/// Edge TTS time limits (REQ-T-25), injectable for tests.
nonisolated struct EdgeTimeouts: Sendable {
    var connect: Duration = .seconds(5)
    /// From sending the SSML to the first audio chunk.
    var firstChunk: Duration = .seconds(5)
    /// From sending the SSML to `turn.end`.
    var utterance: Duration = .seconds(20)

    static let `default` = EdgeTimeouts()
}

// MARK: - EdgeTTSWebSocket

/// One Edge TTS connection (F8.5.2 REQ-T-24…27). `isConnected` follows the socket's own events: a
/// closing event, or the end of the connection's event stream, clears it and discards the stream.
/// One utterance at a time is guaranteed by the playback worker.
actor EdgeTTSWebSocket {
    private let transport: any EdgeTransport
    private let timeouts: EdgeTimeouts
    private let clock: any Clock<Duration>

    private(set) var isConnected = false
    /// Bumped by every connect/disconnect, so events of an older connection are ignored.
    private var connectionID: UInt64 = 0
    private var inbox: AsyncStream<EdgeSocketEvent>?
    private var pump: Task<Void, Never>?

    init(
        transport: any EdgeTransport = StarscreamTransport(),
        timeouts: EdgeTimeouts = .default,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.transport = transport
        self.timeouts = timeouts
        self.clock = clock
    }

    // MARK: Connect

    /// Connects unless already connected, then sends the speech config. Throws after `timeouts.connect`.
    func connect() async throws {
        if isConnected { return }
        let request = try Self.makeRequest()
        disconnect()
        let id = connectionID
        let events = transport.connect(request: request)
        let (inbox, inboxContinuation) = AsyncStream.makeStream(
            of: EdgeSocketEvent.self, bufferingPolicy: .bufferingNewest(EdgeSocketEvent.bufferLimit)
        )
        self.inbox = inbox
        // The pump updates the connection state before the reader sees each event (REQ-T-24).
        pump = Task { [weak self] in
            for await event in events {
                await self?.observe(event, connection: id)
                inboxContinuation.yield(event)
            }
            inboxContinuation.finish()
            await self?.connectionEnded(id)
        }
        do {
            try await Self.withTimeout(timeouts.connect, clock: clock, error: EdgeTTSError.connectTimeout) {
                try await Self.awaitConnected(inbox)
            }
        } catch {
            if id == connectionID { disconnect() }
            throw error
        }
        guard id == connectionID, isConnected else { throw EdgeTTSError.connectionClosed }
        transport.write(string: EdgeTTSMessageBuilder.configMessage())
        logger.debug("Edge TTS connected")
    }

    // MARK: Synthesize

    /// Sends the SSML and streams the MP3 chunks; finishes on `turn.end`, throws on a close, an
    /// error or a timeout before it (REQ-T-24/25).
    nonisolated func synthesize(text: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: Data.self, throwing: Error.self, bufferingPolicy: .bufferingNewest(EdgeSocketEvent.bufferLimit)
        )
        let turn = Task { await self.run(text: text, voice: voice, into: continuation) }
        continuation.onTermination = { _ in turn.cancel() }
        return stream
    }

    // MARK: Disconnect

    func disconnect() {
        connectionID &+= 1
        isConnected = false
        inbox = nil
        pump?.cancel()
        pump = nil
        transport.disconnect()
    }

    // MARK: Private

    private func run(text: String, voice: String, into output: AsyncThrowingStream<Data, Error>.Continuation) async {
        guard isConnected, let inbox else {
            output.finish(throwing: EdgeTTSError.notConnected)
            return
        }
        let id = connectionID
        transport.write(string: EdgeTTSMessageBuilder.ssml(text: text, voice: voice, rate: 0, pitch: 0, volume: 0))
        let timeouts = self.timeouts
        let clock = self.clock
        do {
            try await Self.withTimeout(timeouts.utterance, clock: clock, error: EdgeTTSError.synthesisTimeout) {
                try await Self.receive(inbox, timeouts: timeouts, clock: clock, into: output)
            }
            output.finish()
        } catch {
            if id == connectionID { disconnect() }   // state unknown after a failed or abandoned turn
            output.finish(throwing: error)
        }
    }

    private func observe(_ event: EdgeSocketEvent, connection id: UInt64) {
        guard id == connectionID else { return }
        if event == .connected { isConnected = true }
        if event.isClosing {
            isConnected = false
            inbox = nil
        }
    }

    private func connectionEnded(_ id: UInt64) {
        guard id == connectionID else { return }
        isConnected = false
        inbox = nil
    }

    private static func makeRequest() throws -> URLRequest {
        let connectionToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let path = EdgeTTSConstants.path
            + "?TrustedClientToken=\(EdgeTTSConstants.trustedClientToken)"
            + "&ConnectionId=\(connectionToken)"
            + "&Sec-MS-GEC=\(EdgeTTSDRM.generateSecMsGec())"
            + "&Sec-MS-GEC-Version=\(EdgeTTSConstants.secMsGecVersion)"
        guard let url = URL(string: "wss://\(EdgeTTSConstants.host)\(path)") else { throw EdgeTTSError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(EdgeTTSConstants.origin, forHTTPHeaderField: "Origin")
        request.setValue(EdgeTTSConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }

    // MARK: Event reading (static: runs in the timeout's child tasks)

    private static func awaitConnected(_ events: AsyncStream<EdgeSocketEvent>) async throws {
        for await event in events {
            switch event {
            case .connected: return
            case .error(let message): throw EdgeTTSError.connectionFailed(message)
            case .disconnected, .cancelled, .peerClosed: throw EdgeTTSError.connectionClosed
            case .text, .binary: continue
            }
        }
        throw EdgeTTSError.connectionClosed
    }

    /// Phase 1 until the first audio chunk (`timeouts.firstChunk`), phase 2 until `turn.end`.
    private static func receive(
        _ events: AsyncStream<EdgeSocketEvent>,
        timeouts: EdgeTimeouts,
        clock: any Clock<Duration>,
        into output: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        let ended = try await withTimeout(timeouts.firstChunk, clock: clock, error: EdgeTTSError.firstChunkTimeout) {
            try await readAudio(events, into: output, untilFirstChunk: true)
        }
        if !ended { _ = try await readAudio(events, into: output, untilFirstChunk: false) }
    }

    /// Yields audio chunks; returns true at `turn.end`, or false right after the first chunk when asked.
    private static func readAudio(
        _ events: AsyncStream<EdgeSocketEvent>,
        into output: AsyncThrowingStream<Data, Error>.Continuation,
        untilFirstChunk: Bool
    ) async throws -> Bool {
        for await event in events {
            switch event {
            case .binary(let frame):
                guard let audio = extractAudioData(from: frame) else { continue }
                output.yield(audio)
                if untilFirstChunk { return false }
            case .text(let message):
                if message.contains("Path:turn.end") { return true }
            case .error(let message):
                throw EdgeTTSError.connectionFailed(message)
            case .disconnected, .cancelled, .peerClosed:
                throw EdgeTTSError.connectionClosed
            case .connected:
                continue
            }
        }
        throw EdgeTTSError.connectionClosed   // the connection's stream ended (or this read was cancelled)
    }

    /// Runs `operation`; if `limit` passes first, cancels it and throws `timeoutError`.
    private static func withTimeout<T: Sendable>(
        _ limit: Duration,
        clock: any Clock<Duration>,
        error timeoutError: EdgeTTSError,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(for: limit)
                throw timeoutError
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw timeoutError }
            return first
        }
    }

    /// Edge binary frames: 2-byte big-endian header length, the header, then MP3 bytes.
    nonisolated static func extractAudioData(from data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let headerLength = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        let audioStart = data.startIndex + 2 + headerLength
        guard audioStart < data.endIndex else { return nil }
        return data.subdata(in: audioStart..<data.endIndex)
    }
}
```

In `TranslateCall/Core/TTS/EdgeTTSHelpers.swift`, replace the `EdgeTTSError` enum with:
```swift
nonisolated enum EdgeTTSError: LocalizedError, Equatable {
    case invalidURL
    case notConnected
    case connectTimeout
    case firstChunkTimeout
    case synthesisTimeout
    case connectionClosed
    case connectionFailed(String)
    case emptyAudio
    case decodeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Edge TTS endpoint URL."
        case .notConnected: return "Edge TTS not connected."
        case .connectTimeout: return "Edge TTS did not connect in time."
        case .firstChunkTimeout: return "Edge TTS sent no audio in time."
        case .synthesisTimeout: return "Edge TTS synthesis timed out."
        case .connectionClosed: return "The Edge TTS connection closed."
        case .connectionFailed(let reason): return "The Edge TTS connection failed: \(reason)"
        case .emptyAudio: return "Edge TTS returned no audio."
        case .decodeFailed(let status): return "Edge TTS audio could not be decoded (\(status))."
        }
    }
}
```

`TranslateCall/Core/TTS/EdgeMP3Decoder.swift`:
```swift
import AudioToolbox
import AVFoundation

// MARK: - EdgeMP3Decoder

/// Decodes a complete MP3 byte stream to one mono Float32 buffer, in memory (REQ-T-05): AudioFile reads
/// through callbacks over the `Data` and ExtAudioFile converts to PCM. No temporary file.
nonisolated enum EdgeMP3Decoder {
    private static let chunkFrames: AVAudioFrameCount = 4_096

    static func decode(_ mp3: Data) throws -> AVAudioPCMBuffer {
        guard !mp3.isEmpty else { throw EdgeTTSError.emptyAudio }
        let source = Unmanaged.passRetained(MP3Bytes(mp3))
        defer { source.release() }
        let read: AudioFile_ReadProc = { client, position, requestCount, buffer, actualCount in
            let bytes = Unmanaged<MP3Bytes>.fromOpaque(client).takeUnretainedValue().data
            let start = Int(position)
            guard start < bytes.count else {
                actualCount.pointee = 0
                return noErr
            }
            let count = min(Int(requestCount), bytes.count - start)
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                buffer.copyMemory(from: base.advanced(by: start), byteCount: count)
            }
            actualCount.pointee = UInt32(count)
            return noErr
        }
        let size: AudioFile_GetSizeProc = { client in
            Int64(Unmanaged<MP3Bytes>.fromOpaque(client).takeUnretainedValue().data.count)
        }
        var fileID: AudioFileID?
        var status = AudioFileOpenWithCallbacks(source.toOpaque(), read, nil, size, nil, kAudioFileMP3Type, &fileID)
        guard status == noErr, let fileID else { throw EdgeTTSError.decodeFailed(status) }
        defer { AudioFileClose(fileID) }
        var file: ExtAudioFileRef?
        status = ExtAudioFileWrapAudioFileID(fileID, false, &file)
        guard status == noErr, let file else { throw EdgeTTSError.decodeFailed(status) }
        defer { ExtAudioFileDispose(file) }
        return try readAll(file, as: try clientFormat(of: file))
    }

    /// Mono Float32 at the MP3's own rate (Edge: 24 kHz), set as the ExtAudioFile client format.
    private static func clientFormat(of file: ExtAudioFileRef) throws -> AVAudioFormat {
        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat)
        guard status == noErr, fileFormat.mSampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fileFormat.mSampleRate,
                                         channels: 1, interleaved: false)
        else { throw EdgeTTSError.decodeFailed(status) }
        var client = format.streamDescription.pointee
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, size, &client)
        guard status == noErr else { throw EdgeTTSError.decodeFailed(status) }
        return format
    }

    private static func readAll(_ file: ExtAudioFileRef, as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        var samples: [Float] = []
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
                  let channel = chunk.floatChannelData?[0]
            else { throw EdgeTTSError.decodeFailed(kAudioFileUnspecifiedError) }
            chunk.frameLength = chunkFrames   // the buffer list must advertise the full capacity
            var frames = UInt32(chunkFrames)
            let status = ExtAudioFileRead(file, &frames, chunk.mutableAudioBufferList)
            guard status == noErr else { throw EdgeTTSError.decodeFailed(status) }
            if frames == 0 { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(frames)))
        }
        guard let pcm = PCMBufferFactory.mono(samples, sampleRate: format.sampleRate) else {
            throw EdgeTTSError.emptyAudio
        }
        return pcm
    }
}

/// The MP3 bytes the AudioFile callbacks read from.
nonisolated private final class MP3Bytes {
    let data: Data

    init(_ data: Data) {
        self.data = data
    }
}
```

`TranslateCall/Core/TTS/EdgeUtteranceSynthesizer.swift`:
```swift
import AVFoundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "EdgeUtteranceSynthesizer")

// MARK: - EdgeUtteranceSynthesizer

/// Microsoft Edge neural voices (cloud) as an `UtteranceSynthesizer` (F8.5.2 REQ-T-02/05/26). The MP3
/// is collected until `turn.end` and decoded once, in memory. A connection found dead, or lost before
/// any audio, is re-established once; timeouts are not retried, so the fallback speaks within 5 s.
nonisolated final class EdgeUtteranceSynthesizer: UtteranceSynthesizer {
    let engine: TTSEngine = .edgeTTS
    private let socket: EdgeTTSWebSocket

    init(socket: EdgeTTSWebSocket = EdgeTTSWebSocket()) {
        self.socket = socket
    }

    func canSpeak(_ locale: Locale) -> Bool {
        EdgeTTSVoiceCatalog.defaultVoice(for: locale) != nil
    }

    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let (stream, continuation) = UtteranceStream.make()
        guard let voice = EdgeTTSVoiceCatalog.defaultVoice(for: locale)?.shortName else {
            continuation.finish(throwing: STSError.voiceUnavailable(locale))
            return stream
        }
        let producer = Task { [socket] in
            do {
                let mp3 = try await Self.fetchAudio(socket: socket, text: text, voice: voice)
                let pcm = try EdgeMP3Decoder.decode(mp3)
                try Task.checkCancellation()
                continuation.yield(pcm)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in producer.cancel() }
        return stream
    }

    func shutdown() async {
        await socket.disconnect()
    }

    /// The whole MP3 of one utterance, reconnecting once if the connection was lost before any audio.
    static func fetchAudio(socket: EdgeTTSWebSocket, text: String, voice: String) async throws -> Data {
        do {
            return try await attempt(socket: socket, text: text, voice: voice)
        } catch let failure as EdgeAttemptFailure {
            guard failure.isRetryable else { throw failure.error }
            try Task.checkCancellation()
            logger.info("Edge TTS: reconnecting once after \(failure.error.localizedDescription, privacy: .public)")
            await socket.disconnect()
            do {
                return try await attempt(socket: socket, text: text, voice: voice)
            } catch let second as EdgeAttemptFailure {
                throw second.error
            }
        }
    }

    private static func attempt(socket: EdgeTTSWebSocket, text: String, voice: String) async throws -> Data {
        do {
            try await socket.connect()
        } catch {
            throw EdgeAttemptFailure(error: error, beforeAudio: true)
        }
        var audio = Data()
        do {
            for try await chunk in socket.synthesize(text: text, voice: voice) { audio.append(chunk) }
        } catch {
            throw EdgeAttemptFailure(error: error, beforeAudio: audio.isEmpty)
        }
        guard !audio.isEmpty else { throw EdgeTTSError.emptyAudio }
        return audio
    }
}

/// One failed Edge turn, and whether reconnecting may fix it (REQ-T-26).
nonisolated struct EdgeAttemptFailure: Error {
    let error: Error
    let beforeAudio: Bool

    /// Only a connection lost before any audio is retried; a timeout means the network is slow or
    /// down, and retrying would only delay the fallback.
    var isRetryable: Bool {
        guard beforeAudio, let edgeError = error as? EdgeTTSError else { return false }
        switch edgeError {
        case .connectionClosed, .connectionFailed, .notConnected: return true
        default: return false
        }
    }
}
```

- [ ] **Step 5: Delete `EdgeTTSService` and route Edge through the playback service**

```bash
git rm TranslateCall/Core/TTS/EdgeTTSService.swift
```
In `TranslateCall/Core/TTS/TTSEngineSelector.swift`, the two "explicitly selected" branches (in `makeOutgoingService` and `makeIncomingService`) become:
```swift
        if preferredEngine == .edgeTTS, EdgeTTSVoiceCatalog.supports(locale) {
            return try makeEdgeService(for: locale, deviceID: deviceID)
        }
```
the two consent branches become:
```swift
        if EdgeTTSConsentManager.consentGiven, EdgeTTSVoiceCatalog.supports(locale) {
            return try makeEdgeService(for: locale, deviceID: deviceID)
        }
```
and add, before `// MARK: - For testing`:
```swift
    /// Edge TTS through the playback service, with the system voice as fallback when there is one
    /// (F8.5.2 Task 7; Task 8 builds every engine this way).
    private func makeEdgeService(for locale: Locale, deviceID: AudioDeviceID?) throws -> any SynthesisService {
        let fallback: (any UtteranceSynthesizer)? = hasSystemVoice(locale) ? AVSpeechUtteranceSynthesizer() : nil
        return TTSPlaybackService(primary: EdgeUtteranceSynthesizer(), fallback: fallback,
                                  output: try TTSOutput(deviceID: deviceID))
    }
```

- [ ] **Step 6: Run the unit tests to verify they pass**

Run: `just test-only EdgeTTSWebSocketTests EdgeUtteranceSynthesizerTests TTSEngineSelectorEdgeTTSTests EdgeTTSXMLEscapingTests EdgeTTSVoiceCatalogTests`
Expected: PASS (10 + 9 + 3 + 1 + 6 tests). No network: every socket here is a `FakeEdgeTransport`. Then `just lint` → exit 0.

- [ ] **Step 7: Integration test against the real service**

`TranslateCallTests/Integration/EdgeTTSIntegrationTests.swift`:
```swift
import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

extension IntegrationTests {
    @Suite("Edge TTS (network)", .serialized)
    struct EdgeTTSIntegrationTests {

        /// Any HTTP answer from the Edge host means the network path is there.
        private func requireEdgeNetwork() async throws {
            var request = URLRequest(url: URL(string: "https://\(EdgeTTSConstants.host)/")!, timeoutInterval: 5)
            request.httpMethod = "HEAD"
            let reachable = (try? await URLSession.shared.data(for: request)) != nil
            try requirePrerequisite(reachable, "network access to Edge TTS (speech.platform.bing.com)")
        }

        @Test("Edge \"hello\" (en-US) yields PCM within 10 s (A11)")
        func hello() async throws {
            try await requireEdgeNetwork()
            let edge = EdgeUtteranceSynthesizer()
            defer { Task { await edge.shutdown() } }
            let buffers = try #require(try await collect(edge.synthesize(text: "hello", locale: english),
                                                         within: .seconds(10)),
                                       "no audio from Edge within 10 s")
            #expect(buffers.reduce(0) { $0 + Int($1.frameLength) } > 0)
        }
    }
}
```

Run: `just test-integration`
Expected: `EdgeTTSIntegrationTests.hello` PASS (verified while planning: "hello" decodes to ≈ 1.9 s of 24 kHz PCM in ≈ 0.6 s, and a second sentence on the same socket works). With the network off it FAILS with "Missing prerequisite: network access to Edge TTS (speech.platform.bing.com)".

- [ ] **Step 8: Commit**

```bash
git add TranslateCall/Core/TTS TranslateCallTests/Fixtures/MP3/hello-24k-mono.mp3 \
        TranslateCallTests/Support/FakeEdgeTransport.swift TranslateCallTests/EdgeTTSWebSocketTests.swift \
        TranslateCallTests/EdgeUtteranceSynthesizerTests.swift TranslateCallTests/Integration/EdgeTTSIntegrationTests.swift
git commit -m "fix(tts): Edge TTS on a testable transport with real connection state and timeouts (F8.5.2)

A3: no isPlaying poll (EdgeTTSService deleted; Edge plays through TTSPlaybackService).
A3b: isConnected follows the socket's closing events. A3c: connect 5 s, first chunk 5 s,
utterance 20 s. A3d/A3e: one turn at a time, cancellation disconnects. A11: EdgeTransport fake,
socket and synthesizer suites, network integration test. MP3 decoded in memory (REQ-T-05).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Every engine through `TTSPlaybackService`; delete the legacy services; migrate their tests (REQ-T-10, T-22, T-42)

**Files:**
- Modify (rewrite): `TranslateCall/Core/TTS/TTSEngineSelector.swift`
- Delete: `TranslateCall/Core/TTS/AVSpeechService.swift`, `TranslateCall/Core/TTS/KokoroSpeechService.swift`, `TranslateCall/Core/VoiceCloning/QwenCloneSpeechService.swift`
- Modify: `TranslateCall/Core/Setup/RouteTestService.swift:38-57`, `TranslateCall/Features/Main/AudioViewModel.swift:243`, `TranslateCall/Core/TTS/KokoroTtsManaging.swift:8`
- Delete: `TranslateCallTests/KokoroSpeechServiceTests.swift`, `TranslateCallTests/QwenCloneSpeechServiceTests.swift`
- Modify: `TranslateCallTests/TTSServiceTests.swift` (drop the two AVSpeechService suites), `TranslateCallTests/EdgeTTSTests.swift`, `TranslateCallTests/TTSEngineSelectorVoiceCloneTests.swift`
- Replace: `TranslateCallTests/TTSEngineSelectorTests.swift`
- Modify: `TranslateCallTests/Integration/TTSFixtureTests.swift:11-12`, `TranslateCallTests/Integration/OutgoingPipelineFixtureTests.swift:29-35`

**Interfaces:**
- Consumes: `TTSPlaybackService` (`primaryEngine`, `fallbackEngine`), the four synthesizers, `TTSOutput`, `QwenCloneModelManager.gatedInferrer()`; `FakeSynthesizer`, `FakeOutput`, `RecordingOutput`.
- Produces (`TTSEngineSelector`, all `var`, injectable): `hasSystemVoice: (Locale) -> Bool`, `outputFactory: (AudioDeviceID?) throws -> any AudioOutputting`, `avSpeechFactory: () -> any UtteranceSynthesizer`, `kokoroFactory: (KokoroConfiguration) -> any UtteranceSynthesizer`, `voiceCloneFactory: (UUID, any VoiceProfileStoring) -> any UtteranceSynthesizer`, `edgeFactory: () -> any UtteranceSynthesizer`; `makeOutgoingService(for:deviceID:) throws -> TTSPlaybackService`, `makeIncomingService(for:deviceID:) throws -> TTSPlaybackService`. Priority logic unchanged; fallback = AVSpeech when the primary is not AVSpeech and the locale has a system voice (REQ-T-22).

Test migration (put this table in the commit body; 28 legacy tests go, each behaviour keeps a pinning test):

| Deleted test | Now pinned by |
|---|---|
| `AVSpeechServiceRoutingTests.initWithNilDeviceIDSucceeds`, `.initWithBadDeviceIDThrows` | `TTSPlaybackIntegrationTests.outputDevices` (opens a device: integration tier, NFR-T-03) |
| `AVSpeechServiceTests.speakEmitsIsSpeakingTrue`, `.speakingStreamEmitsTrue` | `TTSPlaybackServiceTests.truthfulSpeaking`, `AVSpeechUtteranceSynthesizerTests.yieldsAndFinishes` |
| `AVSpeechServiceTests.stopSpeakingClearsQueue`, `.queuedUtterancesPlayWithoutCrash`, `.deactivateStopsSynthesis` | `TTSPlaybackServiceTests.stopIsImmediate`, `.fifoOneAtATime`, `.deactivate` |
| `AVSpeechServiceTests.voiceSelectionPrefersEnhancedForEnglish` | `AVSpeechUtteranceSynthesizerTests.englishVoice` |
| `AVSpeechServiceTests.voiceUnavailableDoesNotCrash` | `AVSpeechUtteranceSynthesizerTests.unknownLocale`, `TTSPlaybackServiceTests.noVoice` |
| `AVSpeechServiceHasVoiceTests.hasVoiceForEnglish`, `.hasVoiceMatchesInstalledVoices` | `AVSpeechUtteranceSynthesizerTests.englishVoice`, `.hasVoiceMatchesInstalled` |
| `KokoroSpeechServiceTests.initSucceeds`, `.isSpeakingStreamAccessible`, `.deactivateWithoutSpeak` | `TTSPlaybackServiceTests.deactivate` (no engine in a synthesizer any more) |
| `KokoroSpeechServiceTests.speakAppendsToPending`, `.stopSpeakingClearsPending`, `.stopSpeakingEmitsFalse` | `TTSPlaybackServiceTests.capDropsOldest`, `.stopIsImmediate` |
| `KokoroSpeechServiceTests.speakIgnoresWhitespace` | `TTSPlaybackServiceTests.blankIgnored` |
| `KokoroSpeechServiceTests.longTextTruncatedAtWordBoundary`, `.exactlyFiveHundredCharsNotTruncated` | `KokoroUtteranceSynthesizerTests.truncation`, `UtteranceHelpersTests.truncation` |
| `QwenCloneSpeechServiceTests.speakCallsInferrerWithProfileContext`, `.languagePassedToInferrer` | `QwenUtteranceSynthesizerTests.synthesizesWithProfile` |
| `QwenCloneSpeechServiceTests.textTruncatedAt200Chars` | `QwenUtteranceSynthesizerTests.truncates` |
| `QwenCloneSpeechServiceTests.emptyTextIgnored`, `.stopClearsQueue` | `TTSPlaybackServiceTests.blankIgnored`, `.stopIsImmediate` |
| `QwenCloneSpeechServiceTests.inferenceErrorContinuesQueue`, `.inferenceTimeoutRecovery` | `QwenUtteranceSynthesizerTests.inferenceErrorThrows`, `TTSPlaybackFallbackTests.fallsBackBeforeAudio`, `MLXInferenceGateTests.timeoutKeepsGateClosed` |
| `QwenCloneSpeechServiceTests.conformsToSynthesisServiceProtocol` | compile-time: `TTSEngineSelector` returns `TTSPlaybackService` where `any SynthesisService` is expected |

- [ ] **Step 1: Rewrite the selector tests against the new factories (failing)**

Replace `TranslateCallTests/TTSEngineSelectorTests.swift` with:
```swift
import CoreAudio
import Foundation
import Testing
@testable import TranslateCall

// MARK: - TTSEngineSelectorTests

/// Tests for `TTSEngineSelector`.
///
/// All tests inject fake synthesizers, a fake output and a fresh `UserDefaults` suite, so they are
/// hermetic: no audio device, no model, no installed-voice dependency.
@Suite("TTSEngineSelector")
@MainActor
struct TTSEngineSelectorTests {

    // MARK: - Helpers

    static let suiteName = "TTSEngineSelectorTests"

    func freshDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: TTSEngineSelectorTests.suiteName)!
        suite.removePersistentDomain(forName: TTSEngineSelectorTests.suiteName)
        return suite
    }

    func makeSelector(defaults: UserDefaults? = nil, systemVoice: @escaping (Locale) -> Bool = { _ in true }) -> TTSEngineSelector {
        let selector = TTSEngineSelector(defaults: defaults ?? freshDefaults())
        selector.hasSystemVoice = systemVoice
        selector.outputFactory = { _ in FakeOutput() }
        selector.avSpeechFactory = { FakeSynthesizer(engine: .avSpeech) }
        selector.kokoroFactory = { _ in FakeSynthesizer(engine: .kokoro) }
        selector.voiceCloneFactory = { _, _ in FakeSynthesizer(engine: .voiceClone) }
        selector.edgeFactory = { FakeSynthesizer(engine: .edgeTTS) }
        return selector
    }

    // MARK: - Default engine

    @Test("Default engine is AVSpeech when no preference is stored")
    func defaultEngineIsAVSpeech() {
        let selector = makeSelector()
        #expect(selector.preferredEngine == .avSpeech)
    }

    // MARK: - Preference persistence

    @Test("setPreferredEngine persists to UserDefaults")
    func persistsEnginePreference() {
        let defaults = freshDefaults()
        let selector = makeSelector(defaults: defaults)
        selector.setPreferredEngine(.kokoro)
        #expect(defaults.string(forKey: "tlk.tts.engine") == "kokoro")
    }

    @Test("Selector restores engine from UserDefaults on init")
    func restoresEngineOnInit() {
        let defaults = freshDefaults()
        defaults.set("kokoro", forKey: "tlk.tts.engine")
        let selector = makeSelector(defaults: defaults)
        #expect(selector.preferredEngine == .kokoro)
    }

    @Test("Unknown stored value falls back to avSpeech")
    func unknownStoredValueFallsBack() {
        let defaults = freshDefaults()
        defaults.set("unknownEngine", forKey: "tlk.tts.engine")
        let selector = makeSelector(defaults: defaults)
        #expect(selector.preferredEngine == .avSpeech)
    }

    @Test("Changing preference updates preferredEngine property")
    func setPreferredEngineUpdatesProperty() {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        #expect(selector.preferredEngine == .kokoro)
        selector.setPreferredEngine(.avSpeech)
        #expect(selector.preferredEngine == .avSpeech)
    }

    // MARK: - makeOutgoingService

    @Test("AVSpeech preference builds an AVSpeech primary with no fallback (REQ-T-22)")
    func avSpeechHasNoFallback() throws {
        let service = try makeSelector().makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(service.primaryEngine == .avSpeech)
        #expect(service.fallbackEngine == nil)
    }

    @Test("Kokoro preference, English, model available: Kokoro primary with the AVSpeech fallback (REQ-T-22)")
    func kokoroWithEnglish() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        let service = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(service.primaryEngine == .kokoro)
        #expect(service.fallbackEngine == .avSpeech)
    }

    @Test("Kokoro preference with a non-English locale uses AVSpeech")
    func kokoroPreferenceNonEnglishUsesAVSpeech() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        let service = try selector.makeOutgoingService(for: Locale(identifier: "fr-FR"), deviceID: nil)
        #expect(service.primaryEngine == .avSpeech)
    }

    @Test("Kokoro preference without the model uses AVSpeech")
    func kokoroUnavailableFallsBackToAVSpeech() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        let service = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(service.primaryEngine == .avSpeech)
    }

    @Test("Edge, Kokoro and the voice clone get the AVSpeech fallback only when the locale has a system voice")
    func fallbackNeedsSystemVoice() throws {
        let selector = makeSelector(systemVoice: { $0.language.languageCode?.identifier == "en" })
        selector.setPreferredEngine(.edgeTTS)
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil).fallbackEngine == .avSpeech)
        #expect(try selector.makeOutgoingService(for: Locale(identifier: "uk-UA"), deviceID: nil).fallbackEngine == nil)
    }

    @Test("the output is built for the device the coordinator passes")
    func outputGetsDevice() throws {
        let selector = makeSelector()
        var devices: [AudioDeviceID?] = []
        selector.outputFactory = { devices.append($0); return FakeOutput() }
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: 42)
        _ = try selector.makeIncomingService(for: Locale(identifier: "es-ES"), deviceID: nil)
        #expect(devices == [42, nil])
    }

    @Test("an output that cannot open makes the factory throw (the coordinator shows it)")
    func outputFailureThrows() {
        let selector = makeSelector()
        selector.outputFactory = { _ in throw STSError.deviceRoutingFailed }
        #expect(throws: STSError.deviceRoutingFailed) {
            _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: 42)
        }
    }

    // MARK: - makeIncomingService

    @Test("Incoming uses AVSpeech even when Kokoro is preferred")
    func incomingAlwaysAVSpeech() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        let service = try selector.makeIncomingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(service.primaryEngine == .avSpeech)
        #expect(service.fallbackEngine == nil)
    }

    @Test("Incoming uses Edge when it is the preferred engine")
    func incomingEdgeWhenPreferred() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.edgeTTS)
        let service = try selector.makeIncomingService(for: Locale(identifier: "de-DE"), deviceID: nil)
        #expect(service.primaryEngine == .edgeTTS)
        #expect(service.fallbackEngine == .avSpeech)
    }

    // MARK: - usingFallback

    @Test("usingFallback is false when AVSpeech is preferred")
    func usingFallbackFalseForAVSpeech() {
        let selector = makeSelector()
        #expect(!selector.usingFallback)
    }

    @Test("usingFallback is false when Kokoro is available and target is English")
    func usingFallbackFalseWhenKokoroUsed() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(!selector.usingFallback)
    }

    @Test("usingFallback is true when Kokoro preferred but target is not English")
    func usingFallbackTrueForNonEnglish() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        _ = try selector.makeOutgoingService(for: Locale(identifier: "de-DE"), deviceID: nil)
        #expect(selector.usingFallback)
    }

    @Test("usingFallback is true when Kokoro preferred but model not available")
    func usingFallbackTrueWhenModelUnavailable() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(selector.usingFallback)
    }

    // MARK: - currentTargetLocale

    @Test("makeOutgoingService updates currentTargetLocale")
    func makeOutgoingServiceUpdatesCurrentLocale() throws {
        let selector = makeSelector()
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-AU"), deviceID: nil)
        #expect(selector.currentTargetLocale == Locale(identifier: "en-AU"))
    }
}
```

In `TranslateCallTests/TTSEngineSelectorVoiceCloneTests.swift`, replace the three factory lines in `makeSelector()` with:
```swift
        // Fake synthesizers and output: no audio hardware, no model
        selector.hasSystemVoice = { _ in true }
        selector.outputFactory = { _ in FakeOutput() }
        selector.avSpeechFactory = { FakeSynthesizer(engine: .avSpeech) }
        selector.kokoroFactory = { _ in FakeSynthesizer(engine: .kokoro) }
        selector.voiceCloneFactory = { _, _ in FakeSynthesizer(engine: .voiceClone) }
        selector.edgeFactory = { FakeSynthesizer(engine: .edgeTTS) }
```
and the three `#expect(service is MockSynthesisService)` assertions with, in order: `#expect(service.primaryEngine == .voiceClone)` plus `#expect(service.fallbackEngine == .avSpeech)` (Spanish), `#expect(service.primaryEngine == .avSpeech)` (Hindi; update its comment to "Hindi is not supported by Qwen3-TTS → AVSpeech"), `#expect(service.primaryEngine == .kokoro)` (cloning disabled).

In `TranslateCallTests/EdgeTTSTests.swift`:
- delete the `// MARK: - AVSpeechService.hasVoice Tests` section (suite `AVSpeechServiceHasVoiceTests`; see the table);
- in `TTSEngineSelectorEdgeTTSTests.makeSelector`, replace the two factory lines with:
```swift
        selector.outputFactory = { _ in FakeOutput() }
        selector.avSpeechFactory = { FakeSynthesizer(engine: .avSpeech) }
        selector.kokoroFactory = { _ in FakeSynthesizer(engine: .kokoro) }
        selector.edgeFactory = { FakeSynthesizer(engine: .edgeTTS) }
```
- in `isUsingEdgeTTSWhenConsented`, replace `_ = try selector.makeOutgoingService(…)` and the `#expect(selector.isUsingEdgeTTS)` after it with:
```swift
        let service = try selector.makeOutgoingService(
            for: Locale(identifier: "uk"), deviceID: nil
        )
        #expect(selector.isUsingEdgeTTS)
        #expect(service.primaryEngine == .edgeTTS)
        #expect(service.fallbackEngine == nil)   // no Ukrainian system voice to fall back to
```

In `TranslateCallTests/TTSServiceTests.swift`, delete everything from `// MARK: - T2: AVSpeechService output device routing` to the end of the file (suites `AVSpeechServiceRoutingTests` and `AVSpeechServiceTests`).

```bash
git rm TranslateCallTests/KokoroSpeechServiceTests.swift TranslateCallTests/QwenCloneSpeechServiceTests.swift
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-only TTSEngineSelectorTests TTSEngineSelectorVoiceCloneTests TTSEngineSelectorEdgeTTSTests`
Expected: build FAILS — `value of type 'TTSEngineSelector' has no member 'outputFactory'`, `cannot convert value of type 'FakeSynthesizer' to closure result type 'any SynthesisService'`.

- [ ] **Step 3: Rewrite the selector**

Replace `TranslateCall/Core/TTS/TTSEngineSelector.swift` with:
```swift
import Combine
import CoreAudio
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSEngineSelector")

// MARK: - TTSEngineSelector

/// Manages TTS engine selection, model availability, and the factories that build each direction's
/// `TTSPlaybackService(primary:fallback:output:)` (F8.5.2 §3.6).
///
/// Outgoing priority: explicit Edge > Voice Clone > Kokoro (English) > AVSpeech > Edge (consent) > AVSpeech.
/// Incoming: explicit Edge > AVSpeech > Edge (consent) > AVSpeech.
@MainActor
final class TTSEngineSelector: ObservableObject {

    // MARK: - Published state

    @Published private(set) var preferredEngine: TTSEngine = .avSpeech
    @Published private(set) var kokoroAvailable: Bool = false
    @Published private(set) var voiceCloneAvailable: Bool = false
    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var isVoiceCloneDownloading: Bool = false
    @Published private(set) var currentTargetLocale: Locale = Locale.current

    /// User toggle — persisted in UserDefaults.
    @Published var voiceCloningEnabled: Bool = false {
        didSet { defaults.set(voiceCloningEnabled, forKey: QwenCloneConfiguration.voiceCloningEnabledKey) }
    }

    /// Active voice profile ID — set by VoiceProfileManager observation.
    @Published var activeVoiceProfileId: UUID?

    /// True when all three conditions are met: enabled + voice clone available + profile selected.
    var voiceCloningActive: Bool {
        voiceCloningEnabled && voiceCloneAvailable && activeVoiceProfileId != nil
    }

    /// True when Edge TTS consent is needed for current locale.
    var needsEdgeTTSConsent: Bool {
        !hasSystemVoice(currentTargetLocale)
            && !EdgeTTSConsentManager.consentGiven
    }

    /// True when Edge TTS is being used for the current locale.
    var isUsingEdgeTTS: Bool {
        !hasSystemVoice(currentTargetLocale)
            && EdgeTTSConsentManager.consentGiven
    }

    var usingFallback: Bool {
        preferredEngine == .kokoro && (!kokoroAvailable || !currentTargetLocale.isEnglish)
    }

    // MARK: - UserDefaults

    private let defaults: UserDefaults
    private static let engineKey = "tlk.tts.engine"

    // MARK: - Combine

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Factories (var — injectable for tests)

    /// Whether a system (AVSpeech) voice exists for a locale. Injectable so tests don't depend
    /// on which voices the machine has installed.
    var hasSystemVoice: (Locale) -> Bool = { AVSpeechUtteranceSynthesizer.hasVoice(for: $0) }

    /// The device output of one playback service (unit tests inject a `FakeOutput`).
    var outputFactory: (AudioDeviceID?) throws -> any AudioOutputting = { try TTSOutput(deviceID: $0) }
    var avSpeechFactory: () -> any UtteranceSynthesizer = { AVSpeechUtteranceSynthesizer() }
    var kokoroFactory: (KokoroConfiguration) -> any UtteranceSynthesizer = {
        KokoroUtteranceSynthesizer(configuration: $0)
    }
    var voiceCloneFactory: (UUID, any VoiceProfileStoring) -> any UtteranceSynthesizer = { profileId, store in
        QwenUtteranceSynthesizer(
            activeProfileId: profileId,
            profileStore: store,
            inferrer: QwenCloneModelManager.shared.gatedInferrer()
        )
    }
    var edgeFactory: () -> any UtteranceSynthesizer = { EdgeUtteranceSynthesizer() }

    // MARK: - Dependencies

    private var profileStore: (any VoiceProfileStoring)?

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.engineKey),
           let engine = TTSEngine(rawValue: raw) {
            preferredEngine = engine
        }
        voiceCloningEnabled = defaults.bool(forKey: QwenCloneConfiguration.voiceCloningEnabledKey)
        observeModelManager()
        observeQwenCloneModelManager()

        // REQ-VC-04: auto-load voice clone model on relaunch if previously enabled
        if voiceCloningEnabled {
            Task {
                do {
                    try await QwenCloneModelManager.shared.ensureReady()
                } catch {
                    logger.info("Voice clone auto-load skipped: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Public API

    func setPreferredEngine(_ engine: TTSEngine) {
        preferredEngine = engine
        defaults.set(engine.rawValue, forKey: Self.engineKey)
    }

    /// Creates the outgoing TTS service for `locale` routed to `deviceID`.
    /// If user explicitly selected Edge TTS, use it directly.
    /// Otherwise: Voice Clone > Kokoro > AVSpeech > Edge TTS (auto fallback).
    func makeOutgoingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> TTSPlaybackService {
        currentTargetLocale = locale
        return try makePlayback(primary: outgoingPrimary(for: locale), locale: locale, deviceID: deviceID)
    }

    /// Creates the incoming TTS service.
    /// Uses Edge TTS if explicitly selected or as fallback when no AVSpeech voice.
    func makeIncomingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> TTSPlaybackService {
        try makePlayback(primary: incomingPrimary(for: locale), locale: locale, deviceID: deviceID)
    }

    /// Triggers Kokoro model download; sets `isDownloading` while in-flight.
    func downloadKokoroModel() {
        isDownloading = true
        Task { [weak self] in
            _ = try? await KokoroModelManager.shared.ensureReady()
            self?.isDownloading = false
        }
    }

    func unloadKokoroModel() {
        kokoroAvailable = false
        Task { await KokoroModelManager.shared.unload() }
    }

    // MARK: - Voice Cloning API

    /// Enables voice cloning and begins Qwen3-TTS model download if needed.
    /// Unloads Kokoro first (NF-04: only one MLX TTS model at a time).
    func enableVoiceCloning() {
        voiceCloningEnabled = true
        if !voiceCloneAvailable {
            // Unload Kokoro to free GPU memory
            if kokoroAvailable {
                unloadKokoroModel()
            }
            isVoiceCloneDownloading = true
            Task { [weak self] in
                do {
                    try await QwenCloneModelManager.shared.ensureReady()
                } catch {
                    logger.error("Voice clone setup failed: \(error.localizedDescription)")
                }
                self?.isVoiceCloneDownloading = false
            }
        }
    }

    /// Disables voice cloning and unloads Qwen3-TTS model.
    func disableVoiceCloning() {
        voiceCloningEnabled = false
        Task { await QwenCloneModelManager.shared.unload() }
    }

    /// Sets the profile store for voice clone factory injection.
    func setProfileStore(_ store: any VoiceProfileStoring) {
        self.profileStore = store
    }

    // MARK: - Edge TTS consent

    func grantEdgeTTSConsent() {
        EdgeTTSConsentManager.grantConsent()
        objectWillChange.send()
    }

    // MARK: - For testing

    func setKokoroAvailableForTesting(_ value: Bool) { kokoroAvailable = value }
    func setVoiceCloneAvailableForTesting(_ value: Bool) { voiceCloneAvailable = value }

    // MARK: - Private

    /// Edge, Kokoro and the voice clone fall back to the system voice when the locale has one
    /// (REQ-T-22); AVSpeech as primary has no fallback.
    private func makePlayback(
        primary: any UtteranceSynthesizer, locale: Locale, deviceID: AudioDeviceID?
    ) throws -> TTSPlaybackService {
        let fallback = primary.engine != .avSpeech && hasSystemVoice(locale) ? avSpeechFactory() : nil
        return TTSPlaybackService(primary: primary, fallback: fallback, output: try outputFactory(deviceID))
    }

    private func outgoingPrimary(for locale: Locale) -> any UtteranceSynthesizer {
        if preferredEngine == .edgeTTS, EdgeTTSVoiceCatalog.supports(locale) {
            return edgeFactory()
        }
        // Priority 1: Voice Clone (10 supported languages)
        if voiceCloningActive, QwenCloneConfiguration.supportsLocale(locale),
           let profileId = activeVoiceProfileId, let store = profileStore {
            return voiceCloneFactory(profileId, store)
        }
        // Priority 2: Kokoro (English only)
        if preferredEngine == .kokoro, kokoroAvailable, locale.isEnglish {
            let voiceID = defaults.string(forKey: KokoroConfiguration.voiceDefaultsKey) ?? ""
            return kokoroFactory(KokoroConfiguration(voiceIdentifier: voiceID))
        }
        return systemOrEdgePrimary(for: locale)
    }

    private func incomingPrimary(for locale: Locale) -> any UtteranceSynthesizer {
        if preferredEngine == .edgeTTS, EdgeTTSVoiceCatalog.supports(locale) {
            return edgeFactory()
        }
        return systemOrEdgePrimary(for: locale)
    }

    /// AVSpeech when a system voice exists, else Edge (consent required), else AVSpeech, which then
    /// skips each sentence with a visible "No voice" notice.
    private func systemOrEdgePrimary(for locale: Locale) -> any UtteranceSynthesizer {
        if hasSystemVoice(locale) { return avSpeechFactory() }
        if EdgeTTSConsentManager.consentGiven, EdgeTTSVoiceCatalog.supports(locale) { return edgeFactory() }
        return avSpeechFactory()
    }

    private func observeModelManager() {
        Task { [weak self] in
            for await state in KokoroModelManager.shared.stateStream {
                await MainActor.run {
                    switch state {
                    case .ready:            self?.kokoroAvailable = true
                    case .failed, .idle:    self?.kokoroAvailable = false
                    case .loading:          break
                    }
                }
            }
        }
    }

    private func observeQwenCloneModelManager() {
        Task { [weak self] in
            for await state in QwenCloneModelManager.shared.stateStream {
                await MainActor.run {
                    switch state {
                    case .ready:                        self?.voiceCloneAvailable = true
                    case .failed, .idle:                self?.voiceCloneAvailable = false
                    case .downloading, .loading:        break
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 4: Delete the legacy services and move their last callers**

```bash
git rm TranslateCall/Core/TTS/AVSpeechService.swift TranslateCall/Core/TTS/KokoroSpeechService.swift \
       TranslateCall/Core/VoiceCloning/QwenCloneSpeechService.swift
```
`TranslateCall/Core/Setup/RouteTestService.swift`, in `run(blackHoleDeviceID:)`, replace from `state = .playing` to the end of the `do/catch` with:
```swift
        let locale = Locale(identifier: "en-US")
        guard AVSpeechUtteranceSynthesizer.hasVoice(for: locale) else {
            state = .failed("No English system voice is installed")
            return
        }

        state = .playing
        do {
            let tts = TTSPlaybackService(primary: AVSpeechUtteranceSynthesizer(),
                                         output: try TTSOutput(deviceID: deviceID))
            await tts.speak(text: testPhrase, locale: locale)
            for await speaking in tts.isSpeakingStream where !speaking {
                break
            }
            await tts.deactivate()
            state = .succeeded
        } catch {
            state = .failed(error.localizedDescription)
        }
```
(The voice check matters: without a voice the utterance is skipped without ever reporting `isSpeaking`, and the loop would wait forever.)

`TranslateCall/Features/Main/AudioViewModel.swift:243`: `if !AVSpeechUtteranceSynthesizer.hasVoice(for: targetLocale),`

`TranslateCall/Core/TTS/KokoroTtsManaging.swift:8`: `/// Isolates the FluidAudioEspeak dependency from KokoroUtteranceSynthesizer,`

`TranslateCallTests/Integration/TTSFixtureTests.swift`, lines 11-12 become:
```swift
            try requirePrerequisite(AVSpeechUtteranceSynthesizer.hasVoice(for: locale), "system voice for \(lang)")
            // Default output: audible during the run.
            let tts = TTSPlaybackService(primary: AVSpeechUtteranceSynthesizer(), output: try TTSOutput(deviceID: nil))
```
`TranslateCallTests/Integration/OutgoingPipelineFixtureTests.swift`, replace lines 29-35 (from `let tts = try AVSpeechService…` to `await tts.deactivate()`) with (`speak` only enqueues now, so "first audio" is the first buffer handed to the device):
```swift
            // First TTS audio = the first buffer handed to the device (speak() only enqueues).
            let output = RecordingOutput(wrapping: try TTSOutput(deviceID: nil))
            let tts = TTSPlaybackService(primary: AVSpeechUtteranceSynthesizer(), output: output)
            let ttsStart = ContinuousClock.now
            await tts.speak(text: text, locale: Locale(identifier: "en-US"))
            #expect(await waitUntil(timeout: .seconds(15)) { output.firstScheduleAt != nil }, "no TTS audio within 15 s")
            let ttsMs = ttsStart.duration(to: output.firstScheduleAt ?? .now).milliseconds
            await tts.deactivate()
```

Check nothing refers to the old services any more:
```bash
grep -rn "AVSpeechService\b\|KokoroSpeechService\|QwenCloneSpeechService\|EdgeTTSService\|getInferrer" TranslateCall TranslateCallTests
```
Expected: only the historical mention in `AVSpeechUtteranceSynthesizer.swift`'s doc comment ("as `AVSpeechService` did before F8.5.2").

- [ ] **Step 5: Run the unit tier and the integration tier**

Run: `just test`
Expected: all unit suites PASS; the unit count rises (28 legacy tests out, about 90 new ones in Tasks 1–8). Then `just test-integration` → PASS (the TTS fixture and outgoing-pipeline suites now run through `TTSPlaybackService`). Then `just lint` → exit 0.

- [ ] **Step 6: Commit**

```bash
git add -A TranslateCall TranslateCallTests
git commit -m "refactor(tts): every engine plays through TTSPlaybackService; legacy services removed (F8.5.2)

REQ-T-10/22/42: TTSEngineSelector builds TTSPlaybackService(primary:fallback:output:) with the
AVSpeech fallback when the locale has a system voice. AVSpeechService, KokoroSpeechService and
QwenCloneSpeechService are deleted.

Tests migrated (28 legacy tests out; behaviour → pinning test):
- AVSpeechService device init → TTSPlaybackIntegrationTests.outputDevices (integration tier)
- isSpeaking true on speak → TTSPlaybackServiceTests.truthfulSpeaking, AVSpeechUtteranceSynthesizerTests.yieldsAndFinishes
- stop clears queue / queued play / deactivate → TTSPlaybackServiceTests.stopIsImmediate, .fifoOneAtATime, .deactivate
- voice selection, hasVoice → AVSpeechUtteranceSynthesizerTests.englishVoice, .hasVoiceMatchesInstalled, .unknownLocale
- no voice → TTSPlaybackServiceTests.noVoice
- Kokoro pending/stop/whitespace → TTSPlaybackServiceTests.capDropsOldest, .stopIsImmediate, .blankIgnored
- Kokoro 500-char truncation → KokoroUtteranceSynthesizerTests.truncation, UtteranceHelpersTests.truncation
- Qwen profile context, language, 200-char truncation → QwenUtteranceSynthesizerTests.synthesizesWithProfile, .truncates
- Qwen error/timeout recovery → QwenUtteranceSynthesizerTests.inferenceErrorThrows,
  TTSPlaybackFallbackTests.fallsBackBeforeAudio, MLXInferenceGateTests.timeoutKeepsGateClosed
- SynthesisService conformance → compile time (TTSEngineSelector returns TTSPlaybackService)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Coordinator queues speech in both directions, TTS events become a notice line, preview disabled during a session (REQ-T-33, T-40, T-41, T-43)

**Files:**
- Create: `TranslateCall/Core/TTS/TTSEvent+Notice.swift`, `TranslateCall/Features/Main/TTSNoticeLine.swift`
- Modify: `TranslateCall/Core/Audio/AudioCoordinator.swift` (notice state, init, `stop`, `showTTSNotice`)
- Modify: `TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift` (`observeTTSEvents`, both pipelines, `handleOutgoingTranslation:252`, `handleIncomingTranslation:269`)
- Modify: `TranslateCall/Features/Main/AudioViewModel.swift` (`ttsNotice`, `isSessionActive`)
- Modify: `TranslateCall/Features/ContentView.swift:54-61,106`, `TranslateCall/Features/VoiceCloning/VoiceProfileListView.swift:3-4,85`, `TranslateCall/Features/VoiceCloning/VoicePreviewSection.swift:94-110,125-127`
- Replace: `TranslateCallTests/Mocks/MockSynthesisService.swift`
- Modify: `TranslateCallTests/AudioViewModelTests.swift` (two tests)
- Test: `TranslateCallTests/AudioCoordinatorTTSTests.swift`

**Interfaces:**
- Consumes: `SynthesisService.ttsEvents`, `TTSEvent` (Tasks 1–2); `LanguagePairManager.displayName(for:)`; `CoordinatorMocks`, `MockSpeechRecognizerService.injectTranscription(_:)`, `MockVADService.holdNextActivation()/releaseActivation()`, `ViewModelHarness` (existing test support); `TestClock`.
- Produces:
  - `extension TTSEvent { nonisolated func noticeText(language: String) -> String }`
  - `AudioCoordinator`: `@Published var ttsNotice: String?`; `func showTTSNotice(_ text: String)`; `init(…, halfDuplexTransitionDelay:, noticeClock: any Clock<Duration> = ContinuousClock(), ttsNoticeDuration: Duration = .seconds(5))`
  - `AudioViewModel`: `@Published private(set) var ttsNotice: String?`; `var isSessionActive: Bool { isCapturing || isStarting }`
  - `struct TTSNoticeLine: View { let text: String? }`
  - `VoiceProfileListView(isSessionActive: Bool = false)`; `VoicePreviewSection.canPreview(isPlaying:isSessionActive:) -> Bool`, `static let sessionActiveHelp: String`
  - `MockSynthesisService.emit(_ event: TTSEvent)`; its `ttsEvents` is non-nil.

- [ ] **Step 1: Mock with events, and the failing tests**

Replace `TranslateCallTests/Mocks/MockSynthesisService.swift` with:
```swift
import AVFoundation
import Foundation
@testable import TranslateCall

/// Test double for `SynthesisService`.
actor MockSynthesisService: SynthesisService {
    nonisolated let isSpeakingStream: AsyncStream<Bool>
    nonisolated let ttsEvents: AsyncStream<TTSEvent>?
    private let speakingContinuation: AsyncStream<Bool>.Continuation
    private let eventsContinuation: AsyncStream<TTSEvent>.Continuation

    // Call tracking
    var speakCalls: [(text: String, locale: String)] = []
    var stopSpeakingCalled = false
    var deactivateCalled = false
    private(set) var isSpeaking = false

    init() {
        (isSpeakingStream, speakingContinuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(8))
        let (events, eventsContinuation) = AsyncStream.makeStream(of: TTSEvent.self, bufferingPolicy: .bufferingNewest(16))
        ttsEvents = events
        self.eventsContinuation = eventsContinuation
    }

    func speak(text: String, locale: Locale) async {
        speakCalls.append((text: text, locale: locale.identifier))
        isSpeaking = true
        speakingContinuation.yield(true)
    }

    func stopSpeaking() async {
        stopSpeakingCalled = true
        isSpeaking = false
        speakingContinuation.yield(false)
    }

    func deactivate() async {
        deactivateCalled = true
        isSpeaking = false
        speakingContinuation.finish()
        eventsContinuation.finish()
    }

    /// Emits a TTS event, as `TTSPlaybackService` does on a skip, fallback or drop.
    func emit(_ event: TTSEvent) {
        eventsContinuation.yield(event)
    }
}
```

`TranslateCallTests/AudioCoordinatorTTSTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

@MainActor
private func makeCoordinator(_ mocks: CoordinatorMocks, noticeClock: TestClock) -> AudioCoordinator {
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
        noticeClock: noticeClock
    )
}

private func transcript(_ text: String) -> TranscriptionResult {
    TranscriptionResult(text: text, confidence: 1, locale: Locale(identifier: "es-ES"), capturedAt: .now, audioDuration: 1)
}

@Suite("AudioCoordinator TTS", .serialized) @MainActor
struct AudioCoordinatorTTSTests {

    @Test("outgoing sentences are queued: speak is never preceded by stopSpeaking (REQ-T-40, D-3)")
    func outgoingDoesNotInterrupt() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("hola"))
        await mocks.mockOutgoingSTT.injectTranscription(transcript("adiós"))

        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 2 })
        #expect(!(await mocks.mockOutgoingTTS.stopSpeakingCalled))
        await coordinator.stop()
    }

    @Test("incoming sentences are queued while incoming TTS speaks (REQ-T-43, D-7)")
    func incomingQueuesWhileSpeaking() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        await coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { coordinator.isIncomingActive })
        coordinator.isIncomingSpeaking = true

        await mocks.mockIncomingSTT.injectTranscription(transcript("hello"))
        await mocks.mockIncomingSTT.injectTranscription(transcript("goodbye"))

        #expect(await waitUntil { await mocks.mockIncomingTTS.speakCalls.count == 2 })
        #expect(!(await mocks.mockIncomingTTS.stopSpeakingCalled))
        await coordinator.stop()
    }

    @Test("a TTS event becomes the notice line, never an alert, and clears itself after 5 s (REQ-T-41)")
    func noticeAutoClears() async {
        let mocks = CoordinatorMocks()
        let clock = TestClock()
        let coordinator = makeCoordinator(mocks, noticeClock: clock)
        await coordinator.start()

        await mocks.mockOutgoingTTS.emit(.fellBack(from: .edgeTTS, to: .avSpeech))

        #expect(await waitUntil { coordinator.ttsNotice == "Edge TTS unavailable — used system voice" })
        #expect(coordinator.errorAlert == nil)
        #expect(await waitUntil { clock.pendingDeadlines == [.seconds(5)] })
        clock.advance(by: .seconds(5))
        #expect(await waitUntil { coordinator.ttsNotice == nil })
        await coordinator.stop()
    }

    @Test("a newer event replaces the notice and restarts its 5 s")
    func newerNoticeRestartsTimer() async {
        let mocks = CoordinatorMocks()
        let clock = TestClock()
        let coordinator = makeCoordinator(mocks, noticeClock: clock)
        await coordinator.start()

        await mocks.mockOutgoingTTS.emit(.utteranceDropped)
        #expect(await waitUntil { coordinator.ttsNotice == "Speaking behind — skipped an older sentence" })
        clock.advance(by: .seconds(4))
        await mocks.mockOutgoingTTS.emit(.utteranceSkipped(.timeout))
        #expect(await waitUntil { coordinator.ttsNotice == "Speech failed — sentence skipped" })
        #expect(await waitUntil { clock.pendingDeadlines == [.seconds(9)] })
        clock.advance(by: .seconds(4))
        #expect(coordinator.ttsNotice == "Speech failed — sentence skipped")
        clock.advance(by: .seconds(1))
        #expect(await waitUntil { coordinator.ttsNotice == nil })
        await coordinator.stop()
    }

    @Test("stop() clears the notice")
    func stopClearsNotice() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        await coordinator.start()
        await mocks.mockOutgoingTTS.emit(.utteranceSkipped(.noVoice))
        #expect(await waitUntil { coordinator.ttsNotice != nil })
        await coordinator.stop()
        #expect(coordinator.ttsNotice == nil)
    }
}

@Suite("TTS notice texts")
struct TTSNoticeTextTests {
    @Test("each event has the design §3.7 text")
    func texts() {
        #expect(TTSEvent.fellBack(from: .edgeTTS, to: .avSpeech).noticeText(language: "Ukrainian")
                == "Edge TTS unavailable — used system voice")
        #expect(TTSEvent.fellBack(from: .kokoro, to: .avSpeech).noticeText(language: "English")
                == "Kokoro unavailable — used system voice")
        #expect(TTSEvent.utteranceSkipped(.noVoice).noticeText(language: "Ukrainian")
                == "No voice for Ukrainian — sentence skipped")
        #expect(TTSEvent.utteranceSkipped(.timeout).noticeText(language: "x") == "Speech failed — sentence skipped")
        #expect(TTSEvent.utteranceSkipped(.primaryFailed("boom")).noticeText(language: "x")
                == "Speech failed — sentence skipped")
        #expect(TTSEvent.utteranceDropped.noticeText(language: "x") == "Speaking behind — skipped an older sentence")
        #expect(!TTSEvent.utteranceSkipped(.interrupted).noticeText(language: "x").isEmpty)
        #expect(!TTSEvent.utteranceSkipped(.outputUnavailable).noticeText(language: "x").isEmpty)
    }
}

@Suite("Voice preview during a session") @MainActor
struct VoicePreviewSessionTests {
    @Test("previews are disabled while a session runs or starts (REQ-T-33)")
    func disabledDuringSession() {
        #expect(VoicePreviewSection.canPreview(isPlaying: false, isSessionActive: false))
        #expect(!VoicePreviewSection.canPreview(isPlaying: false, isSessionActive: true))
        #expect(!VoicePreviewSection.canPreview(isPlaying: true, isSessionActive: false))
        #expect(VoicePreviewSection.sessionActiveHelp.contains("session"))
    }
}
```

Append to `struct AudioViewModelTests` in `TranslateCallTests/AudioViewModelTests.swift`:
```swift

    @Test("the voice preview counts as blocked while the session starts and while the mic captures (REQ-T-33)")
    func sessionActiveWhileStartingOrCapturing() async throws {
        let harness = ViewModelHarness()
        #expect(!harness.viewModel.isSessionActive)

        await harness.mocks.mockVADFactory.holdNextActivation()
        let starting = Task { await harness.coordinator.start() }
        #expect(await waitUntil { harness.viewModel.isStarting })
        #expect(harness.viewModel.isSessionActive)
        await harness.mocks.mockVADFactory.releaseActivation()
        await starting.value
        await harness.coordinator.stop()
        #expect(await waitUntil { !harness.viewModel.isStarting })

        _ = try await harness.audioManager.startCaptureSkippingPermissionForTesting()
        #expect(await waitUntil { harness.viewModel.isCapturing })
        #expect(harness.viewModel.isSessionActive)
        harness.audioManager.stopCapture()
    }

    @Test("the coordinator's TTS notice reaches the view model")
    func ttsNoticeIsBound() async {
        let harness = ViewModelHarness()
        harness.coordinator.showTTSNotice("Speech failed — sentence skipped")
        #expect(await waitUntil { harness.viewModel.ttsNotice == "Speech failed — sentence skipped" })
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-only AudioCoordinatorTTSTests TTSNoticeTextTests VoicePreviewSessionTests AudioViewModelTests`
Expected: build FAILS — `extra argument 'noticeClock' in call`, `value of type 'TTSEvent' has no member 'noticeText'`, `type 'VoicePreviewSection' has no member 'canPreview'`.

- [ ] **Step 3: Notice texts**

`TranslateCall/Core/TTS/TTSEvent+Notice.swift`:
```swift
import Foundation

// MARK: - Notice text

extension TTSEvent {
    /// The main window's one-line notice for this event (F8.5.2 REQ-T-41, design §3.7).
    /// `language` names the language the sentence was to be spoken in.
    nonisolated func noticeText(language: String) -> String {
        switch self {
        case .fellBack(let from, .avSpeech):
            return "\(from == .edgeTTS ? "Edge TTS" : from.displayName) unavailable — used system voice"
        case .fellBack(let from, let target):
            return "\(from.displayName) unavailable — used \(target.displayName)"
        case .utteranceSkipped(.noVoice):
            return "No voice for \(language) — sentence skipped"
        case .utteranceSkipped(.timeout), .utteranceSkipped(.primaryFailed):
            return "Speech failed — sentence skipped"
        case .utteranceSkipped(.interrupted):
            return "Speech interrupted — rest of the sentence skipped"
        case .utteranceSkipped(.outputUnavailable):
            return "Audio output unavailable — sentence skipped"
        case .utteranceDropped:
            return "Speaking behind — skipped an older sentence"
        }
    }
}
```

- [ ] **Step 4: Coordinator**

In `TranslateCall/Core/Audio/AudioCoordinator.swift`:
- after `private(set) var ttsMonitor: TTSAudioMonitor?` add:
```swift

    // MARK: - TTS notice (F8.5.2 REQ-T-41)

    /// Latest TTS skip / fallback / drop, as one line; clears itself after `ttsNoticeDuration`.
    /// Never an alert. Written by AudioCoordinator+Pipeline.swift, hence not `private(set)`.
    @Published var ttsNotice: String?
    private var ttsNoticeTask: Task<Void, Never>?
    private let noticeClock: any Clock<Duration>
    private let ttsNoticeDuration: Duration
```
- in `init`, replace `halfDuplexTransitionDelay: Duration = .milliseconds(300)` with
```swift
        halfDuplexTransitionDelay: Duration = .milliseconds(300),
        noticeClock: any Clock<Duration> = ContinuousClock(),
        ttsNoticeDuration: Duration = .seconds(5)
```
  and after `self.halfDuplexTransitionDelay = halfDuplexTransitionDelay` add
```swift
        self.noticeClock = noticeClock
        self.ttsNoticeDuration = ttsNoticeDuration
```
- in `stop()`, after `suppressNextOutgoingTurnFlag = false` add
```swift
        ttsNoticeTask?.cancel()
        ttsNotice = nil
```
- before `// MARK: - TTS Monitor actions` add:
```swift
    // MARK: - TTS notice

    /// Shows `text` in the notice line, replacing any earlier notice and restarting its timer.
    func showTTSNotice(_ text: String) {
        ttsNotice = text
        ttsNoticeTask?.cancel()
        let clock = noticeClock
        let duration = ttsNoticeDuration
        ttsNoticeTask = Task { [weak self] in
            do { try await clock.sleep(for: duration) } catch { return }
            self?.ttsNotice = nil
        }
    }

```

In `TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift`:
- in `startOutgoingPipeline`, after the `observeTTSState(…, into: &outgoingTasks)` call add
```swift
            observeTTSEvents(tts, language: languagePairManager.targetLanguage, into: &outgoingTasks)
```
- in `activateIncoming`, after the `observeTTSState(…, into: &incomingTasks)` call add
```swift
            observeTTSEvents(tts, language: languagePairManager.sourceLanguage, into: &incomingTasks)
```
- before `func cancelAllTasks()` add:
```swift
    /// Skips, fallbacks and drops of a `TTSPlaybackService` → the notice line (REQ-T-41).
    private func observeTTSEvents(
        _ tts: some SynthesisService,
        language: Locale.Language,
        into tasks: inout [Task<Void, Never>]
    ) {
        guard let events = tts.ttsEvents else { return }
        let languageName = languagePairManager.displayName(for: language)
        tasks.append(Task { [weak self] in
            for await event in events {
                self?.showTTSNotice(event.noticeText(language: languageName))
            }
        })
    }

```
- in `handleOutgoingTranslation`, replace `await outgoingTTS?.stopSpeaking()` with
```swift
        // No stopSpeaking() first: sentences queue (≤ 3 pending) instead of cutting each other (D-3).
```
- in `handleIncomingTranslation`, replace
```swift
        // Suppress when outgoing TTS is active (BlackHole loopback prevention) or self is speaking.
        guard !text.isEmpty, !incomingCaptureSuppressed, !isIncomingSpeaking else { return }
```
with
```swift
        // Suppress while outgoing TTS is active (BlackHole loopback prevention, F8.5.3). No
        // isIncomingSpeaking guard: remote sentences queue (≤ 3 pending) like outgoing ones (D-3, D-7).
        guard !text.isEmpty, !incomingCaptureSuppressed else { return }
```

- [ ] **Step 5: View model and UI**

`TranslateCall/Features/Main/AudioViewModel.swift`:
- after `@Published private(set) var isStarting = false` add:
```swift
    /// One-line TTS notice (skip, fallback, drop) from the coordinator; clears itself (F8.5.2 REQ-T-41).
    @Published private(set) var ttsNotice: String?

    /// A translation session is running or starting: the voice preview stays disabled (REQ-T-33).
    var isSessionActive: Bool { isCapturing || isStarting }
```
- in `bindCoordinator()`, after `coordinator.$isStarting.assign(to: &$isStarting)` add `coordinator.$ttsNotice.assign(to: &$ttsNotice)`

`TranslateCall/Features/Main/TTSNoticeLine.swift`:
```swift
import SwiftUI

/// One-line, non-modal TTS notice under the transcription (F8.5.2 REQ-T-41). Renders nothing when nil.
struct TTSNoticeLine: View {
    let text: String?

    var body: some View {
        if let text {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .transition(.opacity)
        }
    }
}

#Preview {
    VStack {
        TTSNoticeLine(text: "Edge TTS unavailable — used system voice")
        TTSNoticeLine(text: nil)
    }
    .padding()
}
```

`TranslateCall/Features/ContentView.swift`:
- right after the `TranscriptionView(…)` call (before `STTMetricsView()`), add `TTSNoticeLine(text: viewModel.ttsNotice)`
- in the voice-profiles sheet, `VoiceProfileListView()` becomes `VoiceProfileListView(isSessionActive: viewModel.isSessionActive)`

`TranslateCall/Features/VoiceCloning/VoiceProfileListView.swift`:
- first lines of the struct:
```swift
struct VoiceProfileListView: View {
    /// A translation session is running or starting: previews are disabled (F8.5.2 REQ-T-33).
    var isSessionActive: Bool = false

    @EnvironmentObject private var profileManager: VoiceProfileManager
```
- in `profileList`, `VoiceProfileDetailView(header: header)` becomes `VoiceProfileDetailView(header: header, isSessionActive: isSessionActive)` (`VoiceProfileDetailView` already forwards it to `VoicePreviewSection`).

`TranslateCall/Features/VoiceCloning/VoicePreviewSection.swift`:
- the "Play Recording" button's `.disabled(isPlaying)` becomes `.disabled(isPlaying || isSessionActive)`, and between that button and `// Status label` add:
```swift

            if isSessionActive {
                Text(Self.sessionActiveHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```
- after the closing brace of the outer `VStack` (before `.task {`) add `.help(isSessionActive ? Self.sessionActiveHelp : "")`
- replace `canPreview` with:
```swift
    private var canPreview: Bool {
        Self.canPreview(isPlaying: isPlaying, isSessionActive: isSessionActive)
    }

    /// Previews share the MLX gate with session TTS; during a session they are off (F8.5.2 REQ-T-33).
    static func canPreview(isPlaying: Bool, isSessionActive: Bool) -> Bool {
        !isPlaying && !isSessionActive
    }

    static let sessionActiveHelp = "Preview is unavailable while a translation session is running."
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `just test-only AudioCoordinatorTTSTests TTSNoticeTextTests VoicePreviewSessionTests AudioViewModelTests AudioCoordinatorTests`
Expected: PASS (5 + 1 + 1 + all AudioViewModel/AudioCoordinator tests, the existing ones unchanged). Then `just build` (SwiftUI changes) and `just lint` → exit 0.

- [ ] **Step 7: Commit**

```bash
git add TranslateCall/Core/TTS/TTSEvent+Notice.swift TranslateCall/Core/Audio TranslateCall/Features \
        TranslateCallTests/Mocks/MockSynthesisService.swift TranslateCallTests/AudioCoordinatorTTSTests.swift \
        TranslateCallTests/AudioViewModelTests.swift
git commit -m "feat(ui): TTS notice line; sentences queue both ways; preview off during a session (F8.5.2)

REQ-T-40: no stopSpeaking() before each outgoing sentence. REQ-T-43: incoming sentences queue
while incoming TTS speaks (isIncomingSpeaking guard removed). REQ-T-41: skips, fallbacks and drops
show as one auto-clearing line under the transcription, never as an alert. REQ-T-33: the voice
preview controls are disabled while a session runs or starts.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Static-analysis gate, hygiene sweep, backlog and manual verification

**Files:**
- Modify: `TranslateCall/Core/TTS/KokoroModelManager.swift:56-62`, `TranslateCall/Core/VoiceCloning/VoiceProfileRecorder.swift:19,30-36,214`, `TranslateCall/Core/TTS/EdgeTTSConsentManager.swift:8`
- Modify: `.opengrep/rules/swift-audio.yml`, `.opengrep/rules/swift-concurrency.yml`, `.opengrep/README.md`
- Modify: `specs/m8.5-stabilization/backlog.md`, this file (manual checklist results)

**Interfaces:**
- Consumes: the finished feature (Tasks 1–9).
- Produces: `playernode-isplaying-poll`, `asyncstream-unbounded`, `asyncstream-force-unwrap` at `ERROR`; zero findings of the three rules repo-wide and of `nonisolated-unsafe-justified` in `Core/TTS` and `Core/VoiceCloning` (REQ-T-50/51, AC 5).

- [ ] **Step 1: Remove the last `cont!` and unjustified `nonisolated(unsafe)` in Core/TTS and Core/VoiceCloning**

`TranslateCall/Core/TTS/KokoroModelManager.swift`, in `init(managerFactory:)` replace the four `var cont …`/`cont!` lines with:
```swift
        (stateStream, stateContinuation) = AsyncStream.makeStream(
            of: ModelState.self, bufferingPolicy: .bufferingNewest(8)
        )
```
`TranslateCall/Core/VoiceCloning/VoiceProfileRecorder.swift`:
- line 19: `private var engine: AVAudioEngine?` (only touched on the actor; `AVAudioEngine` is `Sendable`, so `nonisolated(unsafe)` is unnecessary)
- in `init`, replace the four `var cont …`/`cont!` lines with:
```swift
        (levelStream, levelContinuation) = AsyncStream.makeStream(
            of: Float.self, bufferingPolicy: .bufferingNewest(8)
        )
```
- directly above `nonisolated(unsafe) var consumed = false` add:
```swift
        // SAFETY: the converter calls this input block synchronously, on this thread, within convert().
```
`TranslateCall/Core/TTS/EdgeTTSConsentManager.swift:8`: `nonisolated private static let consentKey = "tlk.edgeTTS.consentGiven"` (a `String` constant is `Sendable`).

Run: `just test-only KokoroModelManagerTests VoiceProfileRecorderTests EdgeTTSConsentManagerTests`
Expected: PASS.

- [ ] **Step 2: Promote the rules**

`.opengrep/rules/swift-audio.yml`, rule `playernode-isplaying-poll`: `severity: ERROR`.
`.opengrep/rules/swift-concurrency.yml`: rules `asyncstream-unbounded` and `asyncstream-force-unwrap`: `severity: ERROR`; the `asyncstream-unbounded` `paths.include` becomes:
```yaml
      include: ["TranslateCall/Core/Audio/", "TranslateCall/Core/TTS/", "TranslateCall/Core/VoiceCloning/", ".opengrep/rules/"]
```
`.opengrep/README.md`, severity table rows:
```markdown
| `asyncstream-unbounded` | ERROR (F8.5.2) | Unbounded `AsyncStream` in audio/TTS/voice-cloning code grows without limit | 48 kHz stream leak, `AudioManager.swift:148` |
| `asyncstream-force-unwrap` | ERROR (F8.5.2) | `cont!` after `AsyncStream { cont = $0 }` | 6 occurrences, all removed in F8.5.1–F8.5.2; use `AsyncStream.makeStream` |
| `nonisolated-unsafe-justified` | WARNING | `nonisolated(unsafe)` without a `// SAFETY:` comment on the previous line | clean in Core/Audio, Core/TTS, Core/VoiceCloning; 4 left in Core/STT and Core/Translation |
| `playernode-isplaying-poll` | ERROR (F8.5.2) | `AVAudioPlayerNode.isPlaying` stays true until `stop()` — polling never ends | `EdgeTTSService.swift:167` (deleted in F8.5.2) |
```

- [ ] **Step 3: Scan**

Run: `just scan 2>&1 | tee build/logs/scan.log`
Expected: `✓ opengrep rule tests`, `✓ no blocking findings`; the WARNING list holds only `nonisolated-unsafe-justified` in `Core/STT/AppleSpeechService.swift`, `Core/STT/ParakeetSpeechService.swift`, `Core/STT/WhisperSpeechService.swift` and `Core/Translation/AppleTranslationService.swift` (verified while planning). Those are outside this feature, so that rule stays WARNING (REQ-T-51). If anything under `Core/TTS` or `Core/VoiceCloning` is reported, fix it the same way as Step 1 and re-run.

- [ ] **Step 4: Lint and the whole unit tier**

Run: `just lint` → exit 0. Then `just test` → PASS.

- [ ] **Step 5: Update the backlog**

In `specs/m8.5-stabilization/backlog.md`, set the "Guard in place" column:

| # | Guard in place |
|---|---|
| A3 | fixed in F8.5.2 (PR #…) — `EdgeTTSService` deleted; `TTSPlaybackServiceTests.truthfulSpeaking`, `.stalledOutput`; opengrep `playernode-isplaying-poll` (ERROR) |
| A3b | fixed in F8.5.2 — `EdgeTTSWebSocketTests.closingEventDisconnects`, `EdgeUtteranceSynthesizerTests.reconnectsOnce`, `.emptyTurnFallsBack` |
| A3c | fixed in F8.5.2 — `EdgeTTSWebSocketTests.connectTimeout`, `.firstChunkTimeout`, `.utteranceTimeout` |
| A3d | fixed in F8.5.2 — one worker per direction: `TTSPlaybackServiceTests.fifoOneAtATime` |
| A3e | fixed in F8.5.2 — `TTSPlaybackServiceTests.stopDuringSynthesis` |
| A9 | fixed in F8.5.2 — `TTSPlaybackServiceTests.stopDuringSynthesis`, `KokoroUtteranceSynthesizerTests.cancelledWhileLoading` |
| A9b | fixed in F8.5.2 — `.dataPlayedBack` handles: `TTSPlaybackServiceTests.schedulesAheadAwaitsLast`, `TTSPlaybackIntegrationTests.avSpeechThroughBlackHole` |
| A12 | fixed in F8.5.2 — `TTSPlaybackIntegrationTests.avSpeechThroughBlackHole`, `TTSPlaybackServiceTests.observerSeesEveryBuffer` (order) |
| A10 | Core/Audio, Core/TTS, Core/VoiceCloning clean (F8.5.1–F8.5.2); `asyncstream-*` ERROR; 4 `nonisolated(unsafe)` left in Core/STT, Core/Translation |
| A11 | fixed in F8.5.2 — `EdgeTTSWebSocketTests`, `EdgeUtteranceSynthesizerTests`, `EdgeTTSIntegrationTests.hello` |
| T6 | fixed in F8.5.2 — `MLXInferenceGateTests.oneAtATime`, `.timeoutKeepsGateClosed`, `.gateBusy`; manual M2 |

Fill in the PR number once the PR exists (Step 8).

- [ ] **Step 6: Commit**

```bash
git add TranslateCall .opengrep specs/m8.5-stabilization/backlog.md
git commit -m "chore(scan): asyncstream rules and playernode-isplaying-poll are now ERRORs; TTS and voice cloning scan-clean (F8.5.2)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Manual checklist (needs BlackHole, a call app, the network, the Qwen and Kokoro models; done by the user)**

Build and run the app (`just build`, then open `build/DerivedData/Build/Products/Debug/TranslateCall.app`). Record the date and result of each line here:

| # | Check | Expected | Result |
|---|-------|----------|--------|
| M1 | Edge selected, session running; cut the network mid-call; say a sentence; restore the network | The next sentence is spoken with the system voice and the notice "Edge TTS unavailable — used system voice" shows for 5 s; within 30 s of the network returning, Edge is used again | |
| M2 | Voice clone active, session running: open Voice Profiles → a profile | Preview, Compare and Play Recording are disabled, with "Preview is unavailable while a translation session is running." Outside a session, 10 rapid Preview clicks: no crash (at worst "The voice clone model is busy…") | |
| M3 | AVSpeech, a long sentence (≥ 25 s of speech) | Spoken to the end, not truncated | |
| M4 | Outgoing: say four sentences quickly | None is cut off; at most 3 wait; if one is dropped, "Speaking behind — skipped an older sentence" shows | |
| M5 | Kokoro English session; press Stop mid-sentence, then Start and speak | Nothing of the stopped sentence plays after Stop; the new session speaks normally | |
| M6 | Incoming (D-7, REQ-T-43): the remote party says two sentences quickly; then the remote speaks 3 sentences and the user replies while they play | Both translations are spoken in order; the second is not dropped while the first is playing; then record what happens to the user's reply (expected today: dropped silently while incoming TTS speaks — backlog F8.5.3, A13) | |

- [ ] **Step 8: Full gate (done by the controller with the user)**

Run: `just pr`
Expected: build → check → test → test-integration all pass; `local/just-pr` status = success on HEAD; PR created against `main` with the template filled in (spec + this plan, tests, `just pr`, manual checklist M1–M6). Then put the PR number into the backlog rows of Step 5 (amend or a follow-up commit, and run `just pr` again).

---

## Spec coverage

| Requirement | Task | Pinned by |
|---|---|---|
| REQ-T-01 `UtteranceSynthesizer` | 1 | every synthesizer suite (Tasks 4–7) |
| REQ-T-02 four synthesizers, none owns an engine | 4, 5, 6, 7 | `AVSpeechUtteranceSynthesizerTests`, `QwenUtteranceSynthesizerTests`, `KokoroUtteranceSynthesizerTests`, `EdgeUtteranceSynthesizerTests` |
| REQ-T-03 AVSpeech: callback order, no Task per buffer, finish on completion / empty | 4 | `AVSpeechUtteranceSynthesizerTests.yieldsAndFinishes`, `.blankFinishesEmpty`; integration `avSpeechThroughBlackHole` |
| REQ-T-04 truncation rules | 1, 5, 6 | `UtteranceHelpersTests.truncation`, `KokoroUtteranceSynthesizerTests.truncation`, `QwenUtteranceSynthesizerTests.truncates` |
| REQ-T-05 MP3 decoded in memory | 7 | `EdgeUtteranceSynthesizerTests.decodesTurn`, `.decoderRejectsGarbage` |
| REQ-T-10 one `SynthesisService` for every engine | 2, 8 | `TTSEngineSelectorTests` (`primaryEngine`/`fallbackEngine`) |
| REQ-T-11 enqueue and return; one worker, FIFO | 2 | `TTSPlaybackServiceTests.fifoOneAtATime` |
| REQ-T-12 cap 3, drop oldest + event, blank ignored | 2 | `.capDropsOldest`, `.blankIgnored` |
| REQ-T-13 schedule as they arrive, await only the last | 2 | `.schedulesAheadAwaitsLast` |
| REQ-T-14 truthful `isSpeaking`, no flicker, false at once on stop | 2 | `.truthfulSpeaking`, `.stopIsImmediate`, `.noVoice` |
| REQ-T-15 generation; nothing stale scheduled | 2 | `.stopDuringSynthesis` |
| REQ-T-16 bounded time, watchdog 30 s | 2 | `.watchdog`, `.stalledOutput`, `.watchdogSparesLongPlayback` |
| REQ-T-17 monitor gets every scheduled buffer | 2, 3 | `.observerSeesEveryBuffer`, `TTSAudioMonitorFormatTests` |
| REQ-T-18 events (bounded) | 1, 2 | `UtteranceHelpersTests.eventEquality`, event assertions throughout |
| REQ-T-19 metrics once per utterance | 2, 3 | `.metrics`, `TTSPlaybackFallbackTests.fallsBackBeforeAudio` (engine actually used) |
| REQ-T-20 fallback before first buffer | 3 | `.fallsBackBeforeAudio`, `.fallbackCannotSpeak`, `.primaryCannotSpeak`, `.fallbackFailsToo` |
| REQ-T-21 failure after audio → interrupted, no replay | 3 | `.interruptedAfterAudio` |
| REQ-T-22 AVSpeech fallback for Edge/Kokoro/Qwen with a system voice | 8 | `TTSEngineSelectorTests.fallbackNeedsSystemVoice`, `.kokoroWithEnglish`, `.avSpeechHasNoFallback` |
| REQ-T-23 breaker 3 failures / 30 s | 3 | `.breaker`, `.successResets`, `.breakerNeedsAFallback` |
| REQ-T-24 `isConnected` from socket events | 7 | `EdgeTTSWebSocketTests.closingEventDisconnects`, `.closeBeforeTurnEnd` |
| REQ-T-25 timeouts 5/5/20 s | 7 | `.connectTimeout`, `.firstChunkTimeout`, `.utteranceTimeout` |
| REQ-T-26 reconnect once | 7 | `EdgeUtteranceSynthesizerTests.reconnectsOnce`, `.secondFailureThrows`, `.failureAfterAudioNotRetried`, `.timeoutNotRetried` |
| REQ-T-27 `EdgeTransport` | 7 | `FakeEdgeTransport` in all Edge suites |
| REQ-T-30 one MLX inference process-wide | 5 | `MLXInferenceGateTests.oneAtATime` |
| REQ-T-31 no raw client | 5 | API removed; `QwenCloneModelManagerTests.synthesizeGoesThroughTheGate` |
| REQ-T-32 wait 2 s / inference limit, gate stays closed | 5 | `.timeoutKeepsGateClosed`, `.gateBusy` |
| REQ-T-33 preview disabled during a session | 9 | `VoicePreviewSessionTests`, `AudioViewModelTests.sessionActiveWhileStartingOrCapturing`, manual M2 |
| REQ-T-40 no pre-emptive `stopSpeaking` | 9 | `AudioCoordinatorTTSTests.outgoingDoesNotInterrupt` |
| REQ-T-43 incoming queues while speaking | 9 | `AudioCoordinatorTTSTests.incomingQueuesWhileSpeaking` |
| REQ-T-41 notice line, auto-clear 5 s, no alert | 9 | `.noticeAutoClears`, `.newerNoticeRestartsTimer`, `.stopClearsNotice`, `TTSNoticeTextTests` |
| REQ-T-42 legacy services removed | 7, 8 | Task 8 Step 4 grep |
| REQ-T-50 hygiene in Core/TTS, Core/VoiceCloning | 5, 10 | `just scan` (Task 10 Step 3) |
| REQ-T-51 rule promotions | 10 | `.opengrep/rules/*.yml` |
| NFR-T-01 no extra gaps between AVSpeech buffers | 4 | `PCMFormatConverterTests.streamsConsecutiveBuffers`; buffers scheduled ahead (`schedulesAheadAwaitsLast`) |
| NFR-T-02 `isSpeaking` false within 150 ms of the last sample | 4 | `TTSPlaybackIntegrationTests.avSpeechThroughBlackHole` |
| NFR-T-03 unit tests: no network, no models, no audio device | all | fakes everywhere; device tests live in the integration tier |
| AC 3 Edge "hello" within 10 s, missing network fails | 7 | `EdgeTTSIntegrationTests.hello` |
| AC 4 manual checklist | 10 | M1–M6 |
| AC 6 backlog | 10 | Step 5 |
