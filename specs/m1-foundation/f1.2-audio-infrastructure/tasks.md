# F1.2 - Audio Infrastructure (AudioManager)
## Implementation Tasks

**Feature**: F1.2
**Milestone**: M1 - Foundation
**Status**: COMPLETED — 2026-03-06
**Last Updated**: 2026-03-06

---

## Task List

---

### T1 — Create Audio folder structure and AudioDevice type

**Maps to**: Design file structure, FR-1
**Owner**: Claude
**Effort**: Small

Create `TranslateCall/Core/Audio/` directory and implement `AudioDevice.swift`:

```swift
struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let hasInput: Bool
    let hasOutput: Bool
    var isBlackHole: Bool { name.contains("BlackHole") }
}
```

**Acceptance**: File compiles. `AudioDevice` is usable in previews with mock data.

---

### T2 — Implement AudioError enum

**Maps to**: FR-6, public API
**Owner**: Claude
**Effort**: Small

Create `TranslateCall/Core/Audio/AudioError.swift`:

```swift
enum AudioError: LocalizedError {
    case permissionDenied
    case deviceUnavailable(String)
    case engineStartFailed(Error)
    case noInputDevice
}
```

**Acceptance**: Compiles clean under Swift 6.

---

### T3 — Implement DeviceMonitor (hot-plug detection)

**Maps to**: FR-1 (hot-plug), AD-5
**Owner**: Claude
**Effort**: Medium

Create `TranslateCall/Core/Audio/DeviceMonitor.swift` using `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyDevices`.

The monitor calls a closure when devices change. AudioManager registers this closure to trigger re-enumeration.

**Acceptance**: Unit test — simulated device change triggers the callback. (Use mock in test; real hardware test is manual.)

---

### T4 — Implement device enumeration in AudioManager

**Maps to**: FR-1
**Owner**: Claude
**Effort**: Medium

Create `TranslateCall/Core/Audio/AudioManager.swift` as an `actor`.

Implement private `enumerateDevices()` that:
1. Gets all `AudioDeviceID`s via `kAudioHardwarePropertyDevices`
2. For each device, reads name, UID, input channel count, output channel count
3. Builds `[AudioDevice]` arrays for input and output
4. Publishes results to `@MainActor var inputDevices` and `outputDevices`

Wire `DeviceMonitor` callback to call `enumerateDevices()`.

**Acceptance**:
- Unit test: `inputDevices` and `outputDevices` are non-empty after init on a Mac with at least one audio device.
- Manual test: BlackHole 2ch appears in both lists.

---

### T5 — Implement audio capture (48kHz stream)

**Maps to**: FR-2, FR-6, AD-2, AD-4
**Owner**: Claude
**Effort**: Large

Implement in `AudioManager`:
- `startCapture() async throws` — configures engine, installs tap, starts engine
- `stopCapture() async` — removes tap, stops engine
- `var audioStream48kHz: AsyncStream<AVAudioPCMBuffer>` — continuation-based stream

The tap callback (`nonisolated`) yields buffers into the continuation.

Handle permission check before starting: use `AVCaptureDevice.requestAccess(for: .audio)`.

**Acceptance**:
- `startCapture()` without permission throws `AudioError.permissionDenied`
- After `startCapture()`, buffers are delivered to a test consumer at ≥ 40 buffers/second
- `stopCapture()` cleanly stops delivery within 500ms

---

### T6 — Implement sample rate conversion (16kHz stream)

**Maps to**: FR-4, AD-3
**Owner**: Claude
**Effort**: Medium

Add to `AudioManager`:
- `var audioStream16kHz: AsyncStream<AVAudioPCMBuffer>`
- Private `convert(buffer:) -> AVAudioPCMBuffer?` using `AVAudioConverter`
- Wire: each 48kHz buffer → convert → yield to 16kHz continuation

**Acceptance**:
- Unit test: a 48kHz buffer with 1024 frames produces a 16kHz buffer with ~341 frames (±1)
- The 16kHz buffer format is: `sampleRate=16000, channels=1, pcmFormatFloat32`

---

### T7 — Implement level metering

**Maps to**: FR-5, AD-1
**Owner**: Claude
**Effort**: Small

Add to `AudioManager`:
- `@MainActor var inputLevel: Float = -160` (RMS dBFS)
- Private `computeRMS(_ buffer:) -> Float` using `vDSP_measqv` (Accelerate framework)
- After each buffer: compute RMS → publish to `inputLevel` via `Task { @MainActor in ... }`

**Acceptance**:
- Unit test: silence buffer (all zeros) → `inputLevel ≤ -60 dBFS`
- Unit test: full-scale sine wave buffer → `inputLevel` between -3 and 0 dBFS
- Manual test: speaking into mic shows varying level in a debug print

---

### T8 — Implement device selection (input & output)

**Maps to**: FR-2, FR-3
**Owner**: Claude
**Effort**: Medium

Add to `AudioManager`:
- `selectInput(_ device: AudioDevice) async throws`
- `selectOutput(_ device: AudioDevice) async throws`
- Both methods stop the engine, reconfigure device, restart the engine
- Persist selection to `UserDefaults` using `device.uid`
- Restore last selection on `init()`

**Acceptance**:
- Switching input device while capturing stops and restarts capture seamlessly
- Selected device persists across app launches
- Selecting an unavailable device throws `AudioError.deviceUnavailable`

---

### T9 — Write unit tests

**Maps to**: All acceptance criteria
**Owner**: Claude
**Effort**: Medium

Create `TranslateCallTests/AudioManagerTests.swift` with tests for:
- `testDeviceEnumeration()` — devices non-empty
- `testSampleRateConversion()` — 1024 frames at 48kHz → ~341 frames at 16kHz
- `testRMSsilence()` — zeros → ≤ -60 dBFS
- `testRMSFullScale()` — sine wave → -3..0 dBFS
- `testAudioErrorCases()` — error enum cases compile and are throwable

Note: Tests that require real hardware (capture, device switching) are marked `@available` and skipped in CI via `#if targetEnvironment(simulator)`.

**Acceptance**: `Cmd+U` passes all tests. CI green.

---

### T10 — Validate full acceptance criteria

**Maps to**: All requirements
**Owner**: Both
**Effort**: Small

Run through the acceptance checklist in `requirements.md`:
- [ ] All audio devices listed correctly
- [ ] Device switching works without restart
- [ ] 48kHz buffer delivery confirmed
- [ ] 16kHz conversion correct
- [ ] Level meters at ≥ 10Hz
- [ ] Hot-plug detection works (manual: plug/unplug USB audio)
- [ ] BlackHole in device lists
- [ ] Permission denied error on first launch (test in simulator or reset permissions)
- [ ] No leaks after 10 start/stop cycles
- [ ] Swift 6 strict concurrency clean

**Acceptance**: All items checked. F1.2 marked complete. Ready for F1.3.

---

## Dependency Order

```
T1 (AudioDevice) ──┐
T2 (AudioError)  ──┼──▶ T4 (enumeration) ──▶ T5 (capture) ──▶ T6 (16kHz) ──▶ T7 (metering)
T3 (DeviceMonitor)─┘                                                               │
                                                                    T8 (selection) ─┤
                                                                    T9 (tests) ─────┤
                                                                                    ▼
                                                                              T10 (validate)
```

T1, T2, T3 can be done in parallel.
T4 depends on T1, T2, T3.
T5 depends on T4.
T6, T7, T8 depend on T5 and can be done in parallel.
T9 can be written alongside T4-T8.
T10 is last.
