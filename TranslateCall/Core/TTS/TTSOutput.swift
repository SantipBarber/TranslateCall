import AVFoundation
import CoreAudio
import OSLog
import Synchronization

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSOutput")

// MARK: - TTSOutput

/// The device side of TTS (design §3.2): one `AVAudioPlayerNode` connected at the output's rate, every
/// buffer converted to that format, completion on `.dataPlayedBack`, restart after a configuration
/// change. The only HAL/AU property it writes is `kAudioOutputUnitProperty_CurrentDevice`
/// (F8.5.1: format writes wedged coreaudiod).
///
/// `@unchecked Sendable`: `engine` and `player` are only driven through calls AVFoundation allows from
/// any thread; every piece of mutable Swift state lives in `state`, a `Mutex`.
nonisolated final class TTSOutput: AudioOutputting, @unchecked Sendable {

    private struct State {
        var converter: PCMFormatConverter
        var pending: [PlaybackHandle] = []
        var isAvailable = true
        var isShutdown = false
    }

    private enum Step: Sendable {
        case play(AVAudioPCMBuffer)
        case alreadyHeard(PlaybackHandle?)
    }

    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private let deviceID: AudioDeviceID?
    private let state: Mutex<State>
    /// Set once at the end of `init`, read by `shutdown()`.
    private var configurationObserver: (any NSObjectProtocol)?

    /// - Parameter deviceID: output device (BlackHole for outgoing TTS); nil = system default output.
    init(deviceID: AudioDeviceID?) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        if let deviceID { try Self.bind(engine, to: deviceID) }
        let format = try Self.playerFormat(of: engine)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            throw STSError.engineStartFailed(error)
        }
        player.play()
        self.engine = engine
        self.player = player
        self.deviceID = deviceID
        state = Mutex(State(converter: PCMFormatConverter(target: format)))
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        shutdown()
    }

    // MARK: AudioOutputting

    func schedule(_ buffer: AVAudioPCMBuffer) throws -> PlaybackHandle {
        guard engine.isRunning else { throw STSError.outputUnavailable }
        let handle = PlaybackHandle()
        let step: Step = try state.withLock { current in
            guard current.isAvailable, !current.isShutdown else { throw STSError.outputUnavailable }
            let converted = try current.converter.convert(buffer)
            current.pending.removeAll { $0.isResolved }
            // Nothing came out of the converter yet (it is priming): this buffer is heard when
            // the audio scheduled before it is.
            guard converted.frameLength > 0 else { return .alreadyHeard(current.pending.last) }
            current.pending.append(handle)
            return .play(converted)
        }
        switch step {
        case .alreadyHeard(let previous):
            if let previous { return previous }
            handle.markPlayed()
            return handle
        case .play(let converted):
            player.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { _ in
                handle.markPlayed()
            }
            if !player.isPlaying { player.play() }
            return handle
        }
    }

    func stop() {
        let cancelled: [PlaybackHandle] = state.withLock { current in
            defer { current.pending.removeAll() }
            current.converter.reset()
            return current.pending
        }
        // Before player.stop(): the completions it fires must not count as played back.
        cancelled.forEach { $0.markCancelled() }
        player.stop()
    }

    func shutdown() {
        let first: Bool = state.withLock { current in
            defer { current.isShutdown = true }
            return !current.isShutdown
        }
        guard first else { return }
        stop()
        engine.stop()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    // MARK: Device

    private static func bind(_ engine: AVAudioEngine, to deviceID: AudioDeviceID) throws {
        guard let unit = engine.outputNode.audioUnit else { throw STSError.deviceRoutingFailed }
        do {
            try CoreAudioDevices.setCurrentDevice(deviceID, on: unit)
        } catch {
            throw STSError.deviceRoutingFailed
        }
    }

    /// Mono Float32 at the rate the output's hardware side reports. The mixer spreads mono over the
    /// device's channels and the output unit resamples if that rate is stale after a device change,
    /// so a stale value costs a resample, never silence (unlike the input side, F8.5.1).
    private static func playerFormat(of engine: AVAudioEngine) throws -> AVAudioFormat {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 1) else {
            throw STSError.outputUnavailable
        }
        return format
    }

    /// The device changed under the engine (unplugged, rate changed, default switched) and AVAudioEngine
    /// stopped. What was scheduled is lost, so its handles are cancelled; then the engine restarts on the
    /// same device. If that fails, `schedule` throws `.outputUnavailable` until the next change.
    private func handleConfigurationChange() {
        guard !engine.isRunning else { return }   // late notice of a change already recovered from
        let lost: [PlaybackHandle]? = state.withLock { current in
            guard !current.isShutdown else { return nil }
            current.isAvailable = false
            defer { current.pending.removeAll() }
            return current.pending
        }
        guard let lost else { return }
        lost.forEach { $0.markCancelled() }
        // Drop what the player still holds so stale audio never plays after being written off
        // (handles are already cancelled, so the completions this fires are harmless).
        player.stop()
        do {
            if let deviceID, let unit = engine.outputNode.audioUnit,
               CoreAudioDevices.currentDevice(of: unit) != deviceID {
                try CoreAudioDevices.setCurrentDevice(deviceID, on: unit)
            }
            let format = try Self.playerFormat(of: engine)
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            state.withLock { $0.converter.retarget(format) }
            try engine.start()
            player.play()
            state.withLock { $0.isAvailable = true }
            logger.info("TTS output restarted after a configuration change")
        } catch {
            logger.error("TTS output could not restart: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - PCMFormatConverter

/// Converts PCM buffers to one target format, keeping one streaming `AVAudioConverter` per source
/// format so consecutive buffers of an utterance join without gaps (NFR-T-01).
/// Not thread-safe: `TTSOutput` only calls it while holding its lock.
nonisolated final class PCMFormatConverter {
    private static let slackFrames: AVAudioFrameCount = 1_024

    private(set) var target: AVAudioFormat
    private var converters: [AVAudioFormat: AVAudioConverter] = [:]

    init(target: AVAudioFormat) {
        self.target = target
    }

    func retarget(_ format: AVAudioFormat) {
        target = format
        converters.removeAll()
    }

    /// Drops what the converters hold back between buffers (after playback was stopped).
    func reset() {
        converters.values.forEach { $0.reset() }
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == target { return buffer }
        let converter = try converter(for: buffer.format)
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + Self.slackFrames
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw STSError.outputUnavailable
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { throw STSError.outputUnavailable }
        return output
    }

    private func converter(for format: AVAudioFormat) throws -> AVAudioConverter {
        if let existing = converters[format] { return existing }
        guard let made = AVAudioConverter(from: format, to: target) else { throw STSError.outputUnavailable }
        converters[format] = made
        return made
    }
}
