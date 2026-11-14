# M9 clause split and look-ahead synthesis — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The other side starts hearing a long sentence ~250–290 ms sooner: its first clause is translated and spoken while the rest is still being translated, and the next utterance is synthesized while the current one plays, so the parts follow without a gap.

**Architecture:**
- **Split.** `ClauseSplitter` (pure) cuts a sentence of ≥ 12 words once, at its first eligible `,` `;` `:`. `SentenceTranslation` starts one translation task per part, in order. `TurnCommitter` holds a `SentenceTranslation` instead of a `Task`; delivery awaits the parts one by one and speaks each when ready. The transcript keeps one entry per sentence.
- **Look-ahead.** `TTSPlaybackService` splits "synthesize" from "wait until played": synthesis stays serial in the worker, each utterance's drain runs in a chained task, at most one utterance is synthesized ahead of the one playing. The service measures the handoff gap and hands it to the output if the output reports handoffs (the tracing output does).
- **Trace and bench.** The tracer resolves parts by running the same splitter on the STT text, so the coordinator does not call the tracer. New stages `translatedAll` and `ttsPartBuffer`; `handoffGapMs` detail. The bench gets a `TC_CLAUSE_SPLIT` switch; `analyze.py` scores quality on the whole translation and reports the handoff gap.

**Tech Stack:** Swift 6 (app target default MainActor isolation), Swift Testing, `Synchronization.Mutex`, Apple Translation (through `TranslationBridgeModel`), SwiftUI (transcript bubble), `just`, SwiftLint (strict), opengrep; the bench: Swift side (`TranslateCallTests/Bench/`) and `tools/bench/tcbench` (Python, uv, pytest).

**Spec:** `specs/m9-product/clause-split/requirements.md` and `design.md` (APPROVED 2026-11-13, CS-1…CS-5, design §11 calls).

## Global Constraints

- **Branches and PR:**
  - work on `feat/m9-clause-split`, created from `spec/m9-clause-split` (Task 0); spec and code ship in one PR, opened with `just pr`;
  - never commit to `main`;
  - subagent-driven. Tasks marked **opus** need the opus model (concurrency, TTS core, delivery, tracer); **sonnet** otherwise. Each phase ends at a gate (G-A…G-D): `just lint`, `just scan`, `just test` green, plus a whole-phase review, before the next phase starts. The final review of the branch runs on opus.
- **Commits:** Conventional Commits, one per task at least. **No attribution lines** (no `Co-Authored-By`, no `Claude-Session`).
- **Build settings:** `SWIFT_VERSION = 6.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`. App target: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; anything used off the main actor says `nonisolated`. Test target: no default isolation. New files are picked up automatically (`PBXFileSystemSynchronizedRootGroup`); never edit `project.pbxproj`.
- **Unit tests:** no audio device, no ML model, no network, no `UserDefaults.standard` (use `UserDefaults(suiteName: "test-\(UUID())")` or `ConversationSettings.forTesting()`). Time through `TestClock` or an injected `now`; waiting through `waitUntil` / `AsyncGate` / `LockedArray` / `mainQueueHop()`. No fixed sleeps.
- **Recipes:** `just test-only <Suite> […]`; `just test`; `just lint`; `just scan`; `just test-bench-tools`; `just scenario all`; `just bench <set> <profile> <edge> <lines> <split>`; `just pr`.
- **SwiftLint strict** (app target only): lines ≤ 120; function bodies ≤ 50; type bodies ≤ 250; **files ≤ 400**; cyclomatic complexity ≤ 10; identifiers ≥ 3 chars; tuples ≤ 2 members; sorted imports.
- **Line budgets today** (measured at eabe83c):
  - `AudioCoordinator.swift` **397/400** → Task 3 moves the echo-gate extension out before adding anything;
  - `PipelineTracer.swift` 309 lines, type body ≈ 236/250 → Task 8 moves the TTS stages to `PipelineTracer+TTS.swift` first;
  - `TTSPlaybackService.swift` 286, actor body ≈ 199/250 → Task 4 moves the worker to `TTSPlaybackService+Worker.swift` first;
  - `AudioCoordinator+Translation.swift` 189, `TurnCommitter.swift` 171, `TranscriptView.swift` 192: room left.
- **Values pinned by the spec (copy exactly):**
  - split: sentence ≥ **12** words; ≥ **5** words before the cut, ≥ **4** after; marks `,` `;` `:` at the end of a whitespace token; at most one cut, at the first eligible mark;
  - setting key `conversation.clauseSplit`, default **true**, read at session start; no Settings control;
  - bench env `TC_CLAUSE_SPLIT` (`1` default, `0` off), recorded in run metadata as `settings.clauseSplit`;
  - look-ahead: at most **one** utterance synthesizing, at most **one** synthesized ahead of the one playing; always on, every engine, no switch;
  - trace: `translated` at part 0 with detail `parts: "2"`; new stage `translatedAll` (joined text); new stage `ttsPartBuffer` with detail `part: "1"`; detail `handoffGapMs`; `partsSpoken: "1"` on `ttsEnd` when part 1 failed;
  - acceptance (REQ-CS-40): en>es p50 **and** p90 total lower with split on; pipeline chrF++ drop ≤ **2** points in every line; handoff gap of second parts p50 ≤ **50 ms**, p90 ≤ **150 ms** with the voice clone; listening check of ≥ **10** split sentences; `just scenario all` passes.
- **Release only for latency:** every latency number comes from the bench (Release).
- **Volume access:** if a build fails with "Operation not permitted" under `/Volumes/SpBarberDev`, stop and ask the user (macOS TCC). Do not work around it.
- **Peer sessions:** before and after any bench or scenario run, list other Claude sessions on this machine (`ListAgents`) and warn the ones in TranslateCall (`SendMessage`): the bench needs an idle Mac.

## Review Focus

- **Stop while part 0 plays and part 1 is already synthesized ahead.** Nothing more is heard, `isSpeaking` goes false at once, no skip notice. Pinned in Task 5 (`stopDropsPlayingAndAhead`) and Task 7 (`stopBetweenPartsSpeaksNothingMore`).
- **The output device stalls or disappears while one utterance plays and the next is ahead (possibly still synthesizing).** Both are reported `outputUnavailable`; nothing of the one ahead is scheduled afterwards. Pinned in Task 5 (`stallSkipsAheadToo`, `aheadStillSynthesizingStopsScheduling`).
- **Pause lands between the two parts.** Part 1 is shown, not spoken; a Pause that reaches the TTS before a part's `speak` still stops it (UI-B1 per part). Pinned in Task 7 (`pauseBetweenPartsShowsNotSpeaks`, `pauseDuringPartSpeakStopsIt`).
- **Numbers, times and URLs in long sentences** (`3,5`, `10:30`, `http://…,…`). Never cut inside a token. Pinned in Task 1 (`innerMarksIgnored`).
- **Speakers mode: the mic hears their split translation as one sentence.** The echo guard still drops it. Pinned in Task 7 (`incomingRegistersPartsAndJoined`).

## Decisions made while planning (spec deviations are marked ⚠)

Replayed on a throwaway clone of `spec/m9-clause-split` at eabe83c (see Replay notes).

- **P-1 Bridge order.** `SentenceTranslation.init` creates the part tasks back to back on the main actor; every hop to `TranslationBridgeModel.translate` (AppleTranslationService → model) is main-actor, and the model appends to its FIFO before its first suspension. Main-actor jobs of equal priority run in order, so no chaining is added. Task 2 pins it with the real `TranslationBridgeModel` and `FakeTranslationSession` (`partsReachTheBridgeInOrder`).
- **P-2 Where the setting lives.** `ConversationSettings.clauseSplit` (key above). The coordinator gets `var clauseSplitSetting: (() -> Bool)?` (like `voiceCloneWarmUp`) and copies it into `isClauseSplitOn` in `start()`. `nil` means **off**: unit tests and previews keep today's behaviour; `AppContainer` and the bench wire it.
- **P-3 Handoff gap path.** `TTSPlaybackService` computes the gap (REQ-CS-56) and hands it to its output through a new `HandoffReporting` protocol (`AudioOutputting.swift`), right before scheduling the first buffer of an utterance. `TracingAudioOutput` conforms and forwards to `PipelineTracer.handoff(gap:)`, which puts it on the next first-buffer event. No change to `TTSEngineSelector` or the bench factory.
- **P-4 ⚠ When the gap is measured.** On the audio timeline (`scheduledAudioEnd` = sum of the scheduled buffers' lengths), not on playback handles: the bench output completes handles at once, so "still playing" by handles would never be true there. The gap is reported for **every** utterance whose first buffer follows audio scheduled earlier in the same `generation` (spec: only when it started while the previous audio played). This keeps the full silence of a part 1 whose translation came late; `analyze.py` gates on second parts only, and reports whole utterances as information.
- **P-5 ⚠ Who reports parts to the tracer.** The tracer itself: `translated(source:)` / `translationFailed(source:)` match a whole STT text first and otherwise a part of `ClauseSplitter.split(sttText)`. The coordinator never calls the tracer (design §7 suggested a coordinator-side call; the result is the same, and the decorator never reports a part as a whole). With the split off, no part is ever sent, so only whole matches happen.
- **P-6 ⚠ Part 1 not spoken because of Pause.** The tracer gets no signal for it, so the utterance stays open until `closeOpen` (session end). Only a failed part 1 (or a part-1 attempt with no audio) ends it at part 0's synthesis end with `partsSpoken: "1"`. The bench never pauses.
- **P-7 Partly skipped in the transcript.** `TranscriptEntry.partlySkipped: Bool`; `TranscriptRules.BubbleState.partlyTranslated` shows the translation, then "Rest not translated" in the same secondary style, not dimmed. Notice on part-1 failure: today's text ("Couldn't translate your sentence — skipped" / "…their sentence…").
- **P-8 Existing TTS queue tests.** Some assume the next synthesis starts only after the current audio played (coalescing, backlog, fallback-of-coalesced). They are rewritten to the look-ahead rule by putting one utterance ahead first; what they assert about coalescing, order and drops does not change.
- **P-9 `just bench` gets a fifth positional parameter** `split="1"` (just has no named recipe arguments): `just bench full best 0 "" 0` turns it off.

## Phase A — split rule, translation parts, setting

### Task 0: Branch (sonnet)

- [ ] `git switch spec/m9-clause-split && git switch -c feat/m9-clause-split`; `just build` green before any change.

### Task 1: `ClauseSplitter` (sonnet)

**Files:**
- Create: `TranslateCall/Core/Translation/ClauseSplitter.swift`
- Test: `TranslateCallTests/ClauseSplitterTests.swift`

**Interfaces:**
- Produces: `nonisolated enum ClauseSplitter { static let minWords = 12; static let minWordsBefore = 5; static let minWordsAfter = 4; static func split(_ text: String) -> [String] }` — 1 or 2 parts; part 0 keeps its mark; parts are whitespace-normalised.

- [ ] **Step 1: Write the failing tests** (`@Suite("ClauseSplitter (REQ-CS-01…04)")`):

```swift
@Test func splitsAtFirstEligibleComma() {
    let text = "When we get to the station, we will call you from the taxi"
    #expect(ClauseSplitter.split(text) == ["When we get to the station,", "we will call you from the taxi"])
}
@Test func elevenWordsWhole() {   // "…, we will call you soon": 11 words
    let text = "When we get to the station, we will call you soon"
    #expect(ClauseSplitter.split(text) == [text])
}
@Test func tooFewBeforeSkipsToNext() {
    let text = "Yes, I really think so, we can meet tomorrow at the main square"
    #expect(ClauseSplitter.split(text) == ["Yes, I really think so,", "we can meet tomorrow at the main square"])
}
@Test func tooFewAfterWhole() {   // 3 words after the only eligible mark
    let text = "We can meet tomorrow at the main square near the station; fine by me"
    #expect(ClauseSplitter.split(text) == [text])
}
@Test func semicolonAndColon() {
    #expect(ClauseSplitter.split("We can meet tomorrow at the main square near the station; it works for me").count == 2)
    let colon = "There is one thing I need to tell you now: the meeting is cancelled today"
    #expect(ClauseSplitter.split(colon) == ["There is one thing I need to tell you now:", "the meeting is cancelled today"])
}
@Test(arguments: [
    "The price went up from 3,5 euros to more than four euros this week",
    "The meeting starts at 10:30 in the big room on the second floor today",
    "Please open http://example.com/a,b before the call starts and tell me what you see",
]) func innerMarksIgnored(_ text: String) { #expect(ClauseSplitter.split(text) == [text]) }
@Test func roundTrip() {
    let text = "  When we get to   the station,  we will call you from the taxi "
    let parts = ClauseSplitter.split(text)
    #expect(parts.count == 2)
    #expect(parts.joined(separator: " ") == text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
}
```

- [ ] **Step 2:** `just test-only ClauseSplitterTests` → FAIL (`ClauseSplitter` not found).
- [ ] **Step 3: Implement `split`.** Words = `text.split(whereSeparator: \.isWhitespace)`. Fewer than `minWords` → `[text]` (untouched). Otherwise walk the words; the first word ending in a mark with ≥ `minWordsBefore` words up to and including it is the cut; if fewer than `minWordsAfter` words follow it, return `[text]` (a later mark leaves even fewer). No eligible mark → `[text]`.
- [ ] **Step 4:** `just test-only ClauseSplitterTests` → PASS.
- [ ] **Step 5:** `git commit -m "feat(translation): clause splitter (QS-5, REQ-CS-01…04)"`

### Task 2: `SentenceTranslation` and mock support (sonnet)

**Files:**
- Create: `TranslateCall/Core/Translation/SentenceTranslation.swift`
- Modify: `TranslateCallTests/TranslationPipelineTests.swift` (`MockTranslationService`)
- Test: `TranslateCallTests/SentenceTranslationTests.swift`

**Interfaces:**
- Consumes: `ClauseSplitter.split(_:)`.
- Produces:
  ```swift
  @MainActor final class SentenceTranslation {
      typealias Translate = @MainActor (String) async throws -> String
      let source: String
      let parts: [String]                  // 1 or 2
      let tasks: [Task<String, Error>]     // one per part, started in order
      var isSplit: Bool { get }
      init(_ text: String, split: Bool, translate: @escaping Translate)
      init(source: String, task: Task<String, Error>)   // one part around a started task (tests, callers holding a Task)
      func cancel()
  }
  ```
- Produces (test support): `MockTranslationService.holdTexts: Set<String>` (a call whose text is in it is held like `holdNext`, released by `releaseHeld()` oldest first) and `MockTranslationService.failTexts: [String: Error]` (thrown for that text). Existing members unchanged.

- [ ] **Step 1: Write the failing tests:**
  - `wholeWhenSplitOff`: `split: false` on a 13-word sentence with a comma → `parts == [text]`, `tasks.count == 1`.
  - `twoPartsTranslatedSeparately`: with `MockTranslationService`, values of `tasks[0]`, `tasks[1]` are `"TRANSLATED: <part0>"`, `"TRANSLATED: <part1>"`.
  - `cancelCancelsEveryPart`: both parts in `holdTexts`; `cancel()`; both tasks end with `CancellationError`.
  - `partsReachTheBridgeInOrder`: `let model = TranslationBridgeModel(); let driver = TranslationSessionDriver(model: model)`; translate closure `{ try await model.translate($0, from: en, to: es) }`; await both tasks; `#expect(driver.session.translated == parts)` (P-1).
- [ ] **Step 2:** `just test-only SentenceTranslationTests` → FAIL.
- [ ] **Step 3: Implement** the class (tasks created in `init`, in part order) and the two mock members.
- [ ] **Step 4:** `just test-only SentenceTranslationTests TranslationPipelineTests` → PASS.
- [ ] **Step 5:** `git commit -m "feat(translation): sentence translation in parts (QS-5, design §3)"`

### Task 3: Setting and coordinator flag (sonnet)

**Files:**
- Create: `TranslateCall/Core/Audio/AudioCoordinator+EchoGate.swift` (moved, unchanged code)
- Modify: `TranslateCall/Core/Audio/AudioCoordinator.swift` (remove the "Mic echo gate and conversation state" extension, lines 358–397; add the flag), `TranslateCall/Core/Audio/ConversationSettings.swift`, `TranslateCall/App/AppContainer.swift`
- Test: `TranslateCallTests/ConversationSettingsTests.swift`, `TranslateCallTests/AudioCoordinatorSessionTests.swift`

**Interfaces:**
- Produces: `ConversationSettings.clauseSplitKey = "conversation.clauseSplit"`; `@Published var clauseSplit: Bool` (default `true`, persisted in `didSet`).
- Produces: `AudioCoordinator.clauseSplitSetting: (() -> Bool)?` and `private(set) var isClauseSplitOn = false` (set in `start()` right after `beginSessionUIState()`: `isClauseSplitOn = clauseSplitSetting?() ?? false`).

- [ ] **Step 1: Move the echo-gate extension** to `AudioCoordinator+EchoGate.swift`. Members it needs from the other file lose `private` (`makeMicEchoGate`, `releaseMicEchoGate`, `updateConversationState` become internal; `isMicPaused` keeps `@Published` with an internal setter, commented like `incomingStatus`). `just build` green; no test change.
- [ ] **Step 2: Write the failing tests:** `clauseSplitDefaultsOn` (fresh suite → `true`), `clauseSplitPersists` (set `false`, new instance on the same suite → `false`); `clauseSplitReadAtStart` in `AudioCoordinatorSessionTests` (setting closure returns `true` → after `start()` `isClauseSplitOn == true`; flip the closure mid-session → unchanged until the next `start()`); `clauseSplitOffWithoutSetting` (`nil` → `false`).
- [ ] **Step 3: Implement** the setting, the coordinator members, and the wiring in `AppContainer` (`coordinator.clauseSplitSetting = { settings.clauseSplit }`, next to `voiceCloneWarmUp`).
- [ ] **Step 4:** `just test-only ConversationSettingsTests AudioCoordinatorSessionTests AudioCoordinatorEchoGateTests` → PASS; `just lint` green.
- [ ] **Step 5:** `git commit -m "feat(settings): clause split setting, read at session start (REQ-CS-20)"`

**Gate G-A:** `just lint`, `just scan`, `just test` green; review Tasks 1–3 together.

## Phase B — look-ahead synthesis (TTSPlaybackService)

### Task 4: Per-attempt state as a value, worker in its own file (opus)

No behaviour change. Prepares two live utterances (one draining, one synthesizing).

**Files:**
- Create: `TranslateCall/Core/TTS/TTSPlaybackService+Worker.swift` (`runWorker`, `takeNext`, `play`, `perform`, `speakWithFallback`, breaker helpers move here)
- Modify: `TranslateCall/Core/TTS/TTSPlaybackService.swift`, `TranslateCall/Core/TTS/TTSPlaybackService+Attempt.swift`, `TranslateCallTests/Support/TTSPlaybackHarness.swift`

**Interfaces:**
- Produces:
  ```swift
  struct AttemptRecord: Sendable {            // nested in TTSPlaybackService
      var startedAt: ContinuousClock.Instant
      var firstBufferAt: ContinuousClock.Instant?
      var bufferCount = 0
      var audioSeconds: Double = 0
      var lastHandle: PlaybackHandle?
      var countsTowardBreaker = true
  }
  func runAttempt(_: any UtteranceSynthesizer, _: Utterance, gen: UInt64) async -> (end: AttemptEnd, record: AttemptRecord)
  func conclude(_ end: AttemptEnd, record: AttemptRecord, engine: TTSEngine, utterance: Utterance, gen: UInt64) async -> Outcome
  ```
  The six `attempt*` actor vars are replaced by one `var attempt: AttemptRecord` that only the synthesizing attempt writes; `runAttempt` returns its final copy.
- Produces: `TTSPlaybackService.init(…, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now })`; every `ContinuousClock.now` / `.now` in the service and its extensions goes through `now()`. `TTSPlaybackHarness.init` gains `now:` with the same default.

- [ ] **Step 1:** Make the moves and the value; widen `private` to internal only where the other file needs it.
- [ ] **Step 2:** `just test-only TTSPlaybackServiceTests TTSPlaybackQueueTests TTSPlaybackFallbackTests TTSPlaybackPrimitivesTests TracingDecoratorTests QwenStreamingChainTests EdgeUtteranceSynthesizerTests` → PASS unchanged; `just lint` green (actor body < 250, files < 400).
- [ ] **Step 3:** `git commit -m "refactor(tts): per-attempt state as a value; worker in its own file"`

### Task 5: Look-ahead and handoff gap (opus)

**Files:**
- Modify: `TranslateCall/Core/TTS/TTSPlaybackService*.swift`, `TranslateCall/Core/TTS/AudioOutputting.swift`, `TranslateCallTests/Support/TTSFakes.swift` (`FakeOutput`)
- Modify (P-8): `TranslateCallTests/TTSPlaybackQueueTests.swift`, `TTSPlaybackServiceTests.swift`, `TTSPlaybackFallbackTests.swift` where they assume serial synthesis
- Test: `TranslateCallTests/TTSPlaybackLookAheadTests.swift`

**Interfaces:**
- Consumes: Task 4's `AttemptRecord`, `conclude(_:record:…)`, `now`.
- Produces: `nonisolated protocol HandoffReporting: Sendable { func handoff(gap: Duration) }` in `AudioOutputting.swift`. The service calls `(output as? any HandoffReporting)?.handoff(gap:)` right before scheduling the first buffer of an attempt that produces audio, when audio was scheduled earlier in the same `generation`: `gap = max(.zero, scheduledAudioEnd.duration(to: now()))`. `scheduledAudioEnd` advances by each buffer's length from `max(now(), scheduledAudioEnd)`, and is reset to nil by `stopSpeaking` and by every `output.stop()` the service makes.
- Produces (test support): `FakeOutput: HandoffReporting` recording `handoffGaps: [Duration]`.

Behaviour (design §7a): the worker synthesizes (attempt + fallback, as today), then hands `(end, record, engine, utterance, gen)` to a drain task chained after the previous drain (outcomes reported in order: skip event, metrics, `setSpeaking(false)` when the queue is empty, no attempt runs and no drain is pending). It starts the next synthesis only while ≤ 1 drain is pending (one playing, the new one becomes the one ahead); otherwise it awaits the oldest drain. An output stall/failure during a drain bumps an output epoch; the attempt ahead stops scheduling when it sees a different epoch (ends `.outputFailed`) and its drain reports `.skipped(.outputUnavailable)`. `stopSpeaking` unchanged in substance (generation bump, queue cleared, attempt cancelled, `output.stop()`, `setSpeaking(false)`); stale drains report nothing.

- [ ] **Step 1: Write the failing tests** (`@Suite("TTSPlaybackService look-ahead (FR-CS.5)")`, `TTSPlaybackHarness` with `FakeOutput(autoComplete: false)`; default fake buffer = 0.1 s):
  - `nextSynthesizesWhileCurrentPlays`: speak "a" → `scheduledCount == 1`; speak "b" → `waitUntil { scheduledCount == 2 }` with no handle completed; `primary.texts == ["a", "b"]` (REQ-CS-50).
  - `atMostOneAhead`: coalescing limits on; a playing, b ahead (`scheduledCount == 2`); speak "c", "d"; `mainQueueHop()`; `await service.pendingCount == 2` and `primary.texts == ["a", "b"]`; `complete(index: 0)` → `waitUntil { scheduledCount == 3 }`; `primary.texts == ["a", "b", "c d"]` (REQ-CS-51).
  - `stopDropsPlayingAndAhead`: a playing, b ahead; `stopSpeaking()`; `speaking.values.last == false` at once; `events.values` has no `.utteranceSkipped`; a later "e" is spoken (REQ-CS-53).
  - `stallSkipsAheadToo`: `playbackGrace` 1 s, a playing, b ahead; advance the `TestClock` past a's bound → `events.values == [.utteranceSkipped(.outputUnavailable), .utteranceSkipped(.outputUnavailable)]` (REQ-CS-54).
  - `aheadStillSynthesizingStopsScheduling`: b scripted with two buffers and `holdBefore: 1`; a stalls; `primary.gate.open()`; `scheduledCount` stays at 2 (a's buffer, b's first); b reported `outputUnavailable`.
  - `fallbackOnAheadWhileCurrentPlays`: primary scripts `[Script(), Script(buffers: [], failAfter: 0)]`, fallback fake; a playing, b fails with no audio → `fallback.texts == ["b"]` and `scheduledCount == 2` before a's handle completes; `.fellBack` emitted (REQ-CS-52).
  - `speakingStaysTrueAcrossHandoff`: a, b ahead; `complete(index: 0)`, then `complete(index: 1)` → `speaking.values == [true, false]` (REQ-CS-55).
  - `handoffGapZeroWhenInTime` / `handoffGapWhenLate`: injected manual `now` (as `PipelineTracerTests.ManualNow`); a at t=0 (0.1 s audio); b spoken at t=0.05 → `output.handoffGaps == [.zero]`; in the late case advance to t=0.3 before b → `[.milliseconds(200)]`; the very first utterance reports nothing (REQ-CS-56).
- [ ] **Step 2:** `just test-only TTSPlaybackLookAheadTests` → FAIL.
- [ ] **Step 3: Implement** the drain chain, the one-ahead rule, the output epoch, `scheduledAudioEnd`, `HandoffReporting`.
- [ ] **Step 4: Rewrite the serial-assuming tests (P-8)**: run the TTS suites, and for each failure put one utterance ahead before queuing what the test coalesces/counts; do not change what they assert about coalescing, order, backlog, fallback.
- [ ] **Step 5:** `just test-only TTSPlaybackLookAheadTests TTSPlaybackServiceTests TTSPlaybackQueueTests TTSPlaybackFallbackTests TTSPlaybackPrimitivesTests TracingDecoratorTests QwenStreamingChainTests EdgeUtteranceSynthesizerTests AudioCoordinatorTTSTests` → PASS.
- [ ] **Step 6:** `git commit -m "feat(tts): look-ahead synthesis, one utterance ahead; handoff gap (REQ-CS-50…56)"`

**Gate G-B:** `just lint`, `just scan`, `just test` green; then warn peers and run `just scenario all` once (look-ahead changes the timing every scenario relies on; must pass as on main). Opus review of Tasks 4–5.

## Phase C — delivery by parts

### Task 6: `TurnCommitter` holds a `SentenceTranslation` (sonnet)

**Files:**
- Modify: `TranslateCall/Core/Audio/TurnCommitter.swift`, `TranslateCall/Core/Audio/AudioCoordinator+Committer.swift`, `TranslateCall/Core/Audio/AudioCoordinator+Translation.swift` (signatures only)
- Modify tests: `TurnCommitterTests.swift` (probe), `AudioCoordinatorSessionTests.swift` and `AudioCoordinatorEarlyProcessingTests.swift` (callers passing a `Task` wrap it in `SentenceTranslation(source:task:)`)

**Interfaces:**
- Consumes: `SentenceTranslation`, `AudioCoordinator.isClauseSplitOn`.
- Produces: `TurnCommitter.init(translate: Translate, splitsClauses: Bool = false, deliver: Deliver)`; `typealias Deliver = @MainActor (_ text: String, _ translation: SentenceTranslation?) async -> Void`; `Entry.translation` and `inFlight` are `SentenceTranslation?`; every `.cancel()` stays a whole-sentence cancel.
- Produces: `AudioCoordinator.makeSentenceTranslation(_ text: String, outgoing: Bool) -> SentenceTranslation` (in `+Committer`, uses `isClauseSplitOn`); `deliverOutgoing(_:translation: SentenceTranslation? = nil)`, `deliverIncoming(_:translation: SentenceTranslation? = nil)` — bodies await `tasks[0]` only for now (Task 7 adds the parts).

- [ ] **Step 1: Write the failing tests** in `TurnCommitterTests`: `tentativeStartsBothParts` (`splitsClauses: true`, 13-word tentative → probe translated both parts before the commit); `retractCancelsBothParts` (both parts in `cancelled`); `cancelAllCancelsBothParts`.
- [ ] **Step 2:** `just test-only TurnCommitterTests` → FAIL.
- [ ] **Step 3: Implement**; update the probe's `deliver` to await every part and record the joined text.
- [ ] **Step 4:** `just test-only TurnCommitterTests AudioCoordinatorEarlyProcessingTests AudioCoordinatorSessionTests AudioCoordinatorTranslationTests` → PASS.
- [ ] **Step 5:** `git commit -m "refactor(audio): committer holds a sentence translation (design §4)"`

### Task 7: Speak part by part; transcript (opus)

**Files:**
- Create: `TranslateCall/Core/Audio/AudioCoordinator+Delivery.swift`
- Modify: `AudioCoordinator+Translation.swift` (guards and flags stay in `deliverOutgoing`/`deliverIncoming`; the translate-show-speak body moves to the new file), `AudioCoordinator+Session.swift` (`markPartlySkipped`), `TranslateCall/Core/Session/TranscriptEntry.swift`, `TranslateCall/Features/StatusPanel/TranscriptView.swift`
- Test: `TranslateCallTests/AudioCoordinatorClauseSplitTests.swift`, `TranscriptRulesTests.swift`

**Interfaces:**
- Consumes: Task 6's `SentenceTranslation?` delivery signatures; `MockTranslationService.holdTexts` / `failTexts`.
- Produces: `func speakParts(of sentence: SentenceTranslation, entry: UUID, direction: TranscriptDirection) async throws` — for each part in order: await its task (cancellation handler cancels the whole sentence), `try Task.checkCancellation()`, join, set the live caption and `completeTranscript(entry, translation: joined)`; if paused, no more speaking (still awaits and shows); else (incoming: `selfEchoGuard.played(part, at: .now)`) `speak(part)` then the UI-B1 guard. After the last part, incoming registers the joined text too when split. Part 0 failure: `sentence.cancel()`, rethrow (caller: `skipTranscript` + `handleTranslationFailure`, as today). Part 1 non-cancellation failure: `markPartlySkipped(entry)`, `handleTranslationFailure(error, outgoing:)`, return. `CancellationError` rethrows.
- Produces: `TranscriptEntry.partlySkipped: Bool = false`; `TranscriptRules.BubbleState.partlyTranslated` (when `partlySkipped && translation != nil`; secondary = translation, then "Rest not translated").

- [ ] **Step 1: Write the failing tests** (`@Suite("AudioCoordinator clause split (FR-CS.2)", .serialized) @MainActor`; `makeCoordinator` as in `AudioCoordinatorEarlyProcessingTests` with `clauseSplitSetting = { true }`; the sentence `S = "When we get to the station, we will call you from the taxi"`, parts `P0`, `P1`):
  - `partZeroSpokenWhilePartOneHeld`: `holdTexts = [P1]`; final `S` → `waitUntil { speakCalls.map(\.text) == ["TRANSLATED: \(P0)"] }`; transcript translation == `"TRANSLATED: \(P0)"`; `isOutgoingTranslating == true` (REQ-CS-18); `releaseHeld()` → speak calls `[…P0, …P1]`; transcript translation == both joined with one space; flag false.
  - `pauseBetweenPartsShowsNotSpeaks`: hold P1; P0 spoken; `pause()`; release → transcript has the joined text, speak calls only P0 (REQ-CS-14).
  - `pauseDuringPartSpeakStopsIt`: `mockOutgoingTTS.setHoldNextSpeak()` before P1's speak; `pause()` while held; release → `stopSpeakingCalled` (UI-B1 per part).
  - `stopBetweenPartsSpeaksNothingMore`: hold P1; P0 spoken; `stop()`; release → no second speak; the next session's flag untouched (REQ-CS-15).
  - `partOneFailureKeepsPartZero`: `failTexts = [P1: TranslationError.timedOut]` → P0 spoken, entry `partlySkipped`, translation `"TRANSLATED: \(P0)"`, `ttsNotice` set (REQ-CS-16).
  - `partZeroFailureSkipsSentence`: hold P1, `failTexts = [P0: …]` → nothing spoken, entry `skipped`, P1 task cancelled.
  - `muteTurnCancelsBothParts` and `echoDropCancelsBothParts` on a held tentative `S` (REQ-CS-13).
  - `incomingRegistersPartsAndJoined`: incoming `S` → after delivery `selfEchoGuard.isEcho("TRANSLATED: \(P0) TRANSLATED: \(P1)", at: .now)` and `isEcho("TRANSLATED: \(P1)", at: .now)` are true (REQ-CS-17).
  - `tentativeTranslatesBothBeforeCommit`: tentative `S` → `translateCallCount == 2` before the commit; commit → spoken in order.
  - `splitOffSpeaksWhole`: `clauseSplitSetting = { false }` → one speak with the whole translation.
  - `TranscriptRulesTests.partlySkippedState`: entry with translation + `partlySkipped` → `.partlyTranslated`.
- [ ] **Step 2:** `just test-only AudioCoordinatorClauseSplitTests TranscriptRulesTests` → FAIL.
- [ ] **Step 3: Implement.** Both `deliver*` stay ≤ 50 lines; the helper switches on `direction` for TTS, locale, caption and echo guard.
- [ ] **Step 4:** `just test-only AudioCoordinatorClauseSplitTests TranscriptRulesTests AudioCoordinatorEarlyProcessingTests AudioCoordinatorSessionTests AudioCoordinatorTranslationTests EchoLoopGuardTests StatusPanelTests` → PASS; `just lint`.
- [ ] **Step 5:** `git commit -m "feat(audio): speak a split sentence part by part (REQ-CS-10…18)"`

**Gate G-C:** `just lint`, `just scan`, `just test` green; opus review of Tasks 6–7.

## Phase D — trace, bench, analysis

### Task 8: Tracer parts and handoff gap (opus)

**Files:**
- Create: `TranslateCall/Core/Trace/PipelineTracer+TTS.swift` (moved: `speakRequested`, `synthesisStarted`, `bufferScheduled`, `synthesisFinished`; `State`, `Utterance`, `Attempt`, `finish`, `emit` lose `private`)
- Modify: `PipelineTracer.swift`, `TraceEvent.swift`, `TracingDecorators.swift` (`TracingAudioOutput: HandoffReporting`)
- Test: `TranslateCallTests/PipelineTracerTests.swift`, `TracingDecoratorTests.swift`

**Interfaces:**
- Consumes: `ClauseSplitter.split`, `HandoffReporting`.
- Produces: `TraceStage.translatedAll`, `TraceStage.ttsPartBuffer`; `PipelineTracer.handoff(gap: Duration)` (kept until the next `bufferScheduled`, which puts `handoffGapMs` on its first fresh event). Spoken units become `(seq, part)` items: `speakRequested` appends the matching item (whole translation, or the utterance's next part translation); `synthesisStarted` joins waiting items as today and, for an unexpected text, takes only the oldest item; `bufferScheduled` emits `ttsFirstBuffer` for part 0 / whole and `ttsPartBuffer` (`part: "1"`) for part 1; an utterance ends `ttsEnd` when its last expected part's attempt finished with audio. Part-1 `translationFailed` or a part-1 attempt with no audio → `ttsEnd` with `partsSpoken: "1"` (at part 0's synthesis end if already past). Part-0 failure → `dropped` as today.

- [ ] **Step 1: Write the failing tests:**
  - `splitUtteranceStampsPartsOnce`: STT `S`; `translated(P0)` → `translated` with detail `["text": T0, "parts": "2"]`; `translated(P1)` → `translatedAll` text `T0 + " " + T1`; speak/synth/buffer/finish T0, then T1 → stages `[speechStart, vadEnd, sttFinal, translated, translatedAll, ttsFirstBuffer, ttsPartBuffer, ttsEnd]`, one `ttsFirstBuffer`, utterance not dropped, `ttsEnd` after part 1's `synthesisFinished`.
  - `partAttemptNeverStampsTheNextUtterance`: utterance B spoken after A's part 0; A's part-1 attempt does not give B a `ttsFirstBuffer`.
  - `partOneFailureEndsAtPartZero`: `translationFailed(source: P1)` after part 0 finished → `ttsEnd` detail `["partsSpoken": "1"]`.
  - `coalescedPartsStampedTogether`: `synthesisStarted(text: T0 + " " + T1)` → both `ttsFirstBuffer` and `ttsPartBuffer` at the same stamp.
  - `handoffGapOnFirstBuffer`: `handoff(gap: .milliseconds(42))` then a fresh buffer → `handoffGapMs: "42"` on that event only.
  - `wholeSentenceUnchanged`: the existing `fullUtteranceInOrder` stays green (no `translatedAll` for unsplit).
  - `TracingDecoratorTests.outputForwardsHandoff`.
- [ ] **Step 2:** `just test-only PipelineTracerTests TracingDecoratorTests` → FAIL.
- [ ] **Step 3: Implement**; move first, then change (two commits allowed).
- [ ] **Step 4:** `just test-only PipelineTracerTests TracingDecoratorTests BenchModelsTests` → PASS; `just lint` (type body < 250).
- [ ] **Step 5:** `git commit -m "feat(trace): clause parts, translatedAll, ttsPartBuffer, handoff gap (REQ-CS-30…32)"`

### Task 9: Bench switch and analysis (sonnet)

**Files:**
- Modify: `TranslateCallTests/Bench/BenchRunner.swift` (`BenchEnvironment.clauseSplit`, `makeMeta` → `settings["clauseSplit"]`), `TranslateCallTests/Bench/BenchPipelineFactory.swift` (`BenchOptions.clauseSplit = true`; after `ConversationSettings(defaults:)` set `settings.clauseSplit = options.clauseSplit` and `coordinator.clauseSplitSetting = { settings.clauseSplit }`), `tools/scripts/bench.sh` (5th arg `split`, `0|1`, exported as `TEST_RUNNER_TC_CLAUSE_SPLIT`), `justfile` (`bench set="pr" profile="all" edge="0" lines="" split="1"`), `tools/bench/tcbench/analyze.py`, `tools/bench/tcbench/templates/report.html.j2`
- Test: `TranslateCallTests/Bench/BenchModelsTests.swift`, `tools/bench/tests/test_analyze.py`, `tools/bench/tests/test_report.py`

**Interfaces:**
- Consumes: Task 8's stages and details; Task 3's setting.
- Produces (`analyze_line`):
  - quality (`pipeline` chrF++/COMET) uses `_joined(utts, "translatedAll")` per utterance, falling back to `translated` when absent;
  - per-utterance `translateAll = translatedAll − sttFinal` (diagnosis, not in `STAGES`, not in `compare`);
  - `"split": {"sentences": n, "handoffGapMs": summary([...]), "backToBackPct": …}` only when a `ttsPartBuffer` exists: gap summary over `ttsPartBuffer.handoffGapMs` (the gate), `backToBackPct` = share of whole-utterance `ttsFirstBuffer` events with `handoffGapMs == "0"` (information).
  - report: a "Clause split" table after "Voice clone" (profile/runLine, split sentences, gap p50, gap p90, back-to-back %).

- [ ] **Step 1: Write the failing tests:** `BenchModelsTests`: `TC_CLAUSE_SPLIT` absent → `true`, `"0"` → `false`, `"x"` → `BenchSetupError`. Pytest: `test_quality_uses_translated_all` (a split utterance's `mt` is the `translatedAll` text), `test_split_handoff_summary` (two parts with gaps 10 and 200 → p50/p90 from `stats.summary`), `test_no_split_section_without_parts`, `test_split_stats_do_not_enter_compare`, `test_report_renders_split_table`.
- [ ] **Step 2:** `just test-only BenchModelsTests` and `just test-bench-tools` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** `just test-only BenchModelsTests` and `just test-bench-tools` → PASS; `bash -n tools/scripts/bench.sh`; `just bench pr best 0 "" 1` on one line (`outgoing-…-en`) produces `settings.clauseSplit == "1"` and, for a split sentence, `translatedAll` + `ttsPartBuffer` in `raw.json` (warn peers first).
- [ ] **Step 5:** `git commit -m "feat(bench): clause split switch; quality on the whole translation; handoff gap report (REQ-CS-21, REQ-CS-31)"`

**Gate G-D:** `just check`, `just test` green; review Tasks 8–9.

## Phase E — acceptance and PR

### Task 10: Acceptance REQ-CS-40 and PR (opus for the final review)

- [ ] **Step 1:** Whole-branch review on opus against requirements.md (every REQ-CS-xx → code + test).
- [ ] **Step 2:** Warn peers (ListAgents/SendMessage). `just scenario all` → pass (echo, pause, voice pitch), as on main.
- [ ] **Step 3:** Mac idle. `just bench full best 0 "" 1` (split on), then `just bench full best 0 "" 0` (off), back to back on the same commit. Note both run dirs.
- [ ] **Step 4:** Check against the gates: en>es p50 and p90 `total` lower with split on; pipeline chrF++ on − off ≥ −2 in every line; `split.handoffGapMs` p50 ≤ 50 and p90 ≤ 150 on clone lines; `just bench-compare run=<on> baseline=<off>` attached to the PR body. If a gate fails: stop, report to the user with numbers (do not tune thresholds).
- [ ] **Step 5: Listening check:** pick ≥ 10 split sentences (`ttsPartBuffer` present) from the on-run WAVs, listen (or hand the list of WAV paths and timestamps to the user if listening is not possible here); record verdicts in the PR body. Prosody fallback of design §10 is out of scope: report, do not implement.
- [ ] **Step 6:** Warn peers the Mac is free. Update `CHANGELOG.md` [Unreleased] (clause split, look-ahead, bench switch) and `specs/m9-product/backlog.md` QS-5 status.
- [ ] **Step 7:** `just pr` (build → check → test → integration → bench pr → push → PR). PR body in English, no attribution lines; include the acceptance table and the run ids.

## Replay notes

Throwaway clone `scratchpad/cs-replay` of `spec/m9-clause-split` at eabe83c, built with the main checkout's `SourcePackages` (`-clonedSourcePackagesDirPath`, no resolution):
- Read and confirmed every name the plan consumes: `TurnCommitter` (`Translate`, `Deliver`, `Entry`, `inFlight`, `cancelAll`), `AudioCoordinator` (`voiceCloneWarmUp`, `sessionGeneration`, `selfEchoGuard`, `isPaused`, `beginSessionUIState`, 397 lines), `deliverOutgoing/Incoming(_:translation:)`, `completeTranscript`, `skipTranscript`, `handleTranslationFailure`, `ConversationSettings` (keys, `forTesting()` used by tests), `TranscriptEntry`, `TranscriptRules.BubbleState`, `TTSPlaybackService` (`attempt*` vars, `play`/`perform`/`conclude`/`drainPlayback`, `bufferObserver`, uses `ContinuousClock.now` for attempt stamps), `AudioOutputting`/`PlaybackHandle`, `PipelineTracer` (stages, `Attempt`, `bufferScheduled`, `ManualNow` in tests), `TracingAudioOutput`, `TranslationBridgeModel` (FIFO append before the first suspension, all main-actor), `BenchEnvironment.parse`, `BenchOptions`, `RawRun.Meta.settings`, `bench.sh` args, `just bench` params, `analyze_line` / `_joined` / clone stats and the report template.
- Wrote `ClauseSplitter`, `SentenceTranslation` and the Task 1 tests plus a `SentenceTranslation` smoke test using `MockTranslationService`, `TestClock` and `TTSPlaybackHarness`, and ran them with `xcodebuild test -only-testing:TranslateCallTests/ClauseSplitterTests`: **8/8 pass** (Task 1's tests as written here, after fixing one example during the replay). Then `partsReachTheBridgeInOrder` (Task 2) with the real `TranslationBridgeModel` + `TranslationSessionDriver`: **pass**, the fake session receives the parts in order (P-1), and `SentenceTranslation(source:task:)` compiles.
- Not replayed: Phases B–D (look-ahead, delivery, tracer, bench); their interfaces were checked by reading the code only.
- Measured line budgets (above) with a non-comment line count; SwiftLint's own count may differ by a few lines.
