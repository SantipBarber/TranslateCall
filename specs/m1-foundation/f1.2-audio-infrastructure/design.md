# F1.2 - Audio Infrastructure (AudioManager)
## Technical Design

**Feature**: F1.2
**Milestone**: M1 - Foundation
**Status**: COMPLETED — 2026-03-06
**Last Updated**: 2026-03-06

---

## Architecture Decisions

### AD-1: AudioManager as an Actor

**Decision**: Implement `AudioManager` as a Swift `actor`.

**Rationale**: AudioManager holds mutable state (engine, devices, selected device) that is accessed from multiple contexts (UI thread for device selection, audio thread for buffer delivery, system for hot-plug events). An actor provides compile-time data race safety under Swift 6 strict concurrency.

**Consequences**: Callers must `await` AudioManager methods. Buffer delivery callbacks run inside the actor's executor. AVAudioEngine tap callbacks (which run on an internal audio thread) use `nonisolated` wrappers to cross the actor boundary safely.

### AD-2: AVAudioEngine as the Audio Backbone

**Decision**: Use `AVAudioEngine` exclusively for capture and playback routing.

**Rationale**: AVAudioEngine provides a node-based audio graph with built-in sample rate conversion, device routing, and tap installation. It's the highest-level Apple API that still gives buffer-level access. CoreAudio directly would offer more control but at significant complexity cost.

**Consequences**: Device switching requires engine reconfiguration (stop → detach → reconfigure → start). This adds ~50-100ms when the user changes devices, which is acceptable.

### AD-3: Separate 48kHz and 16kHz Streams

**Decision**: Maintain two parallel audio streams: 48kHz for playback/routing and 16kHz for ML consumers.

**Rationale**: AVAudioEngine works natively at 48kHz (the hardware rate). ML models (VAD, STT) require 16kHz. Performing conversion in AudioManager centralizes this responsibility and keeps ML components free of audio format concerns.

**Consequences**: `AVAudioConverter` runs on every buffer (~1024 samples at 48kHz = ~21ms). CPU cost is negligible on Apple Silicon.

### AD-4: AsyncStream for Buffer Delivery

**Decision**: Use `AsyncStream<AVAudioPCMBuffer>` to deliver audio buffers to consumers.

**Rationale**: AsyncStream integrates naturally with Swift concurrency, supports multiple consumers via separate streams, and provides backpressure semantics (if a consumer is slow, buffers are dropped rather than accumulating).

**Consequences**: Consumers must be `async` contexts. Buffer references are short-lived — consumers must copy data if they need it beyond the iteration step.

### AD-5: CoreAudio for Hot-Plug Detection

**Decision**: Use `AudioObjectAddPropertyListener` (CoreAudio) for device hot-plug events.

**Rationale**: AVAudioEngine does not expose device addition/removal notifications. `kAudioHardwarePropertyDevices` provides reliable system-level notification for any audio device change.

**Consequences**: Requires a small CoreAudio bridge (a single C-style callback). This is isolated in a `DeviceMonitor` helper and does not pollute the public API.

---

## Component Design

```
┌─────────────────────────────────────────────────────────────┐
│                        AudioManager (actor)                  │
│                                                             │
│  ┌──────────────┐   ┌─────────────────────────────────┐    │
│  │ DeviceMonitor│   │        AVAudioEngine             │    │
│  │ (CoreAudio)  │   │                                  │    │
│  │              │   │  InputNode ──tap──► BufferRouter │    │
│  │ hot-plug     │   │                         │        │    │
│  │ events       │   │                    ┌────┴────┐   │    │
│  └──────┬───────┘   │                    │         │   │    │
│         │           │               48kHz stream  16kHz│    │
│         │           │               (AsyncStream) conv │    │
│         ▼           └─────────────────────────────────┘    │
│  @Published devices                                         │
│  @Published inputLevel (RMS dBFS)                          │
└─────────────────────────────────────────────────────────────┘
```

---

## Public API

```swift
// AudioDevice value type
struct AudioDevice: Identifiable, Sendable {
    let id: AudioDeviceID          // CoreAudio device ID
    let name: String
    let uid: String                // persistent UID for UserDefaults
    let hasInput: Bool
    let hasOutput: Bool
    var isBlackHole: Bool { name.contains("BlackHole") }
}

// AudioManager actor
actor AudioManager {

    // MARK: - Published state (MainActor for UI)
    @MainActor var inputDevices: [AudioDevice] = []
    @MainActor var outputDevices: [AudioDevice] = []
    @MainActor var selectedInput: AudioDevice?
    @MainActor var selectedOutput: AudioDevice?
    @MainActor var inputLevel: Float = -160     // RMS dBFS
    @MainActor var isCapturing: Bool = false

    // MARK: - Streams
    var audioStream48kHz: AsyncStream<AVAudioPCMBuffer> { get }
    var audioStream16kHz: AsyncStream<AVAudioPCMBuffer> { get }

    // MARK: - Control
    func startCapture() async throws
    func stopCapture() async

    // MARK: - Device selection
    func selectInput(_ device: AudioDevice) async throws
    func selectOutput(_ device: AudioDevice) async throws

    // MARK: - Errors
    enum AudioError: Error {
        case permissionDenied
        case deviceUnavailable(String)
        case engineStartFailed(Error)
        case noInputDevice
    }
}
```

---

## Internal Implementation Notes

### Audio Engine Setup

```swift
// Engine graph:
// inputNode → mixerNode → (tap for buffers) → outputNode
//                       ↘ AVAudioConverter → 16kHz tap

private func configureEngine() throws {
    engine.stop()
    engine.reset()

    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    // inputFormat is typically 48000 Hz, 2ch float

    // Install tap at 48kHz
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
        self?.handleBuffer(buffer)  // nonisolated
    }

    try engine.start()
}
```

### Sample Rate Conversion

```swift
private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16000,
    channels: 1,
    interleaved: false
)!

private func convert(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return nil }

    var error: NSError?
    var inputBufferConsumed = false
    converter.convert(to: output, error: &error) { _, outStatus in
        if inputBufferConsumed {
            outStatus.pointee = .noDataNow
            return nil
        }
        outStatus.pointee = .haveData
        inputBufferConsumed = true
        return buffer
    }
    return error == nil ? output : nil
}
```

### Level Metering

```swift
private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channelData = buffer.floatChannelData?[0] else { return -160 }
    let frameCount = Int(buffer.frameLength)
    var rms: Float = 0
    vDSP_measqv(channelData, 1, &rms, vDSP_Length(frameCount))
    let db = rms > 0 ? 10 * log10f(rms) : -160
    return max(-160, db)
}
```

### Hot-Plug Detection (DeviceMonitor)

```swift
// CoreAudio listener — C callback bridge
final class DeviceMonitor {
    var onDevicesChanged: (() -> Void)?

    init() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.onDevicesChanged?()
        }
    }
}
```

---

## File Structure

```
TranslateCall/Core/Audio/
├── AudioManager.swift          ← actor, public API
├── AudioDevice.swift           ← value type
├── DeviceMonitor.swift         ← CoreAudio hot-plug helper
└── AudioError.swift            ← error enum
```

---

## Key Constraints

| Constraint | Value | Source |
|-----------|-------|--------|
| Capture sample rate | 48000 Hz | Hardware default, PoC4 validated |
| ML model sample rate | 16000 Hz | FluidAudio Silero VAD requirement |
| Buffer size | 1024 samples | ~21ms at 48kHz, good latency/CPU balance |
| Level meter rate | ≥ 10 Hz | FR-5 requirement |
| Max latency | 20ms | NFR-1 |
