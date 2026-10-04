import AVFoundation

/// Mono Float32 buffer whose every sample is `fill`; `frameLength == frames`.
func makePCMBuffer(frames: AVAudioFrameCount = 160, sampleRate: Double = 16_000, fill: Float = 0) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    if let data = buffer.floatChannelData?[0] {
        for i in 0..<Int(frames) { data[i] = fill }
    }
    return buffer
}
