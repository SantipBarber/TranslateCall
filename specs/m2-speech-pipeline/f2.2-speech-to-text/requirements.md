# F2.2: Speech-to-Text — Requirements

**Feature**: Speech-to-Text Integration (Apple Speech Framework)
**Milestone**: M2 — Speech Pipeline
**Status**: DRAFT — awaiting Gate 1 review
**Date**: 2026-03-07
**Prerequisites**: F2.1 VAD Integration (completed)

---

## 1. Context and Scope

`SpeechRecognizerService` receives complete speech segments from `VADService.speechSegments` and produces `TranscriptionResult` values. It is the second stage in the pipeline:

```
AudioManager → VADService → SpeechRecognizerService → (F2.3 TTS / M3 Translation)
```

This feature covers **on-device** speech recognition via Apple's Speech framework (`SFSpeechRecognizer`). The output locale (source language of the speaker) is configurable at runtime. Routing the transcription to Translation (M3) is out of scope for M2 — in M2 the result is displayed directly in the UI.

---

## 2. Functional Requirements

### REQ-STT-01: Consume VAD speech segments
WHEN `SpeechRecognizerService` is active AND `VADService` emits a `SpeechSegment` THEN the service SHALL begin speech recognition on that segment's audio buffer.

### REQ-STT-02: Transcribe complete utterances
WHEN a `SpeechSegment` is received THEN the service SHALL submit the audio as a complete (non-streaming) recognition request and wait for the final result before proceeding to the next segment.

### REQ-STT-03: Emit transcription results
WHEN speech recognition succeeds AND the result meets the confidence threshold THEN the service SHALL emit a `TranscriptionResult` on its output stream.

### REQ-STT-04: Discard low-confidence results
IF the average word-level confidence of a recognition result is below `minimumConfidence` (default 0.60) THEN the service SHALL discard the result and NOT emit it.

### REQ-STT-05: Support configurable source language
WHEN `SpeechRecognizerService` is initialized with a `Locale` THEN it SHALL use an `SFSpeechRecognizer` for that locale for all subsequent recognition requests.

### REQ-STT-06: Support runtime locale switching
WHEN the active locale changes THEN the service SHALL stop the current recognizer and create a new `SFSpeechRecognizer` for the new locale on the next segment.

### REQ-STT-07: Request speech recognition permission
WHEN `SpeechRecognizerService` first activates THEN it SHALL request `SFSpeechRecognizer.requestAuthorization` if not already granted.

### REQ-STT-08: Handle permission denied
IF speech recognition authorization is `.denied` or `.restricted` THEN `activate(stream:)` SHALL throw `STTError.permissionDenied`.

### REQ-STT-09: Handle recognizer unavailability
IF `SFSpeechRecognizer.isAvailable` is `false` for the configured locale THEN the service SHALL throw `STTError.recognizerUnavailable(locale)`.

### REQ-STT-10: Handle recognition errors gracefully
WHEN a recognition request fails with an error THEN the service SHALL log the error, skip that segment, and continue processing the next segment without crashing.

### REQ-STT-11: Display transcription in UI
WHILE `SpeechRecognizerService` is active THEN `AudioViewModel` SHALL display the most recent `TranscriptionResult.text` in the main window.

### REQ-STT-12: Display in-progress indicator
WHILE a recognition request is in flight THEN `AudioViewModel` SHALL expose `isTranscribing: Bool = true` for UI feedback.

---

## 3. Non-Functional Requirements

### REQ-NFR-STT-01: Latency
The time from `SpeechSegment` receipt to `TranscriptionResult` emission SHALL be ≤ 800 ms for utterances up to 5 seconds long, measured on Apple M-series hardware with an active internet connection.

### REQ-NFR-STT-02: Privacy
All recognition requests SHALL use `SFSpeechRecognitionRequest.requiresOnDeviceRecognition = true` when the recognizer supports on-device mode. Off-device processing is acceptable only for locales that do not support on-device recognition.

### REQ-NFR-STT-03: Swift 6 compliance
`SpeechRecognizerService` SHALL compile with `-strict-concurrency=complete` and zero warnings.

### REQ-NFR-STT-04: Resource cleanup
WHEN `deactivate()` is called THEN all in-flight recognition tasks SHALL be cancelled and no further output SHALL be emitted.

### REQ-NFR-STT-05: No audio data retention
The service SHALL NOT persist or cache audio buffers or recognition results beyond the duration of a single recognition request.

---

## 4. Entitlement and Configuration

### REQ-STT-20: NSSpeechRecognitionUsageDescription
The app's `Info.plist` SHALL contain `NSSpeechRecognitionUsageDescription` with a user-facing string explaining why speech recognition is needed.
> Suggested: "TranslateCall uses speech recognition to transcribe your spoken words for translation."

### REQ-STT-21: No network entitlement change needed
`SFSpeechRecognizer` manages its own network access via the system. No additional entitlements beyond the existing microphone entitlement are required.

---

## 5. Acceptance Criteria

| ID | Criterion |
|----|-----------|
| AC-STT-01 | Given microphone permission granted and Spanish locale configured, when a 3-second synthetic voice segment is fed as a SpeechSegment, then a TranscriptionResult is emitted within 800ms |
| AC-STT-02 | Given permission denied, when activate() is called, then STTError.permissionDenied is thrown |
| AC-STT-03 | Given a silent (zero-sample) SpeechSegment fed, then no TranscriptionResult is emitted |
| AC-STT-04 | Given a result with average confidence below 0.60, then no TranscriptionResult is emitted |
| AC-STT-05 | Given deactivate() called mid-recognition, then no further results are emitted and resources are freed |
| AC-STT-06 | Given locale changed from "es-ES" to "en-US", then the next segment uses the new recognizer |
| AC-STT-07 | Given a failed recognition request (network error), then the next segment is processed normally |
| AC-STT-08 | Given on-device recognition supported for the locale, then requiresOnDeviceRecognition is set to true |

---

## 6. Open Questions

All questions are resolved:

| # | Question | Resolution |
|---|----------|------------|
| 1 | Should we support streaming partial results in M2? | No — partial results in M2 are out of scope. We await final result per complete segment. M3/M4 can add streaming if needed. |
| 2 | What confidence threshold? | 0.60, matching the ROADMAP specification. Configurable via `STTConfiguration`. |
| 3 | On-device vs cloud recognition? | Prefer on-device (`requiresOnDeviceRecognition = true`) when supported. Fall back to cloud silently. |
| 4 | Language model customization (SFSpeechLanguageModel)? | Deferred to M6 (Enhanced STT). Not in scope for M2. |

---

*Gate 1 Review: human must approve this document before design.md is written.*
