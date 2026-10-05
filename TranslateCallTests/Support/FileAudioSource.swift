import AVFoundation
@testable import TranslateCall

enum FileAudioSourceError: Error {
    case unreadable(URL)
}

/// Feeds a WAV file into the pipeline through the production `AudioCapture` protocol,
/// exactly where the microphone would (F8.5.0 design §5.2).
@MainActor
final class FileAudioSource: AudioCapture {
    nonisolated static let sampleRate: Double = 16_000
    nonisolated static let chunk = 1024

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private let samples: [Float]
    private let realtime: Bool
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - realtime: pace buffers at wall-clock speed (latency tests) or as fast as possible.
    ///   - trailingSilence: seconds of silence appended so the VAD closes the last segment.
    init(url: URL, realtime: Bool = true, trailingSilence: TimeInterval = 1.5) throws {
        samples = try Self.decode16kMono(url) + Array(repeating: 0, count: Int(trailingSilence * Self.sampleRate))
        self.realtime = realtime
    }

    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, cont) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self, bufferingPolicy: .unbounded)
        continuation = cont
        let samples = samples, realtime = realtime
        task = Task.detached {
            guard let format = Self.makeFormat() else { cont.finish(); return }
            var deadline = ContinuousClock.now
            for offset in stride(from: 0, to: samples.count, by: Self.chunk) {
                if Task.isCancelled { break }
                let count = min(Self.chunk, samples.count - offset)
                guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let dst = buf.floatChannelData?[0] else { break }
                buf.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { src in
                    guard let base = src.baseAddress else { return }
                    dst.update(from: base + offset, count: count)
                }
                cont.yield(buf)
                if realtime {
                    deadline = deadline.advanced(by: .seconds(Double(count) / Self.sampleRate))
                    try? await Task.sleep(until: deadline)
                }
            }
            cont.finish()
        }
        return stream
    }

    func stopCapture() {
        task?.cancel()
        continuation?.finish()
        continuation = nil
    }

    /// Live from `startCapture()` until `stopCapture()` (even after the file has played out).
    var isCapturing: Bool { continuation != nil }

    nonisolated private static func makeFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// Reads any PCM file and converts it to 16 kHz mono Float32 samples.
    nonisolated static func decode16kMono(_ url: URL) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url),
              let outFormat = makeFormat() else { throw FileAudioSourceError.unreadable(url) }
        let inFormat = file.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw FileAudioSourceError.unreadable(url) }
        try file.read(into: inBuf)

        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * sampleRate / inFormat.sampleRate) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw FileAudioSourceError.unreadable(url)
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        if let error { throw error }
        guard let data = outBuf.floatChannelData?[0] else { throw FileAudioSourceError.unreadable(url) }
        return Array(UnsafeBufferPointer(start: data, count: Int(outBuf.frameLength)))
    }
}
