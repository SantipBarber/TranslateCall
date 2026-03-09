# F2.3: Text-to-Speech — Tasks

**Feature**: Text-to-Speech Synthesis
**Milestone**: M2 — Speech Pipeline
**Status**: DRAFT — awaiting Gate 3 review
**Date**: 2026-03-07
**Prerequisites**: design.md (Gate 2 approved)

---

## Dependency Order

```
T1 (types + protocol) ──▶ T2 (AVSpeechService) ──▶ T3 (ViewModel + UI) ──▶ T4 (tests)
```

All tasks follow TDD: write failing test → implement → green → refactor.

---

## T1 — Define shared types: `SynthesisConfiguration`, `STSError`, `SynthesisService`

**Maps to**: REQ-TTS-07, REQ-TTS-08, REQ-NFR-TTS-03
**File**: `TranslateCall/Core/TTS/SynthesisService.swift`
**Depends on**: nothing

### What to implement

1. `SynthesisConfiguration` struct (Sendable):
   ```swift
   struct SynthesisConfiguration: Sendable {
       var rate: Float = AVSpeechUtteranceDefaultSpeechRate
       var pitchMultiplier: Float = 1.0
       var volume: Float = 1.0
       static let `default` = SynthesisConfiguration()
   }
   ```

2. `STSError` enum (LocalizedError):
   - `.voiceUnavailable(Locale)` — no voice installed for locale
   - `.engineStartFailed(Error)` — AVAudioEngine failed to start

3. `SynthesisService` actor protocol:
   ```swift
   protocol SynthesisService: Actor {
       nonisolated var isSpeakingStream: AsyncStream<Bool> { get }
       func speak(text: String, locale: Locale) async
       func stopSpeaking() async
       func deactivate() async
   }
   ```

### Tests (RED first) — `TTSServiceTests.swift`

- `testSynthesisConfigurationDefaults()` — verify default rate, pitch, volume values
- `testSTSErrorHasDescription()` — verify each error case has a non-nil `errorDescription`

### Done when
- File compiles with zero warnings
- Tests green

---

## T2 — Implement `AVSpeechService`

**Maps to**: REQ-TTS-01 through REQ-TTS-10, REQ-NFR-TTS-01 through REQ-NFR-TTS-05
**File**: `TranslateCall/Core/TTS/AVSpeechService.swift`
**Depends on**: T1

### What to implement

1. `actor AVSpeechService: SynthesisService`:
   - `nonisolated let isSpeakingStream` initialized in `init()`
   - `private var synthesizer = AVSpeechSynthesizer()`
   - `private let engine = AVAudioEngine()`
   - `private let playerNode = AVAudioPlayerNode()`
   - `private var utteranceQueue: [(text: String, locale: Locale)] = []`
   - `private var isSynthesizing = false`

2. `init(config:) throws`:
   - Create stream + continuation
   - `engine.attach(playerNode)`
   - `engine.connect(playerNode, to: engine.outputNode, format: ...)`
   - `try engine.start()`
   - `synthesizer.delegate = self`

3. `speak(text:locale:)`:
   - Append to `utteranceQueue`
   - Call `processNextUtterance()` if not already synthesizing

4. `processNextUtterance()`:
   - Dequeue head
   - Call `bestVoice(for:)` — skip if nil, log
   - Build `AVSpeechUtterance` with voice, rate, pitch, volume
   - Set `isSynthesizing = true`; yield `true` to `isSpeakingStream`
   - Call `synthesizer.write(utterance) { buffer in ... }`
   - In callback: bridge to actor via `Task { await self.scheduleBuffer(pcm) }`

5. `scheduleBuffer(_ pcm: AVAudioPCMBuffer)`:
   - If `!playerNode.isPlaying`: `playerNode.play()`
   - `playerNode.scheduleBuffer(pcm, completionHandler: nil)`

6. `bestVoice(for locale: Locale) -> AVSpeechSynthesisVoice?`:
   - Filter `AVSpeechSynthesisVoice.speechVoices()` by 2-letter language prefix
   - Prefer `.enhanced`, fallback to first available

7. `AVSpeechSynthesizerDelegate`:
   - `nonisolated func speechSynthesizer(_:didFinish:)`: bridge to `Task { await utteranceDidFinish() }`
   - `utteranceDidFinish()`: set `isSynthesizing = false`, yield `false` if queue empty, else `processNextUtterance()`

8. `stopSpeaking()`: clear queue, `synthesizer.stopSpeaking(at: .immediate)`, `playerNode.stop()`, yield `false`

9. `deactivate()`: call `stopSpeaking()`, `engine.stop()`, finish continuation

### Tests (RED first)

- `testSpeakProducesAudioEngine()` — create `AVSpeechService`, call `speak("Hello", locale: .current)`, assert `isSpeakingStream` emits `true` within 1s. Run `.serialized` to avoid CoreAudio conflicts.
- `testStopSpeakingClearsQueue()` — queue two requests, call `stopSpeaking()`, assert only one (or zero) utterances play.
- `testVoiceSelectionPrefersEnhanced()` — call `bestVoice(for: Locale(identifier: "en-US"))`, assert result is non-nil and `quality == .enhanced` when enhanced voices are installed.
- `testVoiceUnavailableDoesNotCrash()` — call `speak(text:, locale: Locale(identifier: "xx-XX"))` (invalid locale), assert no crash and `isSpeakingStream` emits `false` (not `true`).
- `testDeactivateStopsSynthesis()` — start speaking, call `deactivate()`, assert player stops.

### Done when
- `AVSpeechService` conforms to `SynthesisService` with zero warnings
- Tests green

---

## T3 — Wire `AVSpeechService` into `AudioViewModel` and update UI

**Maps to**: REQ-TTS-11
**File**: `TranslateCall/Features/Main/AudioViewModel.swift`, `ContentView.swift` (modify existing)
**Depends on**: T2

### What to implement

1. Add to `AudioViewModel`:
   ```swift
   @Published var isSpeaking: Bool = false
   private var synthesisService: (any SynthesisService)?
   private var speakingTask: Task<Void, Never>?
   ```

2. In `startCapture()`: instantiate `AVSpeechService(config: .default)`, call `observeSynthesisState(_:)`.

3. In `stopCapture()`: call `await synthesisService?.deactivate()`, cancel `speakingTask`.

4. `observeSynthesisState(_:)`:
   ```swift
   speakingTask = Task { @MainActor [weak self] in
       for await active in service.isSpeakingStream {
           self?.isSpeaking = active
       }
   }
   ```

5. Update `ContentView` status badge logic:
   - `isSpeaking == true` → red badge with "Speaking"
   - `isSpeechActive == true` → orange badge with "Detecting speech"
   - Both `false` → green badge with "Listening"

6. Add a **test TTS button** in the UI (M2 only — removes in M3 when Translation drives it):
   - A `Button("Test TTS")` that calls `viewModel.testTTS()`
   - `testTTS()` calls `speak(text: "Hello, translation is working.", locale: .current)`

### Done when
- App builds and runs
- Tapping "Test TTS" produces audible speech
- Status badge turns red during speech and green when done
- `isSpeaking` correctly reflects synthesis state

---

## T4 — Tests

**Maps to**: All REQ-TTS + AC-TTS
**File**: `TranslateCallTests/TTSServiceTests.swift`
**Depends on**: T1–T3

### Tests (additional to T1, T2)

- `testTTSSpeakingStreamTransitions()` — speak a short utterance, collect `isSpeakingStream` events, assert `[true, false]` sequence (AC-TTS-05)
- `testQueuedUtterancesPlayInOrder()` — enqueue "one", "two", "three" sequentially, assert all play without crash (AC-TTS-03)
- `testCustomRateApplied()` — set `rate = AVSpeechUtteranceMinimumSpeechRate`, assert utterance takes longer than default (best-effort, timing-based)
- `testSimultaneousCaptureAndSynthesis()` — start `AudioManager.startCapture()` and `AVSpeechService.speak()` concurrently, assert neither crashes (AC-TTS-08) — mark `@Suite(.serialized)`

### Done when
- All unit tests green
- All AC-TTS-01 through AC-TTS-08 covered by test or documented as manual/integration

---

## Task Summary

| Task | File(s) | Effort | Blocks |
|------|---------|--------|--------|
| T1 — Types + protocol | `SynthesisService.swift` | Small | T2, T3 |
| T2 — AVSpeechService | `AVSpeechService.swift` | Medium | T3 |
| T3 — ViewModel + UI | `AudioViewModel.swift`, `ContentView` | Small | T4 |
| T4 — Tests | `TTSServiceTests.swift` | Small | — |

---

*Gate 3 Review: human must approve this document before implementation begins.*
