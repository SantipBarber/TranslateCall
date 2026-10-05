# F8.5.3 — Half-duplex + VAD — Technical Design

> Status: DRAFT — pending user review (2026-10-05)
> Requirements: `requirements.md` (same folder)

## 1. Overview

Three changes, one goal ("every pause sends a sentence, nothing is lost"):

1. **Echo handling moves from the translation stage to the mic.** Suppression flags and `HalfDuplexManager` go away. In speakers mode only, a `MicEchoGate` turns the mic into silence while the remote side's translation is playing (+300 ms tail), before the VAD ever sees it. In headphones mode (default) nothing is muted at all.
2. **The TTS queue stops dropping.** It coalesces pending sentences to catch up and warns past 20 pending.
3. **The VAD becomes Silero with a user-tunable pause**, validated against FluidAudio's preconditions, with Energy as fallback.

```
Outgoing:  mic ─► AudioManager (SessionAudioStream, 16 kHz) ─► MicEchoGate ─► VAD ─► STT ─► translate ─► TTSPlaybackService ─► BlackHole
                                                                  ▲ mode, incomingSpeaking
Incoming:  SCStream (call app) ─► VAD ─► STT ─► translate ─► TTSPlaybackService ─► default output
                                                                  └── isSpeakingStream ──► AudioCoordinator ──┘
VAD:       VADProvider (preloads Silero at launch) ─► makeVAD(config) ─► SileroVADService | EnergyVADService
Settings:  ConversationSettings (UserDefaults): listeningMode, pauseSeconds
```

## 2. Files

```
TranslateCall/Core/Audio/ListeningMode.swift            NEW   .headphones / .speakers
TranslateCall/Core/Audio/MicEchoGate.swift              NEW   gate (stream transformer, injectable clock)
TranslateCall/Core/Audio/ConversationSettings.swift     NEW   @MainActor ObservableObject: listeningMode, pauseSeconds (UserDefaults)
TranslateCall/Core/Audio/ConversationState.swift        NEW   enum .listening / .speaking / .micPaused (replaces HalfDuplexState)
TranslateCall/Core/Audio/HalfDuplexManager.swift        DELETED
TranslateCall/Core/Audio/AudioCoordinator.swift         CHANGED  no suppression flags; gate + conversationState; async VAD factories
TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift CHANGED  gate in outgoing path; guards removed; incoming speaking → gate
TranslateCall/Core/VAD/VADService.swift                 CHANGED  nonisolated + Equatable VADConfiguration, pause default 0.6 s, Silero chunk compensation
TranslateCall/Core/VAD/VADConfiguration+Validation.swift NEW  validated(), sileroMinSilenceDuration
TranslateCall/Core/VAD/VADProvider.swift                NEW   preload Silero, make VAD with Energy fallback, activeEngine
TranslateCall/Core/VAD/VADServiceFactory.swift          DELETED
TranslateCall/Core/VAD/SileroVADService.swift           CHANGED  validated config
TranslateCall/Core/VAD/EnergyVADService.swift           CHANGED  validated config
TranslateCall/Core/TTS/TTSPlaybackService.swift         CHANGED  no drop, coalescing, backlog event
TranslateCall/Core/TTS/UtteranceSynthesizer.swift       CHANGED  TTSEvent: -utteranceDropped, +backlog(pending:)
TranslateCall/Core/TTS/TTSEvent+Notice.swift            CHANGED  backlog notice text
TranslateCall/App/AppContainer.swift                    CHANGED  VADProvider, ConversationSettings wiring
TranslateCall/Features/Main/AudioViewModel.swift        CHANGED  conversationState, settings, vad engine
TranslateCall/Features/Main/StatusBadgeView.swift       CHANGED  ConversationState
TranslateCall/Features/MenuBar/*                        CHANGED  ConversationState icon
TranslateCall/Features/ContentView.swift               CHANGED  settings row, hint, window height 760, monitor row moved to an extension (type length)
TranslateCall/Features/Main/ConversationSettingsView.swift NEW  speakers toggle, pause slider, VAD label, guide link
docs/usage-guide.md                                     NEW   Spanish usage guide (REQ-U-01)
TranslateCallTests/…                                    MicEchoGateTests (+ ConversationStateTests), ConversationSettingsTests, VADConfigurationValidationTests,
                                                        VADProviderTests, TTSPlaybackQueueTests, AudioCoordinatorEchoGateTests, ConversationSettingsViewTests,
                                                        AudioCoordinatorTTSTests updated; HalfDuplexManagerTests + MockHalfDuplexCoordinator deleted
TranslateCallTests/Integration/SileroSegmentationIntegrationTests.swift  NEW  Silero on spliced fixtures + echo gate (no new WAVs)
.opengrep/rules/swift-pipeline.{yml,swift}              NEW   no-capture-suppression (ERROR)
```

## 3. Components

### 3.1 `ListeningMode` and `ConversationSettings`

```swift
nonisolated enum ListeningMode: String, Sendable { case headphones, speakers }

@MainActor final class ConversationSettings: ObservableObject {
    @Published var listeningMode: ListeningMode          // key "conversation.listeningMode", default .headphones
    @Published var pauseSeconds: Double                  // key "conversation.pauseSeconds", default 0.6, clamped 0.4…1.2, step 0.1
    init(defaults: UserDefaults = .standard)
}
```

Same pattern as `AudioManager`/`SetupManager`: `UserDefaults` injected, a test suite per test. The coordinator observes `listeningMode` (Combine) and forwards it to the live gate. `pauseSeconds` is read at session start (REQ-V-05).

### 3.2 `MicEchoGate`

A `Sendable` final class. Its state sits behind `Mutex` (Synchronization): the stream consumer runs off the main actor, and setters are called from it.

```swift
nonisolated final class MicEchoGate: Sendable {
    init(mode: ListeningMode, tail: Duration = .milliseconds(300), clock: any Clock<Duration> = ContinuousClock(),
         onPausedChange: @escaping @Sendable (Bool) -> Void)
    func setMode(_ mode: ListeningMode)
    func setIncomingSpeaking(_ speaking: Bool)      // false → reopenAt = clock.now + tail
    func reset()                                    // speaking = false, reopenAt = nil (incoming torn down / session stop)
    func gate(_ input: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<AVAudioPCMBuffer>   // bounded buffering (.bufferingNewest(64))
}
```

Per buffer: `muting = mode == .speakers && (speaking || (reopenAt.map { now < $0 } ?? false))`. If muting, it yields a new `AVAudioPCMBuffer` of the same format and `frameLength`, zero-filled. Otherwise it yields the input buffer itself, with no copy (NFR-H-03). There is no timer: the tail is checked against the clock when each buffer arrives (buffers come every 10–100 ms). A transition of `muting` calls `onPausedChange`, which the coordinator hops to the main actor to update `conversationState`.

Placement: `startOutgoingPipeline` does `let gated = micEchoGate.gate(micStream)` and activates the VAD on `gated`. The gate lives as long as the session; mic hot swap (F8.5.1) keeps the same session stream, so nothing changes there. The incoming TTS `observeTTSState` callback calls `micEchoGate.setIncomingSpeaking(_:)`. Incoming teardown (`handleIncomingEvent`, `teardownIncomingServices`) and `stop()` call `reset()` (REQ-H-06).

Timing note: `TTSPlaybackService` sets speaking `true` when an attempt starts (before synthesis, so before any audio is heard). It sets it `false` only after `.dataPlayedBack` of the last buffer (F8.5.2). The gate therefore closes early and reopens `tail` after the last sample is rendered.

### 3.3 Coordinator: no suppression, `ConversationState`

- Removed: `HalfDuplexManager`, `halfDuplexManager`, `halfDuplexCancellable`, `halfDuplexTransitionDelay`, `outgoingCaptureSuppressed`, `incomingCaptureSuppressed`, the `HalfDuplexCoordinating` conformance (`suppressOutgoingCapture`/`suppressIncomingPipeline`), the two `!…Suppressed` guards.
- `@Published private(set) var conversationState: ConversationState` is derived from `isMicPaused`, `isOutgoingSpeaking` and `isIncomingSpeaking` (REQ-H-13). It is recomputed in a `didSet` on each input.
- `AudioViewModel` re-publishes `conversationState`. `StatusBadgeView` and `MenuBarController` switch on it: `.micPaused` gets its own label "Mic paused (speakers)" and a distinct color and icon.

### 3.4 `TTSPlaybackService` queue

- `TTSPlaybackLimits`: `maxPending` is removed. New fields: `backlogNoticeThreshold = 20` and `maxCoalescedCharacters = 400`.
- `speak` appends and never drops. If `queue.count == backlogNoticeThreshold` and `backlogNoticed == false`, it yields `.backlog(pending:)` and sets `backlogNoticed = true`. The flag resets when the count falls below the threshold.
- The worker's `queue.removeFirst()` becomes `takeNext()`. It pops the first utterance, then appends following ones while they share its locale and `joined.count + 1 + next.count ≤ maxCoalescedCharacters`. Everything downstream (fallback, watchdog, generation, metrics, `isSpeaking`) is unchanged and sees one utterance (REQ-Q-04).
- `TTSEvent.utteranceDropped` is removed. `.backlog(pending: Int)` is added, with notice text "Translation running behind — \(n) sentences waiting".

### 3.5 VAD: `VADProvider` and `VADConfiguration.validated()`

```swift
@MainActor final class VADProvider: ObservableObject {
    @Published private(set) var activeEngine: VADEngine?            // nil until the first session decides
    init(loadSilero: @escaping @Sendable (VADConfiguration) async throws -> any VADService = { try await SileroVADService(config: $0) })
    func preload()                                                  // background Task: one throwaway SileroVADService to download/compile the model
    func makeVAD(config: VADConfiguration) async -> any VADService  // Silero, else EnergyVADService(config:) + log; updates activeEngine
}
```

- The `AudioCoordinator` factories become `() async -> any VADService`. `AppContainer` passes `{ await vadProvider.makeVAD(config: settings.vadConfiguration) }` for both directions. `settings.vadConfiguration` is `VADConfiguration(minSilenceDuration: pauseSeconds).validated()`.
- The `preload()` failure is logged. While the preload is still running, `makeVAD` returns Energy at once instead of waiting. Once the model is ready each session loads Silero (cheap, it is cached). After a failed load (preload or per-session) `makeVAD` never awaits another load inline, which could hang Start on a download: it returns Energy at once and restarts the background load (one at a time), so a later session gets Silero when that succeeds (backlog A18). `AppContainer` skips the preload inside the test host.
- `validated()` clamps to the FluidAudio rules listed in REQ-V-06 (from `VadTypes.swift` preconditions and assertions). It logs one warning listing the clamped fields and never throws. It lives in `VADConfiguration+Validation.swift` (no FluidAudio import). Both services call it in `init`.
- Silero chunk compensation: FluidAudio analyses 4 096-sample (256 ms) chunks and starts counting silence only at the end of the first silent chunk, so it is given `sileroMinSilenceDuration = max(0, minSilenceDuration − 0.256 s)`. Measured while planning: p = 0.6 s → segment 716 ms after the end of speech (it was 0.75 s + one chunk before).
- `minSilenceDuration` default: 0.6. Other defaults are unchanged (`minSpeech` 0.15, `maxSpeech` 14, padding 0.1, threshold 0.85). The Silero threshold is re-checked in the integration tier (risk §6).

### 3.6 UI and guide

`ConversationSettingsView` sits in the main window next to the Monitor row and contains:
- the "I use speakers" toggle;
- the "Pause to translate" slider (0.4–1.2 s), with the caption "Applies to the next session" while capturing;
- the label "VAD: Silero | Energy";
- the link "Usage guide", which opens `docs/usage-guide.md` on GitHub (main branch). Bundling it would need a project-file change outside the synchronized folder.

A one-line hint "Pause briefly after each sentence to send it" sits under the capture button.

## 4. Error handling summary

| Situation | Behaviour |
|-----------|-----------|
| Silero model fails to load | Energy is used for that session. The reason is logged. The UI shows "VAD: Energy". The next session starts a background retry (and still gets Energy); the session after a successful retry gets Silero. |
| Inconsistent VAD values | `validated()` clamps them and logs a warning; there is no crash (T3). |
| Incoming stops mid-session while muting | `reset()` reopens the gate. The state returns to `.listening`/`.speaking`. |
| Backlog ≥ 20 | One notice is shown. Sentences keep queuing and are coalesced. Nothing is dropped. |
| Coalesced utterance fails on Edge | The F8.5.2 per-utterance fallback applies to the whole coalesced text. |
| Speakers mode, user talks over the incoming translation | That speech is not captured, by design (D-3). The UI shows "Mic paused (speakers)". |

## 5. Testing

### 5.1 Fakes and helpers
`TestClock` (from F8.5.2) is reused for the gate. `MockVADService` records the peak of every buffer it receives. `FakeSynthesizer`/`FakeOutput` (F8.5.2) are reused for queue tests. A stub Silero loader that throws is used for `VADProvider`.

### 5.2 Unit tests

| Suite | Pins |
|-------|------|
| `MicEchoGateTests` | `headphonesPassThrough` (same buffer instances); `speakersMutesWhileIncoming` (zeros, same format/frameLength); `tailKeepsMutedThenReopens` (TestClock: 299 ms muted, 300 ms open); `switchToHeadphonesReopens`; `resetReopens`; `pausedChangeReportedOnTransitions`; `neverDropsOrReorders` (count + order). |
| `TTSPlaybackServiceTests` (+ queue suite) | `neverDropsPastOldCap` (25 sentences → all spoken text present, in order); `coalescesPendingSameLocale`; `coalescingRespectsCharacterLimit`; `differentLocaleNotCoalesced`; `backlogNoticeOnceUntilDrained`; removal of `utteranceDropped` cases. |
| `AudioCoordinatorTTSTests` | `incomingTranslatedWhileOutgoingSpeaks` (replaces `incomingDroppedWhileSuppressed`); `outgoingTranslatedWhileIncomingSpeaks`; `muteTurnStillSkipsOne`. |
| `AudioCoordinatorTests` | `conversationStateDerivation` (all input combinations); `speakersModeGatesOutgoingVADInput` (FakeVAD sees zeros while incoming speaking); `gateResetOnIncomingStop`. |
| `VADConfigurationTests` | Each REQ-V-06 rule is clamped. Valid configurations are unchanged. `pauseSeconds` maps to `minSilenceDuration` and is clamped to 0.4–1.2. |
| `VADProviderTests` | `fallsBackToEnergyWhenSileroFails` (activeEngine == .energy); `usesSileroWhenLoaderSucceeds`. |
| `ConversationSettingsTests` | Defaults and persistence round-trip with a test `UserDefaults` suite. |

`HalfDuplexManagerTests` is deleted with the type. Any test asserting `halfDuplexState` migrates to `conversationState`.

### 5.3 Integration tier (`just test-integration`, Mac mini)
- `VADSegmentationIntegrationTests` (real Silero, fixtures generated by `just fixtures`):
  - two sentences with a 1.0 s gap give 2 segments (p = 0.6 s);
  - a 0.3 s micro-pause gives 1 segment;
  - emission time is between p − 0.35 s and p + 0.5 s after the end of speech (NFR-H-01), measured on the audio timeline (buffers are fed at real-time pace) and recorded in `latency.json`.
- `EchoGateIntegrationTests`: a speech fixture goes through `MicEchoGate` (speakers mode) and Silero, with `setIncomingSpeaking(true/false)` around the middle sentence. Only the first and last sentences produce segments.
- No new fixtures: the tests splice existing single-sentence WAVs (`es-meeting`, `en-budget`, `en-hear`, trimmed of their silence) with generated silence, so the manifest-driven STT suites are unaffected.

### 5.4 Manual checklist (tasks.md)
- **M1** Headphones, cross-talk using a browser as the capture app: no sentence lost in either direction.
- **M2** Speakers mode, solo procedure: no echo loop, and "Mic paused (speakers)" is shown.
- **M3** Pause at 0.4, 0.6 and 1.2 s: sentences are sent at clear pauses and not at micro-pauses.
- **M4** Long monologue: coalescing catches up and no content is missing.
- **M5** The VAD label shows Silero, or Energy when the model is blocked.
- **M6** Re-run F8.5.2 M1 and M6, and F8.5.1 M1–M6, with the solo procedure. Record the results in each spec.

### 5.5 Static analysis
A new opengrep rule `no-capture-suppression` (regex, ERROR) flags `CaptureSuppressed` and `HalfDuplexManager` anywhere under `TranslateCall/`, so the drop-based design cannot come back. The `MicEchoGate` stream declares an explicit buffering policy (`asyncstream-unbounded`).

## 6. Risks

| Risk | Mitigation |
|------|------------|
| Bluetooth speakers add 150–250 ms of output latency after `.dataPlayedBack`, so a 300 ms tail may be short. | The tail is injectable. Manual M2 checks it with real speakers. If echo still leaks, raise the tail or add the device's reported output latency (`kAudioDevicePropertyLatency`, read-only, which is safe per audio-engine lessons) in a follow-up. |
| Silero threshold 0.85 misses quiet speech or call-codec audio. | The integration fixtures include incoming-style audio. Tune the threshold there, and record it as a decision if it changes. |
| Silero init per session is slow on the first run (model download). | `preload()` runs at launch. The first session uses Energy if Silero is not ready yet, and the UI shows it. |
| Coalescing produces long utterances on slow engines (Qwen). | The 400-character cap, plus the F8.5.2 watchdog and fallback. |
| Removing suppression lets echo through with speakers when the user forgot the toggle. | The usage guide and hint. Automatic detection is a later milestone (D-2). |
