# F8.5.3 Half-duplex + VAD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No sentence is ever lost, and each pause the speaker makes sends a sentence at once (simultaneous-interpretation feel). Headphones are the default; an opt-in "I use speakers" mode keeps the remote translation out of the mic.

**Architecture:** Suppression at the translation stage (`HalfDuplexManager`, `outgoingCaptureSuppressed`, `incomingCaptureSuppressed`) is deleted. In speakers mode only, a `MicEchoGate` between the session audio stream and the outgoing VAD turns mic buffers into silence while incoming TTS plays (plus a 300 ms tail), so echo never reaches VAD/STT. `TTSPlaybackService` stops dropping: it coalesces the sentences that queued up into one utterance (≤ 400 characters) and reports a backlog at 20. Both directions use Silero VAD (via a `VADProvider` that preloads the model and falls back to Energy), with a user-tunable, validated pause (default 0.6 s).

**Tech Stack:** Swift 6 (app target: default MainActor isolation + approachable concurrency), AVFoundation, FluidAudio (Silero VAD, CoreML), `Synchronization.Mutex`, Combine, SwiftUI, Swift Testing, `just`, opengrep, SwiftLint.

**Spec:** `specs/m8.5-stabilization/f8.5.3-half-duplex-vad/requirements.md`, `specs/m8.5-stabilization/f8.5.3-half-duplex-vad/design.md`

## Global Constraints

- Branch `feat/f8.5.3-half-duplex-vad`, created from `spec/f8.5.3-half-duplex-vad`: spec and code ship in one PR (F8.5.1/F8.5.2 practice). Never commit to `main`; `just pr` must pass before the PR. Execution: subagent-driven (chosen by the user).
- Commits: Conventional Commits; end every message with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```
- `SWIFT_VERSION = 6.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`. The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `MemberImportVisibility`: every type used off the main actor is declared `nonisolated` (`nonisolated enum/struct/final class …`); a test file that touches a Foundation member imports Foundation. The test target has no default isolation.
- New files are picked up automatically (`PBXFileSystemSynchronizedRootGroup`): never edit `project.pbxproj`.
- Streams in app code: `AsyncStream.makeStream(of:bufferingPolicy:)` with an explicit **bounded** policy (opengrep `asyncstream-unbounded` is ERROR in `Core/Audio`). No `cont!`.
- Unit tests: no network, no real ML model (Silero/CoreML, Kokoro, Qwen/MLX), no audio device. No fixed sleeps: `waitUntil` (`TranslateCallTests/Support/AsyncTestHelpers.swift`) or move a `TestClock`. A negative check uses a bounded `waitUntil` and says so in a comment. The app must not warm any model inside the test host (`AppContainer.isTestHost`).
- Audio safety (F8.5.1 lesson): never write a HAL/AU property; this feature touches no device code.
- UI strings are English like the rest of the app; the usage guide is Spanish (P1).
- Run one unit suite: `just test-only <SuiteTypeName> […]` (the Swift `struct` name; nested integration suites are not reachable this way). Unit tier: `just test`. Integration tier: `just test-integration`. Lint (strict): `just lint`. Static analysis: `just scan`. `just pr` is the gate (clean tree; publishes `local/just-pr` on HEAD).
- SwiftLint (app target only): lines ≤ 120, function bodies ≤ 50 lines, type bodies ≤ 250 lines (extensions in the same file do not count), no force unwraps, identifiers ≥ 3 characters.

## Review Focus

- **The user switches "I use speakers" off while the remote translation is playing** → the mic reopens at once, not at the end of the translation (pinned in Task 3 `switchToHeadphonesReopens`, Task 6 `listeningModeAppliesLive`).
- **The call app quits (or its stream errors) while its translation plays in speakers mode** → the mic must not stay muted for the rest of the session (pinned in Task 3 `resetReopens`, Task 6 `gateResetOnIncomingStop`).
- **A spurious "not speaking" report from incoming TTS** (it was not speaking; e.g. on teardown) → must not mute the mic for 300 ms in speakers mode (pinned in Task 3 `falseWithoutTrueDoesNotMute`).
- **The language pair is swapped mid-session with sentences still queued, or one translated sentence is longer than the coalescing limit** → never merged across locales; a long sentence is spoken whole (pinned in Task 4 `differentLocaleNotCoalesced`, `coalescingRespectsCharacterLimit`).
- **First launch offline / Silero model not downloaded yet** → the session starts at once on Energy instead of waiting, and the next session retries Silero (pinned in Task 5 `energyWhileWarming`, `fallsBackToEnergyWhenSileroFails`).

## Decisions made while planning (spec ambiguities resolved)

| # | Point | Choice |
|---|-------|--------|
| P1 | UI language | The whole app UI is English (notices, buttons, badge). New UI strings are English ("I use speakers", "Pause to translate", "Mic paused (speakers)", "Translation running behind — N sentences waiting", "Pause briefly after each sentence to send it"); the usage guide is Spanish. requirements.md (REQ-U-03 added) and design.md updated. |
| P2 | Silero chunking vs. the pause | FluidAudio's `VadManager` analyses 4 096-sample (256 ms) chunks and only starts counting silence at the end of the first silent chunk. Passing the pause unchanged waited `p` + one chunk (+ alignment). `VADConfiguration.sileroMinSilenceDuration = max(0, p − 0.256 s)` is passed instead. Measured while planning (real Silero, spliced fixtures, real-time feed): p = 0.6 s → segment 716 ms after the end of speech, stable over 3 runs; a 0.3 s micro-pause does not split. NFR-H-01 is set to `p − 0.35 s … p + 0.5 s` (was p + 150 ms, unreachable with 256 ms chunks); the split test uses a 1.0 s gap (0.7 s is not guaranteed to contain 3 silent chunks). |
| P3 | Silero threshold | Kept at 0.85: the spliced `say` fixtures segment correctly with it (verified while planning). |
| P4 | Integration fixtures | No new WAVs: tests splice existing single-sentence fixtures (`es-meeting`, `en-budget`, `en-hear`, trimmed) with generated silence. Adding WAVs to `manifest.json` would also feed them to every manifest-driven STT suite. `FileAudioSource.decode16kMono` becomes internal for this. |
| P5 | Guide link | Opens `docs/usage-guide.md` on GitHub (`main`). Bundling a resource needs a project-file change outside the synchronized `TranslateCall/` folder. |
| P6 | `VADProvider` warm-up | `preload()` runs in the background at launch (not in the test host). While it is still loading, `makeVAD` hands out Energy at once (no wait); after it finished (either way), every `makeVAD` tries Silero, and a failure falls back to Energy for that session. |
| P7 | Coalescing in the F8.5.2 suites | Those tests count utterances one by one, so `TTSPlaybackHarness` defaults to `TTSPlaybackLimits.uncoalesced` (coalescing off); the new queue suite passes explicit limits. |
| P8 | Gate state → UI | The gate reports muting transitions on the consumer's thread; the coordinator hops to the main actor and ignores a report from a finished session (`sessionGeneration`). Incoming teardown and `stop()` call `reset()` (reopen without the tail). |
| P9 | Icons | Badge: listening `mic`, speaking `speaker.wave.2` (blue), mic paused `mic.slash` (yellow). Menu bar: `mic` / `waveform` / `mic.slash.circle`; idle stays `mic.slash`. |
| P10 | Window height | 680 → 760 pt for the two new rows and the hint (the window is fixed-size). |

## File Structure

```
TranslateCall/Core/VAD/
  VADService.swift                    MOD  T1  nonisolated + Equatable VADConfiguration, pause 0.6 s, Silero chunk compensation
  VADConfiguration+Validation.swift   NEW  T1  validated(), sileroChunkDuration, sileroMinSilenceDuration
  EnergyVADService.swift              MOD  T1  validated config
  SileroVADService.swift              MOD  T1  validated config
  VADProvider.swift                   NEW  T5  preload, Silero-or-Energy, activeEngine
  VADServiceFactory.swift             DEL  T5
TranslateCall/Core/Audio/
  ListeningMode.swift                 NEW  T2
  ConversationSettings.swift          NEW  T2  listeningMode, pauseSeconds (UserDefaults), vadConfiguration
  MicEchoGate.swift                   NEW  T3
  ConversationState.swift             NEW  T3
  AudioCoordinator.swift              MOD  T5 async VAD factories; T6 gate, conversation state, no suppression
  AudioCoordinator+Pipeline.swift     MOD  T5 await factories; T6 gate in outgoing path, guards removed, reopen on incoming stop
  HalfDuplexManager.swift             DEL  T6
TranslateCall/Core/TTS/
  UtteranceSynthesizer.swift          MOD  T4  TTSEvent: −utteranceDropped, +backlog(pending:)
  TTSEvent+Notice.swift               MOD  T4
  TTSPlaybackService.swift            MOD  T4  no drop, coalescing, backlog notice
TranslateCall/App/AppContainer.swift  MOD  T5  ConversationSettings, VADProvider (preload outside the test host)
TranslateCall/Features/Main/
  AudioViewModel.swift                MOD  T5 settings + provider; T6 conversationState, listeningMode binding
  StatusBadgeView.swift               MOD  T6  ConversationState + presentation()
  ConversationSettingsView.swift      NEW  T7
TranslateCall/Features/MenuBar/{MenuBarController,MenuBarPopoverView}.swift   MOD T6
TranslateCall/Features/ContentView.swift                                       MOD T6 (rename), T7 (settings row, hint, height)
docs/usage-guide.md                   NEW  T7 (Spanish)
docs/ARCHITECTURE.md, docs/COMPATIBILITY_MATRIX.md                             MOD T10
TranslateCallTests/
  VADConfigurationValidationTests.swift, VADServiceTests.swift                 NEW/MOD T1
  ConversationSettingsTests.swift                                              NEW T2
  MicEchoGateTests.swift (+ ConversationStateTests)                            NEW T3
  TTSPlaybackQueueTests.swift; TTSPlaybackServiceTests.swift; Support/TTSPlaybackHarness.swift; AudioCoordinatorTTSTests.swift   NEW/MOD T4
  VADProviderTests.swift; Mocks/MockVADService.swift                           NEW/MOD T5 (engine), T6 (peaks)
  AudioCoordinatorEchoGateTests.swift; AudioCoordinatorTTSTests.swift          NEW/MOD T6
  HalfDuplexManagerTests.swift, Mocks/MockHalfDuplexCoordinator.swift          DEL T6
  ConversationSettingsViewTests.swift                                          NEW T7
  Integration/SileroSegmentationIntegrationTests.swift; Support/FileAudioSource.swift   NEW/MOD T8
.opengrep/rules/swift-pipeline.{yml,swift}, .opengrep/README.md                NEW/MOD T9
specs/m8.5-stabilization/backlog.md, this file                                 MOD T10
```

Dependency order: T1 → T2 → T3 → T4 → T5 → T6 → T7 → T8 → T9 → T10 (T4 only needs T1; T8 needs T3).

Everything below was implemented and run on a throwaway copy of the repo while planning: `build-for-testing` succeeded, the full unit tier passed (545 tests), `swiftlint --strict` was clean, the three Silero integration tests passed 3 times, and the opengrep rule tests and ERROR scan passed.

---

### Task 1: `VADConfiguration` — validated, 0.6 s pause, Silero chunk compensation (T3, D-6, P2)

**Files:**
- Modify: `TranslateCall/Core/VAD/VADService.swift:28-58`
- Create: `TranslateCall/Core/VAD/VADConfiguration+Validation.swift`
- Modify: `TranslateCall/Core/VAD/EnergyVADService.swift:39-40`, `TranslateCall/Core/VAD/SileroVADService.swift:42-44`
- Modify: `TranslateCallTests/VADServiceTests.swift:18`
- Test: `TranslateCallTests/VADConfigurationValidationTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `nonisolated struct VADConfiguration: Sendable, Equatable` (same fields; `minSilenceDuration` default `0.6`)
  - `nonisolated func validated() -> VADConfiguration`
  - `nonisolated static let sileroChunkDuration: TimeInterval` (0.256), `nonisolated static let minimumMaxSpeechDuration: TimeInterval` (0.1)
  - `nonisolated var sileroMinSilenceDuration: TimeInterval`
  - Both VAD services store `config.validated()`.

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/VADConfigurationValidationTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

@Suite("VADConfiguration validation (T3)")
struct VADConfigurationValidationTests {

    @Test("a valid configuration is returned unchanged")
    func validUnchanged() {
        #expect(VADConfiguration().validated() == VADConfiguration())
        var config = VADConfiguration()
        config.minSilenceDuration = 1.2
        config.sileroThreshold = 0.5
        #expect(config.validated() == config)
    }

    @Test("the default pause is 0.6 s (D-6)")
    func defaultPause() {
        #expect(VADConfiguration.default.minSilenceDuration == 0.6)
    }

    @Test("negative durations become 0, and maxSpeechDuration stays positive")
    func negativesClamped() {
        var config = VADConfiguration()
        config.minSpeechDuration = -1
        config.minSilenceDuration = -0.5
        config.speechPadding = -0.1
        config.maxSpeechDuration = 0
        let fixed = config.validated()
        #expect(fixed.minSpeechDuration == 0)
        #expect(fixed.minSilenceDuration == 0)
        #expect(fixed.speechPadding == 0)
        #expect(fixed.maxSpeechDuration == VADConfiguration.minimumMaxSpeechDuration)
    }

    @Test("minSpeech and minSilence never exceed maxSpeech; padding never exceeds minSpeech")
    func orderingClamped() {
        var config = VADConfiguration()
        config.maxSpeechDuration = 0.5
        config.minSpeechDuration = 0.8
        config.minSilenceDuration = 0.9
        config.speechPadding = 0.7
        let fixed = config.validated()
        #expect(fixed.minSpeechDuration == 0.5)
        #expect(fixed.minSilenceDuration == 0.5)
        #expect(fixed.speechPadding == 0.5)

        var padded = VADConfiguration()
        padded.speechPadding = 0.3   // > minSpeechDuration 0.15
        #expect(padded.validated().speechPadding == 0.15)
    }

    @Test("thresholds are clamped and non-finite values fall back to the defaults")
    func thresholdsAndNonFinite() {
        var config = VADConfiguration()
        config.sileroThreshold = 1.5
        config.energyThresholdDBFS = 6
        #expect(config.validated().sileroThreshold == 1)
        #expect(config.validated().energyThresholdDBFS == 0)
        config.sileroThreshold = -0.2
        #expect(config.validated().sileroThreshold == 0)
        config.sileroThreshold = .nan
        config.minSilenceDuration = .infinity
        #expect(config.validated().sileroThreshold == VADConfiguration().sileroThreshold)
        #expect(config.validated().minSilenceDuration == VADConfiguration().minSilenceDuration)
    }

    @Test("Silero is asked for one 256 ms chunk less silence than the configured pause (P2)")
    func sileroSilenceCompensation() {
        var config = VADConfiguration()
        config.minSilenceDuration = 0.6
        #expect(abs(config.sileroMinSilenceDuration - (0.6 - 0.256)) < 1e-9)
        config.minSilenceDuration = 0.2
        #expect(config.sileroMinSilenceDuration == 0)
    }
}
```

In `TranslateCallTests/VADServiceTests.swift`, `VADConfigurationTests.defaultValues`, replace:
```swift
        #expect(config.minSilenceDuration == 0.75)
```
with:
```swift
        #expect(config.minSilenceDuration == 0.6)
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `just test-only VADConfigurationValidationTests VADConfigurationTests`
Expected: build FAILS (`validated()`, `sileroMinSilenceDuration`, `minimumMaxSpeechDuration` not found; `VADConfiguration` not `Equatable`).

- [ ] **Step 3: Implement**

`TranslateCall/Core/VAD/VADService.swift`: replace
```swift
struct VADConfiguration: Sendable {
```
with
```swift
nonisolated struct VADConfiguration: Sendable, Equatable {
```
replace
```swift
    /// Minimum silence duration before an utterance is closed.
    var minSilenceDuration: TimeInterval = 0.75
```
with
```swift
    /// Pause that closes an utterance ("Pause to translate", F8.5.3 D-6: 0.4–1.2 s, default 0.6 s).
    var minSilenceDuration: TimeInterval = 0.6
```
and in `fluidSegmentationConfig` replace
```swift
            minSilenceDuration: minSilenceDuration,
```
with
```swift
            minSilenceDuration: sileroMinSilenceDuration,   // one chunk less: see the property (F8.5.3 P2)
```

Create `TranslateCall/Core/VAD/VADConfiguration+Validation.swift`:
```swift
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "VADConfiguration")

// MARK: - Validation (F8.5.3 REQ-V-06, T3)

extension VADConfiguration {
    /// Seconds of audio Silero (FluidAudio `VadManager`) analyses per inference: 4 096 samples at 16 kHz.
    nonisolated static let sileroChunkDuration: TimeInterval = 4_096.0 / 16_000

    /// Shortest `maxSpeechDuration` accepted; FluidAudio needs it > 0.
    nonisolated static let minimumMaxSpeechDuration: TimeInterval = 0.1

    /// The silence FluidAudio is asked for. Its streaming state machine starts counting silence at the
    /// end of the first silent chunk, so the pause is reached one chunk earlier than configured: give it
    /// one chunk less, so the user's pause is honoured to within one chunk (F8.5.3 P2).
    nonisolated var sileroMinSilenceDuration: TimeInterval {
        max(0, minSilenceDuration - Self.sileroChunkDuration)
    }

    /// A copy that satisfies every FluidAudio precondition and assertion (`VadSegmentationConfig.init`):
    /// durations ≥ 0, `maxSpeechDuration` > 0, `minSpeechDuration` ≤ `maxSpeechDuration`,
    /// `minSilenceDuration` ≤ `maxSpeechDuration`, `speechPadding` ≤ `minSpeechDuration`, threshold in
    /// [0, 1]. Out-of-range or non-finite values are clamped (non-finite → the default, then clamped)
    /// and logged once. Never throws.
    nonisolated func validated() -> VADConfiguration {
        let defaults = VADConfiguration()
        var fixed = self
        var notes: [String] = []

        func clamp(_ name: String, _ value: Double, _ range: ClosedRange<Double>, default fallback: Double) -> Double {
            let start = value.isFinite ? value : fallback
            let result = min(max(start, range.lowerBound), range.upperBound)
            if result != value { notes.append("\(name) \(value) → \(result)") }
            return result
        }

        fixed.maxSpeechDuration = clamp("maxSpeechDuration", maxSpeechDuration,
                                        Self.minimumMaxSpeechDuration...(24 * 3_600),
                                        default: defaults.maxSpeechDuration)
        fixed.minSpeechDuration = clamp("minSpeechDuration", minSpeechDuration, 0...fixed.maxSpeechDuration,
                                        default: defaults.minSpeechDuration)
        fixed.minSilenceDuration = clamp("minSilenceDuration", minSilenceDuration, 0...fixed.maxSpeechDuration,
                                         default: defaults.minSilenceDuration)
        fixed.speechPadding = clamp("speechPadding", speechPadding, 0...fixed.minSpeechDuration,
                                    default: defaults.speechPadding)
        fixed.sileroThreshold = Float(clamp("sileroThreshold", Double(sileroThreshold), 0...1,
                                            default: Double(defaults.sileroThreshold)))
        fixed.energyThresholdDBFS = Float(clamp("energyThresholdDBFS", Double(energyThresholdDBFS), -160...0,
                                                default: Double(defaults.energyThresholdDBFS)))

        if !notes.isEmpty {
            logger.warning("VAD configuration clamped: \(notes.joined(separator: "; "), privacy: .public)")
        }
        return fixed
    }
}
```

`TranslateCall/Core/VAD/EnergyVADService.swift`, in `init(config:)` replace
```swift
        self.config = config
```
with
```swift
        self.config = config.validated()
```

`TranslateCall/Core/VAD/SileroVADService.swift`, in `init(config:)` replace
```swift
        self.config = config
        self.historyCapacity = Int(config.speechPadding * 16_000) + VadManager.chunkSize + 512
```
with
```swift
        let config = config.validated()   // FluidAudio traps on inconsistent values (T3)
        self.config = config
        self.historyCapacity = Int(config.speechPadding * 16_000) + VadManager.chunkSize + 512
```
(The rest of the init, `VadManager(config: config.fluidVadConfig)`, now reads the validated copy.)

- [ ] **Step 4: Run the tests**

Run: `just test-only VADConfigurationValidationTests VADConfigurationTests EnergyVADServiceTests MakePCMBufferTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/VAD TranslateCallTests/VADConfigurationValidationTests.swift TranslateCallTests/VADServiceTests.swift
git commit -m "fix(vad): validate VADConfiguration against FluidAudio's preconditions; 0.6 s pause; Silero chunk compensation (F8.5.3 T3)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `ListeningMode` and `ConversationSettings` (REQ-H-01, REQ-V-05)

**Files:**
- Create: `TranslateCall/Core/Audio/ListeningMode.swift`, `TranslateCall/Core/Audio/ConversationSettings.swift`
- Test: `TranslateCallTests/ConversationSettingsTests.swift`

**Interfaces:**
- Consumes: `VADConfiguration.validated()` (Task 1).
- Produces:
  - `nonisolated enum ListeningMode: String, Sendable, CaseIterable { case headphones, speakers }`
  - `@MainActor final class ConversationSettings: ObservableObject` — `init(defaults: UserDefaults = .standard)`, `@Published var listeningMode: ListeningMode`, `@Published var pauseSeconds: Double`, `var vadConfiguration: VADConfiguration`, `nonisolated static let listeningModeKey`, `pauseSecondsKey`, `pauseRange: ClosedRange<Double>` (0.4…1.2), `pauseStep` (0.1), `defaultPauseSeconds` (0.6), `nonisolated static func clampedPause(_:) -> Double`

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/ConversationSettingsTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

/// A throwaway `UserDefaults` suite, removed by `clear()`.
private struct TestDefaults {
    let name = "ConversationSettingsTests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name) ?? .standard }
    func clear() { UserDefaults().removePersistentDomain(forName: name) }
}

@Suite("ConversationSettings") @MainActor
struct ConversationSettingsTests {

    @Test("defaults: headphones and a 0.6 s pause (D-2, D-6)")
    func defaults() {
        let store = TestDefaults()
        defer { store.clear() }
        let settings = ConversationSettings(defaults: store.defaults)
        #expect(settings.listeningMode == .headphones)
        #expect(settings.pauseSeconds == 0.6)
        #expect(settings.vadConfiguration.minSilenceDuration == 0.6)
    }

    @Test("both settings survive a relaunch (REQ-H-01, REQ-V-05)")
    func persistence() {
        let store = TestDefaults()
        defer { store.clear() }
        let first = ConversationSettings(defaults: store.defaults)
        first.listeningMode = .speakers
        first.pauseSeconds = 0.9

        let second = ConversationSettings(defaults: store.defaults)
        #expect(second.listeningMode == .speakers)
        #expect(abs(second.pauseSeconds - 0.9) < 1e-9)
        #expect(abs(second.vadConfiguration.minSilenceDuration - 0.9) < 1e-9)
    }

    @Test("the pause is clamped to 0.4–1.2 s and rounded to 0.1 s")
    func pauseClamped() {
        let store = TestDefaults()
        defer { store.clear() }
        let settings = ConversationSettings(defaults: store.defaults)
        settings.pauseSeconds = 2
        #expect(settings.pauseSeconds == 1.2)
        settings.pauseSeconds = 0.05
        #expect(settings.pauseSeconds == 0.4)
        settings.pauseSeconds = 0.66
        #expect(abs(settings.pauseSeconds - 0.7) < 1e-9)
        settings.pauseSeconds = .nan
        #expect(settings.pauseSeconds == 0.6)
    }

    @Test("corrupt stored values fall back to the defaults")
    func corruptStoredValues() {
        let store = TestDefaults()
        defer { store.clear() }
        store.defaults.set("loud", forKey: ConversationSettings.listeningModeKey)
        store.defaults.set(9.0, forKey: ConversationSettings.pauseSecondsKey)
        let settings = ConversationSettings(defaults: store.defaults)
        #expect(settings.listeningMode == .headphones)
        #expect(settings.pauseSeconds == 1.2)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `just test-only ConversationSettingsTests`
Expected: build FAILS (`ConversationSettings` not found).

- [ ] **Step 3: Implement**

`TranslateCall/Core/Audio/ListeningMode.swift`:
```swift
// MARK: - ListeningMode

/// How the user hears the translated voice (F8.5.3 D-2). Persisted by `ConversationSettings`.
nonisolated enum ListeningMode: String, Sendable, CaseIterable {
    /// The mic cannot hear the translation: nothing is ever muted (default, recommended).
    case headphones
    /// The mic hears the remote side's translation: `MicEchoGate` mutes it while it plays.
    case speakers
}
```

`TranslateCall/Core/Audio/ConversationSettings.swift`:
```swift
import Combine
import Foundation

/// The user's conversation settings (F8.5.3 REQ-H-01, REQ-V-05), persisted in `UserDefaults`.
///
/// `listeningMode` is applied live (the coordinator forwards it to the mic echo gate);
/// `pauseSeconds` is read when a session starts (the VAD fixes its configuration on activation).
@MainActor
final class ConversationSettings: ObservableObject {
    nonisolated static let listeningModeKey = "conversation.listeningMode"
    nonisolated static let pauseSecondsKey = "conversation.pauseSeconds"
    nonisolated static let pauseRange: ClosedRange<Double> = 0.4...1.2
    /// Slider step: tenths of a second.
    nonisolated static let pauseStep = 0.1
    nonisolated static let defaultPauseSeconds = 0.6

    @Published var listeningMode: ListeningMode {
        didSet { defaults.set(listeningMode.rawValue, forKey: Self.listeningModeKey) }
    }

    /// "Pause to translate", in seconds: clamped to `pauseRange` and rounded to `pauseStep`.
    @Published var pauseSeconds: Double {
        didSet {
            let clamped = Self.clampedPause(pauseSeconds)
            if clamped != pauseSeconds {
                pauseSeconds = clamped   // re-assignment inside didSet does not call didSet again
            }
            defaults.set(pauseSeconds, forKey: Self.pauseSecondsKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        listeningMode = defaults.string(forKey: Self.listeningModeKey).flatMap(ListeningMode.init(rawValue:))
            ?? .headphones
        pauseSeconds = (defaults.object(forKey: Self.pauseSecondsKey) as? Double).map(Self.clampedPause)
            ?? Self.defaultPauseSeconds
    }

    /// The VAD configuration for the next session (REQ-V-05), already validated (REQ-V-06).
    var vadConfiguration: VADConfiguration {
        var config = VADConfiguration()
        config.minSilenceDuration = pauseSeconds
        return config.validated()
    }

    nonisolated static func clampedPause(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultPauseSeconds }
        let clamped = min(max(seconds, pauseRange.lowerBound), pauseRange.upperBound)
        return (clamped * 10).rounded() / 10   // tenths, without 0.1's binary rounding error
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `just test-only ConversationSettingsTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/Audio/ListeningMode.swift TranslateCall/Core/Audio/ConversationSettings.swift TranslateCallTests/ConversationSettingsTests.swift
git commit -m "feat(audio): ConversationSettings — listening mode and pause to translate, persisted (F8.5.3 REQ-H-01, REQ-V-05)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `MicEchoGate` and `ConversationState` (REQ-H-02…07, REQ-H-13)

**Files:**
- Create: `TranslateCall/Core/Audio/MicEchoGate.swift`, `TranslateCall/Core/Audio/ConversationState.swift`
- Test: `TranslateCallTests/MicEchoGateTests.swift` (suites `MicEchoGateTests`, `ConversationStateTests`)

**Interfaces:**
- Consumes: `ListeningMode` (Task 2); `SessionAudioStream.capacity` (64); test support `TestClock`, `LockedArray` (`Support/TTSFakes.swift`), `makePCMBuffer(frames:sampleRate:fill:)`.
- Produces:
  - `nonisolated final class MicEchoGate: Sendable` — `init(mode: ListeningMode, tail: Duration = .milliseconds(300), clock: any Clock<Duration> = ContinuousClock(), onPausedChange: @escaping @Sendable (Bool) -> Void = { _ in })`, `var isMicPaused: Bool`, `func setMode(_:)`, `func setIncomingSpeaking(_:)`, `func reset()`, `func gate(_ input: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<AVAudioPCMBuffer>`, `func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer`, `static func silence(like:) -> AVAudioPCMBuffer?`
  - `nonisolated enum ConversationState: Equatable, Sendable { case listening, speaking, micPaused; static func derive(micPaused:outgoingSpeaking:incomingSpeaking:) -> ConversationState }`

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/MicEchoGateTests.swift`:
```swift
import AVFoundation
import Testing
@testable import TranslateCall

private func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
    guard let data = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
}

@Suite("MicEchoGate")
struct MicEchoGateTests {

    @Test("headphones: every buffer passes through untouched, even while incoming speaks (REQ-H-02)")
    func headphonesPassThrough() {
        let gate = MicEchoGate(mode: .headphones, clock: TestClock())
        gate.setIncomingSpeaking(true)
        let buffer = makePCMBuffer(frames: 1_024, fill: 0.5)
        #expect(gate.process(buffer) === buffer)
        #expect(!gate.isMicPaused)
    }

    @Test("speakers: while incoming speaks a buffer becomes zeros of the same format and length (REQ-H-03/04)")
    func speakersMutesWhileIncoming() {
        let gate = MicEchoGate(mode: .speakers, clock: TestClock())
        gate.setIncomingSpeaking(true)
        let buffer = makePCMBuffer(frames: 1_024, fill: 0.5)

        let out = gate.process(buffer)

        #expect(out !== buffer)
        #expect(out.format == buffer.format)
        #expect(out.frameLength == buffer.frameLength)
        #expect(samples(of: out).allSatisfy { $0 == 0 })
        #expect(samples(of: buffer).allSatisfy { $0 == 0.5 }, "the captured buffer must not be modified")
        #expect(gate.isMicPaused)
    }

    @Test("speakers: muted for the 300 ms tail after incoming stops, open from then on (REQ-H-03/07)")
    func tailKeepsMutedThenReopens() {
        let clock = TestClock()
        let gate = MicEchoGate(mode: .speakers, clock: clock)
        let buffer = makePCMBuffer(frames: 160, fill: 0.5)
        gate.setIncomingSpeaking(true)
        gate.setIncomingSpeaking(false)

        clock.advance(by: .milliseconds(299))
        #expect(gate.process(buffer) !== buffer)
        clock.advance(by: .milliseconds(1))
        #expect(gate.process(buffer) === buffer)
        #expect(!gate.isMicPaused)
    }

    @Test("Review focus: a 'not speaking' report without a preceding 'speaking' never mutes the mic")
    func falseWithoutTrueDoesNotMute() {
        let gate = MicEchoGate(mode: .speakers, clock: TestClock())
        gate.setIncomingSpeaking(false)
        let buffer = makePCMBuffer(frames: 160, fill: 0.5)
        #expect(gate.process(buffer) === buffer)
    }

    @Test("Review focus: switching to headphones while muted reopens at once and reports it (REQ-H-05)")
    func switchToHeadphonesReopens() {
        let reports = LockedArray<Bool>()
        let gate = MicEchoGate(mode: .speakers, clock: TestClock()) { reports.append($0) }
        gate.setIncomingSpeaking(true)
        let buffer = makePCMBuffer(frames: 160, fill: 0.5)
        _ = gate.process(buffer)

        gate.setMode(.headphones)

        #expect(!gate.isMicPaused)
        #expect(reports.values == [true, false])
        #expect(gate.process(buffer) === buffer)
        gate.setMode(.speakers)
        #expect(gate.process(buffer) !== buffer, "incoming is still speaking")
    }

    @Test("Review focus: reset (incoming torn down) reopens at once, without the tail (REQ-H-06)")
    func resetReopens() {
        let reports = LockedArray<Bool>()
        let gate = MicEchoGate(mode: .speakers, clock: TestClock()) { reports.append($0) }
        gate.setIncomingSpeaking(true)
        let buffer = makePCMBuffer(frames: 160, fill: 0.5)
        _ = gate.process(buffer)

        gate.reset()

        #expect(reports.values == [true, false])
        #expect(gate.process(buffer) === buffer)
    }

    @Test("paused changes are reported once per transition")
    func pausedChangeReportedOnTransitions() {
        let clock = TestClock()
        let reports = LockedArray<Bool>()
        let gate = MicEchoGate(mode: .speakers, clock: clock) { reports.append($0) }
        let buffer = makePCMBuffer(frames: 160, fill: 0.5)
        _ = gate.process(buffer)
        gate.setIncomingSpeaking(true)
        _ = gate.process(buffer)
        _ = gate.process(buffer)
        gate.setIncomingSpeaking(false)
        clock.advance(by: .milliseconds(300))
        _ = gate.process(buffer)
        _ = gate.process(buffer)
        #expect(reports.values == [true, false])
    }

    @Test("the gated stream keeps every buffer, in order, and finishes with its input (REQ-H-04)")
    func neverDropsOrReorders() async {
        for mode in ListeningMode.allCases {
            let gate = MicEchoGate(mode: mode, clock: TestClock())
            gate.setIncomingSpeaking(true)
            let (input, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self,
                                                               bufferingPolicy: .bufferingNewest(64))
            let sent = (1...10).map { makePCMBuffer(frames: AVAudioFrameCount(100 + $0), fill: 0.5) }
            sent.forEach { continuation.yield($0) }
            continuation.finish()

            var received: [AVAudioPCMBuffer] = []
            for await buffer in gate.gate(input) { received.append(buffer) }

            #expect(received.map(\.frameLength) == sent.map(\.frameLength))
            let silenced = received.allSatisfy { samples(of: $0).allSatisfy { $0 == 0 } }
            #expect(silenced == (mode == .speakers))
        }
    }
}

@Suite("ConversationState")
struct ConversationStateTests {
    @Test("mic paused wins, then any translation playing, else listening (REQ-H-13)")
    func derivation() {
        for paused in [false, true] {
            for outgoing in [false, true] {
                for incoming in [false, true] {
                    let state = ConversationState.derive(micPaused: paused, outgoingSpeaking: outgoing,
                                                         incomingSpeaking: incoming)
                    let expected: ConversationState = paused ? .micPaused
                        : (outgoing || incoming ? .speaking : .listening)
                    #expect(state == expected, "paused \(paused) outgoing \(outgoing) incoming \(incoming)")
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `just test-only MicEchoGateTests ConversationStateTests`
Expected: build FAILS (`MicEchoGate`, `ConversationState` not found).

- [ ] **Step 3: Implement**

`TranslateCall/Core/Audio/MicEchoGate.swift`:
```swift
import AVFoundation
import OSLog
import Synchronization

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "MicEchoGate")

// MARK: - MicEchoGate

/// Keeps the remote side's translation out of the outgoing pipeline when it plays on speakers
/// (F8.5.3 REQ-H-02…07, design §3.2).
///
/// Sits between the session audio stream and the outgoing VAD. In `.speakers` mode a buffer that
/// arrives while incoming TTS is speaking, or within `tail` after it stopped, is replaced by zeros of
/// the same format and length: the VAD keeps a continuous timeline and ends an utterance in progress
/// by its normal silence rule. Nothing is dropped, reordered or resized (REQ-H-04). There is no timer:
/// the tail is checked against the clock when each buffer arrives (every 10–100 ms).
nonisolated final class MicEchoGate: Sendable {
    private struct State {
        var mode: ListeningMode
        var incomingSpeaking = false
        /// Clock offset at which the gate reopens after incoming TTS stopped.
        var reopenAt: Duration?
        var isMuting = false
    }

    private let state: Mutex<State>
    private let tail: Duration
    private let now: @Sendable () -> Duration
    private let onPausedChange: @Sendable (Bool) -> Void

    /// - Parameter onPausedChange: called on every muting ↔ open transition, from the caller's thread.
    init(mode: ListeningMode,
         tail: Duration = .milliseconds(300),
         clock: any Clock<Duration> = ContinuousClock(),
         onPausedChange: @escaping @Sendable (Bool) -> Void = { _ in }) {
        state = Mutex(State(mode: mode))
        self.tail = tail
        now = Self.offsetReader(clock)
        self.onPausedChange = onPausedChange
    }

    /// True while buffers are being replaced by silence.
    var isMicPaused: Bool { state.withLock { $0.isMuting } }

    /// Takes effect from the next buffer; switching to `.headphones` reopens at once (REQ-H-05).
    func setMode(_ mode: ListeningMode) {
        let reopened: Bool = state.withLock { current in
            current.mode = mode
            guard mode == .headphones, current.isMuting else { return false }
            current.isMuting = false
            return true
        }
        if reopened { onPausedChange(false) }
    }

    /// Incoming TTS started or stopped speaking. Only a true → false change starts the tail.
    func setIncomingSpeaking(_ speaking: Bool) {
        let now = now()
        state.withLock { current in
            if !speaking, current.incomingSpeaking { current.reopenAt = now + tail }
            current.incomingSpeaking = speaking
        }
    }

    /// Incoming went away (torn down, session stop): reopen at once, without the tail (REQ-H-06).
    func reset() {
        let wasMuting: Bool = state.withLock { current in
            current.incomingSpeaking = false
            current.reopenAt = nil
            defer { current.isMuting = false }
            return current.isMuting
        }
        if wasMuting { onPausedChange(false) }
    }

    /// The gated copy of `input`: finishes when `input` finishes; a consumer that goes away stops it.
    func gate(_ input: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<AVAudioPCMBuffer> {
        let (output, continuation) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingNewest(SessionAudioStream.capacity)
        )
        let task = Task { [self] in
            for await buffer in input {
                continuation.yield(process(buffer))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return output
    }

    /// One buffer through the gate: the same instance when open, a zeroed copy when muting (REQ-H-03).
    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let now = now()
        let (muting, changed): (Bool, Bool) = state.withLock { current in
            if let reopenAt = current.reopenAt, now >= reopenAt { current.reopenAt = nil }
            let muting = current.mode == .speakers && (current.incomingSpeaking || current.reopenAt != nil)
            defer { current.isMuting = muting }
            return (muting, muting != current.isMuting)
        }
        if changed { onPausedChange(muting) }
        guard muting else { return buffer }
        if let silent = Self.silence(like: buffer) { return silent }
        // Allocation failed: silence the buffer itself rather than let echo through (never drop it).
        logger.error("Could not allocate a silent buffer; zeroing the captured one in place")
        Self.zero(buffer)
        return buffer
    }

    // MARK: - Helpers

    /// A buffer of `buffer`'s format and length, every byte zero.
    static func silence(like buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let silent = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                            frameCapacity: max(buffer.frameLength, 1)) else { return nil }
        silent.frameLength = buffer.frameLength
        zero(silent)
        return silent
    }

    private static func zero(_ buffer: AVAudioPCMBuffer) {
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audio.mData else { continue }
            memset(data, 0, Int(audio.mDataByteSize))
        }
    }

    /// Elapsed time on `clock` since the gate was created (opens the existential's `Instant`).
    private static func offsetReader<C: Clock>(_ clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }
}
```

`TranslateCall/Core/Audio/ConversationState.swift`:
```swift
// MARK: - ConversationState

/// What the conversation is doing, for the status badge and the menu bar icon (F8.5.3 REQ-H-13).
/// Replaces the half-duplex state machine: nothing is suppressed any more, the mic is only paused
/// by `MicEchoGate` in speakers mode.
nonisolated enum ConversationState: Equatable, Sendable {
    /// No translation is playing.
    case listening
    /// A translation is playing (either direction); both directions keep listening.
    case speaking
    /// Speakers mode: the mic is muted while the remote side's translation plays.
    case micPaused

    static func derive(micPaused: Bool, outgoingSpeaking: Bool, incomingSpeaking: Bool) -> ConversationState {
        if micPaused { return .micPaused }
        if outgoingSpeaking || incomingSpeaking { return .speaking }
        return .listening
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `just test-only MicEchoGateTests ConversationStateTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/Audio/MicEchoGate.swift TranslateCall/Core/Audio/ConversationState.swift TranslateCallTests/MicEchoGateTests.swift
git commit -m "feat(audio): MicEchoGate — silence the mic before the VAD while the remote translation plays on speakers (F8.5.3 REQ-H-02…07)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: TTS queue never drops — coalescing and a backlog notice (REQ-Q-01…04, D-5)

**Files:**
- Modify: `TranslateCall/Core/TTS/UtteranceSynthesizer.swift:34-40`, `TranslateCall/Core/TTS/TTSEvent+Notice.swift:22-23`, `TranslateCall/Core/TTS/TTSPlaybackService.swift`
- Modify: `TranslateCallTests/Support/TTSPlaybackHarness.swift`, `TranslateCallTests/TTSPlaybackServiceTests.swift:21-36`, `TranslateCallTests/AudioCoordinatorTTSTests.swift:106-107,144`
- Test: `TranslateCallTests/TTSPlaybackQueueTests.swift`

**Interfaces:**
- Consumes: F8.5.2 test support (`TTSPlaybackHarness`, `FakeSynthesizer`, `FakeOutput`, `english`).
- Produces:
  - `TTSPlaybackLimits.backlogNoticeThreshold` (20), `.maxCoalescedCharacters` (400; 0 disables); `maxPending` removed
  - `TTSEvent.backlog(pending: Int)`; `TTSEvent.utteranceDropped` removed
  - notice text `"Translation running behind — \(pending) sentences waiting"`
  - test support `TTSPlaybackLimits.uncoalesced`; `TTSPlaybackHarness(limits:)` defaults to it (P7)

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/TTSPlaybackQueueTests.swift`:
```swift
import AVFoundation
import Testing
@testable import TranslateCall

private let spanish = Locale(identifier: "es-ES")

private func limits(backlogAt threshold: Int = 20, coalesceUpTo characters: Int = 400) -> TTSPlaybackLimits {
    var limits = TTSPlaybackLimits.default
    limits.backlogNoticeThreshold = threshold
    limits.maxCoalescedCharacters = characters
    return limits
}

@Suite("TTSPlaybackService queue (F8.5.3)")
struct TTSPlaybackQueueTests {

    @Test("nothing is dropped: 25 sentences behind a busy one are all spoken, in order (REQ-Q-01)")
    func neverDropsPastOldCap() async {
        let harness = TTSPlaybackHarness(limits: limits())
        await harness.service.speak(text: "in flight", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })   // waits for playback
        let sentences = (1...25).map { "s\($0)" }
        for text in sentences { await harness.service.speak(text: text, locale: english) }

        harness.output.completeAll()
        #expect(await waitUntil { harness.output.scheduledCount == 2 })
        harness.output.completeAll()
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(harness.primary.texts == ["in flight", sentences.joined(separator: " ")])
        await harness.service.deactivate()
    }

    @Test("sentences that queued up meanwhile are spoken as one utterance (REQ-Q-02)")
    func coalescesPendingSameLocale() async {
        let harness = TTSPlaybackHarness(limits: limits())
        await harness.service.speak(text: "uno", locale: spanish)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        await harness.service.speak(text: "dos", locale: spanish)
        await harness.service.speak(text: "tres", locale: spanish)

        harness.output.completeAll()
        #expect(await waitUntil { harness.output.scheduledCount == 2 })
        #expect(harness.primary.texts == ["uno", "dos tres"])
        harness.output.completeAll()
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("Review focus: coalescing stops at the character limit; a longer sentence alone is spoken whole")
    func coalescingRespectsCharacterLimit() async {
        let harness = TTSPlaybackHarness(output: FakeOutput(autoComplete: false), limits: limits(coalesceUpTo: 10))
        let long = "a sentence much longer than ten characters"
        await harness.service.speak(text: "first", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        for text in ["aaaa", "bbbb", "cccc", long] { await harness.service.speak(text: text, locale: english) }

        for played in 2...4 {
            harness.output.completeAll()
            #expect(await waitUntil { harness.output.scheduledCount == played })
        }
        #expect(harness.primary.texts == ["first", "aaaa bbbb", "cccc", long])
        harness.output.completeAll()
        await harness.service.deactivate()
    }

    @Test("Review focus: sentences of another locale (language swapped mid-session) are never merged")
    func differentLocaleNotCoalesced() async {
        let harness = TTSPlaybackHarness(limits: limits())
        await harness.service.speak(text: "one", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        await harness.service.speak(text: "dos", locale: spanish)
        await harness.service.speak(text: "tres", locale: spanish)
        await harness.service.speak(text: "four", locale: english)

        for played in 2...3 {
            harness.output.completeAll()
            #expect(await waitUntil { harness.output.scheduledCount == played })
        }
        #expect(harness.primary.texts == ["one", "dos tres", "four"])
        harness.output.completeAll()
        await harness.service.deactivate()
    }

    @Test("a coalesced utterance falls back as one utterance (REQ-Q-04)")
    func coalescedFallsBackWhole() async {
        let primary = FakeSynthesizer(scripts: [FakeSynthesizer.Script(),
                                                FakeSynthesizer.Script(buffers: [], failAfter: 0)])
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let harness = TTSPlaybackHarness(primary: primary, fallback: fallback, limits: limits())
        await harness.service.speak(text: "uno", locale: spanish)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        await harness.service.speak(text: "dos", locale: spanish)
        await harness.service.speak(text: "tres", locale: spanish)

        harness.output.completeAll()
        #expect(await waitUntil { harness.output.scheduledCount == 2 })
        #expect(fallback.texts == ["dos tres"])
        harness.output.completeAll()
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("the backlog notice fires once at the threshold and again only after the queue drained (REQ-Q-03)")
    func backlogNoticeOnceUntilDrained() async {
        let harness = TTSPlaybackHarness(limits: limits(backlogAt: 3, coalesceUpTo: 0))
        await harness.service.speak(text: "a", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        for text in ["b", "c", "d"] { await harness.service.speak(text: text, locale: english) }
        #expect(await waitUntil { harness.events.values == [.backlog(pending: 3)] })
        await harness.service.speak(text: "e", locale: english)

        for played in 2...5 {
            harness.output.completeAll()
            #expect(await waitUntil { harness.output.scheduledCount == played })
        }
        harness.output.completeAll()
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(harness.events.values == [.backlog(pending: 3)])

        await harness.service.speak(text: "f", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 6 })
        for text in ["g", "h", "i"] { await harness.service.speak(text: text, locale: english) }
        #expect(await waitUntil { harness.events.values == [.backlog(pending: 3), .backlog(pending: 3)] })
        await harness.service.deactivate()
    }
}
```

`TranslateCallTests/Support/TTSPlaybackHarness.swift`: change the init parameter
```swift
         limits: TTSPlaybackLimits = .default) {
```
to
```swift
         limits: TTSPlaybackLimits = .uncoalesced) {
```
and append at the end of the file:
```swift

extension TTSPlaybackLimits {
    /// The defaults without coalescing: suites written before F8.5.3 count utterances one by one.
    static var uncoalesced: TTSPlaybackLimits {
        var limits = TTSPlaybackLimits.default
        limits.maxCoalescedCharacters = 0
        return limits
    }
}
```

`TranslateCallTests/TTSPlaybackServiceTests.swift`: delete the whole test `capDropsOldest` (from `@Test("a 4th pending utterance drops the oldest pending one and reports it (REQ-T-12)")` to the closing brace before `@Test("blank text is ignored (REQ-T-12)")`). Its behaviour is reversed by REQ-Q-01 and pinned by `TTSPlaybackQueueTests.neverDropsPastOldCap`.

`TranslateCallTests/AudioCoordinatorTTSTests.swift`, in `newerNoticeRestartsTimer` replace
```swift
        await mocks.mockOutgoingTTS.emit(.utteranceDropped)
        #expect(await waitUntil { coordinator.ttsNotice == "Speaking behind — skipped an older sentence" })
```
with
```swift
        await mocks.mockOutgoingTTS.emit(.backlog(pending: 20))
        #expect(await waitUntil { coordinator.ttsNotice == "Translation running behind — 20 sentences waiting" })
```
and in `TTSNoticeTextTests.texts` replace
```swift
        #expect(TTSEvent.utteranceDropped.noticeText(language: "x") == "Speaking behind — skipped an older sentence")
```
with
```swift
        #expect(TTSEvent.backlog(pending: 20).noticeText(language: "x")
                == "Translation running behind — 20 sentences waiting")
```

- [ ] **Step 2: Run them to see them fail**

Run: `just test-only TTSPlaybackQueueTests`
Expected: build FAILS (`backlogNoticeThreshold`, `maxCoalescedCharacters`, `.backlog` not found).

- [ ] **Step 3: Implement**

`TranslateCall/Core/TTS/UtteranceSynthesizer.swift`: replace
```swift
nonisolated enum TTSEvent: Sendable, Equatable {
    case utteranceDropped
    case utteranceSkipped(TTSSkipReason)
```
with
```swift
nonisolated enum TTSEvent: Sendable, Equatable {
    /// The queue reached `TTSPlaybackLimits.backlogNoticeThreshold` pending sentences (F8.5.3 REQ-Q-03).
    /// Nothing was dropped: the pending sentences are coalesced to catch up.
    case backlog(pending: Int)
    case utteranceSkipped(TTSSkipReason)
```

`TranslateCall/Core/TTS/TTSEvent+Notice.swift`: replace
```swift
        case .utteranceDropped:
            return "Speaking behind — skipped an older sentence"
```
with
```swift
        case .backlog(let pending):
            return "Translation running behind — \(pending) sentences waiting"
```

`TranslateCall/Core/TTS/TTSPlaybackService.swift`, six edits:

1. In `TTSPlaybackLimits` replace
```swift
    /// Utterances waiting behind the one in flight (REQ-T-12).
    var maxPending = 3
```
with
```swift
    /// Pending sentences at which one `.backlog` event is emitted (F8.5.3 REQ-Q-03). Nothing is ever dropped.
    var backlogNoticeThreshold = 20
    /// Longest text one coalesced utterance may have (F8.5.3 REQ-Q-02); 0 disables coalescing.
    var maxCoalescedCharacters = 400
```
2. In the type's doc comment replace
```swift
/// `speak` enqueues (at most `maxPending` waiting, the oldest dropped) and returns. One worker runs
/// utterances strictly one at a time: it starts the synthesizer, schedules each buffer as it arrives
```
with
```swift
/// `speak` enqueues and returns; nothing is ever dropped (F8.5.3 REQ-Q-01). One worker runs
/// utterances strictly one at a time, coalescing the sentences that queued up meanwhile into one
/// utterance to catch up (REQ-Q-02): it starts the synthesizer, schedules each buffer as it arrives
```
3. Below `private var queue: [Utterance] = []` add
```swift
    /// `.backlog` was reported and the queue has not fallen below the threshold since (REQ-Q-03).
    private var backlogNoticed = false
```
4. In `speak(text:locale:)` replace
```swift
        if queue.count >= limits.maxPending {
            queue.removeFirst()
            eventsContinuation.yield(.utteranceDropped)
            logger.info("TTS queue full: dropped the oldest pending sentence")
        }
        queue.append(Utterance(text: text, locale: locale))
```
with
```swift
        queue.append(Utterance(text: text, locale: locale))
        if queue.count >= limits.backlogNoticeThreshold, !backlogNoticed {
            backlogNoticed = true
            eventsContinuation.yield(.backlog(pending: queue.count))
            logger.info("TTS backlog: \(self.queue.count) sentences waiting")
        }
```
5. In `stopSpeaking()` below `queue.removeAll()` add
```swift
        backlogNoticed = false
```
6. In `runWorker()` replace
```swift
                let utterance = queue.removeFirst()
                await play(utterance)
```
with
```swift
                await play(takeNext())
```
and add, directly above `private func play(_ utterance: Utterance) async {`:
```swift
    /// The next utterance: the oldest pending sentence plus the following ones of the same locale,
    /// joined by a space, while the text stays within `maxCoalescedCharacters` (REQ-Q-02).
    private func takeNext() -> Utterance {
        var next = queue.removeFirst()
        while let following = queue.first, following.locale == next.locale,
              next.text.count + 1 + following.text.count <= limits.maxCoalescedCharacters {
            next = Utterance(text: next.text + " " + following.text, locale: next.locale)
            queue.removeFirst()
        }
        if queue.count < limits.backlogNoticeThreshold { backlogNoticed = false }
        return next
    }

```

- [ ] **Step 4: Run the tests**

Run: `just test-only TTSPlaybackQueueTests TTSPlaybackServiceTests TTSPlaybackFallbackTests UtteranceHelpersTests AudioCoordinatorTTSTests TTSNoticeTextTests`
Expected: PASS. Then `grep -rn "utteranceDropped\|maxPending" TranslateCall TranslateCallTests` → no output.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/TTS TranslateCallTests/TTSPlaybackQueueTests.swift TranslateCallTests/TTSPlaybackServiceTests.swift TranslateCallTests/Support/TTSPlaybackHarness.swift TranslateCallTests/AudioCoordinatorTTSTests.swift
git commit -m "feat(tts): the queue never drops — pending sentences are coalesced, backlog notice at 20 (F8.5.3 REQ-Q-01…04)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `VADProvider` — Silero in production, Energy fallback, async VAD factories (A7, REQ-V-01…04)

**Files:**
- Create: `TranslateCall/Core/VAD/VADProvider.swift`
- Delete: `TranslateCall/Core/VAD/VADServiceFactory.swift`
- Modify: `TranslateCall/Core/Audio/AudioCoordinator.swift:82-83,133-134`, `TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift:22,101`, `TranslateCall/App/AppContainer.swift`, `TranslateCall/Features/Main/AudioViewModel.swift`
- Modify: `TranslateCallTests/Mocks/MockVADService.swift` (engine)
- Test: `TranslateCallTests/VADProviderTests.swift`

**Interfaces:**
- Consumes: `VADConfiguration.validated()` (Task 1), `ConversationSettings.vadConfiguration` (Task 2), `AsyncGate`/`LockedArray` (test support).
- Produces:
  - `@MainActor final class VADProvider: ObservableObject` — `typealias SileroLoader = @Sendable (VADConfiguration) async throws -> any VADService`; `init(loadSilero: @escaping SileroLoader = { try await SileroVADService(config: $0) })`; `@Published private(set) var activeEngine: VADEngine?`; `func preload()`; `func makeVAD(config: VADConfiguration) async -> any VADService`
  - `AudioCoordinator` VAD factories: `() async -> any VADService`
  - `AppContainer.conversationSettings`, `.vadProvider`, `nonisolated static var isTestHost: Bool`
  - `AudioViewModel.conversationSettings`, `.vadProvider`; init gains `conversationSettings: ConversationSettings = ConversationSettings()`, `vadProvider: VADProvider = VADProvider()`
  - `MockVADService(engine: VADEngine = .energy)`

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/VADProviderTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

private struct SileroUnavailable: Error {}

@Suite("VADProvider") @MainActor
struct VADProviderTests {

    @Test("Silero when its model loads; the loader gets a validated configuration (REQ-V-01/06)")
    func usesSileroWhenLoaderSucceeds() async {
        let configs = LockedArray<VADConfiguration>()
        let provider = VADProvider { config in
            configs.append(config)
            return MockVADService(engine: .silero)
        }
        var config = VADConfiguration()
        config.minSilenceDuration = -1

        let vad = await provider.makeVAD(config: config)

        #expect(vad.engine == .silero)
        #expect(provider.activeEngine == .silero)
        #expect(configs.values.map(\.minSilenceDuration) == [0])
    }

    @Test("Review focus: Silero cannot load (no model, offline) → Energy, and the next session retries Silero")
    func fallsBackToEnergyWhenSileroFails() async {
        let calls = LockedArray<Int>()
        let provider = VADProvider { _ in
            calls.append(1)
            throw SileroUnavailable()
        }
        let first = await provider.makeVAD(config: VADConfiguration())
        let second = await provider.makeVAD(config: VADConfiguration())
        #expect(first.engine == .energy)
        #expect(second.engine == .energy)
        #expect(provider.activeEngine == .energy)
        #expect(calls.values.count == 2)
    }

    @Test("Review focus: while the launch preload is still loading Silero, a session starts at once on Energy")
    func energyWhileWarming() async {
        let gate = AsyncGate()
        let calls = LockedArray<Int>()
        let provider = VADProvider { _ in
            calls.append(1)
            if calls.values.count == 1 { await gate.wait() }   // the preload's load hangs
            return MockVADService(engine: .silero)
        }
        provider.preload()
        #expect(await waitUntil { gate.waiterCount == 1 })

        let during = await provider.makeVAD(config: VADConfiguration())
        #expect(during.engine == .energy)

        gate.open()
        #expect(await waitUntil {
            await provider.makeVAD(config: VADConfiguration()).engine == .silero
        })
    }

    @Test("preload runs once")
    func preloadOnce() async {
        let calls = LockedArray<Int>()
        let provider = VADProvider { _ in
            calls.append(1)
            return MockVADService(engine: .silero)
        }
        provider.preload()
        provider.preload()
        #expect(await waitUntil { calls.values.count == 1 })
        // Negative check: bounded wait; a second preload must not load again.
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { calls.values.count > 1 }))
    }
}
```

`TranslateCallTests/Mocks/MockVADService.swift`: replace
```swift
actor MockVADService: VADService {
    nonisolated let engine: VADEngine = .energy
```
with
```swift
actor MockVADService: VADService {
    nonisolated let engine: VADEngine
```
and replace
```swift
    init() {
```
with
```swift
    init(engine: VADEngine = .energy) {
        self.engine = engine
```

- [ ] **Step 2: Run them to see them fail**

Run: `just test-only VADProviderTests`
Expected: build FAILS (`VADProvider` not found).

- [ ] **Step 3: Implement the provider and delete the dead factory**

`TranslateCall/Core/VAD/VADProvider.swift`:
```swift
import Combine
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "VADProvider")

/// Builds each session's VADs: Silero when its model loads, Energy otherwise (F8.5.3 REQ-V-01…04).
///
/// `preload()` warms the Silero model (download + CoreML compile) at launch. While that is still
/// running a session gets Energy instead of waiting; afterwards every session tries Silero again,
/// which is cheap once the model is cached and lets a later download succeed.
@MainActor
final class VADProvider: ObservableObject {
    typealias SileroLoader = @Sendable (VADConfiguration) async throws -> any VADService

    private enum Warmup { case idle, warming, done }

    /// Engine of the last VAD handed out; nil before the first session (REQ-V-03).
    @Published private(set) var activeEngine: VADEngine?

    private let loadSilero: SileroLoader
    private var warmup = Warmup.idle

    init(loadSilero: @escaping SileroLoader = { try await SileroVADService(config: $0) }) {
        self.loadSilero = loadSilero
    }

    /// Starts warming the Silero model in the background; a no-op after the first call (REQ-V-02).
    func preload() {
        guard warmup == .idle else { return }
        warmup = .warming
        let load = loadSilero
        Task { [weak self] in
            do {
                let warm = try await load(.default)
                await warm.deactivate()
                logger.info("Silero VAD model ready")
            } catch {
                logger.warning("Silero VAD preload failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.warmup = .done
        }
    }

    /// A VAD for one direction of the next session, on a validated copy of `config` (REQ-V-06).
    func makeVAD(config: VADConfiguration) async -> any VADService {
        let config = config.validated()
        guard warmup != .warming else {
            logger.info("Silero VAD still loading — using energy VAD for this session")
            return energy(config)
        }
        do {
            let vad = try await loadSilero(config)
            activeEngine = vad.engine
            return vad
        } catch {
            let reason = error.localizedDescription
            logger.warning("Silero VAD unavailable (\(reason, privacy: .public)) — using energy VAD")
            return energy(config)
        }
    }

    private func energy(_ config: VADConfiguration) -> any VADService {
        activeEngine = .energy
        return EnergyVADService(config: config)
    }
}
```

```bash
git rm TranslateCall/Core/VAD/VADServiceFactory.swift
```

- [ ] **Step 4: Make the coordinator's VAD factories async**

`TranslateCall/Core/Audio/AudioCoordinator.swift`: replace
```swift
    private(set) var outgoingVADFactory: () -> any VADService
    private(set) var incomingVADFactory: () -> any VADService
```
with
```swift
    // VAD factories are async: Silero loads its CoreML model (F8.5.3 REQ-V-01).
    private(set) var outgoingVADFactory: () async -> any VADService
    private(set) var incomingVADFactory: () async -> any VADService
```
and in `init` replace
```swift
        outgoingVADFactory: @escaping () -> any VADService,
        incomingVADFactory: @escaping () -> any VADService,
```
with
```swift
        outgoingVADFactory: @escaping () async -> any VADService,
        incomingVADFactory: @escaping () async -> any VADService,
```

`TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift`: in `startOutgoingPipeline` replace
```swift
        let vad = outgoingVADFactory()
```
with
```swift
        let vad = await outgoingVADFactory()
```
and in `activateIncoming` replace
```swift
            let vad = incomingVADFactory()
            incomingVAD = vad
```
with
```swift
            let vad = await incomingVADFactory()
            try ensureCurrent(generation)
            incomingVAD = vad
```
(A `stop()` during the model load supersedes the activation before the new VAD is kept.)

Existing tests keep passing synchronous closures (`{ mocks.mockVADFactory }`): a synchronous closure converts to an `async` one.

- [ ] **Step 5: Wire settings and provider in `AppContainer` and `AudioViewModel`**

`TranslateCall/App/AppContainer.swift`: below `let voiceProfileManager: VoiceProfileManager` add
```swift
    let conversationSettings: ConversationSettings
    let vadProvider: VADProvider

    /// True inside the unit/integration test host: no model is warmed there (models stay out of unit tests).
    nonisolated static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
```
In `init()` replace
```swift
        let translationSel = TranslationEngineSelector(
            outgoingBridge: outBridge, incomingBridge: inBridge
        )
        let selector = STTEngineSelector()
        let ttsSelector = TTSEngineSelector()
        let coordinator = AudioCoordinator(
            audioCapture: audioManager,
            systemCapture: SystemAudioCaptureService(),
            outgoingVADFactory: { EnergyVADService() },
            incomingVADFactory: { EnergyVADService() },
```
with
```swift
        let translationSel = TranslationEngineSelector(outgoingBridge: outBridge, incomingBridge: inBridge)
        let selector = STTEngineSelector()
        let ttsSelector = TTSEngineSelector()
        let settings = ConversationSettings()
        let vads = VADProvider()
        if !Self.isTestHost { vads.preload() }
        let coordinator = AudioCoordinator(
            audioCapture: audioManager,
            systemCapture: SystemAudioCaptureService(),
            // Read at each session start: "Pause to translate" applies to the next session (REQ-V-05).
            outgoingVADFactory: { await vads.makeVAD(config: settings.vadConfiguration) },
            incomingVADFactory: { await vads.makeVAD(config: settings.vadConfiguration) },
```
replace
```swift
            outgoingTTSFactory: { [ttsSelector] locale, deviceID in
                try ttsSelector.makeOutgoingService(for: locale, deviceID: deviceID)
            },
            incomingTTSFactory: { [ttsSelector] locale, deviceID in
                try ttsSelector.makeIncomingService(for: locale, deviceID: deviceID)
            },
```
with (keeps `init` within SwiftLint's 50-line function body)
```swift
            outgoingTTSFactory: { [ttsSelector] in try ttsSelector.makeOutgoingService(for: $0, deviceID: $1) },
            incomingTTSFactory: { [ttsSelector] in try ttsSelector.makeIncomingService(for: $0, deviceID: $1) },
```
replace
```swift
        voiceProfileManager = voiceProfiles
        audioCoordinator = coordinator
```
with
```swift
        voiceProfileManager = voiceProfiles
        conversationSettings = settings
        vadProvider = vads
        audioCoordinator = coordinator
```
and in the `AudioViewModel(...)` call replace
```swift
            voiceProfileManager: voiceProfiles
        )
```
with
```swift
            voiceProfileManager: voiceProfiles,
            conversationSettings: settings,
            vadProvider: vads
        )
```

`TranslateCall/Features/Main/AudioViewModel.swift`: below `let voiceProfileManager: VoiceProfileManager` add
```swift
    /// "I use speakers" and "Pause to translate" (F8.5.3 REQ-H-01, REQ-V-05).
    let conversationSettings: ConversationSettings
    /// Which VAD engine the session uses (F8.5.3 REQ-V-03).
    let vadProvider: VADProvider
```
In the designated init replace
```swift
        voiceProfileManager: VoiceProfileManager = VoiceProfileManager()
    ) {
        self.coordinator = coordinator
```
with
```swift
        voiceProfileManager: VoiceProfileManager = VoiceProfileManager(),
        conversationSettings: ConversationSettings = ConversationSettings(),
        vadProvider: VADProvider = VADProvider()
    ) {
        self.coordinator = coordinator
        self.conversationSettings = conversationSettings
        self.vadProvider = vadProvider
```
(The convenience init used by previews and legacy tests keeps `{ EnergyVADService() }` and the default settings/provider.)

- [ ] **Step 6: Run the tests, the build and lint**

Run: `just test-only VADProviderTests AudioCoordinatorTests AudioCoordinatorTTSTests AudioViewModelTests`
Expected: PASS. Then `just lint` → exit 0, and `grep -rn "VADServiceFactory" TranslateCall TranslateCallTests` → no output.

- [ ] **Step 7: Commit**

```bash
git add -A TranslateCall/Core/VAD TranslateCall/Core/Audio/AudioCoordinator.swift TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift TranslateCall/App/AppContainer.swift TranslateCall/Features/Main/AudioViewModel.swift TranslateCallTests/VADProviderTests.swift TranslateCallTests/Mocks/MockVADService.swift
git commit -m "feat(vad): Silero VAD in production via VADProvider, Energy fallback, preloaded at launch (F8.5.3 A7, REQ-V-01…04)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Coordinator — no suppression, mic echo gate, `ConversationState` (A6, A13, REQ-H-05/06/10…13)

**Files:**
- Modify: `TranslateCall/Core/Audio/AudioCoordinator.swift`, `TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift`
- Delete: `TranslateCall/Core/Audio/HalfDuplexManager.swift`, `TranslateCallTests/HalfDuplexManagerTests.swift`, `TranslateCallTests/Mocks/MockHalfDuplexCoordinator.swift`
- Modify: `TranslateCall/Features/Main/AudioViewModel.swift`, `TranslateCall/Features/Main/StatusBadgeView.swift`, `TranslateCall/Features/MenuBar/MenuBarController.swift`, `TranslateCall/Features/MenuBar/MenuBarPopoverView.swift:31`, `TranslateCall/Features/ContentView.swift:38`
- Modify: `TranslateCallTests/Mocks/MockVADService.swift` (peaks), `TranslateCallTests/AudioCoordinatorTTSTests.swift`
- Test: `TranslateCallTests/AudioCoordinatorEchoGateTests.swift` (suites `AudioCoordinatorEchoGateTests`, `ConversationStatePresentationTests`)

**Interfaces:**
- Consumes: `MicEchoGate`, `ConversationState` (Task 3), `ListeningMode` (Task 2), `ConversationSettings` via `AudioViewModel` (Task 5).
- Produces:
  - `AudioCoordinator`: `@Published var listeningMode: ListeningMode`, `@Published private(set) var isMicPaused: Bool`, `@Published private(set) var conversationState: ConversationState`, `private(set) var micEchoGate: MicEchoGate?`, `func reopenMicEchoGate()`; init params `echoGateTail: Duration = .milliseconds(300)`, `echoGateClock: any Clock<Duration> = ContinuousClock()` (replace `halfDuplexTransitionDelay`)
  - Removed: `HalfDuplexManager`, `HalfDuplexState`, `HalfDuplexCoordinating`, `halfDuplexState`, `outgoingCaptureSuppressed`, `incomingCaptureSuppressed`, `suppressOutgoingCapture(_:)`, `suppressIncomingPipeline(_:)`
  - `AudioViewModel.conversationState`
  - `StatusBadgeView(isCapturing:isSpeechActive:conversationState:isIncomingActive:)`, `nonisolated static func presentation(isCapturing:isSpeechActive:state:) -> (label: String, icon: String)`
  - `MenuBarController.iconName(state:isCapturing:) -> String` (nonisolated static)
  - `MockVADService.receivedPeaks: [Float]`

- [ ] **Step 1: Write the failing tests**

`TranslateCallTests/AudioCoordinatorEchoGateTests.swift`:
```swift
import AVFoundation
import Testing
@testable import TranslateCall

private let callTarget = CaptureTarget.app(bundleID: "com.test.call")

@MainActor
private func makeCoordinator(_ mocks: CoordinatorMocks, gateClock: TestClock) -> AudioCoordinator {
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
        echoGateClock: gateClock
    )
}

/// Feeds one loud mic buffer and waits until the outgoing VAD has seen it; returns its peak there.
@MainActor
private func micPeakAtVAD(_ mocks: CoordinatorMocks) async -> Float? {
    let before = await mocks.mockVADFactory.receivedPeaks.count
    mocks.mockAudioCapture.injectBuffer(makePCMBuffer(frames: 160, fill: 0.5))
    guard await waitUntil({ await mocks.mockVADFactory.receivedPeaks.count == before + 1 }) else { return nil }
    return await mocks.mockVADFactory.receivedPeaks.last
}

@Suite("AudioCoordinator mic echo gate (F8.5.3)", .serialized) @MainActor
struct AudioCoordinatorEchoGateTests {

    @Test("headphones (default): the mic reaches the VAD while the remote translation plays")
    func headphonesNeverMutes() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, gateClock: TestClock())
        await coordinator.start(captureTarget: callTarget)
        coordinator.isIncomingSpeaking = true

        #expect(await micPeakAtVAD(mocks) == 0.5)
        #expect(coordinator.conversationState == .speaking)
        await coordinator.stop()
    }

    @Test("speakers: the mic is silenced while incoming speaks and for 300 ms after (REQ-H-03, A6)")
    func speakersModeGatesOutgoingVADInput() async {
        let mocks = CoordinatorMocks()
        let clock = TestClock()
        let coordinator = makeCoordinator(mocks, gateClock: clock)
        coordinator.listeningMode = .speakers
        await coordinator.start(captureTarget: callTarget)

        coordinator.isIncomingSpeaking = true
        #expect(await micPeakAtVAD(mocks) == 0)
        #expect(await waitUntil { coordinator.conversationState == .micPaused })

        coordinator.isIncomingSpeaking = false
        #expect(await micPeakAtVAD(mocks) == 0, "still inside the 300 ms tail")
        clock.advance(by: .milliseconds(300))
        #expect(await micPeakAtVAD(mocks) == 0.5)
        #expect(await waitUntil { coordinator.conversationState == .listening })
        await coordinator.stop()
    }

    @Test("Review focus: turning speakers mode off mid-sentence reopens the mic at once (REQ-H-05)")
    func listeningModeAppliesLive() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, gateClock: TestClock())
        coordinator.listeningMode = .speakers
        await coordinator.start(captureTarget: callTarget)
        coordinator.isIncomingSpeaking = true
        #expect(await micPeakAtVAD(mocks) == 0)

        coordinator.listeningMode = .headphones

        #expect(await waitUntil { coordinator.conversationState == .speaking })
        #expect(await micPeakAtVAD(mocks) == 0.5)
        await coordinator.stop()
    }

    @Test("Review focus: the call app stops while its translation plays → mic reopens, no tail (REQ-H-06)")
    func gateResetOnIncomingStop() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, gateClock: TestClock())
        coordinator.listeningMode = .speakers
        await coordinator.start(captureTarget: callTarget)
        coordinator.isIncomingSpeaking = true
        #expect(await micPeakAtVAD(mocks) == 0)

        await mocks.mockSystemCapture.emit(.stopped(.streamError("gone")))

        #expect(await waitUntil { coordinator.incomingStatus == .stopped(.streamError("gone")) })
        #expect(await micPeakAtVAD(mocks) == 0.5)
        #expect(await waitUntil { coordinator.conversationState == .listening })
        await coordinator.stop()
    }

    @Test("stop() leaves the conversation .listening and the mic unpaused")
    func stopResetsConversationState() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, gateClock: TestClock())
        coordinator.listeningMode = .speakers
        await coordinator.start(captureTarget: callTarget)
        coordinator.isIncomingSpeaking = true
        #expect(await micPeakAtVAD(mocks) == 0)
        #expect(await waitUntil { coordinator.conversationState == .micPaused })

        await coordinator.stop()

        #expect(!coordinator.isMicPaused)
        #expect(coordinator.conversationState == .listening)
        #expect(coordinator.micEchoGate == nil)
    }
}

@Suite("Conversation state presentation")
struct ConversationStatePresentationTests {
    @Test("badge label and icon per state (REQ-H-13)")
    func badge() {
        let idle = StatusBadgeView.presentation(isCapturing: false, isSpeechActive: false, state: .speaking)
        #expect(idle.label == "Idle")
        #expect(StatusBadgeView.presentation(isCapturing: true, isSpeechActive: true, state: .listening).label
                == "Speech detected")
        #expect(StatusBadgeView.presentation(isCapturing: true, isSpeechActive: false, state: .speaking).label
                == "Speaking translation")
        let paused = StatusBadgeView.presentation(isCapturing: true, isSpeechActive: false, state: .micPaused)
        #expect(paused.label == "Mic paused (speakers)")
        #expect(paused.icon == "mic.slash")
    }

    @Test("menu bar icon per state")
    func menuBarIcon() {
        #expect(MenuBarController.iconName(state: .listening, isCapturing: false) == "mic.slash")
        #expect(MenuBarController.iconName(state: .listening, isCapturing: true) == "mic")
        #expect(MenuBarController.iconName(state: .speaking, isCapturing: true) == "waveform")
        #expect(MenuBarController.iconName(state: .micPaused, isCapturing: true) == "mic.slash.circle")
    }
}
```

`TranslateCallTests/Mocks/MockVADService.swift`: below `private(set) var receivedBufferCount = 0` add
```swift
    /// Largest absolute sample of each received buffer, in order (0 = a silenced buffer).
    private(set) var receivedPeaks: [Float] = []
```
in `activate(stream:)` replace
```swift
            for await _ in stream { receivedBufferCount += 1 }
```
with
```swift
            for await buffer in stream {
                receivedBufferCount += 1
                receivedPeaks.append(Self.peak(of: buffer))
            }
```
and directly above `/// Inject a speech segment into the stream` add
```swift
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(data[$1])) }
    }

```

`TranslateCallTests/AudioCoordinatorTTSTests.swift`: replace the whole test `incomingDroppedWhileSuppressed` (from `@Test("incoming sentences are still dropped while incomingCaptureSuppressed is true (REQ-T-43)")` to the closing brace before `@Test("a TTS event becomes the notice line`) with:
```swift
    @Test("an incoming sentence is translated and spoken while outgoing TTS speaks (F8.5.3 REQ-H-11)")
    func incomingTranslatedWhileOutgoingSpeaks() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        await coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { coordinator.isIncomingActive })
        coordinator.isOutgoingSpeaking = true

        await mocks.mockIncomingSTT.injectTranscription(transcript("hello"))

        #expect(await waitUntil { await mocks.mockIncomingTTS.speakCalls.count == 1 })
        #expect(await mocks.mockIncomingTTS.speakCalls.first?.text == "TRANSLATED: hello")
        await coordinator.stop()
    }

    @Test("an outgoing sentence is translated and spoken while incoming TTS speaks (F8.5.3 REQ-H-10)")
    func outgoingTranslatedWhileIncomingSpeaks() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        await coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { coordinator.isIncomingActive })
        coordinator.isIncomingSpeaking = true

        await mocks.mockOutgoingSTT.injectTranscription(transcript("hola"))

        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 1 })
        await coordinator.stop()
    }

    @Test("the one-shot mute turn still skips exactly one outgoing sentence")
    func muteTurnStillSkipsOne() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        await coordinator.start()
        coordinator.suppressNextOutgoingTurn()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("hola"))
        await mocks.mockOutgoingSTT.injectTranscription(transcript("adiós"))

        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 1 })
        #expect(await mocks.mockOutgoingTTS.speakCalls.map(\.text) == ["TRANSLATED: adiós"])
        await coordinator.stop()
    }

```

- [ ] **Step 2: Run them to see them fail**

Run: `just test-only AudioCoordinatorEchoGateTests`
Expected: build FAILS (`echoGateClock`, `listeningMode`, `conversationState`, `presentation`, `iconName` not found).

- [ ] **Step 3: Coordinator state, gate lifecycle, no suppression**

`TranslateCall/Core/Audio/AudioCoordinator.swift`:

1. In the type's doc comment replace
```swift
/// F4.2 hooks (`suppressIncomingPipeline`, `suppressOutgoingCapture`) are no-op stubs
/// filled in by `HalfDuplexManager` in F4.2.
```
with
```swift
/// No sentence is ever dropped at the translation stage (F8.5.3 D-4): echo is kept out by
/// `MicEchoGate`, which mutes the mic before the VAD in speakers mode only.
```
2. Replace
```swift
    @Published var isOutgoingSpeaking: Bool = false
```
with
```swift
    @Published var isOutgoingSpeaking: Bool = false {
        didSet { updateConversationState() }
    }
```
and replace
```swift
    @Published var isIncomingSpeaking: Bool = false
```
with
```swift
    @Published var isIncomingSpeaking: Bool = false {
        didSet {
            micEchoGate?.setIncomingSpeaking(isIncomingSpeaking)
            updateConversationState()
        }
    }
```
3. Replace the whole block from `// MARK: - Half-duplex state (F4.2)` through `private let halfDuplexTransitionDelay: Duration` with:
```swift
    // MARK: - Conversation state and mic echo gate (F8.5.3)

    /// How the user listens (from `ConversationSettings`); applied live to the gate (REQ-H-05).
    @Published var listeningMode: ListeningMode = .headphones {
        didSet { micEchoGate?.setMode(listeningMode) }
    }
    /// The gate is muting the mic (speakers mode, remote translation playing).
    @Published private(set) var isMicPaused = false {
        didSet { updateConversationState() }
    }
    @Published private(set) var conversationState: ConversationState = .listening

    /// This session's gate between the mic stream and the outgoing VAD; nil outside a session.
    private(set) var micEchoGate: MicEchoGate?
    private let echoGateTail: Duration
    private let echoGateClock: any Clock<Duration>

    /// When true, the next outgoing utterance from STT is silently dropped (one-shot).
    /// Set via `suppressNextOutgoingTurn()` — resets automatically after one use.
    var suppressNextOutgoingTurnFlag: Bool = false
```
4. In `init` replace the parameter
```swift
        halfDuplexTransitionDelay: Duration = .milliseconds(300),
```
with
```swift
        echoGateTail: Duration = .milliseconds(300),
        echoGateClock: any Clock<Duration> = ContinuousClock(),
```
and the assignment
```swift
        self.halfDuplexTransitionDelay = halfDuplexTransitionDelay
```
with
```swift
        self.echoGateTail = echoGateTail
        self.echoGateClock = echoGateClock
```
5. In `start(...)` replace `setupHalfDuplex()` with `micEchoGate = makeMicEchoGate()`, and in its superseded branch replace `teardownHalfDuplex()` with `releaseMicEchoGate()`.
6. In `stop()` replace `teardownHalfDuplex()` with `releaseMicEchoGate()` and delete the line `halfDuplexState = .listening`.
7. Delete everything from `// MARK: - F4.2 — HalfDuplexCoordinating conformance (implemented)` to the end of the file (the two `suppress…` methods, `setupHalfDuplex`, `teardownHalfDuplex`, the class's closing brace and the `HalfDuplexCoordinating` extension), and put in its place:
```swift
}

// MARK: - Mic echo gate and conversation state (F8.5.3 REQ-H-02…06, REQ-H-13, design §3.2–3.3)

extension AudioCoordinator {
    /// A gate for the session that is starting. Its paused reports hop to the main actor and are
    /// ignored once that session is over (`sessionGeneration` moved on).
    private func makeMicEchoGate() -> MicEchoGate {
        let generation = sessionGeneration
        return MicEchoGate(mode: listeningMode, tail: echoGateTail, clock: echoGateClock) { [weak self] paused in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                self.isMicPaused = paused
            }
        }
    }

    /// The incoming side went away: the mic must not stay muted (REQ-H-06).
    func reopenMicEchoGate() {
        micEchoGate?.reset()
        isMicPaused = false
    }

    private func releaseMicEchoGate() {
        reopenMicEchoGate()
        micEchoGate = nil
    }

    private func updateConversationState() {
        let state = ConversationState.derive(micPaused: isMicPaused, outgoingSpeaking: isOutgoingSpeaking,
                                             incomingSpeaking: isIncomingSpeaking)
        if state != conversationState { conversationState = state }
    }
}
```
(The extension lives in the same file so it can use the `private` members and keep the class body under 250 lines.)

`TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift`:

1. In `startOutgoingPipeline` replace
```swift
        let micStream = try await audioCapture.startCapture()
        logger.info("Outgoing: audio capture started")
```
with
```swift
        let micStream = try await audioCapture.startCapture()
        logger.info("Outgoing: audio capture started")
        // Speakers mode mutes the mic here, before the VAD, while the remote translation plays (D-3).
        let vadInput = micEchoGate?.gate(micStream) ?? micStream
```
and replace `try await vad.activate(stream: micStream)` with `try await vad.activate(stream: vadInput)`.
2. In `handleIncomingEvent`, `.active` branch, replace
```swift
            isIncomingSpeaking = false
            incomingStatus = .stopped(reason)
```
with
```swift
            isIncomingSpeaking = false
            reopenMicEchoGate()
            incomingStatus = .stopped(reason)
```
3. In `handleOutgoingTranslation` replace
```swift
        // Suppress when incoming TTS is playing on speakers — prevents mic-pickup feedback loop.
        guard !text.isEmpty, !outgoingCaptureSuppressed else { return }
        // No stopSpeaking() first: sentences queue (≤ 3 pending) instead of cutting each other (D-3).
```
with
```swift
        // Never dropped while the other side speaks (F8.5.3 REQ-H-10): echo is handled by MicEchoGate.
        guard !text.isEmpty else { return }
        // No stopSpeaking() first: sentences queue and are coalesced, never cut or dropped (F8.5.3 D-5).
```
4. In `handleIncomingTranslation` replace
```swift
        // Suppress while outgoing TTS is active (BlackHole loopback prevention, F8.5.3). No
        // isIncomingSpeaking guard: remote sentences queue (≤ 3 pending) like outgoing ones (D-3, D-7).
        guard !text.isEmpty, !incomingCaptureSuppressed else { return }
```
with
```swift
        // Never dropped while either TTS speaks (F8.5.3 REQ-H-11): SCStream captures only the call app,
        // which does not play the user's own voice back. Remote sentences queue like outgoing ones.
        guard !text.isEmpty else { return }
```

Delete the half-duplex type and its tests:
```bash
git rm TranslateCall/Core/Audio/HalfDuplexManager.swift TranslateCallTests/HalfDuplexManagerTests.swift TranslateCallTests/Mocks/MockHalfDuplexCoordinator.swift
```

- [ ] **Step 4: View model, status badge and menu bar**

`TranslateCall/Features/Main/AudioViewModel.swift`:
- replace
```swift
    // MARK: - Half-duplex state (from coordinator)

    @Published private(set) var halfDuplexState: HalfDuplexState = .listening
```
with
```swift
    // MARK: - Conversation state (from coordinator, F8.5.3 REQ-H-13)

    @Published private(set) var conversationState: ConversationState = .listening
```
- in `bindCoordinator()` replace `coordinator.$halfDuplexState.assign(to: &$halfDuplexState)` with `coordinator.$conversationState.assign(to: &$conversationState)`
- in the designated init, after `bindVoiceProfileManager()` add `bindConversationSettings()`
- append at the end of the file (a same-file extension keeps the class body under 250 lines):
```swift

// MARK: - Conversation settings (F8.5.3)

extension AudioViewModel {
    /// "I use speakers" is applied live to the running session's mic gate (REQ-H-05).
    private func bindConversationSettings() {
        conversationSettings.$listeningMode
            .sink { [weak self] mode in self?.coordinator.listeningMode = mode }
            .store(in: &cancellables)
    }
}
```

`TranslateCall/Features/Main/StatusBadgeView.swift`: replace everything from `struct StatusBadgeView: View {` through the end of the `micIcon` property with:
```swift
struct StatusBadgeView: View {
    var isCapturing: Bool
    var isSpeechActive: Bool = false
    var conversationState: ConversationState = .listening
    var isIncomingActive: Bool = false

    @State private var isPulsing = false

    /// Label and mic icon for a state (F8.5.3 REQ-H-13). Nothing is muted while a translation
    /// plays, except the mic in speakers mode (`.micPaused`).
    nonisolated static func presentation(isCapturing: Bool, isSpeechActive: Bool,
                                         state: ConversationState) -> (label: String, icon: String) {
        guard isCapturing else { return ("Idle", "mic") }
        switch state {
        case .listening:  return (isSpeechActive ? "Speech detected" : "Listening", "mic")
        case .speaking:   return ("Speaking translation", "speaker.wave.2")
        case .micPaused:  return ("Mic paused (speakers)", "mic.slash")
        }
    }

    private var badgeColor: Color {
        guard isCapturing else { return .secondary }
        switch conversationState {
        case .listening:  return isSpeechActive ? .orange : .green
        case .speaking:   return .blue
        case .micPaused:  return .yellow
        }
    }

    private var label: String {
        Self.presentation(isCapturing: isCapturing, isSpeechActive: isSpeechActive, state: conversationState).label
    }

    private var micIcon: String {
        Self.presentation(isCapturing: isCapturing, isSpeechActive: isSpeechActive, state: conversationState).icon
    }
```
and replace the last two previews with:
```swift
#Preview("Speaking translation") {
    StatusBadgeView(isCapturing: true, conversationState: .speaking, isIncomingActive: true)
        .padding()
}

#Preview("Mic paused (speakers)") {
    StatusBadgeView(isCapturing: true, conversationState: .micPaused, isIncomingActive: true)
        .padding()
}
```

`TranslateCall/Features/MenuBar/MenuBarController.swift`: in `observeState()` replace `viewModel.$halfDuplexState` with `viewModel.$conversationState`, and replace the whole `updateIcon(state:isCapturing:)` method with:
```swift
    /// Menu bar symbol for a state (F8.5.3 REQ-H-13).
    nonisolated static func iconName(state: ConversationState, isCapturing: Bool) -> String {
        guard isCapturing else { return "mic.slash" }
        switch state {
        case .listening:  return "mic"
        case .speaking:   return "waveform"
        case .micPaused:  return "mic.slash.circle"
        }
    }

    private func updateIcon(state: ConversationState, isCapturing: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol = Self.iconName(state: state, isCapturing: isCapturing)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TranslateCall")
        button.image?.isTemplate = true
    }
```

`TranslateCall/Features/MenuBar/MenuBarPopoverView.swift:31` and `TranslateCall/Features/ContentView.swift:38`: replace
```swift
                halfDuplexState: viewModel.halfDuplexState,
```
(indentation as found) with
```swift
                conversationState: viewModel.conversationState,
```

- [ ] **Step 5: Run the tests, the whole unit tier and lint**

Run: `just test-only AudioCoordinatorEchoGateTests ConversationStatePresentationTests AudioCoordinatorTests AudioCoordinatorTTSTests AudioViewModelTests`
Expected: PASS.
Run: `grep -rn "halfDuplex\|HalfDuplex\|CaptureSuppressed\|suppressIncomingPipeline\|suppressOutgoingCapture" TranslateCall TranslateCallTests` → no output.
Run: `just lint` → exit 0. Then `just test` → PASS.

- [ ] **Step 6: Commit**

```bash
git add -A TranslateCall TranslateCallTests
git commit -m "feat(audio): no sentence dropped at the translation stage; MicEchoGate in the outgoing path; ConversationState replaces half-duplex (F8.5.3 A6, A13)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Settings row, hint and usage guide (REQ-H-01, REQ-V-03, REQ-V-05, REQ-U-01…03, A14)

**Files:**
- Create: `TranslateCall/Features/Main/ConversationSettingsView.swift`, `docs/usage-guide.md`
- Modify: `TranslateCall/Features/ContentView.swift`
- Test: `TranslateCallTests/ConversationSettingsViewTests.swift`

**Interfaces:**
- Consumes: `AudioViewModel.conversationSettings`, `.vadProvider`, `.isCapturing`; `ConversationSettings.pauseRange`, `.pauseStep`.
- Produces: `struct ConversationSettingsView: View` — `init(settings:vadProvider:isCapturing:)`, `static let guideURL: URL?`, `nonisolated static func vadLabel(_: VADEngine?) -> String`, `nonisolated static func pauseLabel(_: Double) -> String`.

- [ ] **Step 1: Write the failing test**

`TranslateCallTests/ConversationSettingsViewTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

@Suite("Conversation settings view")
struct ConversationSettingsViewTests {
    @Test("VAD and pause labels (REQ-V-03, REQ-V-05)")
    func labels() {
        #expect(ConversationSettingsView.vadLabel(.silero) == "VAD: Silero")
        #expect(ConversationSettingsView.vadLabel(.energy) == "VAD: Energy")
        #expect(ConversationSettingsView.vadLabel(nil) == "VAD: —")
        #expect(ConversationSettingsView.pauseLabel(0.6) == "Pause to translate: 0.6 s")
        #expect(ConversationSettingsView.guideURL?.absoluteString.hasSuffix("docs/usage-guide.md") == true)
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `just test-only ConversationSettingsViewTests`
Expected: build FAILS (`ConversationSettingsView` not found).

- [ ] **Step 3: Implement the view**

`TranslateCall/Features/Main/ConversationSettingsView.swift`:
```swift
import SwiftUI

/// "I use speakers", "Pause to translate", the active VAD engine and the usage guide
/// (F8.5.3 REQ-H-01, REQ-V-03, REQ-V-05, REQ-U-02).
struct ConversationSettingsView: View {
    @ObservedObject var settings: ConversationSettings
    @ObservedObject var vadProvider: VADProvider
    var isCapturing: Bool

    /// The usage guide on the repository's main branch (REQ-U-01).
    static let guideURL = URL(string: "https://github.com/SantipBarber/TranslateCall/blob/main/docs/usage-guide.md")

    /// "VAD: Silero" / "VAD: Energy" / "VAD: —" before the first session.
    nonisolated static func vadLabel(_ engine: VADEngine?) -> String {
        switch engine {
        case .silero: return "VAD: Silero"
        case .energy: return "VAD: Energy"
        case nil: return "VAD: —"
        }
    }

    nonisolated static func pauseLabel(_ seconds: Double) -> String {
        "Pause to translate: " + String(format: "%.1f s", seconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: speakersBinding) {
                    Label("I use speakers", systemImage: "speaker.wave.2")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Turn on if the translation plays through speakers: the mic pauses while it plays")

                Spacer()

                Text(Self.vadLabel(vadProvider.activeEngine))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let url = Self.guideURL {
                    Link("Usage guide", destination: url)
                        .font(.caption)
                }
            }
            HStack(spacing: 8) {
                Text(Self.pauseLabel(settings.pauseSeconds))
                    .font(.caption)
                    .monospacedDigit()
                Slider(value: $settings.pauseSeconds,
                       in: ConversationSettings.pauseRange,
                       step: ConversationSettings.pauseStep)
                    .controlSize(.mini)
                if isCapturing {
                    Text("Applies to the next session")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var speakersBinding: Binding<Bool> {
        Binding(
            get: { settings.listeningMode == .speakers },
            set: { settings.listeningMode = $0 ? .speakers : .headphones }
        )
    }
}
```

`TranslateCall/Features/ContentView.swift`:
1. After the `ttsMonitorRow` line in `body` add:
```swift

            ConversationSettingsView(
                settings: viewModel.conversationSettings,
                vadProvider: viewModel.vadProvider,
                isCapturing: viewModel.isCapturing
            )
```
2. Below the `HStack(spacing: 12) { CaptureButtonView() … }` block (the last view in the `VStack`) add:
```swift
            Text("Pause briefly after each sentence to send it")
                .font(.caption2)
                .foregroundStyle(.secondary)
```
3. Replace `.frame(width: 480, height: 680)` with `.frame(width: 480, height: 760)` (P10).
4. Move the `// MARK: - TTS Monitor row` section (`private var ttsMonitorRow: some View { … }`, unchanged) out of the struct into a same-file extension placed just above `#Preview("Idle")`. This keeps the struct body under 250 lines:
```swift
// MARK: - TTS Monitor row

extension ContentView {
    private var ttsMonitorRow: some View {
        …the existing body, unchanged…
    }
}
```

- [ ] **Step 4: Write the usage guide**

`docs/usage-guide.md`:
```md
# Guía de uso de TranslateCall

TranslateCall traduce una videollamada en los dos sentidos, como un intérprete simultáneo:
tú hablas en tu idioma y el otro te oye en el suyo; el otro habla en el suyo y tú le oyes en el tuyo.

## 1. Usa auriculares

Con auriculares, el micrófono no oye la voz traducida del otro, así que **los dos sentidos están
siempre activos** y no se pierde ninguna frase: puedes hablar aunque esté sonando una traducción.

Si tienes que usar los altavoces del Mac, activa **«I use speakers»** en la ventana principal
(sección 4).

## 2. Haz una pausa para enviar cada frase

TranslateCall traduce frase a frase. Una frase termina cuando haces una **pausa clara**: en ese momento
se traduce y se oye en el otro idioma.

- Habla con normalidad y haz una pausa breve al final de cada frase, como al dictar.
- Las pausas cortas dentro de una frase (respirar, dudar) no la cortan.
- Si hablas sin pausas durante más de 14 s, la frase se envía igualmente.
- Si dices varias frases seguidas mientras aún suena una traducción, se juntan y se dicen de una vez
  para recuperar el retraso. Nunca se descarta ninguna. Si el retraso llega a 20 frases, aparece el
  aviso «Translation running behind».

## 3. «Pause to translate»: cuánto dura la pausa que envía una frase

En la ventana principal, el control **«Pause to translate»** (de 0,4 s a 1,2 s; por defecto 0,6 s)
fija cuánto silencio cierra una frase:

- **Más corto** (0,4–0,5 s): la traducción empieza antes, pero una pausa a mitad de frase puede
  partirla en dos.
- **Más largo** (0,8–1,2 s): las frases largas no se parten, pero la traducción tarda más en empezar.

El cambio se aplica **en la siguiente sesión** (Stop → Start). El detector de voz (Silero) analiza
el audio en bloques de unos 0,25 s, así que la pausa real puede variar en ese margen.
La etiqueta «VAD» indica qué detector está activo: **Silero** (el normal) o **Energy**
(el de respaldo, si el modelo de Silero aún no está disponible).

## 4. «I use speakers»: altavoces en lugar de auriculares

Con los altavoces, el micrófono oye la traducción del otro y la volvería a traducir (eco).
Con **«I use speakers»** activado, TranslateCall **pone el micrófono en pausa mientras suena la
traducción del otro** (y 0,3 s después). El estado muestra **«Mic paused (speakers)»**.

Mientras el micrófono está en pausa, lo que digas **no se envía**: espera a que termine la traducción.
Por eso recomendamos auriculares. El ajuste se aplica al momento, también en mitad de una sesión.

## 5. Probar la voz traducida tú solo

No hace falta otra persona para comprobar que todo suena.

**Tu voz traducida (sentido saliente):**

1. En la ventana principal elige como micrófono el de tus auriculares (o el del Mac).
2. Activa **Monitor**: la voz traducida que se envía a la llamada también suena en la salida del sistema.
3. Pulsa Start, habla y haz una pausa: oirás tu frase en el otro idioma.

**La voz traducida del otro (sentido entrante):**

1. Cierra Zoom/Teams para que todas las apps aparezcan en «Capture».
2. En «Capture» elige el navegador (Safari o Chrome).
3. Reproduce en el navegador un vídeo o audio de alguien hablando en el idioma del otro.
4. Pulsa Start: oirás la traducción en tu idioma por la salida del sistema.

**Las dos cosas a la vez (micrófono de los auriculares, traducción por los altavoces):**

1. En Ajustes del Sistema → Sonido → Salida elige los altavoces del Mac.
2. En la app elige como micrófono el de los auriculares.
3. Activa **«I use speakers»**: si los altavoces se cuelan en el micrófono, la app lo pone en pausa
   mientras suena la traducción y no se forma un bucle de eco.

## 6. Problemas frecuentes

| Qué pasa | Qué hacer |
|----------|-----------|
| Las frases se cortan a mitad | Sube «Pause to translate» (por ejemplo, a 0,8 s) y reinicia la sesión. |
| La traducción tarda en empezar | Baja «Pause to translate» (por ejemplo, a 0,5 s) y reinicia la sesión. |
| El otro oye su propia frase traducida de vuelta | Usa auriculares o activa «I use speakers». |
| «Mic paused (speakers)» y no te oyen | Espera a que termine la traducción del otro, o usa auriculares y desactiva «I use speakers». |
| «VAD: Energy» | El modelo de Silero no estaba listo; la siguiente sesión lo vuelve a intentar. Funciona igual, pero distingue peor la voz del ruido. |
```

- [ ] **Step 5: Run the test, lint and look at the window**

Run: `just test-only ConversationSettingsViewTests` → PASS. `just lint` → exit 0.
Run: `just build`, then `open build/DerivedData/Build/Products/Debug/TranslateCall.app`. Expected: under the Monitor row there is an "I use speakers" switch, "VAD: —" (or Silero/Energy after a session), a "Usage guide" link, the "Pause to translate: 0.6 s" slider, and the hint under the Start button; nothing is clipped at the bottom of the window.

- [ ] **Step 6: Commit**

```bash
git add TranslateCall/Features docs/usage-guide.md TranslateCallTests/ConversationSettingsViewTests.swift
git commit -m "feat(ui): I use speakers, pause to translate, VAD engine and usage guide (F8.5.3 REQ-H-01, REQ-V-03/05, REQ-U-01…03)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Integration — real Silero on spliced fixtures, and the echo gate (NFR-H-01/02, AC 3)

**Files:**
- Modify: `TranslateCallTests/Support/FileAudioSource.swift:70`
- Test: `TranslateCallTests/Integration/SileroSegmentationIntegrationTests.swift`

**Interfaces:**
- Consumes: `SileroVADService`, `MicEchoGate` (Task 3), `VADConfiguration` (Task 1), `Fixtures`, `requirePrerequisite`, `LatencyReport`, `waitUntil`.
- Produces: suite `IntegrationTests.SileroSegmentationTests`; `latency.json` row `silero-pause-0.6` (stage `vad`).

- [ ] **Step 1: Expose the fixture decoder**

`TranslateCallTests/Support/FileAudioSource.swift`: replace
```swift
    nonisolated private static func decode16kMono(_ url: URL) throws -> [Float] {
```
with
```swift
    nonisolated static func decode16kMono(_ url: URL) throws -> [Float] {
```

- [ ] **Step 2: Write the integration suite**

`TranslateCallTests/Integration/SileroSegmentationIntegrationTests.swift`:
```swift
import AVFoundation
import Synchronization
import Testing
@testable import TranslateCall

/// When a segment reached the consumer, and how long it was.
struct SegmentArrival: Sendable {
    let at: ContinuousClock.Instant
    let frames: Int
}

/// Spliced speech fixtures, fed at real-time pace (F8.5.3 NFR-H-01/02, AC 3).
private enum SplicedSpeech {
    static let rate = 16_000.0
    static let chunk = 1_024

    /// The fixture's speech without the silence `say` puts around it.
    static func speech(_ id: String) throws -> [Float] {
        let fixture = try #require(try Fixtures.all().first { $0.id == id })
        let samples = try FileAudioSource.decode16kMono(Fixtures.url(for: fixture))
        let first = samples.firstIndex { abs($0) > 0.01 } ?? 0
        let last = samples.lastIndex { abs($0) > 0.01 } ?? samples.count - 1
        return Array(samples[first...last])
    }

    static func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * rate))
    }

    static func seconds(_ samples: Int) -> Duration {
        .seconds(Double(samples) / rate)
    }

    /// Streams `samples` as 1 024-sample 16 kHz buffers at wall-clock pace, starting now.
    /// `beforeBuffer` runs before each buffer with the sample offset it starts at.
    static func paced(_ samples: [Float], beforeBuffer: @escaping @Sendable (Int) -> Void = { _ in })
        -> (stream: AsyncStream<AVAudioPCMBuffer>, start: ContinuousClock.Instant, feeder: Task<Void, Never>) {
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self, bufferingPolicy: .unbounded)
        let start = ContinuousClock.now
        let feeder = Task.detached {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                             channels: 1, interleaved: false) else { return }
            for offset in stride(from: 0, to: samples.count, by: chunk) {
                let count = min(chunk, samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let data = buffer.floatChannelData?[0] else { break }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { src in
                    if let base = src.baseAddress { data.update(from: base + offset, count: count) }
                }
                beforeBuffer(offset)
                continuation.yield(buffer)
                try? await Task.sleep(until: start + seconds(offset + count))
            }
            continuation.finish()
        }
        return (stream, start, feeder)
    }
}

extension IntegrationTests {
    @Suite("Silero segmentation", .serialized) @MainActor
    struct SileroSegmentationTests {

        func makeSilero(pause: Double) async throws -> SileroVADService {
            var config = VADConfiguration()
            config.minSilenceDuration = pause
            do {
                return try await SileroVADService(config: config)
            } catch {
                try requirePrerequisite(false, "Silero VAD model (FluidAudio download): \(error)")
                throw error
            }
        }

        /// Runs `vad` over `audio` and returns the segments that arrived, once no more are coming.
        func segments(of audio: [Float], through vad: SileroVADService, expecting count: Int,
                      gate: MicEchoGate? = nil,
                      beforeBuffer: @escaping @Sendable (Int) -> Void = { _ in })
            async throws -> (arrivals: [SegmentArrival], start: ContinuousClock.Instant) {
            let arrivals = Mutex<[SegmentArrival]>([])
            let collector = Task {
                for await segment in vad.speechSegments {
                    let arrival = SegmentArrival(at: .now, frames: Int(segment.audio.frameLength))
                    arrivals.withLock { $0.append(arrival) }
                }
            }
            let feed = SplicedSpeech.paced(audio, beforeBuffer: beforeBuffer)
            try await vad.activate(stream: gate?.gate(feed.stream) ?? feed.stream)
            await feed.feeder.value
            _ = await waitUntil(timeout: .seconds(3)) { arrivals.withLock { $0.count } >= count }
            // Negative check: bounded wait; no extra segment may follow.
            _ = await waitUntil(timeout: .milliseconds(500)) { arrivals.withLock { $0.count } > count }
            await vad.deactivate()
            collector.cancel()
            return (arrivals.withLock { $0 }, feed.start)
        }

        @Test("a 1.0 s gap with a 0.6 s pause splits two sentences, within pause + 0.5 s (NFR-H-01)")
        func splitsAtPauseWithinBound() async throws {
            let pause = 0.6
            let first = try SplicedSpeech.speech("es-meeting")
            let second = try SplicedSpeech.speech("en-budget")
            let lead = SplicedSpeech.silence(0.5)
            let audio = lead + first + SplicedSpeech.silence(1.0) + second + SplicedSpeech.silence(1.5)

            let run = try await segments(of: audio, through: try await makeSilero(pause: pause), expecting: 2)

            #expect(run.arrivals.count == 2, "segments: \(run.arrivals.map(\.frames))")
            guard let closed = run.arrivals.first?.at else { return }
            let speechEnd = run.start + SplicedSpeech.seconds(lead.count + first.count)
            let latency = speechEnd.duration(to: closed)
            await LatencyReport.shared.record(fixture: "silero-pause-0.6", stage: .vad, ms: latency.milliseconds)
            #expect(latency <= .seconds(pause + 0.5), "segment closed \(latency) after the end of speech")
            #expect(latency >= .seconds(pause - 0.35), "segment closed before the pause: \(latency)")
        }

        @Test("a 0.3 s micro-pause with a 0.6 s pause does not split the sentence (NFR-H-02)")
        func microPauseDoesNotSplit() async throws {
            let audio = try SplicedSpeech.silence(0.5) + SplicedSpeech.speech("es-meeting")
                + SplicedSpeech.silence(0.3) + SplicedSpeech.speech("en-budget") + SplicedSpeech.silence(1.5)

            let run = try await segments(of: audio, through: try await makeSilero(pause: 0.6), expecting: 1)

            #expect(run.arrivals.count == 1, "segments: \(run.arrivals.map(\.frames))")
        }

        @Test("speakers mode: speech while incoming 'speaks' never becomes a segment; before and after do (A6)")
        func echoGateKeepsEchoOut() async throws {
            let first = try SplicedSpeech.speech("es-meeting")
            let echo = try SplicedSpeech.speech("en-hear")
            let last = try SplicedSpeech.speech("en-budget")
            let gap = SplicedSpeech.silence(1.0)
            let audio = SplicedSpeech.silence(0.5) + first + gap + echo + gap + last + SplicedSpeech.silence(1.5)
            let echoStart = SplicedSpeech.silence(0.5).count + first.count + gap.count
            let echoEnd = echoStart + echo.count
            let gate = MicEchoGate(mode: .speakers)

            let run = try await segments(of: audio, through: try await makeSilero(pause: 0.6), expecting: 2,
                                         gate: gate) { offset in
                // The remote translation "plays" from 0.2 s before the echo until its last sample.
                if offset >= echoStart - Int(0.2 * SplicedSpeech.rate), offset < echoEnd {
                    gate.setIncomingSpeaking(true)
                } else {
                    gate.setIncomingSpeaking(false)
                }
            }

            #expect(run.arrivals.count == 2, "segments: \(run.arrivals.map(\.frames))")
        }
    }
}
```

- [ ] **Step 3: Run the integration tier**

Run: `just test-integration`
Expected: PASS, including the three `Silero segmentation` tests (~27 s; Silero's CoreML model is downloaded by FluidAudio on first use, and a missing model **fails** with a prerequisite message). `build/reports/latency.json` gets a `silero-pause-0.6` row with `vad_ms` around 716 (measured while planning; bound 250–1 100 ms).

If `splitsAtPauseWithinBound` or `echoGateKeepsEchoOut` sees fewer segments on another machine, Silero did not trigger on the `say` audio. Re-run once with `sileroThreshold` 0.5 in `makeSilero` to confirm. If that passes, set the `VADConfiguration` default `sileroThreshold` to 0.5 (Silero's own default), update `VADConfigurationTests.defaultValues`, and record the change in the decisions table above (P3). Never weaken the segment counts or the latency bound.

- [ ] **Step 4: Commit**

```bash
git add TranslateCallTests/Integration/SileroSegmentationIntegrationTests.swift TranslateCallTests/Support/FileAudioSource.swift
git commit -m "test(vad): Silero segmentation and echo gate on spliced fixtures, pause latency bound (F8.5.3 NFR-H-01/02)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: opengrep `no-capture-suppression` (design §5.5)

**Files:**
- Create: `.opengrep/rules/swift-pipeline.yml`, `.opengrep/rules/swift-pipeline.swift`
- Modify: `.opengrep/README.md` (severity table)

**Interfaces:**
- Consumes: Task 6 (no occurrence left under `TranslateCall/`).
- Produces: rule `no-capture-suppression` (ERROR).

- [ ] **Step 1: Write the rule self-test (it fails without the rule)**

`.opengrep/rules/swift-pipeline.swift`:
```swift
func handle(text: String) {
    // ruleid: no-capture-suppression
    guard !text.isEmpty, !outgoingCaptureSuppressed else { return }
    // ruleid: no-capture-suppression
    let manager = HalfDuplexManager(coordinator: self)
    // ruleid: no-capture-suppression
    coordinator.suppressIncomingPipeline(true)
    // ok: no-capture-suppression
    coordinator.suppressNextOutgoingTurn()
    // ok: no-capture-suppression
    micEchoGate?.setIncomingSpeaking(true)
}
```

Run: `just scan`
Expected: FAIL — `opengrep test` finds `ruleid` annotations for an unknown rule.

- [ ] **Step 2: Add the rule**

`.opengrep/rules/swift-pipeline.yml`:
```yaml
rules:
  - id: no-capture-suppression
    languages: [regex]
    severity: ERROR
    message: "F8.5.3: a sentence is never dropped at the translation stage. Echo is kept out by MicEchoGate before the VAD (speakers mode only); see specs/m8.5-stabilization/f8.5.3-half-duplex-vad."
    metadata: { audit_ref: "F8.5.3 / A6, A13" }
    pattern-regex: '\b(\w*CaptureSuppressed|HalfDuplexManager|HalfDuplexCoordinating|suppressIncomingPipeline|suppressOutgoingCapture)\b'
```

`.opengrep/README.md`: add this row to the severity table, after the `buffer-nocopy-escape` row:
```markdown
| `no-capture-suppression` | ERROR (F8.5.3) | Dropping sentences at the translation stage (half-duplex suppression) loses speech and still leaks echo; echo is handled by `MicEchoGate` | A6, A13 — `HalfDuplexManager`, `*CaptureSuppressed` (deleted in F8.5.3) |
```

- [ ] **Step 3: Scan**

Run: `just scan`
Expected: `✓ opengrep rule tests` (8/8), `✓ no blocking findings`.

- [ ] **Step 4: Commit**

```bash
git add .opengrep
git commit -m "chore(scan): no-capture-suppression rule keeps the drop-based half-duplex out (F8.5.3)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Docs, backlog, manual verification and the PR gate

**Files:**
- Modify: `docs/ARCHITECTURE.md:857-903`, `docs/COMPATIBILITY_MATRIX.md:312,314`
- Modify: `specs/m8.5-stabilization/backlog.md`, this file (manual checklist results)

**Interfaces:**
- Consumes: the finished feature (Tasks 1–9).
- Produces: backlog rows fixed with their pinning tests; T2 re-owned; manual results recorded.

- [ ] **Step 1: Architecture docs**

`docs/ARCHITECTURE.md`: replace everything from `**Solution: Half-Duplex Mode (MVP)**` up to (not including) `### Translation Framework SwiftUI Dependency` with:
````markdown
**Solution (F8.5.3): headphones by default, mic echo gate in speakers mode**

Half-duplex suppression (the MVP's `HalfDuplexManager`) was removed in F8.5.3: it dropped sentences
in both directions and still leaked echo, because it was checked when the transcription arrived,
long after the audio had been captured.

- **Headphones (default):** the mic cannot hear the translation, so both directions are always live
  and no sentence is ever dropped.
- **Speakers ("I use speakers"):** `MicEchoGate` sits between the mic stream and the outgoing VAD and
  replaces mic buffers with silence while the remote side's translation plays, plus a 300 ms tail.
  The echo never reaches VAD/STT; the UI shows "Mic paused (speakers)".
- The incoming direction is never muted: ScreenCaptureKit captures only the call app, which does not
  play the user's own voice back.

```
mic ─► SessionAudioStream ─► MicEchoGate ─► VAD (Silero | Energy) ─► STT ─► translate ─► TTS ─► BlackHole
                                  ▲ speakers mode + incoming TTS speaking (+300 ms)
```
````

`docs/COMPATIBILITY_MATRIX.md`, Audio table: replace the row
```markdown
| Half-duplex mode | Can't interrupt | Wait for turn |
```
with
```markdown
| Speakers mode ("I use speakers") | Your speech is not sent while the remote translation plays | Use headphones |
```
and the row
```markdown
| Echo (no headphones) | Feedback possible | Use headphones |
```
with
```markdown
| Echo (no headphones) | Feedback unless "I use speakers" is on | Use headphones, or turn on "I use speakers" |
```

- [ ] **Step 2: Backlog**

In `specs/m8.5-stabilization/backlog.md`:
- in the sub-features table, set the F8.5.3 row's Spec column to `f8.5.3-half-duplex-vad/` and remove `T2 (evaluation)` from its Items; add `T2` to a new row `| Whisper uk evaluation (after F8.5.4) | — | T2 |`;
- set the "Guard in place" column:

| # | Guard in place |
|---|---|
| A6 | fixed in F8.5.3 (PR #…) — `MicEchoGate` before the VAD: `MicEchoGateTests.tailKeepsMutedThenReopens`, `AudioCoordinatorEchoGateTests.speakersModeGatesOutgoingVADInput`, `SileroSegmentationTests.echoGateKeepsEchoOut`; opengrep `no-capture-suppression` (ERROR) |
| A7 | fixed in F8.5.3 — `VADProvider` (Silero, Energy fallback): `VADProviderTests` |
| A13 | fixed in F8.5.3 — no suppression, queue never drops: `AudioCoordinatorTTSTests.incomingTranslatedWhileOutgoingSpeaks`, `.outgoingTranslatedWhileIncomingSpeaks`, `TTSPlaybackQueueTests.neverDropsPastOldCap` |
| A14 | fixed in F8.5.3 — solo procedure in `docs/usage-guide.md` §5; manual M2 |
| A15 | fixed in F8.5.3 — pause is the sentence boundary by design (D-1), tunable 0.4–1.2 s: `SileroSegmentationTests.microPauseDoesNotSplit`; manual M3 |
| T2 | moved out of F8.5.3 (D-9): own task after F8.5.4 — `withKnownIssue` stays |
| T3 | fixed in F8.5.3 — `VADConfiguration.validated()`: `VADConfigurationValidationTests` |
| T4 | VAD part fixed in F8.5.3 — 0.6 s pause with chunk compensation, bound enforced: `SileroSegmentationTests.splitsAtPauseWithinBound` (716 ms measured); translation part → F8.5.4 |

Fill in the PR number once the PR exists (Step 6).

- [ ] **Step 3: Lint, scan and the whole unit tier**

Run: `just lint` → exit 0. `just scan` → `✓ no blocking findings`. `just test` → PASS.

- [ ] **Step 4: Commit**

```bash
git add docs specs/m8.5-stabilization/backlog.md
git commit -m "docs: F8.5.3 echo handling in ARCHITECTURE/COMPATIBILITY; backlog A6, A7, A13–A15, T3, T4 fixed

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Manual checklist (done by the user; needs BlackHole, a browser and the network)**

Build and run the app (`just build`, then open `build/DerivedData/Build/Products/Debug/TranslateCall.app`). Follow `docs/usage-guide.md` §5 for the solo setups. Record the date and result of each line here:

| # | Check | Expected | Result |
|---|-------|----------|--------|
| M1 | Headphones, "I use speakers" off. Browser as capture app playing speech in the remote language; while its translation plays, say two sentences of your own | Both directions are translated; none of your sentences and none of the browser's is lost (Monitor on to hear yours) | |
| M2 | Headset mic in the app, system output = Mac speakers, Monitor on, "I use speakers" on; play remote speech in the browser, then talk after it | No echo loop (the speakers' translation is not translated back); the badge shows "Mic paused (speakers)" while the remote translation plays and "Listening" ~0.3 s after; turning "I use speakers" off mid-translation turns the badge back at once | |
| M3 | "Pause to translate" at 0.4, 0.6 and 1.2 s (Stop → Start after each change); say a long sentence with a short breath in the middle, then pause clearly | The breath does not split the sentence at 0.6 and 1.2 s; every clear pause sends a sentence; 0.4 s may split at the breath (expected) | |
| M4 | Browser: a long monologue (≥ 1 min) in the remote language | Nothing missing in the translation; when it falls behind, sentences are spoken together and the delay shrinks; at ≥ 20 queued, "Translation running behind — N sentences waiting" | |
| M5 | Start a session | "VAD: Silero"; with the network off on a machine without the model cached (or right after a first launch), "VAD: Energy" and the session still works | |
| M6 | Re-run F8.5.2 M1 (Edge, network cut → system voice) and M6 (incoming), and F8.5.1 M1–M6, with the solo procedure | As written in those checklists; record results in their tasks.md | |

- [ ] **Step 6: Full gate (done by the controller with the user)**

Run: `just pr`
Expected: build → check → test → test-integration all pass; `local/just-pr` status = success on HEAD; PR created against `main` with the template filled in (spec + this plan, tests, `just pr`, manual checklist M1–M6). Then put the PR number into the backlog rows of Step 2 (follow-up commit, and run `just pr` again).

---

## Spec coverage

| Requirement | Task | Pinned by |
|---|---|---|
| REQ-H-01 listening mode setting, persisted | 2, 7 | `ConversationSettingsTests.defaults`, `.persistence`, `.corruptStoredValues`; manual M2 |
| REQ-H-02 gate between session stream and outgoing VAD; headphones pass-through | 3, 6 | `MicEchoGateTests.headphonesPassThrough`, `AudioCoordinatorEchoGateTests.headphonesNeverMutes` |
| REQ-H-03 zeros while incoming speaks + 300 ms tail | 3, 6 | `MicEchoGateTests.speakersMutesWhileIncoming`, `.tailKeepsMutedThenReopens`, `AudioCoordinatorEchoGateTests.speakersModeGatesOutgoingVADInput` |
| REQ-H-04 never drop/reorder/resize | 3 | `MicEchoGateTests.neverDropsOrReorders`, `.speakersMutesWhileIncoming` (format, length, original untouched) |
| REQ-H-05 mode change from the next buffer; headphones reopens at once | 3, 6 | `MicEchoGateTests.switchToHeadphonesReopens`, `AudioCoordinatorEchoGateTests.listeningModeAppliesLive` |
| REQ-H-06 `isMicPaused`; reopen on incoming stop / session stop | 3, 6 | `MicEchoGateTests.resetReopens`, `.pausedChangeReportedOnTransitions`, `AudioCoordinatorEchoGateTests.gateResetOnIncomingStop`, `.stopResetsConversationState` |
| REQ-H-07 injectable clock | 3 | `TestClock` in every gate test |
| REQ-H-10 outgoing never dropped; mute turn kept | 6 | `AudioCoordinatorTTSTests.outgoingTranslatedWhileIncomingSpeaks`, `.muteTurnStillSkipsOne` |
| REQ-H-11 incoming never dropped | 6 | `AudioCoordinatorTTSTests.incomingTranslatedWhileOutgoingSpeaks` |
| REQ-H-12 half-duplex types removed | 6, 9 | Task 6 Step 5 grep; opengrep `no-capture-suppression` |
| REQ-H-13 `ConversationState` for badge and menu bar | 3, 6 | `ConversationStateTests.derivation`, `ConversationStatePresentationTests`, `AudioCoordinatorEchoGateTests` (state assertions) |
| REQ-Q-01 never drop | 4 | `TTSPlaybackQueueTests.neverDropsPastOldCap` |
| REQ-Q-02 coalescing, same locale, ≤ 400 characters | 4 | `.coalescesPendingSameLocale`, `.coalescingRespectsCharacterLimit`, `.differentLocaleNotCoalesced` |
| REQ-Q-03 backlog notice once per crossing | 4 | `.backlogNoticeOnceUntilDrained`, `TTSNoticeTextTests.texts`, `AudioCoordinatorTTSTests.newerNoticeRestartsTimer` |
| REQ-Q-04 coalesced = one utterance | 4 | `.coalescedFallsBackWhole`; existing F8.5.2 suites unchanged |
| REQ-V-01 Silero both directions, async factories | 5 | `VADProviderTests.usesSileroWhenLoaderSucceeds`; `AppContainer` wiring |
| REQ-V-02 preload, Energy fallback, retry next session | 5 | `VADProviderTests.energyWhileWarming`, `.fallsBackToEnergyWhenSileroFails`, `.preloadOnce` |
| REQ-V-03 active engine visible | 5, 7 | `ConversationSettingsViewTests.labels`; manual M5 |
| REQ-V-04 `VADServiceFactory` removed | 5 | Task 5 Step 6 grep |
| REQ-V-05 pause setting 0.4–1.2 s, next session | 2, 5, 7 | `ConversationSettingsTests.pauseClamped`, `.persistence` (`vadConfiguration`); manual M3 |
| REQ-V-06 `validated()` | 1 | `VADConfigurationValidationTests` |
| REQ-V-07 both services validate on init | 1 | Task 1 Step 3; `VADProviderTests.usesSileroWhenLoaderSucceeds` (validated config handed over) |
| REQ-U-01 usage guide (Spanish) | 7 | `docs/usage-guide.md`; manual M1–M3 follow it |
| REQ-U-02 guide link + hint | 7 | `ConversationSettingsViewTests.labels` (URL); Task 7 Step 5 visual check |
| REQ-U-03 English UI strings | 4, 6, 7 | `TTSNoticeTextTests`, `ConversationStatePresentationTests`, `ConversationSettingsViewTests` |
| NFR-H-01 segment within p − 0.35 s … p + 0.5 s | 1, 8 | `SileroSegmentationTests.splitsAtPauseWithinBound` (latency.json) |
| NFR-H-02 micro-pause does not split | 8 | `SileroSegmentationTests.microPauseDoesNotSplit` |
| NFR-H-03 no allocation in headphones mode | 3 | `MicEchoGateTests.headphonesPassThrough` (same instance) |
| NFR-H-04 unit tests without models/network/device | all | fakes and mocks; `AppContainer.isTestHost` skips the preload |
| AC 3 echo-gate integration | 8 | `SileroSegmentationTests.echoGateKeepsEchoOut` |
| AC 4 manual checklist | 10 | M1–M6 |
| AC 5 backlog | 10 | Step 2 |
