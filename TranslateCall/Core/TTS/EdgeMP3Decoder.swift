import AudioToolbox
import AVFoundation

// MARK: - EdgeMP3Decoder

/// Decodes a complete MP3 byte stream to one mono Float32 buffer, in memory (REQ-T-05): AudioFile reads
/// through callbacks over the `Data` and ExtAudioFile converts to PCM. No temporary file.
nonisolated enum EdgeMP3Decoder {
    private static let chunkFrames: AVAudioFrameCount = 4_096

    static func decode(_ mp3: Data) throws -> AVAudioPCMBuffer {
        guard !mp3.isEmpty else { throw EdgeTTSError.emptyAudio }
        let source = Unmanaged.passRetained(MP3Bytes(mp3))
        defer { source.release() }
        let read: AudioFile_ReadProc = { client, position, requestCount, buffer, actualCount in
            let bytes = Unmanaged<MP3Bytes>.fromOpaque(client).takeUnretainedValue().data
            let start = Int(position)
            guard start < bytes.count else {
                actualCount.pointee = 0
                return noErr
            }
            let count = min(Int(requestCount), bytes.count - start)
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                buffer.copyMemory(from: base.advanced(by: start), byteCount: count)
            }
            actualCount.pointee = UInt32(count)
            return noErr
        }
        let size: AudioFile_GetSizeProc = { client in
            Int64(Unmanaged<MP3Bytes>.fromOpaque(client).takeUnretainedValue().data.count)
        }
        var fileID: AudioFileID?
        var status = AudioFileOpenWithCallbacks(source.toOpaque(), read, nil, size, nil, kAudioFileMP3Type, &fileID)
        guard status == noErr, let fileID else { throw EdgeTTSError.decodeFailed(status) }
        defer { AudioFileClose(fileID) }
        var file: ExtAudioFileRef?
        status = ExtAudioFileWrapAudioFileID(fileID, false, &file)
        guard status == noErr, let file else { throw EdgeTTSError.decodeFailed(status) }
        defer { ExtAudioFileDispose(file) }
        return try readAll(file, as: try clientFormat(of: file))
    }

    /// Mono Float32 at the MP3's own rate (Edge: 24 kHz), set as the ExtAudioFile client format.
    private static func clientFormat(of file: ExtAudioFileRef) throws -> AVAudioFormat {
        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat)
        guard status == noErr, fileFormat.mSampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fileFormat.mSampleRate,
                                         channels: 1, interleaved: false)
        else { throw EdgeTTSError.decodeFailed(status) }
        var client = format.streamDescription.pointee
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, size, &client)
        guard status == noErr else { throw EdgeTTSError.decodeFailed(status) }
        return format
    }

    private static func readAll(_ file: ExtAudioFileRef, as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        var samples: [Float] = []
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
                  let channel = chunk.floatChannelData?[0]
            else { throw EdgeTTSError.decodeFailed(kAudioFileUnspecifiedError) }
            chunk.frameLength = chunkFrames   // the buffer list must advertise the full capacity
            var frames = UInt32(chunkFrames)
            let status = ExtAudioFileRead(file, &frames, chunk.mutableAudioBufferList)
            guard status == noErr else { throw EdgeTTSError.decodeFailed(status) }
            if frames == 0 { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(frames)))
        }
        guard let pcm = PCMBufferFactory.mono(samples, sampleRate: format.sampleRate) else {
            throw EdgeTTSError.emptyAudio
        }
        return pcm
    }
}

/// The MP3 bytes the AudioFile callbacks read from.
nonisolated private final class MP3Bytes {
    let data: Data

    init(_ data: Data) {
        self.data = data
    }
}
