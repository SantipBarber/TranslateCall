@_exported import Testing
import AVFoundation
import CoreMedia
import ScreenCaptureKit
@testable import TranslateCall

// MARK: - SystemAudioCaptureService Tests

@Suite("SystemAudioCaptureService", .serialized)
struct SystemAudioCaptureServiceTests {

    // MARK: - Initial state

    @Test("isActive is false initially")
    func isActiveFalseInitially() async {
        let service = SystemAudioCaptureService()
        #expect(await service.isActive == false)
    }

    // MARK: - Deactivate while inactive

    @Test("deactivate while inactive is a no-op (no crash)")
    func deactivateWhenInactive() async {
        let service = SystemAudioCaptureService()
        await service.deactivate()  // must not throw or crash
        #expect(await service.isActive == false)
    }

    // MARK: - SystemTap (A2: owned memory)

    @Test("extracted buffer owns its samples: wiping the sample buffer does not change them")
    func extractedBufferOwnsMemory() throws {
        let sine = makeSine48k(frames: 480)
        let sampleBuffer = try makeSampleBuffer(copying: sine)
        let extracted = try #require(SystemTap.extractOwnedPCMBuffer(from: sampleBuffer))

        // Overwrite the CMSampleBuffer's backing memory with zeros.
        let block = try #require(CMSampleBufferGetDataBuffer(sampleBuffer))
        #expect(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                           dataLength: CMBlockBufferGetDataLength(block)) == noErr)

        #expect(extracted.frameLength == 480)
        let got = Array(UnsafeBufferPointer(start: extracted.floatChannelData![0], count: 480))
        let want = Array(UnsafeBufferPointer(start: sine.floatChannelData![0], count: 480))
        #expect(got == want)
    }

    @Test("extract returns nil when the sample buffer has no data")
    func extractNilWithoutData() {
        #expect(SystemTap.extractOwnedPCMBuffer(from: makeSilentAudioSampleBuffer()) == nil)
    }

    @Test("extract rejects non-Float32 PCM")
    func rejectsNonFloatFormat() throws {
        let int16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: int16, frameCapacity: 480)!
        buffer.frameLength = 480
        let sampleBuffer = try makeSampleBuffer(copying: buffer)
        #expect(SystemTap.extractOwnedPCMBuffer(from: sampleBuffer) == nil)
    }

    @Test("process yields a 16 kHz mono buffer into the session")
    func processYields16k() async throws {
        let session = SessionAudioStream(label: "test")
        let tap = try SystemTap(session: session)
        tap.process(try makeSampleBuffer(copying: makeSine48k(frames: 4800)))
        session.finish()
        var buffers: [AVAudioPCMBuffer] = []
        for await buffer in session.stream { buffers.append(buffer) }
        let first = try #require(buffers.first)
        #expect(first.format.sampleRate == 16_000)
        #expect(first.format.channelCount == 1)
        #expect(first.frameLength > 0)
    }

    // MARK: - Stream stop handling (A1b)

    @Test("stopReason maps userDeclined to permissionDenied, anything else to streamError")
    func stopReasonMapping() {
        #expect(SystemAudioCaptureService.stopReason(for: SCStreamError(.userDeclined)) == .permissionDenied)
        let other = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "gone"])
        #expect(SystemAudioCaptureService.stopReason(for: other) == .streamError("gone"))
    }

    @Test("a stop callback while inactive or from an old generation is ignored")
    func staleStopIgnored() async {
        let service = SystemAudioCaptureService()
        #expect(await service.handleStreamStopped(.streamError("late"), generation: 0) == false)
        #expect(await service.handleStreamStopped(.streamError("late"), generation: 42) == false)
    }

    // MARK: - Permission + SCStream (manual / requires entitlement)
    // These tests require Screen Recording permission and are skipped in CI.

    @Test("requestPermissionAndLoadApps returns sorted app list",
          .disabled("Requires Screen Recording permission — run manually"))
    func requestPermissionReturnsSortedApps() async throws {
        let service = SystemAudioCaptureService()
        let apps = try await service.requestPermissionAndLoadApps()
        // If permission granted, should return non-empty sorted list
        let names = apps.map(\.applicationName)
        #expect(names == names.sorted())
    }
}

// MARK: - Helpers

private func make48kHzBuffer(frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    // Fill with zeros (silence)
    if let data = buffer.floatChannelData {
        for i in 0..<Int(frameCount) { data[0][i] = 0.0 }
    }
    return buffer
}

private func makeSilentAudioSampleBuffer() -> CMSampleBuffer {
    // Create a CMSampleBuffer with a valid audio format description (silence, 1 frame at 48kHz)
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var formatDesc: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
        allocator: nil,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDesc
    )

    var sampleBuffer: CMSampleBuffer?
    let frameCount = CMItemCount(1)
    let sampleDuration = CMTimeMake(value: 1, timescale: 48000)
    CMSampleBufferCreate(
        allocator: nil,
        dataBuffer: nil,
        dataReady: false,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDesc,
        sampleCount: frameCount,
        sampleTimingEntryCount: 0,
        sampleTimingArray: nil,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    )
    _ = sampleDuration  // suppress unused warning
    return sampleBuffer!
}

private func makeSine48k(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let buffer = make48kHzBuffer(frameCount: frames)
    let data = buffer.floatChannelData![0]
    for i in 0..<Int(frames) { data[i] = 0.5 * sinf(2 * .pi * 440 * Float(i) / 48_000) }
    return buffer
}

/// CMSampleBuffer whose block buffer holds a *copy* of `pcm` (CMSampleBufferSetDataBufferFromAudioBufferList copies).
private func makeSampleBuffer(copying pcm: AVAudioPCMBuffer) throws -> CMSampleBuffer {
    var formatDescription: CMAudioFormatDescription?
    #expect(CMAudioFormatDescriptionCreate(allocator: nil, asbd: pcm.format.streamDescription, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &formatDescription) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
                                    presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    #expect(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                 refcon: nil, formatDescription: formatDescription,
                                 sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
                                 sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                 sampleBufferOut: &sampleBuffer) == noErr)
    let result = try #require(sampleBuffer)
    #expect(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: nil,
                                                           blockBufferMemoryAllocator: nil, flags: 0,
                                                           bufferList: pcm.audioBufferList) == noErr)
    return result
}
