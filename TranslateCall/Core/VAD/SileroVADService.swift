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
///
/// Early processing (FR-QS.5, plan P6): while `triggered`, FluidAudio's `tempEndSample` going
/// nil → non-nil (first silent chunk) yields the utterance so far as a `.tentative`; back to nil
/// (speech resumed) retracts it; `.speechEnd` commits it. Force-emit and flush retract it and
/// yield a `.final`. The bookkeeping lives in `TentativeTracker`.
actor SileroVADService: VADService {

    // MARK: - VADService conformance

    nonisolated let speechSegments: AsyncStream<SpeechSegment>
    nonisolated let vadStateEvents: AsyncStream<Bool>
    nonisolated let boundaryEvents: AsyncStream<SegmentBoundary>
    nonisolated let engine: VADEngine = .silero

    // MARK: - Private state

    private let config: VADConfiguration
    private let vadManager: VadManager
    private var segmentContinuation: AsyncStream<SpeechSegment>.Continuation?
    private var stateContinuation: AsyncStream<Bool>.Continuation?
    private var boundaryContinuation: AsyncStream<SegmentBoundary>.Continuation?
    private var processingTask: Task<Void, Never>?

    // Processing state (actor-isolated)
    private var sampleAccumulator: [Float] = []
    private var utteranceBuffer: [Float] = []
    private var vadStreamState: VadStreamState = .initial()
    private var utteranceStartDate: Date?
    private var tentatives = TentativeTracker()

    // History buffer for pre-speech context (design §11)
    private var historyBuffer: [Float] = []
    private let historyCapacity: Int  // speechPadding samples + 1 chunk ≈ 5700
    /// FluidAudio's silence threshold (`threshold − 0.15`): chunks at or above it are not clear silence.
    private let negativeThreshold: Float

    // MARK: - Init

    init(config: VADConfiguration = .default) async throws {
        let config = config.validated()   // FluidAudio traps on inconsistent values (T3)
        self.config = config
        self.historyCapacity = Int(config.speechPadding * 16_000) + VadManager.chunkSize + 512
        self.negativeThreshold = config.fluidSegmentationConfig
            .effectiveNegativeThreshold(baseThreshold: config.sileroThreshold)

        var segCont: AsyncStream<SpeechSegment>.Continuation?
        var stateCont: AsyncStream<Bool>.Continuation?
        var boundaryCont: AsyncStream<SegmentBoundary>.Continuation?
        speechSegments = AsyncStream { segCont = $0 }
        vadStateEvents = AsyncStream { stateCont = $0 }
        boundaryEvents = AsyncStream { boundaryCont = $0 }
        segmentContinuation = segCont
        stateContinuation = stateCont
        boundaryContinuation = boundaryCont

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
                yieldBoundary(tentatives.forced())
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

        let previousTempEnd = vadStreamState.tempEndSample
        vadStreamState = result.state
        tentatives.observe(probability: result.probability, negativeThreshold: negativeThreshold)
        trackTentative(previousTempEnd: previousTempEnd)

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
            await closeUtterance()
            utteranceBuffer = []
            utteranceStartDate = nil
            stateContinuation?.yield(false)
            logger.debug("Silero: speech end at sample \(event.sampleIndex)")
        }
    }

    /// At `.speechEnd`: commit the open tentative, or yield a `.final` (after retracting the
    /// tentative when a soft chunk followed it, REQ-QS-42).
    private func closeUtterance() async {
        switch tentatives.ended() {
        case .commit(let id)?:
            yieldBoundary(.commit(id))   // the open tentative already holds this utterance
        case .retract(let id)?:
            yieldBoundary(.retract(id))  // a soft chunk came after it: the final carries it
            await yieldUtterance()
        case nil:
            await yieldUtterance()
        }
    }

    /// Tentative transitions of `tempEndSample` while still triggered (plan P6).
    private func trackTentative(previousTempEnd: Int?) {
        guard vadStreamState.triggered else { return }
        switch (previousTempEnd, vadStreamState.tempEndSample) {
        case (nil, .some):
            yieldTentative()
        case (.some, nil):
            yieldBoundary(tentatives.speechResumed())
        default:
            break
        }
    }

    /// Same minimum-speech rule for tentatives and finals.
    private var hasMinimumSpeech: Bool {
        utteranceBuffer.count >= Int(config.minSpeechDuration * 16_000)
    }

    /// The utterance so far as a `.tentative` (kept buffered: the final audio still grows from it).
    private func yieldTentative() {
        guard hasMinimumSpeech, let pcmBuffer = makePCMBuffer(from: utteranceBuffer),
              let id = tentatives.silenceStarted() else { return }
        segmentContinuation?.yield(SpeechSegment(audio: pcmBuffer, capturedAt: utteranceStartDate ?? Date(),
                                                 id: id, kind: .tentative))
        logger.debug("Silero: yielded tentative \(id): \(self.utteranceBuffer.count) samples")
    }

    private func yieldBoundary(_ boundary: SegmentBoundary?) {
        guard let boundary else { return }
        boundaryContinuation?.yield(boundary)
    }

    private func yieldUtterance() async {
        guard hasMinimumSpeech, let pcmBuffer = makePCMBuffer(from: utteranceBuffer) else {
            utteranceBuffer = []
            return
        }
        let segment = SpeechSegment(audio: pcmBuffer, capturedAt: utteranceStartDate ?? Date(),
                                    id: tentatives.nextFinalID(), kind: .final)
        segmentContinuation?.yield(segment)
        let count = utteranceBuffer.count
        utteranceBuffer = []
        logger.debug("Silero: yielded segment \(count) samples")
    }

    private func flushUtteranceIfNeeded() async {
        guard vadStreamState.triggered else { return }
        yieldBoundary(tentatives.forced())
        await yieldUtterance()
        stateContinuation?.yield(false)
    }
}
