import AVFoundation
import CoreMedia
import os

nonisolated private let logger = Logger(subsystem: "TranslateCall", category: "SystemTap")

// SAFETY: used only on SystemAudioCaptureService's serial `sampleQueue`; one SystemTap per
// activation, so `converter` is never touched concurrently.
/// Per-activation SCStream audio handler: copies samples out of the CMSampleBuffer (A2),
/// downsamples 48 kHz → 16 kHz mono and yields into the session stream.
nonisolated final class SystemTap: @unchecked Sendable {
    private let session: SessionAudioStream
    private let converter: AVAudioConverter

    init(session: SessionAudioStream) throws {
        guard let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: input, to: output)
        else {
            throw SystemAudioCaptureError.streamFailed(underlying: NSError(
                domain: "TranslateCall", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"]))
        }
        self.session = session
        self.converter = converter
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.extractOwnedPCMBuffer(from: sampleBuffer),
              let converted = downsample(pcm) else { return }
        session.yield(converted)
    }

    /// Copies the sample buffer's Float32 PCM into a newly allocated buffer (REQ-C-40).
    /// Returns nil for empty, not-ready or non-Float32 buffers.
    static func extractOwnedPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32,
              let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                         channels: asbd.mChannelsPerFrame)
        else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let destination = pcm.floatChannelData
        else { return nil }
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 && asbd.mChannelsPerFrame > 1
        guard !interleaved else {
            logger.warning("Interleaved multi-channel SCStream audio is not supported — buffer dropped")
            return nil
        }
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                for (channel, buffer) in list.enumerated() where channel < Int(format.channelCount) {
                    guard let source = buffer.mData else { continue }
                    let bytes = min(Int(buffer.mDataByteSize), Int(frames) * MemoryLayout<Float>.size)
                    memcpy(destination[channel], source, bytes)
                }
            }
        } catch {
            return nil
        }
        pcm.frameLength = frames
        return pcm
    }

    private func downsample(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }
        let provided = SyncBox(false)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if provided.value { outStatus.pointee = .noDataNow; return nil }
            provided.value = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            logger.warning("AVAudioConverter error: \(conversionError?.localizedDescription ?? "unknown")")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}
