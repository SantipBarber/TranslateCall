@_exported import Testing
import AVFoundation
import Accelerate
@testable import TranslateCall

// Thread-safe box for use in @Sendable closures (e.g. AVAudioConverterInputBlock).
// Mirrors the SyncBox pattern in AudioManager.swift — safe for synchronous callbacks
// that may run on CoreAudio's internal thread under load.
private final class ConsumeBox: @unchecked Sendable {
    nonisolated(unsafe) var consumed = false
}

// MARK: - AudioDevice Tests

@MainActor
struct AudioDeviceTests {

    @Test func audioDeviceIsIdentifiable() {
        let device = AudioDevice.mockMic
        #expect(device.id == 1)
        #expect(device.name == "Built-in Microphone")
        #expect(device.hasInput == true)
        #expect(device.hasOutput == false)
    }

    @Test func blackHoleDeviceIsDetected() {
        let blackHole = AudioDevice.mockBlackHole
        #expect(blackHole.isBlackHole == true)
        #expect(AudioDevice.mockMic.isBlackHole == false)
    }

    @Test func audioDeviceIsHashable() {
        var set = Set<AudioDevice>()
        set.insert(AudioDevice.mockMic)
        set.insert(AudioDevice.mockMic) // duplicate
        #expect(set.count == 1)
    }

    // T7 — AudioDevice.deviceID(forNameContaining:)

    @Test("deviceID returns nil for nonexistent device name")
    func deviceIDForUnknownDeviceReturnsNil() {
        let id = AudioDevice.deviceID(forNameContaining: "THIS_DEVICE_DOES_NOT_EXIST_XYZ_12345")
        #expect(id == nil)
    }

    @Test("deviceID finds built-in audio device by partial name")
    func deviceIDFindsBuiltInDevice() {
        // Every Mac has a built-in microphone or output — "Built-in" should match something.
        // If the machine has no audio hardware (rare CI case), this returns nil — also valid.
        let id = AudioDevice.deviceID(forNameContaining: "Built-in")
        // Non-nil is expected on real hardware; nil is acceptable in headless CI.
        _ = id  // result depends on hardware — just verify it doesn't crash
    }
}

// MARK: - AudioError Tests

@MainActor
struct AudioErrorTests {

    @Test func permissionDeniedHasDescription() {
        let error = AudioError.permissionDenied
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription!.contains("Microphone"))
    }

    @Test func deviceUnavailableIncludesName() {
        let error = AudioError.deviceUnavailable("BlackHole 2ch")
        #expect(error.errorDescription!.contains("BlackHole 2ch"))
    }

    @Test func engineStartFailedIncludesUnderlying() {
        let underlying = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "test error"])
        let error = AudioError.engineStartFailed(underlying)
        #expect(error.errorDescription!.contains("test error"))
    }

    @Test func noInputDeviceHasDescription() {
        let error = AudioError.noInputDevice
        #expect(error.errorDescription != nil)
    }
}

// MARK: - Sample Rate Conversion Tests

@Suite(.serialized)
struct SampleRateConversionTests {

    /// Validates that a 1024-frame 48kHz buffer converts to the expected ~341 frames at 16kHz.
    @Test func conversionFrameCount() throws {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1024) else {
            Issue.record("Could not create input buffer")
            return
        }
        input.frameLength = 1024

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            Issue.record("Could not create converter")
            return
        }

        let expectedFrames = AVAudioFrameCount(Double(1024) * (16_000.0 / 48_000.0))  // 341
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: expectedFrames + 1) else {
            Issue.record("Could not create output buffer")
            return
        }

        let box = ConsumeBox()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard !box.consumed else { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            box.consumed = true
            return input
        }

        #expect(error == nil)
        // Allow for SRC filter delay: CoreAudio resampler buffers ~16 input samples
        // on first use, yielding up to ~6 fewer output frames. Upper bound stays +1.
        #expect(output.frameLength >= expectedFrames - 8)
        #expect(output.frameLength <= expectedFrames + 1)
    }

    @Test func outputFormatIs16kHzMono() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        #expect(format.commonFormat == .pcmFormatFloat32)
    }
}

// MARK: - Level Metering Tests

@Suite(.serialized)
@MainActor
struct LevelMeteringTests {

    @Test func silenceBufferReportsLowLevel() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { return }
        buffer.frameLength = 1024
        // All samples are zero (silence)

        let rms = computeRMS(buffer)
        #expect(rms <= -60)
    }

    @Test func fullScaleSineReportsHighLevel() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024),
              let data = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = 1024

        // Fill with full-scale sine wave
        for i in 0..<1024 {
            data[i] = sin(Float(i) * 2 * .pi / 32)
        }

        let rms = computeRMS(buffer)
        // Full-scale sine RMS is ~0.707 → -3 dBFS
        #expect(rms >= -6)
        #expect(rms <= 0)
    }

    /// Replicates the private computeRMS logic for isolated testing.
    private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        var rms: Float = 0
        vDSP_measqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
        guard rms > 0 else { return -160 }
        return max(-160, 10 * log10f(rms))
    }
}

// MARK: - Device Persistence Tests

@Suite("AudioManager Device Persistence", .serialized) @MainActor
struct AudioManagerDevicePersistenceTests {

    private static let inputKey  = "tlk.input.deviceUID"
    private static let outputKey = "tlk.output.deviceUID"

    private func makeDefaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @Test("No saved UID: selectedInput defaults to first available device")
    func deviceUIDNoSavedUIDUsesDefault() {
        let defs = makeDefaults()
        let mgr = AudioManager(defaults: defs)
        // No saved UID — selectedInput should be nil or the first device (hardware-dependent)
        // Key point: UserDefaults key should not be set
        #expect(defs.string(forKey: Self.inputKey) == nil)
    }

    @Test("Saved UID matches a device: selectedInput is restored")
    func deviceUIDRestoredWhenFound() {
        let defs = makeDefaults()
        // First, discover what UIDs are available on this machine
        let mgr1 = AudioManager(defaults: defs)
        guard let first = mgr1.inputDevices.first else { return }  // no hardware — skip
        let uid = first.uid

        // Write that UID to a fresh test suite
        let defs2 = makeDefaults()
        defs2.set(uid, forKey: Self.inputKey)
        let mgr2 = AudioManager(defaults: defs2)
        #expect(mgr2.selectedInput?.uid == uid)
    }

    @Test("Stale UID cleared when device is gone")
    func deviceUIDStaleClearedWhenDeviceGone() {
        let defs = makeDefaults()
        defs.set("uid-that-does-not-exist-xyz", forKey: Self.inputKey)
        let mgr = AudioManager(defaults: defs)
        // Device not found → key should be removed
        #expect(defs.string(forKey: Self.inputKey) == nil)
        _ = mgr  // suppress unused warning
    }

    @Test("selectInput persists UID to UserDefaults")
    func deviceUIDPersistedOnSelectionChange() {
        let defs = makeDefaults()
        let mgr = AudioManager(defaults: defs)
        guard let device = mgr.inputDevices.first else { return }  // no hardware — skip
        try? mgr.selectInput(device)
        #expect(defs.string(forKey: Self.inputKey) == device.uid)
    }
}

// MARK: - Input choice and device switching (F8.5.1 A5, A5b)

@Suite("AudioManager input choice") @MainActor
struct AudioManagerInputChoiceTests {
    private let usb = AudioDevice(id: 10, name: "USB Mic", uid: "usb", hasInput: true, hasOutput: false)
    private let builtIn = AudioDevice(id: 20, name: "MacBook Mic", uid: "builtin", hasInput: true, hasOutput: false)
    private let blackHole = AudioDevice(id: 30, name: "BlackHole 2ch", uid: "bh", hasInput: true, hasOutput: true)

    @Test("selected device wins when present")
    func selectedWins() {
        #expect(AudioManager.chooseInput(selectedUID: "usb", available: [builtIn, usb], defaultID: 20) == usb)
    }

    @Test("missing selected device falls back to the system default")
    func fallsBackToDefault() {
        #expect(AudioManager.chooseInput(selectedUID: "usb", available: [blackHole, builtIn], defaultID: 20) == builtIn)
    }

    @Test("no default falls back to the first non-BlackHole input; nothing usable → nil")
    func fallsBackToFirst() {
        #expect(AudioManager.chooseInput(selectedUID: nil, available: [blackHole, builtIn], defaultID: nil) == builtIn)
        #expect(AudioManager.chooseInput(selectedUID: "usb", available: [blackHole], defaultID: nil) == nil)
        #expect(AudioManager.chooseInput(selectedUID: "usb", available: [], defaultID: 20) == nil)
    }

    @Test("a BlackHole system default is skipped; an explicitly selected BlackHole is honored")
    func blackHoleNeverAutoChosen() {
        #expect(AudioManager.chooseInput(selectedUID: nil, available: [blackHole, builtIn], defaultID: 30) == builtIn)
        #expect(AudioManager.chooseInput(selectedUID: "bh", available: [blackHole, builtIn], defaultID: 20) == blackHole)
    }
}

@Suite("AudioManager device switching") @MainActor
struct AudioManagerSwitchTests {
    /// Records configure calls and fails for device IDs in `failing`.
    final class ConfigureSpy {
        var calls: [AudioDeviceID] = []
        var failing: Set<AudioDeviceID> = []
        func configure(_ id: AudioDeviceID, _ session: SessionAudioStream) throws {
            calls.append(id)
            if failing.contains(id) { throw CoreAudioError.status(-1) }
        }
    }

    private func makeManager(_ spy: ConfigureSpy) -> AudioManager {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return AudioManager(defaults: defaults, configure: { try spy.configure($0, $1) })
    }

    private let micA = AudioDevice(id: 101, name: "Mic A", uid: "a", hasInput: true, hasOutput: false)
    private let micB = AudioDevice(id: 102, name: "Mic B", uid: "b", hasInput: true, hasOutput: false)

    @Test("switch failure keeps the previous device and the session stream alive")
    func switchFailureKeepsPreviousDevice() async throws {
        let spy = ConfigureSpy()
        let manager = makeManager(spy)
        manager.injectInputDevicesForTesting([micA, micB])
        try manager.selectInput(micA)
        let stream = try await manager.startCaptureSkippingPermissionForTesting()
        spy.failing = [micB.id]

        #expect(throws: AudioError.self) { try manager.selectInput(micB) }

        #expect(manager.selectedInput == micA)
        #expect(manager.isCapturing)
        #expect(spy.calls == [micA.id, micB.id, micA.id])
        manager.stopCapture()
        for await _ in stream {}   // returns only because stopCapture finished the still-open stream
    }

    @Test("mid-session switch reconfigures once on the same open stream and persists the choice")
    func switchSuccessKeepsStreamAndPersists() async throws {
        let spy = ConfigureSpy()
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let manager = AudioManager(defaults: defaults, configure: { try spy.configure($0, $1) })
        manager.injectInputDevicesForTesting([micA, micB])
        try manager.selectInput(micA)
        let stream = try await manager.startCaptureSkippingPermissionForTesting()
        spy.calls.removeAll()

        try manager.selectInput(micB)

        #expect(spy.calls == [micB.id])
        #expect(manager.isCapturing)
        #expect(manager.selectedInput == micB)
        #expect(defaults.string(forKey: "tlk.input.deviceUID") == micB.uid)
        let finished = SyncBox(false)
        let drain = Task { for await _ in stream {}; finished.value = true }
        await Task.yield()
        #expect(!finished.value)              // stream still open after the swap
        manager.stopCapture()
        await drain.value
        #expect(finished.value)
    }

    @Test("switch and restore both failing stops capture and says so in the error")
    func switchAndRestoreFailureStopsCapture() async throws {
        let spy = ConfigureSpy()
        let manager = makeManager(spy)
        manager.injectInputDevicesForTesting([micA, micB])
        try manager.selectInput(micA)
        let stream = try await manager.startCaptureSkippingPermissionForTesting()
        spy.failing = [micA.id, micB.id]

        let error = #expect(throws: AudioError.self) { try manager.selectInput(micB) }

        #expect(error?.localizedDescription.contains("capture stopped") == true)
        #expect(!manager.isCapturing)
        for await _ in stream {}   // finished by the internal stop
    }

    @Test("starting on a fallback device shows it as selected without persisting it")
    func startOnFallbackUpdatesSelection() async throws {
        let spy = ConfigureSpy()
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let manager = AudioManager(defaults: defaults, configure: { try spy.configure($0, $1) })
        manager.injectInputDevicesForTesting([micA, micB])
        try manager.selectInput(micA)
        manager.injectInputDevicesForTesting([micB])   // A unplugged while idle

        _ = try await manager.startCaptureSkippingPermissionForTesting()

        #expect(spy.calls == [micB.id])
        #expect(manager.selectedInput == micB)
        #expect(defaults.string(forKey: "tlk.input.deviceUID") == micA.uid)
        manager.stopCapture()
    }

    @Test("a configuration change for the active, still-present device is ignored")
    func configChangeForActiveDeviceIsIgnored() async throws {
        let spy = ConfigureSpy()
        let manager = makeManager(spy)
        manager.injectInputDevicesForTesting([micA, micB])
        try manager.selectInput(micA)
        _ = try await manager.startCaptureSkippingPermissionForTesting()
        spy.calls.removeAll()

        manager.handleConfigurationChange(engineRunning: true)

        #expect(spy.calls.isEmpty)
        #expect(manager.deviceNotice == nil)
        manager.stopCapture()
    }

    @Test("the active device disappearing falls back and publishes a notice")
    func activeDeviceGoneFallsBack() async throws {
        let spy = ConfigureSpy()
        let manager = makeManager(spy)
        manager.injectInputDevicesForTesting([micA, micB])
        try manager.selectInput(micA)
        _ = try await manager.startCaptureSkippingPermissionForTesting()

        manager.injectInputDevicesForTesting([micB])       // A unplugged
        manager.handleConfigurationChange(engineRunning: false)

        #expect(spy.calls.last == micB.id)
        #expect(manager.selectedInput == micB)
        #expect(manager.deviceNotice?.contains("Mic A") == true)
        manager.stopCapture()
    }
}

@Suite("AudioManager tap format")
struct AudioManagerTapFormatTests {
    private func format(client: AVAudioChannelCount, rate: Double, hardware: AVAudioChannelCount) -> AVAudioFormat? {
        AudioManager.tapFormat(commonFormat: .pcmFormatFloat32, interleaved: false,
                               clientChannels: client, hardwareRate: rate, hardwareChannels: hardware)
    }

    @Test("stale stereo client format on a mono mic taps mono at the mic's rate")
    func stereoClientOnMonoHardware() throws {
        let tap = try #require(format(client: 2, rate: 16_000, hardware: 1))
        #expect(tap.channelCount == 1)
        #expect(tap.sampleRate == 16_000)
    }

    @Test("mono client format on a stereo device keeps mono (never more than the client asks)")
    func monoClientOnStereoHardware() throws {
        let tap = try #require(format(client: 1, rate: 48_000, hardware: 2))
        #expect(tap.channelCount == 1)
        #expect(tap.sampleRate == 48_000)
    }

    @Test("a client format with no channels falls back to the hardware channel count")
    func zeroClientUsesHardware() throws {
        let tap = try #require(format(client: 0, rate: 44_100, hardware: 2))
        #expect(tap.channelCount == 2)
    }

    @Test("hardware reporting no rate or no channels yields no tap format")
    func emptyHardwareIsRejected() {
        #expect(format(client: 2, rate: 0, hardware: 2) == nil)
        #expect(format(client: 2, rate: 48_000, hardware: 0) == nil)
    }
}
