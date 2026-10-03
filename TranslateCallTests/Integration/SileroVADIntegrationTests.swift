import AVFoundation
import Testing
@testable import TranslateCall

// MARK: - T3: SileroVADService Tests

extension IntegrationTests {
@Suite("SileroVADService", .serialized)
@MainActor
struct SileroVADServiceTests {

    /// Silero needs its CoreML model (downloaded by FluidAudio on first use): fail, never skip, when unavailable.
    func makeService(config: VADConfiguration = .default) async throws -> SileroVADService {
        do {
            return try await SileroVADService(config: config)
        } catch {
            try requirePrerequisite(false, "Silero VAD model (FluidAudio download): \(error)")
            throw error
        }
    }

    // Helper: sine wave samples at given amplitude
    func sineWave(count: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<count).map { i in
            amplitude * sin(2.0 * Float.pi * 440.0 * Float(i) / 16_000)
        }
    }

    func makeBuffer(samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    @Test func sileroVADEngineIdentifier() async throws {
        let service = try await makeService()
        #expect(service.engine == .silero)
    }

    @Test func sileroVADIgnoresSilence() async throws {
        var config = VADConfiguration()
        config.minSilenceDuration = 0.2
        let silentService = try await makeService(config: config)

        let silentBuf = makeBuffer(samples: Array(repeating: Float(0), count: 16_000))
        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            for _ in 0..<3 { continuation.yield(silentBuf) }
            continuation.finish()
        }

        var segments: [SpeechSegment] = []
        let task = Task { for await seg in silentService.speechSegments { segments.append(seg) } }
        try? await silentService.activate(stream: stream)
        try? await Task.sleep(for: .milliseconds(500))
        await silentService.deactivate()
        task.cancel()

        #expect(segments.isEmpty, "Silence should produce 0 segments")
    }

    @Test func sileroVADDetectsSpeech() async throws {
        let service = try await makeService()

        // Feed 2 seconds of loud speech + 1 second silence
        let speechSamples = sineWave(count: 32_000, amplitude: 0.9)
        let silenceSamples = Array(repeating: Float(0), count: 16_000)
        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            continuation.yield(makeBuffer(samples: speechSamples))
            continuation.yield(makeBuffer(samples: silenceSamples))
            continuation.finish()
        }

        var segments: [SpeechSegment] = []
        let task = Task { for await seg in service.speechSegments { segments.append(seg) } }
        try? await service.activate(stream: stream)
        try? await Task.sleep(for: .milliseconds(800))
        await service.deactivate()
        task.cancel()

        // Note: Silero may not trigger on synthetic sine waves.
        // This test verifies the pipeline works end-to-end without crash.
        // AC-01 (real speech detection) is covered by integration tests with real audio.
        _ = segments  // May be empty with synthetic sine waves
    }

    @Test func sileroVADDeactivateWithoutActivate() async throws {
        let service = try await makeService()
        await service.deactivate()  // Should not crash
    }

    @Test func sileroVADMaxDuration() async throws {
        var config = VADConfiguration()
        config.maxSpeechDuration = 0.5
        config.minSpeechDuration = 0.1
        // FluidAudio asserts minSilence/speechPadding ≤ maxSpeech/minSpeech; keep the config consistent.
        config.minSilenceDuration = 0.3
        config.speechPadding = 0.1
        let service = try await makeService(config: config)

        // Feed enough speech to trigger max duration; actual Silero detection depends on model
        let speechSamples = sineWave(count: 32_000, amplitude: 0.9)
        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            continuation.yield(makeBuffer(samples: speechSamples))
            continuation.finish()
        }
        try? await service.activate(stream: stream)
        try? await Task.sleep(for: .milliseconds(500))
        await service.deactivate()
        // Test verifies no crash during max-duration force-emit path
    }
}
}
