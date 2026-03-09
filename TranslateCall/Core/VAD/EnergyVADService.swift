import Accelerate
import AVFoundation
import Foundation
import OSLog

nonisolated(unsafe) private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "EnergyVADService")

// MARK: - EnergyVADService

/// Energy-based VAD fallback. No ML model required; runs purely on vDSP RMS.
///
/// State machine: silence → speaking (when dBFS > threshold for ≥ minSpeechDuration samples)
///                speaking → silence (when dBFS ≤ threshold for ≥ minSilenceDuration samples)
actor EnergyVADService: VADService {

    // MARK: - VADService conformance

    nonisolated let speechSegments: AsyncStream<SpeechSegment>
    nonisolated let vadStateEvents: AsyncStream<Bool>
    nonisolated let engine: VADEngine = .energy

    // MARK: - Private state

    private let config: VADConfiguration
    private var segmentContinuation: AsyncStream<SpeechSegment>.Continuation?
    private var stateContinuation: AsyncStream<Bool>.Continuation?
    private var processingTask: Task<Void, Never>?

    // State machine
    private enum SpeakingState { case silence, speaking }
    private var speakingState: SpeakingState = .silence
    private var utteranceBuffer: [Float] = []
    private var silenceSamples: Int = 0       // consecutive silent samples since last speech
    private var speechSamples: Int = 0        // consecutive speech samples since state change
    private var utteranceStartDate: Date?

    // MARK: - Init

    init(config: VADConfiguration = .default) {
        self.config = config
        var segCont: AsyncStream<SpeechSegment>.Continuation?
        var stateCont: AsyncStream<Bool>.Continuation?
        speechSegments = AsyncStream { segCont = $0 }
        vadStateEvents = AsyncStream { stateCont = $0 }
        segmentContinuation = segCont
        stateContinuation = stateCont
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
        await flush()
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
        let minSpeechSamples = Int(config.minSpeechDuration * sampleRate)
        let minSilenceSamples = Int(config.minSilenceDuration * sampleRate)
        let maxSpeechSamples = Int(config.maxSpeechDuration * sampleRate)

        switch speakingState {
        case .silence:
            if isSpeech {
                speechSamples += count
                utteranceBuffer.append(contentsOf: samples)
                if speechSamples >= minSpeechSamples {
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
            if isSpeech {
                silenceSamples = 0
            } else {
                silenceSamples += count
                if silenceSamples >= minSilenceSamples {
                    yieldUtterance()
                    speakingState = .silence
                    speechSamples = 0
                    silenceSamples = 0
                    stateContinuation?.yield(false)
                    logger.debug("Speech end detected")
                    return
                }
            }
            // Force-emit if max duration exceeded
            if utteranceBuffer.count >= maxSpeechSamples {
                yieldUtterance()
                speechSamples = 0
                silenceSamples = 0
                utteranceStartDate = Date()
                logger.debug("Speech max duration reached — forced emit")
            }
        }
    }

    private func flush() {
        guard speakingState == .speaking, !utteranceBuffer.isEmpty else { return }
        yieldUtterance()
        speakingState = .silence
        stateContinuation?.yield(false)
    }

    private func yieldUtterance() {
        let sampleRate = 16_000.0
        let minSamples = Int(config.minSpeechDuration * sampleRate)
        guard utteranceBuffer.count >= minSamples else {
            utteranceBuffer = []
            return
        }
        guard let pcmBuffer = makePCMBuffer(from: utteranceBuffer) else {
            utteranceBuffer = []
            return
        }
        let segment = SpeechSegment(audio: pcmBuffer, capturedAt: utteranceStartDate ?? Date())
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
