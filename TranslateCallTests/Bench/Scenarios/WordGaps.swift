import AVFoundation
import Speech
import Synchronization

/// Where one word ends and the next begins in a clip, from Apple Speech's word timings (QS-8). The pause
/// scenarios put a hesitation there: the quietest frame of the audio can be a consonant inside a word (the
/// closure of the "g" in "antigua"), and a cut there leaves a word fragment the recognizer scores low.
enum WordGaps {
    /// Sample offsets midway between consecutive words in `samples` (mono, `rate` Hz), recognized on device.
    /// Empty when recognition fails or finds fewer than two words.
    static func find(in samples: [Float], rate: Double, locale: Locale) async -> [Int] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.append(buffer)
        request.endAudio()

        let words: [(start: Double, end: Double)] = await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            let finish = { (words: [(start: Double, end: Double)]) in
                guard !resumed.withLock({ done in defer { done = true }; return done }) else { return }
                continuation.resume(returning: words)
            }
            recognizer.recognitionTask(with: request) { result, error in
                if error != nil { finish([]); return }
                guard let result, result.isFinal else { return }
                finish(result.bestTranscription.segments.map { ($0.timestamp, $0.timestamp + $0.duration) })
            }
        }
        return zip(words, words.dropFirst()).map { previous, next in
            Int((previous.end + next.start) / 2 * rate)
        }
    }
}
