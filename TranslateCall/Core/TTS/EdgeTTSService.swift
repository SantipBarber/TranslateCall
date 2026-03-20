import AVFoundation
import Foundation
import OSLog

private nonisolated let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "EdgeTTSService"
)

// MARK: - EdgeTTSService

/// Cloud-based TTS using Microsoft Edge TTS neural voices.
/// Used as automatic fallback when AVSpeechSynthesizer has no voice for a locale.
actor EdgeTTSService: SynthesisService {

    // MARK: - Protocol conformance

    nonisolated let isSpeakingStream: AsyncStream<Bool>

    // MARK: - Private state

    private var speakingContinuation: AsyncStream<Bool>.Continuation?
    nonisolated(unsafe) private var engine: AVAudioEngine?
    nonisolated(unsafe) private var playerNode: AVAudioPlayerNode?
    nonisolated(unsafe) private var mixerNode: AVAudioMixerNode?
    private let webSocket: EdgeTTSWebSocket
    private let voiceName: String
    private var currentTask: Task<Void, Never>?
    private var audioMonitor: TTSAudioMonitor?

    // MARK: - Init

    init(
        outputDeviceID: AudioDeviceID? = nil,
        voiceName: String,
        webSocket: EdgeTTSWebSocket = EdgeTTSWebSocket()
    ) throws {
        self.voiceName = voiceName
        self.webSocket = webSocket

        var cont: AsyncStream<Bool>.Continuation?
        self.isSpeakingStream = AsyncStream { cont = $0 }
        self.speakingContinuation = cont

        try setupAudioEngine(outputDeviceID: outputDeviceID)
    }

    // MARK: - SynthesisService

    func speak(text: String, locale: Locale) async {
        currentTask?.cancel()

        speakingContinuation?.yield(true)
        defer { speakingContinuation?.yield(false) }

        let startDate = Date()

        do {
            try await webSocket.connect()
            let audioStream = try await webSocket.synthesize(
                text: text, voice: voiceName
            )

            var allData = Data()
            for try await chunk in audioStream {
                allData.append(chunk)
            }

            guard !allData.isEmpty else {
                logger.warning("Edge TTS returned empty audio")
                return
            }

            try playMP3Data(allData)

            // Wait for playback to complete
            await waitForPlaybackEnd()

            let latencyMs = Date().timeIntervalSince(startDate) * 1000
            await TTSMetricsCollector.shared.record(TTSMetrics(
                engine: .edgeTTS,
                synthesisLatencyMs: Int(latencyMs),
                textLength: text.count,
                locale: locale,
                timestamp: Date()
            ))
        } catch {
            logger.error("Edge TTS speak failed: \(error.localizedDescription)")
        }
    }

    func stopSpeaking() async {
        currentTask?.cancel()
        currentTask = nil
        playerNode?.stop()
        speakingContinuation?.yield(false)
    }

    func setAudioMonitor(_ monitor: TTSAudioMonitor?) async {
        self.audioMonitor = monitor
    }

    func deactivate() async {
        await stopSpeaking()
        await webSocket.disconnect()
        engine?.stop()
    }

    // MARK: - Audio Engine Setup

    private nonisolated func setupAudioEngine(
        outputDeviceID: AudioDeviceID?
    ) throws {
        let eng = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()

        eng.attach(player)
        eng.attach(mixer)

        // player → mixer (handles format conversion) → output
        eng.connect(player, to: mixer, format: nil)
        let hwFormat = eng.outputNode.outputFormat(forBus: 0)
        eng.connect(mixer, to: eng.outputNode, format: hwFormat)

        if let deviceID = outputDeviceID,
           let audioUnit = eng.outputNode.audioUnit {
            var devID = deviceID
            let size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &devID, size
            )
            if status != noErr {
                logger.warning("Failed to set output device: \(status)")
            }
        }

        try eng.start()
        self.engine = eng
        self.playerNode = player
        self.mixerNode = mixer
    }

    // MARK: - MP3 Playback

    private func playMP3Data(_ data: Data) throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp3")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let audioFile = try AVAudioFile(forReading: tempURL)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: frameCount
        ) else { return }
        try audioFile.read(into: buffer)

        playerNode?.stop()
        playerNode?.scheduleBuffer(buffer, at: nil, options: [])
        playerNode?.play()
        audioMonitor?.process(buffer)
    }

    private func waitForPlaybackEnd() async {
        guard let player = playerNode else { return }
        // Poll player state
        while player.isPlaying {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
