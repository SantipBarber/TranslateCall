import AVFoundation
import CoreAudio
import os

private nonisolated let logger = Logger(subsystem: "TranslateCall", category: "AVSpeechService")

// MARK: - AVSpeechService

actor AVSpeechService: SynthesisService {

    // MARK: - SynthesisService conformance

    nonisolated let isSpeakingStream: AsyncStream<Bool>

    // MARK: - Private state

    private var speakingContinuation: AsyncStream<Bool>.Continuation?
    private let config: SynthesisConfiguration

    // Audio engine (actor-isolated)
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    // Mixer handles mono→stereo conversion and sample-rate adaptation
    private let mixer = AVAudioMixerNode()
    private var synthesizer = AVSpeechSynthesizer()

    // Monitor (optional — for local playback/recording of outgoing TTS)
    private var audioMonitor: TTSAudioMonitor?

    // Queue (actor-isolated)
    private var utteranceQueue: [(text: String, locale: Locale)] = []
    private var isSynthesizing = false
    /// Tracks whether the playerNode→mixer connection has been reconfigured to match the TTS buffer format.
    private var playerFormatConfigured = false

    // Delegate bridge — holds self weakly via ObjC delegate
    private var delegateBridge: SpeechSynthesizerDelegateBridge?

    // MARK: - Init

    /// - Parameters:
    ///   - config: Synthesis configuration (rate, pitch, volume).
    ///   - outputDeviceID: CoreAudio device ID to route output to. `nil` = system default.
    ///     Used to send outgoing TTS to BlackHole (F4.1).
    init(config: SynthesisConfiguration = .default, outputDeviceID: AudioDeviceID? = nil) throws {
        self.config = config

        var cont: AsyncStream<Bool>.Continuation?
        isSpeakingStream = AsyncStream { cont = $0 }
        speakingContinuation = cont

        // Wire audio engine:
        // playerNode → mixer (format: nil = accept whatever speech synth delivers, e.g. mono)
        // mixer → outputNode (hardware stereo format)
        // AVAudioMixerNode handles mono→stereo conversion and sample-rate adaptation.
        engine.attach(playerNode)
        engine.attach(mixer)
        engine.connect(playerNode, to: mixer, format: nil)
        engine.connect(mixer, to: engine.outputNode,
                       format: engine.outputNode.outputFormat(forBus: 0))

        // Route to specific output device before starting (e.g. BlackHole for outgoing TTS).
        if let deviceID = outputDeviceID {
            engine.prepare()
            try Self.configureOutputDevice(deviceID, on: engine)
        }

        do {
            try engine.start()
        } catch {
            throw STSError.engineStartFailed(error)
        }
    }

    // MARK: - Output device routing

    /// Sets the CoreAudio output device on the engine's output audio unit.
    /// Must be called after `engine.prepare()` and before `engine.start()`.
    private static func configureOutputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw STSError.deviceRoutingFailed
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw STSError.deviceRoutingFailed
        }
    }

    // MARK: - Post-init delegate setup (call after init completes)

    private func setupDelegate() {
        let bridge = SpeechSynthesizerDelegateBridge(service: self)
        self.delegateBridge = bridge
        synthesizer.delegate = bridge
    }

    // MARK: - SynthesisService

    func speak(text: String, locale: Locale) async {
        if delegateBridge == nil { setupDelegate() }
        utteranceQueue.append((text: text, locale: locale))
        if !isSynthesizing {
            await processNextUtterance()
        }
    }

    func stopSpeaking() async {
        utteranceQueue.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        playerNode.stop()
        isSynthesizing = false
        speakingContinuation?.yield(false)
    }

    func deactivate() async {
        await stopSpeaking()
        engine.stop()
        speakingContinuation?.finish()
    }

    // MARK: - Private

    private func processNextUtterance() async {
        guard !utteranceQueue.isEmpty, !isSynthesizing else { return }
        let (text, locale) = utteranceQueue.removeFirst()

        guard let voice = bestVoice(for: locale) else {
            logger.warning("No voice found for locale: \(locale.identifier) — skipping utterance")
            // Advance queue if more items
            if !utteranceQueue.isEmpty {
                await processNextUtterance()
            }
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = config.rate
        utterance.pitchMultiplier = config.pitchMultiplier
        utterance.volume = config.volume

        isSynthesizing = true
        speakingContinuation?.yield(true)

        synthesizer.write(utterance) { [weak self] buffer in
            guard let self,
                  let pcm = buffer as? AVAudioPCMBuffer,
                  pcm.frameLength > 0 else { return }
            Task { await self.scheduleBuffer(pcm) }
        }
    }

    func setAudioMonitor(_ monitor: TTSAudioMonitor?) async {
        self.audioMonitor = monitor
    }

    private func scheduleBuffer(_ pcm: AVAudioPCMBuffer) async {
        guard engine.isRunning else { return }
        // On first buffer, reconnect playerNode→mixer with the actual TTS buffer format
        // (e.g. mono 22 kHz). This avoids the channel-count mismatch crash because
        // `format: nil` at init time resolves to stereo (from the output node).
        if !playerFormatConfigured {
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: mixer, format: pcm.format)
            playerFormatConfigured = true
            logger.info("Player format configured: \(pcm.format.description)")
        }
        if !playerNode.isPlaying { playerNode.play() }
        // DO NOT use async scheduleBuffer — it blocks the synthesis callback pipeline.
        playerNode.scheduleBuffer(pcm, at: nil, options: [], completionHandler: nil)
        audioMonitor?.process(pcm)
    }

    func bestVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        let lang = String(locale.identifier
            .replacingOccurrences(of: "_", with: "-")
            .prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        return voices.first(where: { $0.quality == .premium })
            ?? voices.first(where: { $0.quality == .enhanced })
            ?? voices.first
    }

    // MARK: - Delegate callback (called from bridge)

    func utteranceDidFinish() async {
        isSynthesizing = false
        if utteranceQueue.isEmpty {
            speakingContinuation?.yield(false)
            playerNode.stop()
        } else {
            await processNextUtterance()
        }
    }
}

// MARK: - Voice availability

extension AVSpeechService {
    /// Returns true if AVSpeechSynthesizer has at least one voice for the locale.
    nonisolated static func hasVoice(for locale: Locale) -> Bool {
        guard let code = locale.language.languageCode?.identifier,
              !code.isEmpty else { return false }
        return AVSpeechSynthesisVoice.speechVoices().contains { voice in
            let voiceLang = voice.language
                .components(separatedBy: "-").first ?? ""
            return voiceLang == code
        }
    }

    /// Exposed for unit tests only.
    func bestVoiceForTesting(locale: Locale) -> AVSpeechSynthesisVoice? {
        bestVoice(for: locale)
    }
}

// MARK: - Delegate Bridge

/// ObjC delegate must be an NSObject, so we use a bridge that holds a weak reference to the actor.
private final class SpeechSynthesizerDelegateBridge: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private weak var service: AVSpeechService?

    init(service: AVSpeechService) {
        self.service = service
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let service else { return }
        Task { await service.utteranceDidFinish() }
    }
}
