import AVFoundation
import CoreAudio
import FluidAudioEspeak
import Foundation
import OSLog

// nonisolated(unsafe): file-level logger used from actor context; Logger is Sendable — safe
nonisolated(unsafe) private let kokoroServiceLogger = Logger(subsystem: "com.spbarber.TranslateCall", category: "KokoroSpeechService")

// MARK: - KokoroSpeechService

/// Actor-based TTS service using FluidAudio Kokoro CoreML model.
///
/// Conforms to `SynthesisService` without protocol changes (REQ-KOK-NF-09).
/// Audio pipeline: Kokoro [Float] 24kHz → AVAudioConverter SRC → AVAudioPlayerNode.
/// Incoming TTS always uses AVSpeechService; Kokoro handles outgoing English only.
actor KokoroSpeechService: SynthesisService {

    // MARK: - SynthesisService

    nonisolated let isSpeakingStream: AsyncStream<Bool>
    private let speakingContinuation: AsyncStream<Bool>.Continuation

    // MARK: - Audio engine (nonisolated(unsafe): set in throws init, read from actor — safe)

    nonisolated(unsafe) private let engine = AVAudioEngine()
    nonisolated(unsafe) private let playerNode = AVAudioPlayerNode()

    // MARK: - Dependencies

    private let configuration: KokoroConfiguration
    private let modelManager: KokoroModelManager

    // MARK: - Queue

    private var isSpeaking = false
    private(set) var pendingTexts: [(text: String, locale: Locale)] = []

    // MARK: - Init

    init(
        outputDeviceID: AudioDeviceID?,
        configuration: KokoroConfiguration = .default,
        modelManager: KokoroModelManager = .shared
    ) throws {
        self.configuration = configuration
        self.modelManager = modelManager

        var cont: AsyncStream<Bool>.Continuation!
        isSpeakingStream = AsyncStream { cont = $0 }
        speakingContinuation = cont

        try setupAudioEngineNonisolated(outputDeviceID: outputDeviceID)
    }

    // MARK: - SynthesisService

    func speak(text: String, locale: Locale) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingTexts.append((text, locale))
        if !isSpeaking { await processNext() }
    }

    func stopSpeaking() async {
        pendingTexts.removeAll()
        playerNode.stop()
        setSpeaking(false)
    }

    func deactivate() async {
        await stopSpeaking()
        engine.stop()
    }

    // MARK: - Private: synthesis loop

    private func processNext() async {
        guard !pendingTexts.isEmpty else { setSpeaking(false); return }
        let (text, locale) = pendingTexts.removeFirst()
        setSpeaking(true)

        let startDate = Date()

        // Handle long text (REQ-KOK-NF-07): truncate at last word boundary before 500 chars
        let inputText: String
        if text.count > 500 {
            let truncated = String(text.prefix(500))
            inputText = truncated.components(separatedBy: " ").dropLast().joined(separator: " ")
            kokoroServiceLogger.warning("KokoroSpeechService: text truncated from \(text.count) to \(inputText.count) chars")
        } else {
            inputText = text
        }

        do {
            let manager = try await modelManager.ensureReady(config: configuration)
            let voice = configuration.voiceIdentifier.isEmpty ? nil : configuration.voiceIdentifier
            let samples = try await manager.synthesizeSamples(text: inputText, voice: voice)
            let latencyMs = Int(Date().timeIntervalSince(startDate) * 1000)

            if let buffer = makePCMBuffer(from: samples) {
                scheduleBuffer(buffer)
            } else {
                kokoroServiceLogger.error("KokoroSpeechService: failed to create PCM buffer")
                setSpeaking(false)
            }

            Task {
                await TTSMetricsCollector.shared.record(
                    TTSMetrics(
                        engine: .kokoro,
                        synthesisLatencyMs: latencyMs,
                        textLength: text.count,
                        locale: locale,
                        timestamp: .now
                    )
                )
            }
        } catch {
            kokoroServiceLogger.error("KokoroSpeechService: synthesis failed — \(error.localizedDescription)")
            setSpeaking(false)
            await processNext()
        }
    }

    // MARK: - Private: audio pipeline

    // nonisolated: called from throws init (synchronous, nonisolated context);
    // only touches nonisolated(unsafe) engine/playerNode — safe by design.
    private nonisolated func setupAudioEngineNonisolated(outputDeviceID: AudioDeviceID?) throws {
        engine.attach(playerNode)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        engine.connect(playerNode, to: mixer, format: nil)
        engine.connect(mixer, to: engine.outputNode, format: outputFormat)
        if let deviceID = outputDeviceID {
            routeToDevice(deviceID)
        }
        try engine.start()
    }

    // nonisolated: called from setupAudioEngineNonisolated; only touches nonisolated(unsafe) engine
    private nonisolated func routeToDevice(_ deviceID: AudioDeviceID) {
        guard let audioUnit = engine.outputNode.audioUnit else { return }
        var deviceIDVar = deviceID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDVar,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    /// Converts raw 24 kHz Float32 samples → AVAudioPCMBuffer at the engine's output sample rate.
    private func makePCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }

        guard let kokoroFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ) else { return nil }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let kokoroBuf = AVAudioPCMBuffer(pcmFormat: kokoroFormat, frameCapacity: frameCount),
              let channelData = kokoroBuf.floatChannelData else {
            return nil
        }
        kokoroBuf.frameLength = frameCount
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            channelData[0].update(from: base, count: samples.count)
        }

        let outputFormat = engine.outputNode.outputFormat(forBus: 0)

        // If the device already runs at 24kHz, skip SRC
        if outputFormat.sampleRate == 24_000 { return kokoroBuf }

        // SRC: 24kHz → device sample rate via AVAudioConverter callback API
        guard let converter = AVAudioConverter(from: kokoroFormat, to: outputFormat) else { return nil }
        let ratio = outputFormat.sampleRate / 24_000
        let outFrames = AVAudioFrameCount(Double(frameCount) * ratio)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outFrames) else {
            return nil
        }

        var inputConsumed = false
        let status = converter.convert(to: outBuf, error: nil) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return kokoroBuf
        }
        return status == .error ? nil : outBuf
    }

    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { await self?.bufferCompleted() }
        }
        if !playerNode.isPlaying { playerNode.play() }
    }

    private func bufferCompleted() async {
        await processNext()
    }

    private func setSpeaking(_ value: Bool) {
        isSpeaking = value
        speakingContinuation.yield(value)
    }
}
