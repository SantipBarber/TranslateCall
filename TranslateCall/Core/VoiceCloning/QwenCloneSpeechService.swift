import AVFoundation
import CoreAudio
import Foundation
import OSLog

nonisolated private let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "QwenCloneSpeechService"
)

// MARK: - QwenCloneSpeechService

/// Actor-based TTS service using Qwen3-TTS for voice-cloned synthesis.
///
/// Audio pipeline: Qwen3-TTS [Float] 24kHz → AVAudioConverter SRC → AVAudioPlayerNode.
/// Mirrors `KokoroSpeechService` structure: queue management, audio engine, metrics.
actor QwenCloneSpeechService: SynthesisService {

    // MARK: - SynthesisService

    nonisolated let isSpeakingStream: AsyncStream<Bool>
    private let speakingContinuation: AsyncStream<Bool>.Continuation

    // MARK: - Audio engine (nonisolated(unsafe): set in throws init, read from actor — safe)

    nonisolated(unsafe) private let engine = AVAudioEngine()
    nonisolated(unsafe) private let playerNode = AVAudioPlayerNode()

    // MARK: - Dependencies

    private let inferrer: any QwenCloneInferring
    private let profileStore: any VoiceProfileStoring
    private let activeProfileId: UUID
    private let config: QwenCloneConfiguration

    // MARK: - Queue

    private var isSpeaking = false
    private(set) var pendingTexts: [(text: String, locale: Locale)] = []

    // MARK: - Init

    init(
        outputDeviceID: AudioDeviceID?,
        activeProfileId: UUID,
        profileStore: any VoiceProfileStoring,
        inferrer: any QwenCloneInferring,
        config: QwenCloneConfiguration = .default
    ) throws {
        self.activeProfileId = activeProfileId
        self.profileStore = profileStore
        self.inferrer = inferrer
        self.config = config

        var cont: AsyncStream<Bool>.Continuation?
        isSpeakingStream = AsyncStream { cont = $0 }
        // swiftlint:disable:next force_unwrapping
        speakingContinuation = cont!

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

        // Truncate at last word boundary before textTruncationLimit chars
        let inputText: String
        if text.count > config.textTruncationLimit {
            let truncated = String(text.prefix(config.textTruncationLimit))
            let words = truncated.components(separatedBy: " ").dropLast()
            inputText = words.isEmpty ? truncated : words.joined(separator: " ")
            logger.warning("Text truncated from \(text.count) to \(inputText.count) chars")
        } else {
            inputText = text
        }

        // Derive language from locale
        let language = QwenCloneConfiguration.language(for: locale) ?? "english"

        do {
            let (samples, transcript) = try await loadProfileData()

            let audio = try await inferWithTimeout(
                text: inputText,
                referenceAudio: samples,
                referenceTranscript: transcript,
                language: language
            )

            let latencyMs = Int(Date().timeIntervalSince(startDate) * 1000)

            if let buffer = makePCMBuffer(from: audio) {
                scheduleBuffer(buffer)
            } else {
                logger.error("Failed to create PCM buffer")
                setSpeaking(false)
            }

            // Record metrics
            Task {
                await TTSMetricsCollector.shared.record(
                    TTSMetrics(
                        engine: .voiceClone,
                        synthesisLatencyMs: latencyMs,
                        textLength: text.count,
                        locale: locale,
                        timestamp: .now
                    )
                )
            }
        } catch {
            logger.error("Synthesis failed — \(error.localizedDescription)")
            setSpeaking(false)
            await processNext()
        }
    }

    // MARK: - Profile loading

    private func loadProfileData() async throws -> (samples: [Float], transcript: String) {
        let profile = try await profileStore.load(id: activeProfileId)
        guard let samples = profile.samples, let transcript = profile.transcript else {
            throw VoiceProfileError.payloadMissing
        }
        return (samples, transcript)
    }

    // MARK: - Inference with timeout

    private func inferWithTimeout(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) async throws -> [Float] {
        try await withThrowingTaskGroup(of: [Float].self) { group in
            group.addTask { [inferrer] in
                try await inferrer.synthesize(
                    text: text,
                    referenceAudio: referenceAudio,
                    referenceTranscript: referenceTranscript,
                    language: language
                )
            }

            group.addTask { [config] in
                try await Task.sleep(for: .seconds(config.inferenceTimeoutSeconds))
                throw QwenCloneError.inferenceTimeout
            }

            guard let result = try await group.next() else {
                throw QwenCloneError.inferenceTimeout
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Private: audio pipeline

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

        guard let srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ) else { return nil }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount),
              let channelData = srcBuf.floatChannelData else {
            return nil
        }
        srcBuf.frameLength = frameCount
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            channelData[0].update(from: base, count: samples.count)
        }

        let outputFormat = engine.outputNode.outputFormat(forBus: 0)

        // If the device already runs at 24kHz, skip SRC
        if outputFormat.sampleRate == 24_000 { return srcBuf }

        // SRC: 24kHz → device sample rate via AVAudioConverter callback API
        guard let converter = AVAudioConverter(from: srcFormat, to: outputFormat) else { return nil }
        let ratio = outputFormat.sampleRate / 24_000
        let outFrames = AVAudioFrameCount(Double(frameCount) * ratio)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outFrames) else {
            return nil
        }

        nonisolated(unsafe) var inputConsumed = false
        let status = converter.convert(to: outBuf, error: nil) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return srcBuf
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
