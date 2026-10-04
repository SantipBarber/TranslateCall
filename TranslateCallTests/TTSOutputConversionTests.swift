import AVFoundation
import Testing
@testable import TranslateCall

@Suite("PCMFormatConverter")
struct PCMFormatConverterTests {
    private let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    @Test("a buffer already in the target format passes through untouched")
    func passthrough() throws {
        let converter = PCMFormatConverter(target: target)
        let buffer = makePCMBuffer(frames: 480, sampleRate: 48_000, fill: 0.5)
        #expect(try converter.convert(buffer) === buffer)
    }

    @Test("24 kHz Kokoro/Qwen/Edge audio is resampled to the output rate (about twice the frames)")
    func resamples24k() throws {
        let converter = PCMFormatConverter(target: target)
        let out = try converter.convert(makePCMBuffer(frames: 2_400, sampleRate: 24_000, fill: 0.5))
        #expect(out.format == target)
        #expect(abs(Int(out.frameLength) - 4_800) <= 480)
    }

    @Test("consecutive buffers of one utterance stream through one converter without losing audio (NFR-T-01)")
    func streamsConsecutiveBuffers() throws {
        let converter = PCMFormatConverter(target: target)
        var total = 0
        for _ in 0..<10 {
            total += Int(try converter.convert(makePCMBuffer(frames: 2_205, sampleRate: 22_050, fill: 0.5)).frameLength)
        }
        #expect(abs(total - 48_000) <= 480)   // 1 s in, 1 s out, minus the converter's few frames of latency
    }

    @Test("stereo and Int16 sources come out as the mono Float32 target")
    func otherLayouts() throws {
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let stereoBuffer = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4_410))
        stereoBuffer.frameLength = 4_410
        let int16 = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22_050,
                                               channels: 1, interleaved: false))
        let int16Buffer = try #require(AVAudioPCMBuffer(pcmFormat: int16, frameCapacity: 2_205))
        int16Buffer.frameLength = 2_205
        let converter = PCMFormatConverter(target: target)
        #expect(try converter.convert(stereoBuffer).format == target)
        #expect(try converter.convert(int16Buffer).format == target)
    }
}
