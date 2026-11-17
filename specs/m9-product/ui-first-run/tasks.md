# M9 UI first-run setup assistant — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the setup sheet with a four-step assistant window whose last step really verifies the outgoing route (mic level, phrase heard at BlackHole 2ch) and, when the pair is ready, rehearses one real translation through the real session.

**Architecture:** Pure detection logic (`LevelMeter`, `SustainedLevelDetector`) under small audio sources (`InputLevelSource`); two `@MainActor` state machines (`SetupChecks`, `Rehearsal`) behind protocols so they are unit-tested with fakes and `TestClock`; a rehearsal mode in `AudioCoordinator` plus a `SessionPhase.rehearsing` that keeps the rest of the app quiet; SwiftUI views on top.

**Tech Stack:** Swift 6, SwiftUI (macOS 14+), AVFoundation/CoreAudio, Combine, Swift Testing.

**Spec:** `specs/m9-product/ui-first-run/requirements.md` (REQ-FR-xx) and `design.md`.

## Global Constraints

- Branch `feat/m9-ui-first-run`, created from `spec/m9-ui-first-run`; spec + code ship in one PR. One commit per task, Conventional Commits.
- Synchronized folders: new files need no `project.pbxproj` edit.
- New tests use `ScratchDefaults.make(label)`, never `UserDefaults(suiteName:)`. Timeouts use an injected `any Clock<Duration>`; tests use `TranslateCallTests/Support/TestClock.swift`.
- SwiftLint strict: line ≤ 120, function body ≤ 50, type body ≤ 250 lines, file ≤ 400 lines. `AudioViewModel.swift` (392 lines) and `AudioCoordinator.swift` (375) are near the limit: put new coordinator code in `AudioCoordinator+Rehearsal.swift`.
- All user-facing strings via `String(localized:)` / SwiftUI literals; VoiceOver labels on every check state and the level meter (NF-FR-01). System font and SF Symbols (NF-FR-02). No new dependency (NF-FR-04).
- Thresholds (verbatim from the spec): mic check −40 dBFS for 300 ms; route check baseline 300 ms, then −70 dBFS sustained 200 ms within 3 s of playback start; rehearsal: 15 s to a transcript, 30 s to completion, both counted from capture running; "Preparing…" capped at 90 s; settle 1.5 s with no speaking and no translating.
- BlackHole 2ch: name exactly "BlackHole 2ch" (case-insensitive) or UID `BlackHole2ch_UID`.
- Verification per task: `just build`, `just test`, `just lint`. Never touch anything outside the repo checkout (no global caches, symlinks or settings); if blocked, stop and report.

## Review Focus

1. Window closed or step left mid-rehearsal → the session is stopped, mic and BlackHole released, phase back to `.idle` (Task 8 `cancelMidRehearsalStops`).
2. BlackHole 2ch unplugged/uninstalled between steps → checks fail with "BlackHole 2ch not found", no crash (Task 7 `routeCheckWithoutBlackHole`).
3. User says two sentences, or clause split speaks one sentence in parts → only the first entry counts and the rehearsal waits for all its parts (Task 8 `waitsForAllParts`, `ignoresSecondSentence`).
4. Relaunch after granting screen recording → assistant reopens on the same step (Task 5 `stepPersists`).
5. A call starts from the menu bar while step 4 is open → checks stop; Start is disabled during a rehearsal (Task 4 `rehearsingDisablesStart`, Task 7 `availabilityDuringCall`).

## pi delegation

Per the global "Delegar en pi" rules: each task goes to pi as a self-contained requirements file (this task's text + Global Constraints + the files to read), visible session `pi-task -m <model> -v fr-tN`. Claude reviews every diff and runs build/lint/tests. Model per task:

| Task | Model | Why |
|---|---|---|
| 1, 2, 11 | `rapido` | Small, pure, fully specified |
| 4, 5, 7 | `codigo` | Multi-file edits, compile-driven |
| 3, 6, 8 | `potente` | Concurrency/audio-engine work where a wrong guess is costly |
| 9, 10 | `diario` | Larger SwiftUI views; frame data extracted by Claude into `build/pi/setup-frames.md` (pi has no pencil MCP) |

---

### Task 1: Exact BlackHole 2ch lookup (REQ-FR-21)

**Files:**
- Create: `TranslateCall/Core/Setup/BlackHoleDevice.swift`
- Modify: `TranslateCall/Core/Setup/SetupManager.swift` (init, `checkBlackHole`), `TranslateCall/Features/Main/AudioViewModel.swift` (`startPipeline`)
- Test: `TranslateCallTests/BlackHoleDeviceTests.swift`

**Interfaces:**
- Produces: `nonisolated enum BlackHoleDevice { static let name = "BlackHole 2ch"; static let uid = "BlackHole2ch_UID"; static func find(in devices: [AudioDevice] = CoreAudioDevices.allDevices()) -> AudioDeviceID?; static func hasOtherBlackHole(in devices: [AudioDevice] = CoreAudioDevices.allDevices()) -> Bool }`; `SetupManager.hasOtherBlackHole: Bool` (`@Published private(set)`).

- [ ] **Step 1: Write the failing tests** (`@Suite("BlackHoleDevice (REQ-FR-21)")`), with `AudioDevice(id:name:uid:hasInput:hasOutput:)` literals:
  - `prefersTwoChannel`: devices `[16ch (id 7, "BlackHole 16ch"), 2ch (id 9, "BlackHole 2ch")]` → `find == 9`.
  - `matchesUID`: name "Renamed", uid `BlackHole2ch_UID` → found.
  - `caseInsensitive`: "blackhole 2CH" → found.
  - `onlySixteen`: `[16ch]` → `find == nil`, `hasOtherBlackHole == true`.
  - `none`: `[MacBook Mic]` → `nil`, `false`.
- [ ] **Step 2: Run** `just test` → FAIL (type missing).
- [ ] **Step 3: Implement `BlackHoleDevice`**; `hasOtherBlackHole` = some `isBlackHole` device and `find == nil`. Switch `SetupManager` (`isBlackHolePresent = BlackHoleDevice.find() != nil`, set `hasOtherBlackHole`) and `AudioViewModel.startPipeline` (`BlackHoleDevice.find()`) to it.
- [ ] **Step 4: Run** `just build && just test && just lint` → PASS.
- [ ] **Step 5: Commit** `feat(setup): look up BlackHole 2ch exactly (REQ-FR-21)`.

### Task 2: Level maths (REQ-FR-40/41)

**Files:**
- Create: `TranslateCall/Core/Setup/LevelMeter.swift`
- Test: `TranslateCallTests/LevelMeterTests.swift`

**Interfaces:**
- Produces: `nonisolated enum LevelMeter { static let silence: Float = -160; static func peakDBFS(_ buffer: AVAudioPCMBuffer) -> Float }` (max |sample| over all channels, `20·log10`, `silence` for empty/zero); `nonisolated struct LevelSample: Sendable, Equatable { let dbfs: Float; let duration: Duration }`; `nonisolated struct SustainedLevelDetector { init(threshold: Float, minDuration: Duration); mutating func feed(_ sample: LevelSample) -> Bool }` — true once contiguous samples `>= threshold` add up to `>= minDuration`; a sample below resets the run; stays true once reached.

- [ ] **Step 1: Write the failing tests:** `peakOfHalfScale` (float buffer with peak 0.5 → ≈ −6.02 ± 0.01); `silenceIsFloor` (zeros → −160); `sustainedNeedsDuration` (−30 dB × 100 ms ×2 → false, ×3 → true at threshold −40/300 ms); `dipResets` (200 ms loud, 10 ms at −80, 200 ms loud → false); `latches` (after true, a quiet sample still returns true).
- [ ] **Step 2: Run** `just test` → FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run** `just test && just lint` → PASS.
- [ ] **Step 5: Commit** `feat(setup): level meter and sustained-level detector`.

### Task 3: Rehearsal mode in the coordinator (REQ-FR-52, 56; design §6.1)

**Files:**
- Create: `TranslateCall/Core/Audio/AudioCoordinator+Rehearsal.swift`
- Modify: `TranslateCall/Core/Audio/AudioCoordinator.swift` (stored properties, `start`, `stop`), `TranslateCall/Features/Main/AudioViewModel.swift` (errorAlert binding line ~210, `toggleCapture`)
- Test: `TranslateCallTests/AudioCoordinatorRehearsalTests.swift` (reuse `CoordinatorMocks` / `makeCoordinator` pattern from `AudioCoordinatorTests.swift`), plus one case in `AudioViewModelTests.swift`

**Interfaces:**
- Produces on `AudioCoordinator`:
  - `@Published private(set) var isRehearsal = false`
  - `@Published private(set) var lastRehearsalError: AlertItem?`
  - `func start(captureTarget: CaptureTarget? = nil, blackHoleDeviceID: AudioDeviceID? = nil, rehearsal: Bool = false) async`
  - `func finishRehearsalIfNeeded()` (in the new file)
  - `var isMicCapturing: Bool { audioCapture.isCapturing }`

- [ ] **Step 1: Write the failing tests** (`@Suite("AudioCoordinator rehearsal (REQ-FR-56)", .serialized) @MainActor`):
  - `rehearsalIgnoresCaptureTarget`: `start(captureTarget: .app(bundleID: "x"), rehearsal: true)` → `isOutgoingActive`, `!(await mocks.mockSystemCapture.activateCalled)`, `isRehearsal`.
  - `isRehearsalBeforeStarting`: observe `$isStarting`; at the first `true`, `isRehearsal` is already true.
  - `transcriptRestored`: set two entries via `appendTranscript`, rehearse, append one, `stop()` → transcript equals the two original entries, `isRehearsal == false`.
  - `errorsGoToRehearsal`: during a rehearsal set `errorAlert = AlertItem(title:"t", message:"m", action:nil)` → `lastRehearsalError?.message == "m"`; after `stop()`, `errorAlert == nil`.
  - `packsMissingEndsRehearsal`: coordinator with `isTranslationPairInstalled: { _, _ in false }`, `start(rehearsal: true)` → `isRehearsal == false`, `lastRehearsalError != nil`, `errorAlert == nil`.
  - `normalStartUnaffected`: `start()` → `isRehearsal == false`, transcript cleared as today.
  - In `AudioViewModelTests`: `rehearsalErrorNotForwarded` (rehearsal error does not reach `viewModel.errorAlert`) and `toggleIgnoredDuringRehearsal` (`toggleCapture()` during a rehearsal leaves `isOutgoingActive` true).
- [ ] **Step 2: Run** `just test` → FAIL.
- [ ] **Step 3: Implement.**
  - `start`: set `isRehearsal = rehearsal` and `lastRehearsalError = nil` **before** `isStarting = true`. In rehearsal, use `captureTarget = nil` and keep `savedTranscript = transcript` (new internal stored `var savedTranscript: [TranscriptEntry]?`) before `beginSessionUIState()`.
  - Call `finishRehearsalIfNeeded()` on every `start` return that leaves the session inactive (packs missing, outgoing start failure, superseded) and at the end of `stop()`.
  - `errorAlert` gets `didSet { if isRehearsal, let errorAlert { lastRehearsalError = errorAlert } }`.
  - `finishRehearsalIfNeeded()`: guard `isRehearsal`; restore `savedTranscript` if any; clear it; `errorAlert = nil`; `isRehearsal = false` (last).
  - `AudioViewModel`: `coordinator.$errorAlert.filter { [unowned coordinator] _ in !coordinator.isRehearsal }.assign(to: &$errorAlert)`; `toggleCapture` starts with `guard !coordinator.isRehearsal else { return }`.
- [ ] **Step 4: Run** `just build && just test && just lint` → PASS (file lengths within limits).
- [ ] **Step 5: Commit** `feat(session): outgoing-only rehearsal mode in AudioCoordinator`.

### Task 4: `SessionPhase.rehearsing` keeps the app quiet (REQ-FR-56, F-9)

**Files:**
- Modify: `TranslateCall/Core/Session/DirectionState.swift` (`SessionPhase`), `Features/Session/CallSessionModel.swift` (`phase`, `recompute`, `routeAlert`, `start`, `stop`), `Features/Main/Readiness.swift` (new `Primary.setupTestInProgress`, title "Setup test in progress"), `Features/MenuBar/MenuBarIcon.swift`, `Features/StatusPanel/StatusPanelController+Session.swift`, `App/AppContainer.swift` (`sessionEnded`), every other exhaustive `switch` the compiler flags.
- Test: `TranslateCallTests/ReadinessTests.swift`, `CallSessionModelTests.swift` (existing file; create if absent), `MenuBarIconTests` (wherever `MenuBarDot` is tested).

**Interfaces:**
- Consumes: `AudioCoordinator.isRehearsal` (Task 3).
- Produces: `SessionPhase.rehearsing`; `CallSessionModel.phase(launching: Bool, starting: Bool, active: Bool, rehearsing: Bool) -> SessionPhase` (rehearsing wins over all); `Readiness.Primary.setupTestInProgress`.

- [ ] **Step 1: Write the failing tests:**
  - `phaseRehearsingWins`: `phase(launching:false, starting:true, active:false, rehearsing:true) == .rehearsing`, and with `active:true` too.
  - `rehearsingDisablesStart`: `Readiness.derive(..., phase: .rehearsing)` → `primary == .setupTestInProgress`, `!primaryEnabled`, `cards == []`, `blockingReason == "Setup test in progress"`.
  - `menuBarDotNoneWhileRehearsing`: `MenuBarDot.derive(phase: .rehearsing, title: .translating) == .none`.
  - `transcriptFrozenWhileRehearsing` (CallSessionModel with a real coordinator + mocks): a call's transcript `[a]`, rehearsal appends `b` → `session.transcript == [a]` during and after.
  - `rehearsalErrorNoWindow`: during a rehearsal an error does not call the injected `openMainWindow`.
  - `stopIgnoredDuringRehearsal`: `session.stop()` while rehearsing leaves the coordinator active.
- [ ] **Step 2: Run** `just test` → FAIL.
- [ ] **Step 3: Implement.** `recompute` passes `rehearsing: coordinator.isRehearsal` and skips `set(\.transcript…)` while `coordinator.isRehearsal`; `routeAlert` `.rehearsing` → `break`; `start`/`stop` guard `!coordinator.isRehearsal`. Status panel: `.rehearsing` grouped with `.launching, .starting` (no change). `AppContainer`: `sessionEnded` filters out ends while `coordinator.isRehearsal` (it is still true when `isOutgoingActive` drops, by Task 3's ordering). `TranscriptView.isSessionActive` and `MainSetupView`'s dismissal stay keyed on `.running`/`.starting` — no change.
- [ ] **Step 4: Run** `just build && just test && just lint` → PASS.
- [ ] **Step 5: Commit** `feat(session): rehearsing phase invisible to panel, menu bar and transcript`.

### Task 5: Step model and persistence (REQ-FR-01, 03, 32/33)

**Files:**
- Create: `TranslateCall/Core/Setup/SetupStep.swift`
- Modify: `TranslateCall/Core/Setup/SetupManager.swift`
- Test: `TranslateCallTests/SetupManagerTests.swift`, `TranslateCallTests/SetupStepTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum SetupStep: Int, CaseIterable, Sendable { case permissions, audioDriver, callAppMic, test }` with `var title: String` ("Permissions", "Audio driver", "Call app microphone", "Test").
  - `nonisolated enum SetupStepStatus: Sendable, Equatable { case todo, done, attention }`.
  - `SetupStep.status(permissions: PermissionState, blackHolePresent: Bool, hasOtherBlackHole: Bool, callAppMicConfirmed: Bool, testResult: SetupStepStatus) -> SetupStepStatus`. Rules: permissions done iff both granted, else todo; audioDriver done iff present, attention iff `hasOtherBlackHole`, else todo; callAppMic done iff confirmed; test returns `testResult`.
  - On `SetupManager`: `@Published var currentStep: SetupStep` (key `tlk.setup.step`, unknown/absent → `.permissions`, persisted on set); `@Published private(set) var callAppMicConfirmed: Bool` (key `tlk.setup.callAppMicConfirmed`); `func confirmCallAppMic()`. `completeSetup()` also removes `tlk.setup.step` and sets `currentStep = .permissions`.
- [ ] **Step 1: Write the failing tests:** `stepPersists` (set `.callAppMic`, new `SetupManager` on the same `ScratchDefaults` → `.callAppMic`); `invalidStepFallsBack` (stored 9 → `.permissions`); `completeClearsStep`; `confirmPersists`; one test per status rule (incl. `driverAttentionForSixteen`).
- [ ] **Step 2: Run** `just test` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `just test && just lint` → PASS.
- [ ] **Step 5: Commit** `feat(setup): persisted assistant step and step status`.

### Task 6: Audio sources: input level, recording, playback (design §5.2)

**Files:**
- Create: `TranslateCall/Core/Setup/InputLevelSource.swift`, `TranslateCall/Core/Setup/RecordingPlayer.swift`
- Test: `TranslateCallTests/Integration/SetupAudioIntegrationTests.swift` (inside the `IntegrationTests` tier, skipped without BlackHole via `requireBlackHole`)

**Interfaces:**
- Consumes: `LevelMeter`, `LevelSample` (Task 2), `BlackHoleDevice` (Task 1).
- Produces:
  - `@MainActor protocol LevelSource: AnyObject { func start() throws -> AsyncStream<LevelSample>; func stop(); var recording: [AVAudioPCMBuffer] { get } }`
  - `@MainActor final class InputLevelSource: LevelSource { init(deviceID: AudioDeviceID, records: Bool, maxRecording: Duration = .seconds(60)) }` — its own `AVAudioEngine`; input device set with `CoreAudioDevices.setCurrentDevice(_:on:)` on `engine.inputNode.audioUnit` (never via `AudioManager`, whose selection is persisted); tap of 1024 frames yields `LevelSample(dbfs: LevelMeter.peakDBFS(buf), duration: frames / sampleRate)`; when `records`, keeps buffer copies up to `maxRecording`. `stop()` removes the tap, stops the engine, finishes the stream; idempotent.
  - `@MainActor final class RecordingPlayer { func play(_ buffers: [AVAudioPCMBuffer]) throws; func stop() }` — default output device, `AVAudioPlayerNode`.
  - `@MainActor protocol PhrasePlayer { func play(on device: AudioDeviceID) async throws }` and `SystemVoicePhrasePlayer: PhrasePlayer` — moves today's `RouteTestService.run` body (phrase "Testing audio routing. TranslateCall is ready.", `en-US`, wait for `isSpeakingStream` false, `deactivate`); throws `SetupAudioError.noSystemVoice` when no English voice.
- [ ] **Step 1: Write the failing integration tests:** `listenerHearsBlackHole` (play the fixture into BlackHole 2ch with `BlackHolePlayer`, an `InputLevelSource` on it sees a `SustainedLevelDetector(-70, 200 ms)` pass within 3 s); `listenerSilentBaseline` (nothing playing → 300 ms of samples all `< -70`); `phraseReachesBlackHole` (`SystemVoicePhrasePlayer` + listener passes); `recordingKeepsAudio` (`records: true` → `recording` non-empty after the phrase).
- [ ] **Step 2: Run** `just test-integration` → FAIL (types missing).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `just build && just test-integration && just lint` → PASS (or the suite reports the BlackHole prerequisite as missing).
- [ ] **Step 5: Commit** `feat(setup): input level source, recording player and system-voice phrase player`.

### Task 7: Basic checks state machine (REQ-FR-40…43, 57b)

**Files:**
- Create: `TranslateCall/Core/Setup/SetupChecks.swift`
- Test: `TranslateCallTests/SetupChecksTests.swift` (fake `LevelSource` fed by a script of `LevelSample`s, fake `PhrasePlayer`, `TestClock`)

**Interfaces:**
- Consumes: Tasks 1, 2, 6 types; `PermissionState`.
- Produces:
  - `nonisolated enum CheckFailure: Equatable, Sendable { case microphoneOff, noBlackHole, busy, notReceived, callRunning, other(String) }` with `var message: String`: "Microphone access is off", "BlackHole 2ch not found", "Another app is sending audio to BlackHole — close it and try again", "BlackHole isn't receiving audio", "Available when no call is running", the string.
  - `nonisolated enum CheckState: Equatable, Sendable { case idle, running, passed, failed(CheckFailure) }`
  - `@MainActor final class SetupChecks: ObservableObject` with `@Published private(set) var micLevel: Float`, `micState: CheckState`, `routeState: CheckState`; `init(micSource: @escaping () throws -> any LevelSource, blackHoleSource: @escaping (AudioDeviceID) throws -> any LevelSource, phrasePlayer: any PhrasePlayer, clock: any Clock<Duration> = ContinuousClock(), permissions: @escaping () -> PermissionState = PermissionState.current, blackHole: @escaping () -> AudioDeviceID? = { BlackHoleDevice.find() }, callRunning: @escaping () -> Bool)`; `func startMicCheck()`, `func stopMicCheck()`, `func runRouteCheck() async`, `func cancelAll()`; `var testStatus: SetupStepStatus` (done if either passed, attention if either failed, else todo).
- Route algorithm: preconditions in order — `callRunning` → `.callRunning`; mic not granted → `.microphoneOff`; no BlackHole → `.noBlackHole`. Start the listener; baseline = first 300 ms of sample durations; any sample `>= -70` → `.busy`. Then start `phrasePlayer.play` in a child task and feed a `SustainedLevelDetector(-70, 200 ms)`; pass → `.passed`; 3 s on `clock` → `.notReceived`; player throws → `.other(message)`. Always stop the listener and cancel the player.
- Mic check: same preconditions (minus BlackHole); `micLevel` follows samples; `SustainedLevelDetector(-40, 300 ms)` → `.passed`; keeps metering after passing until `stopMicCheck`.
- [ ] **Step 1: Write the failing tests:** `routePasses`, `routeBusyBaseline`, `routeTimesOut` (advance clock 3 s), `routeCheckWithoutBlackHole`, `routeMicOff`, `availabilityDuringCall` (callRunning → `.failed(.callRunning)`, player never called), `listenerAlwaysStopped` (fake records `stop()` in pass, fail and cancel), `micPassesAtMinus40For300ms`, `micQuietStaysRunning`, `testStatusRules`.
- [ ] **Step 2: Run** `just test` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `just test && just lint` → PASS.
- [ ] **Step 5: Commit** `feat(setup): microphone and route checks (REQ-FR-40…43)`.

### Task 8: Rehearsal driver (REQ-FR-50…55, 57)

**Files:**
- Create: `TranslateCall/Core/Setup/Rehearsal.swift`; add `RehearsalHost` conformance in `TranslateCall/Core/Audio/AudioCoordinator+Rehearsal.swift`
- Test: `TranslateCallTests/RehearsalTests.swift` (fake host publishing scripted snapshots, fake `LevelSource`, `TestClock`)

**Interfaces:**
- Consumes: Task 3 (`start(…rehearsal:)`, `isRehearsal`, `lastRehearsalError`, `isMicCapturing`), Tasks 2, 6, Readiness.
- Produces:
  - `nonisolated struct RehearsalSnapshot: Equatable, Sendable { var isCapturing: Bool; var isActive: Bool; var firstOutgoing: TranscriptEntry?; var isTranslating: Bool; var isSpeaking: Bool; var error: String? }`
  - `@MainActor protocol RehearsalHost: AnyObject { func startRehearsal(blackHole: AudioDeviceID) async; func stopRehearsal() async; var snapshot: RehearsalSnapshot { get }; var snapshots: AnyPublisher<RehearsalSnapshot, Never> { get } }` — `AudioCoordinator` conforms: `firstOutgoing` = first `.outgoing` entry of `transcript` while `isRehearsal`; `isTranslating` = `isOutgoingTranslating`; `isSpeaking` = `isOutgoingSpeaking`; `error` = `lastRehearsalError?.message`; `snapshots` from `objectWillChange` on the main queue.
  - `nonisolated enum RehearsalFailure: Equatable, Sendable { case notHeard, notReceived, preparingTooLong, pipeline(String) }` — messages "We didn't hear you — try again, a bit louder", "Your translation didn't reach BlackHole", "Preparing is taking too long — try again", the string.
  - `nonisolated enum RehearsalState: Equatable, Sendable { case unavailable(String), ready, needsConsent, preparing, listening, translating(said: String), passed(said: String, received: String), failed(RehearsalFailure) }`
  - `@MainActor final class Rehearsal: ObservableObject` — `@Published private(set) var state: RehearsalState`; `init(host: any RehearsalHost, listener: @escaping (AudioDeviceID) throws -> any LevelSource, player: RecordingPlayer?, clock: any Clock<Duration> = ContinuousClock(), needsConsent: @escaping () -> Bool, grantConsent: @escaping () -> Void)`; `func refresh(availability: String?)` (nil → `.ready` unless running); `func rehearse()`; `func consent(accepted: Bool)`; `func cancel() async`; `func playResult()`.
  - `nonisolated static func availability(phase: SessionPhase, readiness: Readiness, blackHolePresent: Bool, microphone: PermissionStatus) -> String?` — first match: phase ≠ idle → "Available when no call is running"; mic ≠ granted → "Allow the microphone in step 1"; no BlackHole → "Install BlackHole 2ch in step 2"; `.download(l)` → "Available once \(l) is downloaded"; `.waitingForDownload` → "Waiting for the download to finish"; `.unsupportedPair` → "This language pair isn't available"; `.checking` → "Checking languages…"; else `readiness.blockingReason`.
- Sequence (design §6.3): `rehearse()` → `needsConsent()` ? `.needsConsent` : run. Run: listener (records) → `host.startRehearsal` → `.preparing` until `snapshot.isCapturing` (90 s cap → `.preparingTooLong`) → `.listening`; from here 15 s to `firstOutgoing` (`.notHeard`), 30 s to completion (`.notReceived` if the listener never passed, else `.notReceived` too). `firstOutgoing` arrives → `.translating(said:)`. Done when `firstOutgoing.translation != nil && !isTranslating && !isSpeaking` holds for 1.5 s on the clock **and** the listener's `SustainedLevelDetector(-70, 200 ms)` passed → `.passed(said:, received:)`. Any `error` → `.failed(.pipeline)`. Always (defer) `await host.stopRehearsal()` and `listener.stop()`; keep `listener.recording` for `playResult()` only on pass. `cancel()` cancels the run and awaits that cleanup; state → `.ready`.
- [ ] **Step 1: Write the failing tests:** `availabilityOrder` (one case per reason, incl. `.running` phase); `consentAskedFirst` / `consentDeclinedBackToReady` / `consentAcceptedGrantsAndRuns`; `passesAfterSettle`; `waitsForAllParts` (translation set, `isTranslating` stays true for a second part 1 s, then false → passes only 1.5 s after); `ignoresSecondSentence` (a second entry appearing does not change `said`); `notHeardAfter15s`; `notReceivedWhenListenerSilent`; `preparingTimesOut` (90 s); `pipelineErrorFails`; `cancelMidRehearsalStops` (host `stopRehearsal` and listener `stop` called once, state `.ready`); `stopAlwaysCalledOnFailure`; `timersStartAtCapture` (14 s in `.preparing` then capture → still 15 s budget).
- [ ] **Step 2: Run** `just test` → FAIL.
- [ ] **Step 3: Implement.** `AudioCoordinator.startRehearsal(blackHole:)` = `await start(captureTarget: nil, blackHoleDeviceID: blackHole, rehearsal: true)`; `stopRehearsal()` = `guard isRehearsal else { return }; await stop()`.
- [ ] **Step 4: Run** `just build && just test && just lint` → PASS.
- [ ] **Step 5: Commit** `feat(setup): rehearsal driver over the real outgoing session`.

### Task 9: Assistant window, sidebar, steps 1–3; remove the old wizard (REQ-FR-01…05, 10…13, 20, 30…33, 60)

**Files:**
- Create: `TranslateCall/App/SetupWindowOpener.swift`, `TranslateCall/Core/Setup/PermissionRequester.swift`, `TranslateCall/Features/Setup/SetupAssistantView.swift`, `SetupSidebar.swift`, `PermissionsStepView.swift`, `AudioDriverStepView.swift`, `CallAppMicStepView.swift`, `TestStepView.swift` (placeholder body "Test" until Task 10)
- Modify: `TranslateCall/App/TranslateCallApp.swift` (new `Window(id: "setup")` scene with the same environment objects as the main window), `Features/Main/MainSetupView.swift` (launch + `setUpDriver` → opener; remove the sheet), `Features/Settings/AdvancedSettingsView.swift` (Run setup again → opener), `Core/Setup/SetupManager.swift` (remove ScreenCaptureKit members: `selectedCaptureApp`, `availableCaptureApps`, `isLoadingCaptureApps`, `detectedVideoCallApp`, `captureAppsLoaded`, `loadCaptureApps`, `refreshCaptureApps`, `requestScreenCapturePermission`, `selectCaptureApp(_: SCRunningApplication?)`, `restoreSelectedApp`)
- Delete: `Features/Setup/SetupWizardView.swift`, `Step1_BlackHoleCheckView.swift`, `Step2_VideoAppInstructionView.swift`, `Step3_CaptureAppSelectView.swift`, `Step4_RouteTestView.swift`, `Core/Setup/RouteTestService.swift` (its code moved in Task 6); SCKit tests in `SetupManagerTests.swift`; `AudioViewModelTests.swift:158` becomes `selectCaptureApp(bundleID: nil)`.
- Test: `TranslateCallTests/SetupWindowOpenerTests.swift`, `PermissionRequesterTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 5; `CallAppMonitor`, `MainSetupModel` (`select`, `selectOther`), `VideoCallApp` (per-app steps, `matching(bundleID:displayName:)`), `PermissionState.current()`.
- Produces: `@MainActor final class SetupWindowOpener { static let shared; static let windowID = "setup"; var openWindow: (() -> Void)?; func open() }` (set in `TranslateCallApp`'s main-window `onAppear`, next to `MainWindowOpener`); `@MainActor protocol PermissionRequesting { func requestMicrophone() async -> Bool; func requestScreenRecording(); func openPrivacyPane(_ pane: PrivacyPane); func relaunch() }`, `enum PrivacyPane { case microphone, screenRecording }` (URLs `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` / `?Privacy_ScreenCapture`), live `PermissionRequester`.
- Views follow the frames' copy and layout in `build/pi/setup-frames.md` (extracted by Claude). Sidebar rows show `SetupStep.title` + status icon (`checkmark.circle.fill` green / `exclamationmark.circle.fill` orange / `circle`). Footer: Back, Continue, and "Finish" on step 4 (→ `completeSetup()`, close window). Permission and driver state refresh on `NSApplication.didBecomeActiveNotification`. Step 1 "Reopen TranslateCall" shown when screen recording is denied after a request. Step 3: picker over `CallAppMonitor.rows` + "None — translate only my voice" (calls `selectCaptureApp(bundleID: nil)` and `confirmCallAppMic()`); per-app three steps from `VideoCallApp`; "Open <app>" via `CallAppMonitor.open`; "I've done it" → `confirmCallAppMic()`.
- [ ] **Step 1: Write the failing tests:** `openerCallsOpenWindow`; `privacyPaneURLs` (exact URLs above); `micRequestReportsGrant` (fake). Update/delete the SCKit tests listed above.
- [ ] **Step 2: Run** `just test` → FAIL.
- [ ] **Step 3: Implement** the files above. Before writing each step view, read its frame section in `build/pi/setup-frames.md`.
- [ ] **Step 4: Run** `just build && just test && just lint` → PASS; `grep -rn "SetupWizardView\|RouteTestService\|loadCaptureApps" TranslateCall TranslateCallTests` → no output.
- [ ] **Step 5: Commit** `feat(setup): assistant window with sidebar and steps 1–3; remove the old wizard`.

### Task 10: Step 4 views and wiring (REQ-FR-40…58)

**Files:**
- Create: `TranslateCall/Features/Setup/RehearsalBox.swift`, `LevelMeterView.swift`
- Modify: `TranslateCall/Features/Setup/TestStepView.swift`, `SetupAssistantView.swift` (pass `SetupChecks.testStatus` to the sidebar; `onDisappear` → `checks.cancelAll()` + `await rehearsal.cancel()`), `TranslateCall/App/AppContainer.swift` (build one `SetupChecks` and one `Rehearsal` with live sources: mic source = `InputLevelSource(deviceID: audioViewModel.selectedInput?.id ?? CoreAudioDevices.defaultInputDeviceID(), records: false)`; host = coordinator; consent closures from `AudioViewModel.needsEdgeConsentBeforeStart` and `ttsEngineSelector.grantEdgeTTSConsent()`; `callRunning` = `callSession.phase` in `.launching/.starting/.running`), `TranslateCallApp.swift` (inject both into the setup window).
- Test: `TranslateCallTests/TestStepPresentationTests.swift`

**Interfaces:**
- Consumes: Tasks 7, 8, 9.
- Produces: `nonisolated enum TestStepPresentation { static func micLine(_ state: CheckState) -> String; static func routeLine(_ state: CheckState) -> String; static func rehearsalLines(_ state: RehearsalState, appName: String, myLanguage: String) -> [String] }` — the strings the views show (mic: "Say something" / "We can hear you" / failure message; route: "Test" idle, "Testing…", "BlackHole receives audio", failure; rehearsal: unavailable reason, "Preparing…", "Say a short sentence in \(myLanguage)", "You said: …", "\(appName) receives: …", failure message). Incoming line: "Audio from \(appName) — checked in your first call".
- Behaviour: entering step 4 → `checks.startMicCheck()` (unless a call runs); leaving → `checks.cancelAll()` + `rehearsal.cancel()`; `onChange(of: callSession.phase)` to a call phase → same cancel. Rehearse stops the mic check first and restarts it after. `.needsConsent` shows an alert with today's Edge text ("No voice is available for this language on your device. Enable Cloud TTS? Text will be sent to Microsoft for speech synthesis.") calling `rehearsal.consent(accepted:)`. `.passed` shows "Play" → `rehearsal.playResult()`. Availability recomputed with `Rehearsal.availability(…)` from `MainSetupModel.readiness` inputs whenever they change. Every check row has an `accessibilityLabel` with its state.
- [ ] **Step 1: Write the failing tests** for `TestStepPresentation` (one per state listed above, exact strings).
- [ ] **Step 2: Run** `just test` → FAIL.
- [ ] **Step 3: Implement**, matching frame `YDVmk`/`lHIVU` in `build/pi/setup-frames.md`.
- [ ] **Step 4: Run** `just build && just test && just lint` → PASS.
- [ ] **Step 5: Commit** `feat(setup): test step with checks, rehearsal and playback`.

### Task 11: Docs and close-out (REQ-FR-61)

**Files:**
- Modify: `CHANGELOG.md` (`[Unreleased]` → Added: setup assistant window with real route checks and rehearsal; Changed: BlackHole 2ch matched exactly; Removed: old setup sheet), `specs/m9-product/backlog.md` (add `UI-S1 | Spike: detect whether the call app has BlackHole 2ch open as input (CoreAudio process objects, macOS 14+; browsers likely show helpers) | — | —`), `specs/m9-product/ui-first-run/requirements.md` and `design.md` (Status → APPROVED 2026-11-17), `specs/m9-product/ui-redesign/roadmap.md` row 3 (`ui-first-run/` link).
- [ ] **Step 1: Edit** the files.
- [ ] **Step 2: Run** `just lint` → PASS.
- [ ] **Step 3: Commit** `docs: ui-first-run changelog, backlog UI-S1, spec approved`.

## Manual checklist (the user runs it before merge)

| # | Check | Expected |
|---|---|---|
| M1 | Fresh user (`tlk.setupCompleted` false), launch | Assistant opens on step 1 |
| M2 | Grant screen recording → "Reopen TranslateCall" | App relaunches on step 1 with both granted |
| M3 | Without BlackHole 2ch (or only 16ch) → step 2 | "not found" / "needs the 2-channel version"; installing + Check again → done |
| M4 | Step 3: pick Teams, "Open Teams", "I've done it" | Step marked done; main window shows Teams selected |
| M5 | Step 4 mic meter, speak | Meter moves; "We can hear you" |
| M6 | Route check | "BlackHole receives audio" |
| M7 | Route check with music playing into BlackHole | "Another app is sending audio…" |
| M8 | Rehearsal with the pair installed (and once with "Use my voice" on) | Preparing → say a sentence → "You said" / "Teams receives" ✓; Play plays it; no status panel, main window stays, menu bar dot none |
| M9 | Rehearsal with the pair missing | Box shows "Available once … is downloaded" |
| M10 | Close the window mid-rehearsal | Mic indicator off within 1 s; Start works afterwards |
| M11 | Start a call, open Settings › Run setup again → step 4 | "Available when no call is running" |
| M12 | Previous call's transcript after a rehearsal | Unchanged |
| M13 | Light and dark vs. frames; VoiceOver over step 4 | Matches; every state announced |
