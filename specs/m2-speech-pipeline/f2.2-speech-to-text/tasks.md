# F2.2: Speech-to-Text — Tasks

**Feature**: Speech-to-Text Integration
**Milestone**: M2 — Speech Pipeline
**Status**: DRAFT — awaiting Gate 3 review
**Date**: 2026-03-07
**Prerequisites**: design.md (Gate 2 approved)

---

## Dependency Order

```
T1 (types + protocol) ──▶ T2 (AppleSpeechService) ──▶ T4 (ViewModel) ──▶ T5 (tests)
                      ──▶ T3 (Info.plist) [parallel with T2]
```

All tasks follow TDD: write failing test → implement → green → refactor.

---

## T1 — Define shared types: `TranscriptionResult`, `STTError`, `STTConfiguration`, `SpeechRecognizerService`

**Maps to**: REQ-STT-01, REQ-STT-03, REQ-STT-04, REQ-NFR-STT-03
**File**: `TranslateCall/Core/STT/SpeechRecognizerService.swift`
**Depends on**: nothing

### What to implement

1. `TranscriptionResult` struct (Sendable):
   ```swift
   struct TranscriptionResult: Sendable {
       let text: String
       let confidence: Float     // 0.0 – 1.0, mean of word confidences
       let locale: Locale
       let capturedAt: Date
       let audioDuration: TimeInterval
   }
   ```

2. `STTError` enum (LocalizedError):
   - `.permissionDenied`
   - `.recognizerUnavailable(Locale)`
   - `.recognitionFailed(Error)`

3. `STTConfiguration` struct (Sendable):
   - `minimumConfidence: Float = 0.60`
   - `preferOnDevice: Bool = true`
   - `static let default = STTConfiguration()`

4. `SpeechRecognizerService` actor protocol:
   ```swift
   protocol SpeechRecognizerService: Actor {
       nonisolated var transcriptionStream: AsyncStream<TranscriptionResult> { get }
       nonisolated var locale: Locale { get }
       func activate(stream: AsyncStream<SpeechSegment>) async throws
       func deactivate() async
       func setLocale(_ locale: Locale) async
   }
   ```

### Tests (RED first) — `STTServiceTests.swift`

- `testTranscriptionResultIsValueType()` — assert `TranscriptionResult` can be copied and compared field by field
- `testSTTConfigurationDefaults()` — verify `minimumConfidence == 0.60`, `preferOnDevice == true`
- `testSTTErrorHasDescription()` — verify each case has a non-nil `errorDescription`

### Done when
- File compiles with zero warnings under `-strict-concurrency=complete`
- Tests green

---

## T2 — Implement `AppleSpeechService`

**Maps to**: REQ-STT-01, REQ-STT-02, REQ-STT-03, REQ-STT-04, REQ-STT-05, REQ-STT-07, REQ-STT-08, REQ-STT-09, REQ-STT-10, REQ-NFR-STT-02
**File**: `TranslateCall/Core/STT/AppleSpeechService.swift`
**Depends on**: T1

### What to implement

1. `actor AppleSpeechService: SpeechRecognizerService`:
   - `nonisolated let transcriptionStream` initialized in `init()`
   - `nonisolated private(set) var locale: Locale`

2. `activate(stream:)`:
   - Call `SFSpeechRecognizer.requestAuthorization()` via `await`
   - Guard `.authorized` → throw `STTError.permissionDenied`
   - Create `SFSpeechRecognizer(locale: locale)`, guard `isAvailable` → throw `STTError.recognizerUnavailable`
   - Spawn `processingTask` iterating `stream`

3. Per-segment recognition (`transcribeSegment(_:)`):
   - Create `SFSpeechAudioBufferRecognitionRequest`
   - Set `shouldReportPartialResults = false`
   - Set `requiresOnDeviceRecognition = true` when supported and `config.preferOnDevice`
   - Call `request.append(segment.audio)` then `request.endAudio()`
   - Bridge `recognitionTask(with:resultHandler:)` to `withCheckedThrowingContinuation`
   - Compute mean confidence from `bestTranscription.segments`
   - Return `nil` if confidence < `config.minimumConfidence`

4. `deactivate()`: cancel `processingTask` + `activeRecognitionTask`

5. `setLocale(_:)`: cancel active recognition task, replace `recognizer`

### Tests (RED first)

- `testAppleSpeechServiceEmitsResultOnSyntheticSegment()` — feed a `SpeechSegment` wrapping a 16kHz sine burst (not real speech), assert the recognizer runs and either emits or discards (no crash). Mark `@available(macOS 15, *)` and skip if recognizer unavailable.
- `testAppleSpeechServiceDiscardsLowConfidence()` — inject a mock `SFSpeechRecognizer` (or use a protocol seam) that returns a result with confidence = 0.0; assert no emission.
- `testAppleSpeechServiceCancelsOnDeactivate()` — start processing, call `deactivate()`, assert no further emissions.
- `testAppleSpeechServiceLocaleSwitch()` — call `setLocale("en-US")`, assert `locale` property reflects change.

> **Note**: Integration tests requiring real speech recognition (network or on-device model) are in T5.

### Done when
- `AppleSpeechService` conforms to `SpeechRecognizerService` with zero warnings
- Unit tests green (mocked or minimal input)

---

## T3 — Add `NSSpeechRecognitionUsageDescription` to Info.plist

**Maps to**: REQ-STT-20
**File**: `TranslateCall/Resources/` or project-level `Info.plist`
**Depends on**: nothing (parallel with T2)

### What to implement

Add to the app target's `Info.plist`:

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>TranslateCall uses speech recognition to transcribe your spoken words for translation.</string>
```

Verify by running the app and confirming macOS presents the speech recognition permission dialog on first launch.

### Done when
- App builds and runs
- On first launch, macOS presents the speech recognition permission prompt
- No `Error Domain=kAFAssistantErrorDomain` errors about missing usage description

---

## T4 — Wire `AppleSpeechService` into `AudioViewModel`

**Maps to**: REQ-STT-11, REQ-STT-12
**File**: `TranslateCall/Features/Main/AudioViewModel.swift` (modify existing)
**Depends on**: T2, T3

### What to implement

1. Add to `AudioViewModel`:
   ```swift
   @Published var latestTranscription: String?
   @Published var isTranscribing: Bool = false
   private var sttService: (any SpeechRecognizerService)?
   private var transcriptionTask: Task<Void, Never>?
   ```

2. In `startCapture()`: after activating VAD, create `AppleSpeechService` and activate with `vadService.speechSegments`. Spawn observer task.

3. In `stopCapture()`: call `await sttService?.deactivate()`, cancel `transcriptionTask`.

4. Observation task (`observeTranscriptions(_:)`):
   ```swift
   Task { @MainActor [weak self] in
       for await result in service.transcriptionStream {
           self?.latestTranscription = result.text
           self?.isTranscribing = false
       }
   }
   ```

5. Set `isTranscribing = true` when `isSpeechActive` transitions to `false` (speech just ended, STT now processing).

6. Update `ContentView` to display `latestTranscription` below the level meter, with a spinning indicator when `isTranscribing`.

### Done when
- App builds and runs
- Speaking into the mic produces displayed transcription text in the UI within ~800ms after speech ends

---

## T5 — Tests

**Maps to**: All REQ-STT + AC-STT
**File**: `TranslateCallTests/STTServiceTests.swift`
**Depends on**: T1–T4

### Existing unit tests (from T1, T2)

Already written. Confirm all still green.

### Additional tests

- `testSTTServicePermissionDenied()` — mock `SFSpeechRecognizer.authorizationStatus` as `.denied`; assert `activate()` throws `STTError.permissionDenied` (AC-STT-02)
- `testSTTServiceRecognizerUnavailable()` — create recognizer for unsupported locale; assert `activate()` throws `STTError.recognizerUnavailable` (AC-STT-05 prerequisite)
- `testSTTServiceNoEmitOnSilence()` — feed a SpeechSegment with silent audio (zero samples); assert no TranscriptionResult (AC-STT-03)
- `testOnDeviceFlagSet()` — for a locale supporting on-device recognition, assert `requiresOnDeviceRecognition == true` on request (AC-STT-08)
- `testSTTServiceDeactivateCleansUp()` — call `deactivate()` mid-processing; assert no further emissions (AC-STT-05)

> Integration test (real speech): deferred to F2.6 / end-to-end tests in M2 acceptance gate. Too slow and network-dependent for unit suite.

### Done when
- All unit tests green
- All AC-STT-01 through AC-STT-08 are covered by some test or documented as integration-level

---

## Task Summary

| Task | File(s) | Effort | Blocks |
|------|---------|--------|--------|
| T1 — Types + protocol | `SpeechRecognizerService.swift` | Small | T2, T4 |
| T2 — AppleSpeechService | `AppleSpeechService.swift` | Medium | T4 |
| T3 — Info.plist | `Info.plist` | Trivial | T4 |
| T4 — ViewModel + UI | `AudioViewModel.swift`, `ContentView` | Small | T5 |
| T5 — Tests | `STTServiceTests.swift` | Small | — |

---

*Gate 3 Review: human must approve this document before implementation begins.*
