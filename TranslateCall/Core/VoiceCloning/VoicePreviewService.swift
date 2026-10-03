import AVFoundation
import Foundation
import OSLog

nonisolated private let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "VoicePreviewService"
)

// MARK: - VoicePreviewService

/// Standalone actor for voice preview synthesis and training audio playback.
///
/// Uses its own `AVAudioEngine` (separate from the main translation pipeline)
/// so preview can run without interfering with an active session.
/// Plays through the system default output device (never BlackHole).
actor VoicePreviewService {

    // MARK: - State

    enum PreviewState: Sendable, Equatable {
        case idle
        case loadingModel
        case synthesizing(VoicePreviewMode)
        case playing(VoicePreviewMode)
        case error(String)
    }

    enum VoicePreviewMode: Sendable, Equatable {
        case cloned
        case standard
        case abComparison
        case recording
    }

    // MARK: - State stream

    private(set) var state: PreviewState = .idle

    nonisolated let stateStream: AsyncStream<PreviewState>
    private let stateContinuation: AsyncStream<PreviewState>.Continuation

    // MARK: - Audio engine (nonisolated(unsafe): set in init, read from actor — safe)

    nonisolated(unsafe) private let engine = AVAudioEngine()
    nonisolated(unsafe) private let playerNode = AVAudioPlayerNode()

    // MARK: - Dependencies

    private let profileStore: any VoiceProfileStoring
    private var inferenceTask: Task<Void, Never>?

    // MARK: - Init

    /// Supplies the voice-clone inferrer. Injectable so tests never load the real Qwen3-TTS model.
    typealias InferrerProvider = @Sendable () async throws -> any QwenCloneInferring

    private let inferrerProvider: InferrerProvider

    init(
        profileStore: any VoiceProfileStoring,
        inferrerProvider: @escaping InferrerProvider = {
            try await QwenCloneModelManager.shared.ensureReady()
            return try await QwenCloneModelManager.shared.getInferrer()
        }
    ) throws {
        self.profileStore = profileStore
        self.inferrerProvider = inferrerProvider

        var cont: AsyncStream<PreviewState>.Continuation?
        stateStream = AsyncStream { cont = $0 }
        // swiftlint:disable:next force_unwrapping
        stateContinuation = cont!

        try setupAudioEngine()
    }

    // MARK: - Public API

    /// Preview cloned voice with demo text in specified language.
    func previewClone(profileId: UUID, text: String, language: String) {
        stop()
        inferenceTask = Task { [weak self] in
            guard let self else { return }
            await self.performClonePreview(profileId: profileId, text: text, language: language)
        }
    }

    /// A/B comparison: standard TTS → 0.5s pause → cloned voice.
    func compareAB(profileId: UUID, text: String, locale: Locale) {
        stop()
        inferenceTask = Task { [weak self] in
            guard let self else { return }
            await self.performABComparison(profileId: profileId, text: text, locale: locale)
        }
    }

    /// Play raw training audio from profile (no model needed).
    func playRecording(profileId: UUID) {
        stop()
        inferenceTask = Task { [weak self] in
            guard let self else { return }
            await self.performPlayRecording(profileId: profileId)
        }
    }

    /// Stop any active playback or synthesis.
    func stop() {
        inferenceTask?.cancel()
        inferenceTask = nil
        playerNode.stop()
        transition(to: .idle)
    }

    // MARK: - Clone Preview

    private func performClonePreview(profileId: UUID, text: String, language: String) async {
        do {
            // Ensure model is ready
            transition(to: .loadingModel)
            let inferrer = try await inferrerProvider()

            guard !Task.isCancelled else { return }

            // Load profile
            transition(to: .synthesizing(.cloned))
            let profile = try await profileStore.load(id: profileId)
            guard let samples = profile.samples, let transcript = profile.transcript else {
                transition(to: .error("Profile has no audio data"))
                return
            }

            guard !Task.isCancelled else { return }

            // Synthesize
            let audio = try await inferrer.synthesize(
                text: text,
                referenceAudio: samples,
                referenceTranscript: transcript,
                language: language
            )

            guard !Task.isCancelled else { return }

            // Play
            transition(to: .playing(.cloned))
            playBuffer(from: audio)
        } catch {
            if !Task.isCancelled {
                logger.error("Clone preview failed: \(error.localizedDescription)")
                transition(to: .error(error.localizedDescription))
            }
        }
    }

    // MARK: - A/B Comparison

    private func performABComparison(profileId: UUID, text: String, locale: Locale) async {
        do {
            // 1. Standard TTS
            transition(to: .synthesizing(.standard))
            let standardSamples = try await synthesizeWithAVSpeech(text: text, locale: locale)

            guard !Task.isCancelled else { return }

            transition(to: .playing(.standard))
            playBufferAndWait(from: standardSamples)

            guard !Task.isCancelled else { return }

            // 2. Pause
            try await Task.sleep(for: .milliseconds(500))

            guard !Task.isCancelled else { return }

            // 3. Cloned voice
            transition(to: .loadingModel)
            let inferrer = try await inferrerProvider()

            let profile = try await profileStore.load(id: profileId)
            guard let samples = profile.samples, let transcript = profile.transcript else {
                transition(to: .error("Profile has no audio data"))
                return
            }

            let language = QwenCloneConfiguration.language(for: locale) ?? "english"

            transition(to: .synthesizing(.cloned))
            let clonedAudio = try await inferrer.synthesize(
                text: text,
                referenceAudio: samples,
                referenceTranscript: transcript,
                language: language
            )

            guard !Task.isCancelled else { return }

            transition(to: .playing(.cloned))
            playBuffer(from: clonedAudio)
        } catch {
            if !Task.isCancelled {
                logger.error("A/B comparison failed: \(error.localizedDescription)")
                transition(to: .error(error.localizedDescription))
            }
        }
    }

    // MARK: - Play Recording

    private func performPlayRecording(profileId: UUID) async {
        do {
            let profile = try await profileStore.load(id: profileId)
            guard let samples = profile.samples else {
                transition(to: .error("Profile has no audio data"))
                return
            }

            guard !Task.isCancelled else { return }

            transition(to: .playing(.recording))
            playBuffer(from: samples)
        } catch {
            if !Task.isCancelled {
                logger.error("Play recording failed: \(error.localizedDescription)")
                transition(to: .error(error.localizedDescription))
            }
        }
    }

    // MARK: - Standard TTS (AVSpeech)

    private func synthesizeWithAVSpeech(text: String, locale: Locale) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: locale.identifier)
            utterance.rate = 0.5

            let synthesizer = AVSpeechSynthesizer()
            var collectedSamples: [Float] = []

            // Hold synthesizer reference until completion
            nonisolated(unsafe) var retainedSynthesizer: AVSpeechSynthesizer? = synthesizer

            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    // Empty buffer = synthesis complete
                    continuation.resume(returning: collectedSamples)
                    retainedSynthesizer = nil
                    return
                }
                if let channelData = pcm.floatChannelData {
                    let frames = Int(pcm.frameLength)
                    let ptr = channelData[0]
                    collectedSamples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: frames))
                }
            }
            _ = retainedSynthesizer // suppress unused warning
        }
    }

    // MARK: - Audio Pipeline

    private nonisolated func setupAudioEngine() throws {
        engine.attach(playerNode)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        engine.connect(playerNode, to: mixer, format: nil)
        engine.connect(mixer, to: engine.outputNode, format: outputFormat)
        try engine.start()
    }

    private func playBuffer(from samples: [Float]) {
        guard let buffer = makePCMBuffer(from: samples) else {
            transition(to: .error("Failed to create audio buffer"))
            return
        }
        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { await self?.bufferCompleted() }
        }
        if !playerNode.isPlaying { playerNode.play() }
    }

    private func playBufferAndWait(from samples: [Float]) {
        guard let buffer = makePCMBuffer(from: samples) else { return }
        playerNode.scheduleBuffer(buffer, at: nil, options: []) {}
        if !playerNode.isPlaying { playerNode.play() }
        // Wait for buffer duration
        let duration = Double(samples.count) / 24_000.0
        Thread.sleep(forTimeInterval: duration)
    }

    private func bufferCompleted() {
        if case .playing = state {
            transition(to: .idle)
        }
    }

    /// Converts raw 24 kHz Float32 samples → AVAudioPCMBuffer at device sample rate.
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
        if outputFormat.sampleRate == 24_000 { return srcBuf }

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

    // MARK: - State

    private func transition(to newState: PreviewState) {
        state = newState
        stateContinuation.yield(newState)
        logger.debug("VoicePreviewService → \(String(describing: newState))")
    }
}
