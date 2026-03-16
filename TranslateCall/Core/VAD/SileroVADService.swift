import AVFoundation
import FluidAudio
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "SileroVADService")

// MARK: - SileroVADService

/// Silero VAD via FluidAudio. Downloads/caches the CoreML model on first use.
///
/// History buffer (§11 of design.md): maintains the last ~360ms of 16kHz samples
/// so that when `speechStart` fires, pre-speech context is prepended to the utterance.
actor SileroVADService: VADService {

    // MARK: - VADService conformance

    nonisolated let speechSegments: AsyncStream<SpeechSegment>
    nonisolated let vadStateEvents: AsyncStream<Bool>
    nonisolated let engine: VADEngine = .silero

    // MARK: - Private state

    private let config: VADConfiguration
    private let vadManager: VadManager
    private var segmentContinuation: AsyncStream<SpeechSegment>.Continuation?
    private var stateContinuation: AsyncStream<Bool>.Continuation?
    private var processingTask: Task<Void, Never>?

    // Processing state (actor-isolated)
    private var sampleAccumulator: [Float] = []
    private var utteranceBuffer: [Float] = []
    private var vadStreamState: VadStreamState = .initial()
    private var utteranceStartDate: Date?

    // History buffer for pre-speech context (design §11)
    private var historyBuffer: [Float] = []
    private let historyCapacity: Int  // speechPadding samples + 1 chunk ≈ 5700

    // MARK: - Init

    init(config: VADConfiguration = .default) async throws {
        self.config = config
        self.historyCapacity = Int(config.speechPadding * 16_000) + VadManager.chunkSize + 512

        var segCont: AsyncStream<SpeechSegment>.Continuation?
        var stateCont: AsyncStream<Bool>.Continuation?
        speechSegments = AsyncStream { segCont = $0 }
        vadStateEvents = AsyncStream { stateCont = $0 }
        segmentContinuation = segCont
        stateContinuation = stateCont

        // VadManager init downloads/loads CoreML model — async throws
        vadManager = try await VadManager(config: config.fluidVadConfig)
        logger.info("SileroVADService initialized")
    }

    // MARK: - VADService

    func activate(stream: AsyncStream<AVAudioPCMBuffer>) async throws {
        guard processingTask == nil else { return }
        sampleAccumulator = []
        utteranceBuffer = []
        historyBuffer = []
        vadStreamState = await vadManager.makeStreamState()
        utteranceStartDate = nil

        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.runProcessingLoop(stream: stream)
        }
    }

    func deactivate() async {
        processingTask?.cancel()
        processingTask = nil
        await flushUtteranceIfNeeded()
    }

    // MARK: - Private

    private func runProcessingLoop(stream: AsyncStream<AVAudioPCMBuffer>) async {
        for await buffer in stream {
            guard !Task.isCancelled else { break }
            await appendBuffer(buffer)
        }
        await flushUtteranceIfNeeded()
    }

    private func appendBuffer(_ buffer: AVAudioPCMBuffer) async {
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: count))

        // Rolling history buffer for pre-speech context
        historyBuffer.append(contentsOf: samples)
        if historyBuffer.count > historyCapacity {
            historyBuffer.removeFirst(historyBuffer.count - historyCapacity)
        }

        sampleAccumulator.append(contentsOf: samples)

        // Drain accumulator in 4096-sample chunks
        while sampleAccumulator.count >= VadManager.chunkSize {
            let chunk = Array(sampleAccumulator.prefix(VadManager.chunkSize))
            sampleAccumulator.removeFirst(VadManager.chunkSize)
            await processChunk(chunk)
        }
    }

    private func processChunk(_ chunk: [Float]) async {
        // Buffer mid-speech samples BEFORE running Silero (so we never miss a chunk)
        if vadStreamState.triggered {
            utteranceBuffer.append(contentsOf: chunk)

            // Force-emit if max speech duration exceeded
            let maxSamples = Int(config.maxSpeechDuration * 16_000)
            if utteranceBuffer.count >= maxSamples {
                await yieldUtterance()
                vadStreamState = await vadManager.makeStreamState()
                logger.debug("Silero: force-emit at max duration")
                return
            }
        }

        // Run Silero inference on chunk
        let result: VadStreamResult
        do {
            result = try await vadManager.processStreamingChunk(
                chunk,
                state: vadStreamState,
                config: config.fluidSegmentationConfig
            )
        } catch {
            logger.error("Silero chunk failed: \(error.localizedDescription)")
            return
        }

        vadStreamState = result.state

        guard let event = result.event else { return }

        switch event.kind {
        case .speechStart:
            utteranceStartDate = Date()
            // Prepend pre-speech context from history buffer
            let contextSamples = Int(config.speechPadding * 16_000)
            let contextStart = max(0, historyBuffer.count - contextSamples - chunk.count)
            let context = Array(historyBuffer[contextStart...])
            // Start utterance with context + current chunk
            utteranceBuffer = context
            if !vadStreamState.triggered {
                // If triggered flag not yet set (edge case), just use current chunk
                utteranceBuffer = chunk
            }
            stateContinuation?.yield(true)
            logger.debug("Silero: speech start at sample \(event.sampleIndex)")

        case .speechEnd:
            await yieldUtterance()
            utteranceBuffer = []
            utteranceStartDate = nil
            stateContinuation?.yield(false)
            logger.debug("Silero: speech end at sample \(event.sampleIndex)")
        }
    }

    private func yieldUtterance() async {
        let minSamples = Int(config.minSpeechDuration * 16_000)
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
        let count = utteranceBuffer.count
        utteranceBuffer = []
        logger.debug("Silero: yielded segment \(count) samples")
    }

    private func flushUtteranceIfNeeded() async {
        guard vadStreamState.triggered else { return }
        await yieldUtterance()
        stateContinuation?.yield(false)
    }
}
