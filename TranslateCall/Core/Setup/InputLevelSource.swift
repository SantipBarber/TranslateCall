import AVFoundation
import CoreAudio
import Foundation
import Synchronization

// MARK: - LevelSource

/// A per-buffer peak level stream over one input device (design §5.2).
@MainActor
protocol LevelSource: AnyObject {
    /// Starts the engine on the bound device and returns its level stream.
    func start() throws -> AsyncStream<LevelSample>
    /// Removes the tap, stops the engine and finishes the stream. Idempotent.
    func stop()
    /// The audio buffers recorded so far (only when `records` was true).
    var recording: [AVAudioPCMBuffer] { get }
}

/// A self-contained input listener for setup checks (REQ-FR-40…42, 55). Owns its `AVAudioEngine`
/// and binds it with `CoreAudioDevices.setCurrentDevice`, never through `AudioManager`.
@MainActor
final class InputLevelSource: LevelSource {

    private let deviceID: AudioDeviceID
    private let records: Bool
    private let maxRecording: Duration
    private let engine = AVAudioEngine()
    private var tap: LevelTap?
    private var continuation: AsyncStream<LevelSample>.Continuation?
    private var isStarted = false

    var recording: [AVAudioPCMBuffer] {
        tap?.takeRecording() ?? []
    }

    init(deviceID: AudioDeviceID, records: Bool, maxRecording: Duration = .seconds(60)) {
        self.deviceID = deviceID
        self.records = records
        self.maxRecording = maxRecording
    }

    func start() throws -> AsyncStream<LevelSample> {
        guard !isStarted else { throw SetupAudioError.alreadyStarted }
        let (stream, continuation) = AsyncStream.makeStream(
            of: LevelSample.self, bufferingPolicy: .bufferingNewest(1024)
        )
        let tap = LevelTap(continuation: continuation, records: records, maxRecording: maxRecording)
        do {
            try Self.installTap(on: engine, deviceID: deviceID, tap: tap)
        } catch {
            continuation.finish()
            throw error
        }
        self.tap = tap
        self.continuation = continuation
        isStarted = true
        return stream
    }

    func stop() {
        guard isStarted else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        continuation?.finish()
        continuation = nil
        tap = nil
        isStarted = false
    }

    // MARK: - Engine configuration

    /// `nonisolated` so the installTap closure does not inherit `@MainActor`: AVAudioEngine
    /// calls it from its real-time audio thread.
    private nonisolated static func installTap(
        on engine: AVAudioEngine, deviceID: AudioDeviceID, tap: LevelTap
    ) throws {
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        guard let unit = inputNode.audioUnit else {
            throw SetupAudioError.noInputUnit
        }
        do {
            try CoreAudioDevices.setCurrentDevice(deviceID, on: unit)
        } catch {
            throw SetupAudioError.engineStartFailed(error.localizedDescription)
        }
        // Tap at the hardware rate, never with more channels than the hardware has.
        let clientFormat = inputNode.outputFormat(forBus: 0)
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        guard let captureFormat = AudioManager.tapFormat(
            commonFormat: clientFormat.commonFormat,
            interleaved: clientFormat.isInterleaved,
            clientChannels: clientFormat.channelCount,
            hardwareRate: hardwareFormat.sampleRate,
            hardwareChannels: hardwareFormat.channelCount
        ) else {
            throw SetupAudioError.invalidFormat
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: captureFormat) { buffer, _ in
            tap.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw SetupAudioError.engineStartFailed(error.localizedDescription)
        }
    }
}

// MARK: - LevelTap

/// In-memory recording kept by `LevelTap` when `records` is true.
private struct LevelRecording: Sendable {
    var buffers: [AVAudioPCMBuffer] = []
    var duration: Duration = .zero
}

/// Per-buffer tap callback: measures the peak, yields a `LevelSample`, and (optionally) keeps an
/// in-memory copy of the audio up to `maxRecording`. Created once per `start()`.
nonisolated private final class LevelTap: @unchecked Sendable {
    private let continuation: AsyncStream<LevelSample>.Continuation
    private let records: Bool
    private let maxRecording: Duration
    private let recording = Mutex<LevelRecording>(LevelRecording())

    init(continuation: AsyncStream<LevelSample>.Continuation, records: Bool, maxRecording: Duration) {
        self.continuation = continuation
        self.records = records
        self.maxRecording = maxRecording
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let duration = Duration.seconds(Double(buffer.frameLength) / buffer.format.sampleRate)
        continuation.yield(LevelSample(dbfs: LevelMeter.peakDBFS(buffer), duration: duration))
        guard records, let copy = Self.copy(buffer) else { return }
        recording.withLock { state in
            state.buffers.append(copy)
            state.duration += duration
            while state.duration > maxRecording, !state.buffers.isEmpty {
                let removed = state.buffers.removeFirst()
                state.duration -= Duration.seconds(Double(removed.frameLength) / removed.format.sampleRate)
            }
        }
    }

    func takeRecording() -> [AVAudioPCMBuffer] {
        recording.withLock { $0.buffers }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData
        else { return nil }
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(destination[channel], source[channel], Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }
        copy.frameLength = buffer.frameLength
        return copy
    }
}
