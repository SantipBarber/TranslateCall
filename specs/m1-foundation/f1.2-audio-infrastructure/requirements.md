# F1.2 - Audio Infrastructure (AudioManager)
## Requirements

**Feature**: F1.2
**Milestone**: M1 - Foundation
**Status**: COMPLETED — 2026-03-06
**Last Updated**: 2026-03-06

---

## Context

AudioManager is the central audio component of TranslateCall. It wraps AVAudioEngine and provides:
- Enumeration of all audio devices (input and output)
- Real-time audio capture from a selected input device
- Audio playback routing to a selected output device (speakers or BlackHole)
- Sample rate conversion (48kHz → 16kHz) for downstream ML models (VAD, STT)
- Real-time level metering for UI visualization

This component is consumed by all higher-level features (VAD in F2.1, STT in F2.2, TTS in F2.3, bidirectional pipeline in F4.1).

---

## Functional Requirements

### FR-1: Device Enumeration

- WHEN AudioManager initializes THEN it SHALL enumerate all available audio input devices on the system.
- WHEN AudioManager initializes THEN it SHALL enumerate all available audio output devices on the system.
- WHEN a new audio device is connected or disconnected THEN AudioManager SHALL update its device lists within 2 seconds (hot-plug detection).
- WHEN BlackHole 2ch is installed THEN it SHALL appear in both input and output device lists.
- WHEN no audio devices are available THEN AudioManager SHALL emit an error state (not crash).

### FR-2: Input Device Selection

- WHEN the user selects an input device THEN AudioManager SHALL reconfigure the audio engine to capture from that device.
- WHEN an input device is selected THEN AudioManager SHALL capture audio at 48kHz, 32-bit float, mono (downmixed from stereo if needed).
- WHEN capturing audio THEN AudioManager SHALL deliver audio buffers to registered consumers via a callback/stream.
- IF the selected input device becomes unavailable THEN AudioManager SHALL emit a `deviceDisconnected` event and stop capture gracefully.

### FR-3: Output Device Selection

- WHEN the user selects an output device THEN AudioManager SHALL route audio playback to that device.
- WHEN BlackHole 2ch is selected as output THEN audio played SHALL be audible to any app using BlackHole as its input (e.g., Zoom).
- IF the selected output device becomes unavailable THEN AudioManager SHALL fall back to the system default output.

### FR-4: Sample Rate Conversion

- WHEN audio is captured at 48kHz THEN AudioManager SHALL provide a 16kHz downsampled stream for ML consumers (VAD, STT).
- WHEN performing sample rate conversion THEN the conversion SHALL use AVAudioConverter with high-quality settings.
- WHILE the 16kHz stream is active THEN it SHALL maintain < 10ms conversion latency per buffer.

### FR-5: Level Metering

- WHILE audio is being captured THEN AudioManager SHALL compute RMS and peak levels from the raw audio buffers.
- WHEN level data is computed THEN it SHALL be published at minimum 10 times per second (≤ 100ms interval).
- WHEN there is silence THEN the RMS level SHALL report ≤ -60 dBFS.
- WHEN the microphone captures speech at normal volume THEN the RMS level SHALL report between -30 dBFS and -6 dBFS.

### FR-6: Start / Stop Control

- WHEN `startCapture()` is called THEN AudioManager SHALL begin audio capture from the selected input device.
- WHEN `stopCapture()` is called THEN AudioManager SHALL stop capture and release audio engine resources.
- WHEN `startCapture()` is called without microphone permission THEN it SHALL throw a `PermissionDenied` error.
- WHEN `startCapture()` is called and no input device is selected THEN it SHALL use the system default input device.

---

## Non-Functional Requirements

### NFR-1: Latency
- WHILE capturing audio THEN the buffer delivery latency SHALL be ≤ 20ms (one buffer duration at 48kHz with 1024-sample buffer size).

### NFR-2: Thread Safety
- WHEN audio buffers are delivered THEN they SHALL be delivered on a dedicated audio thread (not main thread).
- WHEN level data is published THEN it SHALL be safe to observe from the main thread (via `@MainActor` or Combine).

### NFR-3: Resource Usage
- WHILE capturing audio THE CPU usage of AudioManager alone SHALL not exceed 3% on Apple Silicon.
- WHEN `stopCapture()` is called THEN all AVAudioEngine resources SHALL be deallocated within 500ms.

### NFR-4: Swift 6 Concurrency
- AudioManager SHALL be implemented as an `actor` or use explicit `@MainActor` / `nonisolated` annotations.
- All public APIs SHALL be `async` or `@MainActor` where appropriate to satisfy strict concurrency checking.

---

## Out of Scope (F1.2)

- VAD processing of captured audio → F2.1
- STT transcription → F2.2
- TTS playback → F2.3
- Half-duplex muting logic → F4.2
- System audio capture (loopback) for incoming remote audio → F4.1

---

## Acceptance Criteria

- [ ] All available audio input and output devices are listed correctly
- [ ] Selecting a different input device reconfigures capture without restart
- [ ] Audio captured at 48kHz is delivered to a test consumer callback
- [ ] 16kHz downsampled stream is available and correct (verified by sample count)
- [ ] Level meters update at ≥ 10Hz during active capture
- [ ] Hot-plug: connecting/disconnecting a USB audio device updates the device list
- [ ] BlackHole 2ch appears in device lists when installed
- [ ] `startCapture()` without permission throws `PermissionDenied`
- [ ] No crashes or resource leaks after 10 start/stop cycles
- [ ] All code compiles clean under Swift 6 strict concurrency
