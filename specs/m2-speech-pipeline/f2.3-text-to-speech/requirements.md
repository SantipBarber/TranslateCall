# F2.3: Text-to-Speech — Requirements

**Feature**: Text-to-Speech Synthesis (AVSpeechSynthesizer)
**Milestone**: M2 — Speech Pipeline
**Status**: DRAFT — awaiting Gate 1 review
**Date**: 2026-03-07
**Prerequisites**: F2.1 VAD (completed), F2.2 STT (in progress)

---

## 1. Context and Scope

`SynthesisService` accepts text strings and synthesizes speech audio in a target language. In M2 it operates as a standalone component: the UI can trigger synthesis directly (for testing) and it will be wired to Translation output in M3.

```
(M3 Translation) ──▶ SynthesisService ──▶ Audio Output Device
      │                     │
   (text in)         (speaking state)
                            │
                      AudioViewModel
```

**Routing in M2**: Output goes to the system default audio output (speakers). BlackHole routing for outgoing calls is an M4 concern. However, the architecture uses `AVSpeechSynthesizer.write(_:toBufferCallback:)` + `AVAudioPlayerNode` from the start so M4 routing requires zero architectural change (only configuration).

**Out of scope for M2**:
- BlackHole output routing (M4)
- Half-duplex mute coordination (M4)
- Voice cloning (M7)
- Reading translated text from M3 pipeline (M3)

---

## 2. Functional Requirements

### REQ-TTS-01: Synthesize text on demand
WHEN `SynthesisService.speak(text:locale:)` is called THEN the service SHALL synthesize the provided text as speech audio using the target locale.

### REQ-TTS-02: Queue synthesis requests
WHEN `speak(text:locale:)` is called while synthesis is already in progress THEN the service SHALL queue the new request and process it after the current synthesis completes.

### REQ-TTS-03: Select best available voice
WHEN synthesizing for a given locale THEN the service SHALL select the highest-quality installed voice for that locale, preferring `.enhanced` over `.default` quality voices.

### REQ-TTS-04: Fall back to any available voice
IF no `.enhanced` voice exists for the requested locale THEN the service SHALL use the first `.default` quality voice for that locale. IF no voice exists for the locale THEN synthesis SHALL be skipped and `STSError.voiceUnavailable(locale)` SHALL be logged (not thrown — synthesis is best-effort).

### REQ-TTS-05: Route audio to configured output
WHEN synthesizing THEN the audio SHALL be played through the configured audio output device. In M2 the configured device is the system default.

### REQ-TTS-06: Publish speaking state
WHILE synthesis is in progress THEN the service SHALL emit `true` on its `isSpeakingStream`. WHEN synthesis of a queued request completes THEN the service SHALL emit `false` if the queue is empty.

### REQ-TTS-07: Configurable speech rate
WHEN `SynthesisConfiguration.rate` is set THEN the synthesizer SHALL use that rate for all utterances. Valid range: `AVSpeechUtteranceMinimumSpeechRate` to `AVSpeechUtteranceMaximumSpeechRate`. Default: `AVSpeechUtteranceDefaultSpeechRate`.

### REQ-TTS-08: Configurable pitch
WHEN `SynthesisConfiguration.pitchMultiplier` is set THEN the synthesizer SHALL apply that pitch adjustment. Valid range: 0.5 – 2.0. Default: 1.0.

### REQ-TTS-09: Stop synthesis on demand
WHEN `stopSpeaking()` is called THEN the service SHALL immediately cancel the current utterance and clear the queue. `isSpeakingStream` SHALL emit `false`.

### REQ-TTS-10: Deactivate cleanly
WHEN `deactivate()` is called THEN all synthesis SHALL stop, the queue SHALL be cleared, the audio engine SHALL be stopped, and no further output SHALL occur.

### REQ-TTS-11: Indicate speaking in UI
WHILE `isSpeakingStream` emits `true` THEN `AudioViewModel.isSpeaking` SHALL be `true` and the UI SHALL reflect the speaking state (red status badge, per F1.3 design).

---

## 3. Non-Functional Requirements

### REQ-NFR-TTS-01: Latency
The time from `speak(text:locale:)` call to first audible audio SHALL be ≤ 600 ms for texts up to 100 characters, measured on Apple M-series hardware.

### REQ-NFR-TTS-02: Quality
WHEN an `.enhanced` voice is available for the requested locale THEN the synthesizer SHALL use it. Enhanced voices are downloaded by the OS independently of the app.

### REQ-NFR-TTS-03: Swift 6 compliance
`SynthesisService` SHALL compile with `-strict-concurrency=complete` and zero warnings.

### REQ-NFR-TTS-04: No audio session conflicts
The TTS audio engine SHALL NOT conflict with `AudioManager`'s input capture engine. Both SHALL run simultaneously in M2 (capture and synthesis active at the same time for loopback tests).

### REQ-NFR-TTS-05: Memory
The synthesis engine SHALL NOT accumulate unbounded audio buffers. PCM buffers produced by `write(_:toBufferCallback:)` SHALL be scheduled to `AVAudioPlayerNode` and released after playback.

---

## 4. Acceptance Criteria

| ID | Criterion |
|----|-----------|
| AC-TTS-01 | Given `speak(text: "Hola mundo", locale: Locale(identifier: "es-ES"))` is called, then audible Spanish speech is produced within 600ms |
| AC-TTS-02 | Given an `.enhanced` Spanish voice is installed, then that voice (not `.default`) is used |
| AC-TTS-03 | Given two consecutive `speak()` calls, then both utterances are heard in order |
| AC-TTS-04 | Given `stopSpeaking()` called mid-utterance, then speech stops immediately and queue is cleared |
| AC-TTS-05 | Given `isSpeakingStream`, then `true` is emitted when speech starts and `false` when it ends |
| AC-TTS-06 | Given a custom `rate = 0.6`, then speech is noticeably slower than default |
| AC-TTS-07 | Given a locale with no installed voice, then no crash occurs and a log entry is produced |
| AC-TTS-08 | Given AudioManager is capturing and TTS is speaking simultaneously, then neither engine crashes |

---

## 5. Open Questions

All resolved:

| # | Question | Resolution |
|---|----------|------------|
| 1 | Use `speak(_:)` or `write(_:toBufferCallback:)`? | `write(_:toBufferCallback:)` from M2 — routes audio through AVAudioPlayerNode for future M4 BlackHole routing with zero architecture change. |
| 2 | How to route to specific device in M2? | Use system default output in M2 (AVAudioEngine default output node). M4 sets a specific `AVAudioOutputNode` device. |
| 3 | Half-duplex muting — here or in coordinator? | Not in SynthesisService. M4 will add a `HalfDuplexCoordinator` that observes `isSpeakingStream` and mutes AudioManager's input tap. |
| 4 | Supported languages | All languages with installed AVSpeechSynthesisVoice voices. No additional downloads required by the app. |
| 5 | Should TTS queue be bounded? | No — M2 only receives one translation at a time. M3/M4 may add bounds if pipelining is introduced. |

---

*Gate 1 Review: human must approve this document before design.md is written.*
