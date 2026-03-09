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
