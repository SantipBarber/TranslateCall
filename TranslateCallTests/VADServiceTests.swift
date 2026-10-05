@_exported import Testing
import AVFoundation
@testable import TranslateCall

// MARK: - T1: VADConfiguration Tests
// @MainActor required: VADConfiguration has var properties which are @MainActor
// under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor. Running tests on @MainActor
// matches the isolation, consistent with the rest of the app.

@MainActor
struct VADConfigurationTests {

    @Test func defaultValues() {
        let config = VADConfiguration.default
        #expect(config.sileroThreshold == 0.85)
        #expect(config.energyThresholdDBFS == -40.0)
        #expect(config.minSpeechDuration == 0.15)
        #expect(config.minSilenceDuration == 0.6)
        #expect(config.maxSpeechDuration == 14.0)
        #expect(config.speechPadding == 0.1)
    }

    @Test func customValues() {
        var config = VADConfiguration()
        config.sileroThreshold = 0.7
        config.minSilenceDuration = 1.0
        #expect(config.sileroThreshold == 0.7)
        #expect(config.minSilenceDuration == 1.0)
    }
}

// MARK: - T1: makePCMBuffer helper
// .serialized: AVAudioFormat/AVAudioPCMBuffer init calls CoreAudio — run sequentially with other audio tests.

@Suite(.serialized)
@MainActor
struct MakePCMBufferTests {

    // Concrete actor to test the protocol extension without a full VAD implementation.
    actor MockVADService: VADService {
        nonisolated let speechSegments: AsyncStream<SpeechSegment>
        nonisolated let vadStateEvents: AsyncStream<Bool>
        nonisolated let engine: VADEngine = .energy

        init() {
            speechSegments = AsyncStream { $0.finish() }
            vadStateEvents = AsyncStream { $0.finish() }
        }

        func activate(stream: AsyncStream<AVAudioPCMBuffer>) async throws {}
        func deactivate() async {}
    }

    @Test func makePCMBufferProducesCorrectFormat() {
        let mock = MockVADService()
        let samples: [Float] = Array(repeating: 0.5, count: 1600)  // 100ms @ 16kHz
        let buffer = mock.makePCMBuffer(from: samples)

        #expect(buffer != nil)
        #expect(buffer?.frameLength == 1600)
        #expect(buffer?.format.sampleRate == 16_000)
        #expect(buffer?.format.channelCount == 1)
    }

    @Test func makePCMBufferReturnsNilForEmpty() {
        let mock = MockVADService()
        let buffer = mock.makePCMBuffer(from: [])
        #expect(buffer == nil)
    }

    @Test func makePCMBufferCopiesSamplesCorrectly() {
        let mock = MockVADService()
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        guard let buffer = mock.makePCMBuffer(from: samples),
              let channelData = buffer.floatChannelData?[0] else {
            Issue.record("Buffer or channel data is nil")
            return
        }
        for (index, expected) in samples.enumerated() {
            #expect(channelData[index] == expected)
        }
    }
}

// MARK: - T2: EnergyVADService Tests

@Suite(.serialized)
@MainActor
struct EnergyVADServiceTests {

    // Helper: create a 16kHz mono buffer from [Float] samples
    func makeBuffer(samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    // Helper: create an AsyncStream of buffers, then finish it
    func makeStream(buffers: [AVAudioPCMBuffer]) -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { continuation in
            for buffer in buffers {
                continuation.yield(buffer)
            }
            continuation.finish()
        }
    }

    // Helper: sine wave samples at given amplitude
    func sineWave(count: Int, amplitude: Float = 0.5, frequency: Float = 440) -> [Float] {
        (0..<count).map { i in
            amplitude * sin(2.0 * Float.pi * frequency * Float(i) / 16_000)
        }
    }

    @Test func energyVADIgnoresSilence() async {
        let vad = EnergyVADService()
        // 3 seconds of silence at 16kHz = 48000 samples
        let silentBuf = makeBuffer(samples: Array(repeating: 0.0, count: 16_000))
        let stream = makeStream(buffers: Array(repeating: silentBuf, count: 3))

        var segments: [SpeechSegment] = []
        let collectTask = Task {
            for await seg in vad.speechSegments { segments.append(seg) }
        }

        try? await vad.activate(stream: stream)
        // Wait for stream to finish processing
        try? await Task.sleep(for: .milliseconds(200))
        await vad.deactivate()
        collectTask.cancel()

        #expect(segments.isEmpty, "Silence should produce 0 segments")
    }

    @Test func energyVADDetectsSpeech() async {
        var config = VADConfiguration()
        config.minSpeechDuration = 0.1    // 100ms
        config.minSilenceDuration = 0.1   // 100ms
        let vad = EnergyVADService(config: config)

        // 500ms loud speech then 500ms silence
        let speechSamples = sineWave(count: 8_000, amplitude: 0.8)  // well above -40dBFS
        let silenceSamples = Array(repeating: Float(0), count: 8_000)
        let stream = makeStream(buffers: [
            makeBuffer(samples: speechSamples),
            makeBuffer(samples: silenceSamples)
        ])

        var stateEvents: [Bool] = []
        let stateTask = Task {
            for await active in vad.vadStateEvents { stateEvents.append(active) }
        }

        try? await vad.activate(stream: stream)
        try? await Task.sleep(for: .milliseconds(200))
        await vad.deactivate()
        stateTask.cancel()

        #expect(stateEvents.contains(true), "Should detect speech start")
    }

    @Test func energyVADYieldsSegment() async {
        var config = VADConfiguration()
        config.minSpeechDuration = 0.1
        config.minSilenceDuration = 0.1
        let vad = EnergyVADService(config: config)

        let speechSamples = sineWave(count: 8_000, amplitude: 0.8)
        let silenceSamples = Array(repeating: Float(0), count: 8_000)
        let stream = makeStream(buffers: [
            makeBuffer(samples: speechSamples),
            makeBuffer(samples: silenceSamples)
        ])

        var segments: [SpeechSegment] = []
        let collectTask = Task {
            for await seg in vad.speechSegments { segments.append(seg) }
        }

        try? await vad.activate(stream: stream)
        try? await Task.sleep(for: .milliseconds(300))
        await vad.deactivate()
        collectTask.cancel()

        #expect(segments.count >= 1, "Should yield at least 1 segment")
        if let seg = segments.first {
            let duration = Double(seg.audio.frameLength) / seg.audio.format.sampleRate
            #expect(duration >= 0.1, "Segment should be at least minSpeechDuration")
        }
    }

    @Test func energyVADMaxDuration() async {
        var config = VADConfiguration()
        config.maxSpeechDuration = 0.5  // Force-emit at 500ms
        config.minSpeechDuration = 0.1
        config.minSilenceDuration = 10.0  // Never naturally ends
        let vad = EnergyVADService(config: config)

        // 2 seconds of continuous speech (4x maxSpeechDuration)
        let speechSamples = sineWave(count: 32_000, amplitude: 0.8)
        let stream = makeStream(buffers: [makeBuffer(samples: speechSamples)])

        var segments: [SpeechSegment] = []
        let collectTask = Task {
            for await seg in vad.speechSegments { segments.append(seg) }
        }

        try? await vad.activate(stream: stream)
        try? await Task.sleep(for: .milliseconds(300))
        await vad.deactivate()
        collectTask.cancel()

        #expect(segments.count >= 1, "Should force-emit at max duration")
    }

    @Test func energyVADEngineIdentifier() {
        let vad = EnergyVADService()
        #expect(vad.engine == .energy)
    }

    @Test func energyVADDeactivateWithoutActivate() async {
        let vad = EnergyVADService()
        await vad.deactivate()  // Should not crash
    }
}
