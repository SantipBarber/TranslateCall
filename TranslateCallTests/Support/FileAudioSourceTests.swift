import AVFoundation
import Testing
@testable import TranslateCall

@Suite("FileAudioSource") @MainActor
struct FileAudioSourceTests {
    /// Writes a 0.5 s sine WAV at the given format to a temp file.
    private func makeWAV(sampleRate: Double, channels: AVAudioChannelCount) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        let fmt = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(sampleRate / 2)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames))
        buf.frameLength = frames
        let data = try #require(buf.floatChannelData)
        for ch in 0..<Int(channels) {
            for i in 0..<Int(frames) { data[ch][i] = sin(Float(i) * 0.05) * 0.3 }
        }
        try file.write(from: buf)
        return url
    }

    private func collect(_ src: FileAudioSource) async throws -> [AVAudioPCMBuffer] {
        try await src.startCapture()
        var out: [AVAudioPCMBuffer] = []
        for await b in src.audioStream16kHz { out.append(b) }
        return out
    }

    private func frameCount(_ bufs: [AVAudioPCMBuffer]) -> Int {
        bufs.reduce(0) { $0 + Int($1.frameLength) }
    }

    @Test func yields16kMonoWithTrailingSilence() async throws {
        let src = try FileAudioSource(url: makeWAV(sampleRate: 16_000, channels: 1), realtime: false, trailingSilence: 1.0)
        let bufs = try await collect(src)
        #expect(bufs.allSatisfy { $0.format.sampleRate == 16_000 && $0.format.channelCount == 1 })
        #expect(abs(frameCount(bufs) - 24_000) <= 1024) // 0.5 s audio + 1.0 s silence
    }

    @Test func convertsStereo48k() async throws {
        let src = try FileAudioSource(url: makeWAV(sampleRate: 48_000, channels: 2), realtime: false, trailingSilence: 0)
        let bufs = try await collect(src)
        #expect(bufs.allSatisfy { $0.format.sampleRate == 16_000 && $0.format.channelCount == 1 })
        #expect(abs(frameCount(bufs) - 8_000) <= 1024)
    }

    @Test func unreadableFileThrows() {
        #expect(throws: FileAudioSourceError.self) {
            try FileAudioSource(url: URL(fileURLWithPath: "/nonexistent.wav"))
        }
    }

    @Test func realtimePacing() async throws {
        let src = try FileAudioSource(url: makeWAV(sampleRate: 16_000, channels: 1), realtime: true, trailingSilence: 0)
        let start = ContinuousClock.now
        _ = try await collect(src)
        #expect(start.duration(to: .now) >= .milliseconds(400)) // ~0.5 s of audio
    }

    @Test func stopCaptureFinishesStream() async throws {
        let src = try FileAudioSource(url: makeWAV(sampleRate: 16_000, channels: 1), realtime: true, trailingSilence: 5)
        try await src.startCapture()
        src.stopCapture()
        var count = 0
        for await _ in src.audioStream16kHz { count += 1 }
        #expect(count < 10) // finished early instead of streaming 5.5 s
    }
}
