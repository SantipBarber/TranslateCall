import Accelerate
import AVFoundation
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "EnergyVADService")

// MARK: - EnergyVADService

/// Energy-based VAD fallback. No ML model required; runs purely on vDSP RMS.
///
/// State machine: silence → speaking (when dBFS > threshold for ≥ minSpeechDuration samples)
///                speaking → silence (when dBFS ≤ threshold for ≥ minSilenceDuration samples)
///
/// Early processing (FR-QS.5): at `tentativeSilence` of silence inside `.speaking` the utterance so
/// far is yielded as a `.tentative` segment; speech before the pause completes retracts it, the
/// completed pause commits it (no new segment). Force-emit and flush retract it and yield a `.final`.
actor EnergyVADService: VADService {

    // MARK: - VADService conformance

    nonisolated let speechSegments: AsyncStream<SpeechSegment>
    nonisolated let vadStateEvents: AsyncStream<Bool>
    nonisolated let boundaryEvents: AsyncStream<SegmentBoundary>
    nonisolated let engine: VADEngine = .energy

    /// Silence that yields the tentative segment (REQ-QS-40); the pause itself stays `minSilenceDuration`.
    nonisolated static let tentativeSilence: TimeInterval = 0.2

    // MARK: - Private state

    private let config: VADConfiguration
    private var segmentContinuation: AsyncStream<SpeechSegment>.Continuation?
    private var stateContinuation: AsyncStream<Bool>.Continuation?
    private var boundaryContinuation: AsyncStream<SegmentBoundary>.Continuation?
    private var processingTask: Task<Void, Never>?

    // State machine
    private enum SpeakingState { case silence, speaking }
    private var speakingState: SpeakingState = .silence
    private var utteranceBuffer: [Float] = []
    private var silenceSamples: Int = 0       // consecutive silent samples since last speech
    private var speechSamples: Int = 0        // consecutive speech samples since state change
    private var utteranceStartDate: Date?
    private var tentatives = TentativeTracker()

    // MARK: - Init

    init(config: VADConfiguration = .default) {
        self.config = config.validated()
        var segCont: AsyncStream<SpeechSegment>.Continuation?
        var stateCont: AsyncStream<Bool>.Continuation?
        var boundaryCont: AsyncStream<SegmentBoundary>.Continuation?
        speechSegments = AsyncStream { segCont = $0 }
        vadStateEvents = AsyncStream { stateCont = $0 }
        boundaryEvents = AsyncStream { boundaryCont = $0 }
        segmentContinuation = segCont
        stateContinuation = stateCont
        boundaryContinuation = boundaryCont
    }

    // MARK: - VADService

    func activate(stream: AsyncStream<AVAudioPCMBuffer>) async throws {
        guard processingTask == nil else { return }
        resetState()
        processingTask = Task { [weak self] in
            guard let self else { return }
            for await buffer in stream {
                guard !Task.isCancelled else { break }
                await self.processBuffer(buffer)
            }
            await self.flush()
        }
    }

    func deactivate() async {
        processingTask?.cancel()
        processingTask = nil
        flush()
    }

    /// Test-only: ends the three output streams, so a test can read everything yielded so far to the end.
    func finishStreamsForTesting() {
        segmentContinuation?.finish()
        stateContinuation?.finish()
        boundaryContinuation?.finish()
    }

    // MARK: - Private

    private func resetState() {
        speakingState = .silence
        utteranceBuffer = []
        silenceSamples = 0
        speechSamples = 0
        utteranceStartDate = nil
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0],
              buffer.frameLength > 0 else { return }

        let count = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
        let dbfs = computeDBFS(channelData: channelData, count: count)
        let isSpeech = dbfs > config.energyThresholdDBFS
        let sampleRate = buffer.format.sampleRate

        switch speakingState {
        case .silence:
            if isSpeech {
                speechSamples += count
                utteranceBuffer.append(contentsOf: samples)
                if speechSamples >= Int(config.minSpeechDuration * sampleRate) {
                    speakingState = .speaking
                    utteranceStartDate = Date()
                    silenceSamples = 0
                    stateContinuation?.yield(true)
                    logger.debug("Speech start detected (energy: \(dbfs)dBFS)")
                }
            } else {
                speechSamples = 0
                utteranceBuffer = []
            }

        case .speaking:
            utteranceBuffer.append(contentsOf: samples)
            if speaking(isSpeech: isSpeech, count: count, sampleRate: sampleRate) == .ended { return }
            // Force-emit if max duration exceeded
            if utteranceBuffer.count >= Int(config.maxSpeechDuration * sampleRate) {
                yieldBoundary(tentatives.forced())
                yieldUtterance()
                speechSamples = 0
                silenceSamples = 0
                utteranceStartDate = Date()
                logger.debug("Speech max duration reached — forced emit")
            }
        }
    }

    private enum SpeakingStep { case continuing, ended }

    /// One buffer inside `.speaking`: tentative at `tentativeSilence`, retract on speech, end at the pause.
    private func speaking(isSpeech: Bool, count: Int, sampleRate: Double) -> SpeakingStep {
        if isSpeech {
            silenceSamples = 0
            yieldBoundary(tentatives.speechResumed())
            return .continuing
        }
        let tentativeSamples = Int(Self.tentativeSilence * sampleRate)
        let reachedTentative = silenceSamples < tentativeSamples && silenceSamples + count >= tentativeSamples
        silenceSamples += count
        if reachedTentative { yieldTentative(bufferSamples: count, sampleRate: sampleRate) }
        guard silenceSamples >= Int(config.minSilenceDuration * sampleRate) else { return .continuing }
        // No `observe` here: any buffer above the energy threshold already retracted the tentative.
        if let commit = tentatives.ended() {
            yieldBoundary(commit)
            utteranceBuffer = []
            utteranceStartDate = nil
        } else {
            yieldUtterance()
        }
        speakingState = .silence
        speechSamples = 0
        silenceSamples = 0
        stateContinuation?.yield(false)
        logger.debug("Speech end detected")
        return .ended
    }

    private func flush() {
        guard speakingState == .speaking, !utteranceBuffer.isEmpty else { return }
        yieldBoundary(tentatives.forced())
        yieldUtterance()
        speakingState = .silence
        stateContinuation?.yield(false)
    }

    /// Same minimum-speech rule for tentatives and finals.
    private var hasMinimumSpeech: Bool {
        utteranceBuffer.count >= Int(config.minSpeechDuration * 16_000.0)
    }

    /// The utterance so far as a `.tentative` (kept buffered: the final audio still grows from it).
    /// Its STT copy is zero-padded to the trailing silence a final would carry: the pause, rounded up
    /// to whole buffers (G3 I1).
    private func yieldTentative(bufferSamples: Int, sampleRate: Double) {
        let pause = Int(config.minSilenceDuration * sampleRate)
        let audio = TentativePadding.padded(
            utteranceBuffer, silenceInBuffer: silenceSamples,
            finalSilence: TentativePadding.roundedUp(pause, step: bufferSamples)
        )
        guard hasMinimumSpeech, let pcmBuffer = makePCMBuffer(from: audio),
              let id = tentatives.silenceStarted() else { return }
        segmentContinuation?.yield(SpeechSegment(audio: pcmBuffer, capturedAt: utteranceStartDate ?? Date(),
                                                 id: id, kind: .tentative))
        logger.debug("Yielded tentative \(id): \(self.utteranceBuffer.count) samples, \(audio.count) padded")
    }

    private func yieldBoundary(_ boundary: SegmentBoundary?) {
        guard let boundary else { return }
        boundaryContinuation?.yield(boundary)
    }

    private func yieldUtterance() {
        guard hasMinimumSpeech, let pcmBuffer = makePCMBuffer(from: utteranceBuffer) else {
            utteranceBuffer = []
            return
        }
        let segment = SpeechSegment(audio: pcmBuffer, capturedAt: utteranceStartDate ?? Date(),
                                    id: tentatives.nextFinalID(), kind: .final)
        segmentContinuation?.yield(segment)
        let sampleCount = utteranceBuffer.count
        utteranceBuffer = []
        logger.debug("Yielded segment: \(sampleCount) samples")
        utteranceStartDate = nil
    }

    // Compute RMS energy and convert to dBFS
    private func computeDBFS(channelData: UnsafeMutablePointer<Float>, count: Int) -> Float {
        var rms: Float = 0
        vDSP_measqv(channelData, 1, &rms, vDSP_Length(count))
        guard rms > 0 else { return -160 }
        return 10 * log10f(rms)
    }
}
