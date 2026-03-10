# F4.1 – Bidirectional Translation Pipeline

**Milestone**: M4 – Full Pipeline Integration
**Feature**: F4.1 – Bidirectional Translation
**Status**: DRAFT – Pending Gate 1 Review
**Date**: 2026-03-09
**Depends on**: F3.3 (One-Way Pipeline), F3.1 (TranslationBridge), F3.2 (LanguagePairManager)

---

## 1. Context & Motivation

M3 delivers a one-way pipeline: the local user speaks language A, the system translates and speaks language B into BlackHole so the remote participant hears it. This solves only half of the conversation. The remote participant's voice (language B) comes back through the system audio but is never translated.

M4 F4.1 closes the loop by adding the **incoming pipeline**: capture the remote participant's audio (language B), translate it to language A, and speak it through the local speakers so the local user understands the reply.

The result is a full **half-duplex bidirectional conversation**:

```
Local user speaks A  ──▶  [Outgoing pipeline]  ──▶  TTS(B) → BlackHole → Zoom → Remote
Remote speaks B       ──▶  [Incoming pipeline]  ──▶  TTS(A) → Speakers → Local user hears
```

### Key insight from PoC5
Echo prevention is a prerequisite for bidirectional to work. However, F4.1 **defines the dual pipeline architecture and audio routing**; the half-duplex state machine that prevents feedback between the two pipelines is specified separately in F4.2. F4.1 must expose the primitives (pipeline active/inactive flags, TTS lifecycle events) that F4.2 will consume.

---

## 2. Scope

**In scope for F4.1**:
- Outgoing pipeline: local mic → VAD → STT(A) → Translate(A→B) → TTS(B) → BlackHole
- Incoming pipeline: system audio capture → VAD → STT(B) → Translate(B→A) → TTS(A) → speakers
- `AudioCoordinator`: owns and coordinates both pipelines
- System audio capture mechanism (remote participant's voice from Zoom/Teams/Meet)
- Dual `TranslationBridge` sessions (one per direction)
- Language pair symmetry: incoming uses the swapped direction of the active language pair
- UI: two subtitle rows per direction, pipeline state indicators
- Pause/resume controls per pipeline

**Out of scope for F4.1** (covered in F4.2 / F4.3):
- Echo prevention state machine (F4.2)
- Microphone mute/unmute tied to TTS lifecycle (F4.2)
- BlackHole + Zoom setup wizard (F4.3)

---

## 3. Functional Requirements

### 3.1 Dual Pipeline

**FR-4.1.1** WHEN the user starts a session THEN the system SHALL activate both outgoing and incoming pipelines concurrently.

**FR-4.1.2** WHEN the user stops a session THEN the system SHALL deactivate both pipelines cleanly, releasing all audio resources.

**FR-4.1.3** IF a pipeline encounters a non-fatal error (e.g., STT timeout, single translation failure) THEN that pipeline SHALL log the error and continue listening; it SHALL NOT stop the other pipeline.

**FR-4.1.4** IF a pipeline encounters a fatal error (e.g., audio device removed, permission revoked) THEN the system SHALL stop BOTH pipelines and surface a recoverable error to the user.

### 3.2 Outgoing Pipeline (Local → Remote)

**FR-4.1.5** WHEN the local user's voice is detected by VAD THEN the outgoing pipeline SHALL transcribe the audio using STT configured for the **source language** (language A).

**FR-4.1.6** WHEN a transcription is produced THEN the outgoing pipeline SHALL translate it from language A to language B using the configured `TranslationService`.

**FR-4.1.7** WHEN translation completes THEN the outgoing pipeline SHALL synthesize speech in language B and route the audio to the **BlackHole output device**.

**FR-4.1.8** WHILE outgoing TTS is active, the outgoing pipeline SHALL emit an `isOutgoingSpeaking: Bool` event that F4.2 (HalfDuplexManager) consumes.

### 3.3 Incoming Pipeline (Remote → Local)

**FR-4.1.9** WHEN the system audio capture detects the remote participant's voice THEN the incoming pipeline SHALL transcribe the audio using STT configured for the **target language** (language B).

**FR-4.1.10** WHEN a transcription is produced THEN the incoming pipeline SHALL translate it from language B to language A using a separate `TranslationService` instance.

**FR-4.1.11** WHEN translation completes THEN the incoming pipeline SHALL synthesize speech in language A and route the audio to the **local speaker output device**.

**FR-4.1.12** WHILE incoming TTS is active, the incoming pipeline SHALL emit an `isIncomingSpeaking: Bool` event that F4.2 (HalfDuplexManager) consumes.

**FR-4.1.13** IF the incoming pipeline is suppressed by F4.2 (echo prevention) THEN it SHALL buffer or discard audio until suppression is lifted; it SHALL NOT crash or emit errors during suppression.

### 3.4 System Audio Capture

**FR-4.1.14** WHEN the user designates a system audio capture source THEN the system SHALL capture audio from that source and feed it to the incoming pipeline's VAD.

**FR-4.1.15** The system SHALL support at least one capture mechanism:
- **Mechanism A** (primary): Capture from a virtual audio device (e.g., BlackHole 2ch) configured by the user as a loopback of the remote audio stream.
- **Mechanism B** (secondary): ScreenCaptureKit `SCStream` audio capture from a specific running application (Zoom, Teams, etc.) — macOS 13+.

> **Design note**: The choice between Mechanism A and B is deferred to `design.md`. Requirements mandate that a mechanism exists; the implementation may start with A and add B later.

**FR-4.1.16** IF the system audio capture source is unavailable or not configured THEN the incoming pipeline SHALL remain disabled and the user SHALL be notified with an actionable message.

### 3.5 Language Pair Symmetry

**FR-4.1.17** WHEN the user changes the active language pair (A→B) THEN both pipelines SHALL automatically update:
- Outgoing: STT locale = A, translation = A→B, TTS locale = B
- Incoming: STT locale = B, translation = B→A, TTS locale = A

**FR-4.1.18** WHEN the user swaps the language pair (A↔B) THEN the system SHALL swap both pipelines symmetrically without interrupting an active session.

### 3.6 Translation Sessions

**FR-4.1.19** The outgoing and incoming pipelines SHALL use **separate** `TranslationBridgeModel` and `AppleTranslationService` instances to avoid session conflicts.

**FR-4.1.20** WHEN a translation session is not yet downloaded for the incoming direction (B→A) THEN the system SHALL prompt the user to download it, using the same flow as F3.2.

### 3.7 UI

**FR-4.1.21** WHILE a session is active THE UI SHALL display four text rows:
- Row 1: Local user's transcription (language A) — outgoing pipeline
- Row 2: Translated outgoing text (language B) — what remote user hears
- Row 3: Remote participant's transcription (language B) — incoming pipeline
- Row 4: Translated incoming text (language A) — what local user hears

**FR-4.1.22** WHILE a session is active THE UI SHALL show a **pipeline direction indicator**:
- Outgoing active (local mic → translation): green mic icon
- Incoming active (remote audio → translation): green headphone icon
- Either TTS speaking: respective icon turns orange/red (to be refined in F4.2)

**FR-4.1.23** WHEN both pipelines are idle (no speech detected) THE status badge SHALL show "Listening" with green indicator.

---

## 4. Non-Functional Requirements

### 4.1 Performance

**NFR-4.1.1** The incoming pipeline SHALL add no more than 200ms latency to the existing one-way pipeline (total end-to-end for incoming: < 3 seconds).

**NFR-4.1.2** System audio capture SHALL NOT introduce audio glitches detectable in the outgoing TTS output.

**NFR-4.1.3** Running both pipelines simultaneously SHOULD increase CPU usage by no more than 50% relative to the one-way pipeline (target: < 25% sustained CPU on Apple M1).

### 4.2 Audio Quality

**NFR-4.1.4** The incoming pipeline SHALL capture system audio at 48 kHz and downsample to 16 kHz for VAD/STT (same as the existing outgoing pipeline).

**NFR-4.1.5** The outgoing TTS output to BlackHole SHALL use the same sample rate as BlackHole's native format (48 kHz stereo, as validated in PoC4).

### 4.3 Privacy

**NFR-4.1.6** System audio capture SHALL request explicit user permission (macOS Privacy: Screen Recording for `SCStream`, or equivalent for virtual device access) before activating the incoming pipeline.

**NFR-4.1.7** No audio from either pipeline SHALL be written to disk or sent to external services; all processing SHALL remain on-device.

### 4.4 Reliability

**NFR-4.1.8** WHEN an audio device is disconnected during an active session THEN the system SHALL detect the interruption within 2 seconds and surface a clear error with a "reconnect" action.

**NFR-4.1.9** The pipelines SHALL operate stably for 60-minute sessions without memory leaks or audio degradation.

---

## 5. Constraints

**C-4.1.1** The `TranslationSession` API requires a SwiftUI context (`TranslationBridge` pattern). Both directions require their own `.translationTask()` modifier — the existing single `TranslationBridge` must be extended or duplicated.

**C-4.1.2** `SFSpeechRecognizer` does not support concurrent requests for the same locale. Each pipeline MUST use its own `SpeechRecognizerService` instance.

**C-4.1.3** `AVSpeechSynthesizer.write(_:toBufferCallback:)` (the buffer callback used in `AVSpeechService`) is incompatible with concurrent synthesis. Each pipeline MUST use its own `AVSpeechService` instance.

**C-4.1.4** BlackHole 2ch is a single virtual device with one input bus and one output bus. Routing Zoom audio BACK through BlackHole (for incoming capture) while also routing outgoing TTS TO BlackHole requires careful configuration — typically using macOS `Multi-Output Device` and `Aggregate Device` in Audio MIDI Setup, or a dedicated second virtual device. This is addressed in the design phase.

**C-4.1.5** `ScreenCaptureKit` (`SCStream`) requires the `com.apple.security.screen-capture` entitlement and user permission dialog. This may not be required if using Mechanism A (virtual device loopback), which requires no additional entitlement.

**C-4.1.6** `AVAudioEngine.isVoiceProcessingEnabled` requires both input and output to be the same audio unit — this is incompatible with routing outgoing TTS to BlackHole while capturing from the system microphone. Therefore, hardware AEC is NOT available for this use case; F4.2 MUST implement software-level half-duplex echo prevention.

---

## 6. Acceptance Criteria

| ID | Criterion | Test Method |
|----|-----------|-------------|
| AC-4.1.1 | Both pipelines start and stop cleanly with no resource leaks | Unit test: start → 5s run → stop, verify no dangling Tasks |
| AC-4.1.2 | Outgoing pipeline correctly routes TTS to BlackHole device | Integration test: check audio device of `AVSpeechService` outgoing instance |
| AC-4.1.3 | Incoming pipeline correctly routes TTS to speaker device | Integration test: check audio device of `AVSpeechService` incoming instance |
| AC-4.1.4 | Language pair change updates both pipelines' STT locales | Unit test: change pair A→B to C→D, verify both STT services reconfigured |
| AC-4.1.5 | Language pair swap updates both pipelines symmetrically | Unit test: swap A↔B, verify outgoing STT=B and incoming STT=A |
| AC-4.1.6 | Two separate `TranslationBridgeModel` instances exist | Unit test: inspect `AppContainer`, verify two bridge models |
| AC-4.1.7 | Incoming pipeline disables when no capture source configured | Unit test: start session without capture device, verify incoming disabled + alert shown |
| AC-4.1.8 | UI displays 4 text rows during active session | UI test / manual: both transcription rows and translation rows visible |
| AC-4.1.9 | Fatal error in either pipeline stops both and shows alert | Unit test: inject `AudioError.deviceUnavailable`, verify both stopped |
| AC-4.1.10 | Non-fatal STT error in one pipeline does NOT affect the other | Unit test: inject STT timeout on outgoing, verify incoming still processes |

---

## 7. Open Questions

| # | Question | Owner | Status |
|---|----------|-------|--------|
| OQ-1 | Should Mechanism A (virtual device) or Mechanism B (SCStream) be the MVP implementation? SCStream is cleaner (no user AudioMIDISetup configuration) but requires Screen Recording permission which users may distrust. | Architecture | **Unresolved — defer to design.md** |
| OQ-2 | If Mechanism A is chosen, should we require a second BlackHole instance (e.g., BlackHole 16ch) for incoming capture, or guide users to create an Aggregate Device? | Architecture | **Unresolved — defer to design.md** |
| OQ-3 | For the incoming pipeline, can we reuse `VADServiceFactory` (Energy+Silero upgrade) or should the incoming pipeline start with Energy VAD only to reduce memory footprint? | Architecture | **Tentative: start with Energy VAD, upgrade to Silero if performance allows** |
| OQ-4 | Should the incoming pipeline's transcription be shown in the UI continuously, or only when a complete utterance is detected? | UX | **Tentative: only complete utterances (same as outgoing)** |
| OQ-5 | How to handle the case where the remote participant speaks language A (same as local user)? Should the incoming pipeline detect language and skip translation if same-language? | UX | **Unresolved — likely a F4.3 or M5 concern** |

---

## 8. Dependencies on Other Features

| Feature | Dependency Type | Notes |
|---------|----------------|-------|
| F3.1 TranslationBridge | Extension | Need a second `TranslationBridge` SwiftUI view instance or extend to multi-config |
| F3.2 LanguagePairManager | Reuse | Both pipelines derive their locales from the same `LanguagePairManager` |
| F3.3 One-Way Pipeline | Base | Outgoing pipeline = M3's F3.3 pipeline (no changes needed beyond AudioCoordinator integration) |
| F4.2 Echo Management | Downstream | F4.1 must expose `isOutgoingSpeaking` and `isIncomingSpeaking` streams for F4.2 |
| F4.3 Video Call Integration | Downstream | F4.1 exposes audio routing configuration that F4.3's setup wizard configures |

---

*End of F4.1 Requirements — Gate 1 Review Pending*
