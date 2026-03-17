import Accelerate
import AVFoundation
import Foundation
import OSLog

private nonisolated let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "VoiceProfileRecorder"
)

actor VoiceProfileRecorder {

    // MARK: - Dependencies

    private let isSessionActive: @Sendable () -> Bool

    // MARK: - Engine state

    nonisolated(unsafe) private var engine: AVAudioEngine?
    private var capturedSamples: [Float] = []
    private let targetSampleRate: Double = 24_000

    // MARK: - Level stream (≥ 10 Hz UI updates)

    private let levelContinuation: AsyncStream<Float>.Continuation
    nonisolated let levelStream: AsyncStream<Float>

    // MARK: - Init

    init(isSessionActive: @escaping @Sendable () -> Bool = { false }) {
        self.isSessionActive = isSessionActive
        var cont: AsyncStream<Float>.Continuation?
        levelStream = AsyncStream { cont = $0 }
        // swiftlint:disable:next force_unwrapping
        levelContinuation = cont!
    }

    // MARK: - Public API

    func startRecording() async throws {
        guard !isSessionActive() else {
            throw VoiceProfileRecorderError.sessionConflict
        }
        guard await requestMicrophonePermission() else {
            throw VoiceProfileRecorderError.permissionDenied
        }
        capturedSamples = []
        try setupEngine()
    }

    func stopRecording() throws -> RecordingResult {
        guard let eng = engine else { throw VoiceProfileRecorderError.notRecording }
        eng.stop()
        eng.inputNode.removeTap(onBus: 0)
        engine = nil

        let metrics = Self.computeQualityStatic(
            samples: capturedSamples,
            sampleRate: targetSampleRate
        )
        let duration = Float(capturedSamples.count) / Float(targetSampleRate)
        logger.info(
            "Recording stopped: \(self.capturedSamples.count) samples, grade=\(metrics.grade.rawValue)"
        )
        return RecordingResult(
            samples: capturedSamples,
            durationSeconds: duration,
            quality: metrics
        )
    }

    var sampleCount: Int { capturedSamples.count }

    // MARK: - Private: Engine setup

    private func setupEngine() throws {
        let eng = AVAudioEngine()

        let inputNode = eng.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw VoiceProfileRecorderError.engineSetupFailed
        }

        // SRC converter if native rate differs (typical: 48 kHz → 24 kHz)
        let needsSRC = nativeFormat.sampleRate != targetSampleRate
        let converter: AVAudioConverter? = needsSRC
            ? AVAudioConverter(from: nativeFormat, to: targetFormat)
            : nil

        let cont = levelContinuation

        // Tap runs on the audio thread (nonisolated context)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nativeFormat
        ) { [weak self] buffer, _ in
            guard let self else { return }

            let mono: [Float]
            if let conv = converter {
                if let resampled = Self.resample(
                    buffer, converter: conv, targetFormat: targetFormat
                ) {
                    mono = Self.extractMono(resampled)
                } else {
                    return
                }
            } else {
                mono = Self.extractMono(buffer)
            }

            // Post level update
            let rms = Self.computeRMSdBFS(mono)
            cont.yield(rms)

            // Hop back to actor to append samples
            Task { await self.appendSamples(mono) }
        }

        try eng.start()
        self.engine = eng
        logger.info("Recording engine started (native \(nativeFormat.sampleRate) Hz)")
    }

    private func appendSamples(_ new: [Float]) {
        capturedSamples.append(contentsOf: new)
    }

    // MARK: - Quality Validation (static for testability)

    static func computeQualityStatic(
        samples: [Float],
        sampleRate: Double
    ) -> VoiceQualityMetrics {
        guard !samples.isEmpty else {
            return VoiceQualityMetrics(
                peakRmsDbfs: -60,
                hasClipping: false,
                voicedDurationSeconds: 0,
                grade: .poor
            )
        }

        // Peak RMS over all samples
        let peakRms = computeRMSdBFS(samples)

        // Clipping: any |sample| ≥ 0.98 in > 0.1% of frames
        let clippedCount = samples.reduce(0) { $0 + (abs($1) >= 0.98 ? 1 : 0) }
        let hasClipping = Float(clippedCount) / Float(samples.count) > 0.001

        // Voiced duration: 10 ms chunks above -40 dBFS threshold
        let chunkSize = Int(sampleRate / 100)  // 10 ms chunks
        let voiceThresholdLinear: Float = 0.0001  // -40 dBFS ≈ 10^(-40/10) = 0.0001 mean square
        var voicedChunks = 0
        let totalChunks = samples.count / max(chunkSize, 1)
        for chunkIdx in 0 ..< totalChunks {
            let start = chunkIdx * chunkSize
            let end = min(start + chunkSize, samples.count)
            let chunk = Array(samples[start ..< end])
            var chunkMeanSq: Float = 0
            vDSP_measqv(chunk, 1, &chunkMeanSq, vDSP_Length(chunk.count))
            if chunkMeanSq >= voiceThresholdLinear {
                voicedChunks += 1
            }
        }
        let voicedDuration = Float(voicedChunks * chunkSize) / Float(sampleRate)

        // Grade logic
        let grade: VoiceQualityGrade
        if peakRms < -30 || voicedDuration < 8 || hasClipping {
            grade = .poor
        } else if peakRms < -20 || voicedDuration < 20 {
            grade = .fair
        } else {
            grade = .good
        }

        return VoiceQualityMetrics(
            peakRmsDbfs: peakRms,
            hasClipping: hasClipping,
            voicedDurationSeconds: voicedDuration,
            grade: grade
        )
    }

    // MARK: - Private: Audio helpers (static, nonisolated — safe on audio thread)

    private static func computeRMSdBFS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -60 }
        var meanSq: Float = 0
        vDSP_measqv(samples, 1, &meanSq, vDSP_Length(samples.count))
        return meanSq > 0 ? 10 * log10f(meanSq) : -60
    }

    private static func resample(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let out = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: outFrames
        ) else { return nil }

        nonisolated(unsafe) var consumed = false
        let status = converter.convert(to: out, error: nil) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : out
    }

    private static func extractMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    // MARK: - Private: Permission

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }
}
