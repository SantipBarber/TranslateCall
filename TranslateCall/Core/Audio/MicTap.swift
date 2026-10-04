import Accelerate
import AVFoundation

// SAFETY: AVAudioEngine invokes an installed tap block serially; a new MicTap is created for
// every (re)configuration and only `process` touches `converter`, so it is never used concurrently.
/// Per-configuration mic tap: downsamples to 16 kHz mono and yields into the session stream.
nonisolated final class MicTap: @unchecked Sendable {
    private let session: SessionAudioStream
    private let converter: AVAudioConverter
    private let onLevel: @Sendable (Float) -> Void

    init?(session: SessionAudioStream, inputFormat: AVAudioFormat, onLevel: @escaping @Sendable (Float) -> Void) {
        guard let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else { return nil }
        self.session = session
        self.converter = converter
        self.onLevel = onLevel
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        if let converted = downsample(buffer) {
            session.yield(converted)
        }
        onLevel(Self.rms(buffer))
    }

    private func downsample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }
        let provided = SyncBox(false)
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if provided.value { status.pointee = .noDataNow; return nil }
            provided.value = true
            status.pointee = .haveData
            return buffer
        }
        return conversionError == nil && output.frameLength > 0 ? output : nil
    }

    /// RMS level in dBFS of channel 0; −160 for silence or empty buffers.
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        var meanSquare: Float = 0
        vDSP_measqv(data, 1, &meanSquare, vDSP_Length(buffer.frameLength))
        guard meanSquare > 0 else { return -160 }
        return max(-160, 10 * log10f(meanSquare))
    }
}
