import Accelerate
import AVFoundation
import Combine
import CoreAudio
import Foundation

// AVAudioPCMBuffer is safe to pass across concurrency boundaries when the sender
// does not mutate it after yielding. We declare this explicitly for Swift 6.
extension AVAudioPCMBuffer: @unchecked @retroactive Sendable {}

// MARK: - AudioCapture protocol

/// Minimal interface over `AudioManager` consumed by `AudioCoordinator`.
/// Allows mock injection for unit tests without requiring real hardware.
@MainActor
protocol AudioCapture: AnyObject {
    var audioStream16kHz: AsyncStream<AVAudioPCMBuffer> { get }
    func startCapture() async throws
    func stopCapture()
}

extension AudioManager: AudioCapture {}

// Minimal box to pass mutable state into @Sendable callbacks that are guaranteed
// to be called synchronously (e.g. AVAudioConverterInputBlock). Thread-safe by
// design: the callback runs on the same thread as the caller, never concurrently.
private final class SyncBox<T>: @unchecked Sendable {
    nonisolated(unsafe) var value: T
    nonisolated init(_ value: T) { self.value = value }
}

/// Central audio hub: device enumeration, capture, routing, sample-rate conversion, and metering.
///
/// All public API is `@MainActor` for safe use from SwiftUI.
/// Audio tap callbacks run on a real-time thread and use `nonisolated(unsafe)` storage.
@MainActor
final class AudioManager: ObservableObject {

    // MARK: - Published state

    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published var selectedInput: AudioDevice?
    @Published var selectedOutput: AudioDevice?
    @Published private(set) var inputLevel: Float = -160     // RMS dBFS
    @Published private(set) var isCapturing = false

    // MARK: - Audio streams

    /// Raw 48 kHz PCM stream — for routing / future full-quality processing.
    private(set) lazy var audioStream48kHz: AsyncStream<AVAudioPCMBuffer> = {
        AsyncStream { self._continuation48 = $0 }
    }()

    /// Downsampled 16 kHz mono PCM stream — for VAD and STT.
    private(set) lazy var audioStream16kHz: AsyncStream<AVAudioPCMBuffer> = {
        AsyncStream { self._continuation16 = $0 }
    }()

    // MARK: - Private — real-time thread storage (set on MainActor, read on audio thread)

    nonisolated(unsafe) private var _continuation48: AsyncStream<AVAudioPCMBuffer>.Continuation?
    nonisolated(unsafe) private var _continuation16: AsyncStream<AVAudioPCMBuffer>.Continuation?
    nonisolated(unsafe) private var _converter: AVAudioConverter?

    // MARK: - Private — engine (nonisolated so configureEngine can be nonisolated too)

    // The engine is created on MainActor and reconfigured only from MainActor callers.
    // nonisolated(unsafe) lets configureEngine() (nonisolated) access it without an
    // actor hop, which is required so the tap closure does NOT inherit @MainActor.
    nonisolated(unsafe) private let engine = AVAudioEngine()
    private let monitor = DeviceMonitor()
    private let defaults: UserDefaults

    // MARK: - UserDefaults keys

    private static let inputDeviceUIDKey  = "tlk.input.deviceUID"
    private static let outputDeviceUIDKey = "tlk.output.deviceUID"

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Force lazy stream init here (MainActor) so the continuations are populated
        // before any audio thread access. configureEngine() is nonisolated and must
        // not touch @MainActor lazy vars.
        _ = audioStream48kHz
        _ = audioStream16kHz

        monitor.onDevicesChanged = { [weak self] in
            self?.refreshDevices()
        }
        refreshDevices()
        restoreSelection()
    }

    // MARK: - Device enumeration (T4)

    private func refreshDevices() {
        let all = enumerateCoreAudioDevices()
        inputDevices = all.filter(\.hasInput)
        outputDevices = all.filter(\.hasOutput)
    }

    private func enumerateCoreAudioDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }

        return ids.compactMap { makeDevice(id: $0) }
    }

    private func makeDevice(id: AudioDeviceID) -> AudioDevice? {
        guard
            let name = stringProperty(
                id, selector: kAudioDevicePropertyDeviceNameCFString,
                scope: kAudioObjectPropertyScopeGlobal
            ),
            let uid = stringProperty(
                id, selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            )
        else { return nil }

        let hasInput = channelCount(id, scope: kAudioDevicePropertyScopeInput) > 0
        let hasOutput = channelCount(id, scope: kAudioDevicePropertyScopeOutput) > 0
        guard hasInput || hasOutput else { return nil }

        return AudioDevice(id: id, name: name, uid: uid, hasInput: hasInput, hasOutput: hasOutput)
    }

    // MARK: - Capture control (T5)

    func startCapture() async throws {
        guard !isCapturing else { return }

        guard await requestMicrophonePermission() else {
            throw AudioError.permissionDenied
        }

        guard selectedInput != nil || !inputDevices.isEmpty else {
            throw AudioError.noInputDevice
        }

        if selectedInput == nil {
            selectedInput = inputDevices.first
        }

        try configureEngine()
        isCapturing = true
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()      // clean state so next configureEngine() starts fresh
        isCapturing = false
        inputLevel = -160
    }

    // MARK: - Device selection (T8)

    func selectInput(_ device: AudioDevice) throws {
        guard inputDevices.contains(device) else {
            throw AudioError.deviceUnavailable(device.name)
        }
        let wasCapturing = isCapturing
        if wasCapturing { stopCapture() }
        selectedInput = device
        defaults.set(device.uid, forKey: Self.inputDeviceUIDKey)
        if wasCapturing { Task { try await self.startCapture() } }
    }

    func selectOutput(_ device: AudioDevice) throws {
        guard outputDevices.contains(device) else {
            throw AudioError.deviceUnavailable(device.name)
        }
        selectedOutput = device
        defaults.set(device.uid, forKey: Self.outputDeviceUIDKey)
    }

    // MARK: - Engine configuration
    //
    // nonisolated is REQUIRED here. Because this function is nonisolated, any closure
    // defined inside it (including the tap block) also has no actor isolation.
    // If configureEngine() were @MainActor, the tap closure would inherit @MainActor,
    // and AVAudioEngine would crash with _dispatch_assert_queue_fail when it calls the
    // tap from the audio thread (not the main thread).

    nonisolated private func configureEngine() throws {
        // Engine is already stopped by stopCapture() or was never started.
        // Do NOT call engine.stop() here — doing so before outputFormat(forBus:) can
        // return a zeroed-out format which causes installTap to assert internally.
        engine.inputNode.removeTap(onBus: 0)

        let inputNode = engine.inputNode
        let captureFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioError.engineStartFailed(
                NSError(domain: "AudioManager", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not create 16 kHz target format"])
            )
        }

        _converter = AVAudioConverter(from: captureFormat, to: targetFormat)

        // Streams were initialized in init() — continuations are already set.
        // Do NOT access audioStream48kHz / audioStream16kHz (lazy @MainActor vars) here.

        inputNode.installTap(
            onBus: 0, bufferSize: 1024, format: captureFormat
        ) { [weak self] buffer, _ in
            // Closure is nonisolated (defined in nonisolated context) — safe to call
            // from AVAudioEngine's real-time audio thread without queue assertions.
            self?.handleBuffer(buffer)
        }

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw AudioError.engineStartFailed(error)
        }
    }

    // MARK: - Real-time buffer handler (nonisolated — runs on audio thread)

    nonisolated private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        _continuation48?.yield(buffer)

        if let converted = downsample(buffer) {
            _continuation16?.yield(converted)
        }

        let rms = computeRMS(buffer)
        Task { @MainActor [weak self] in
            self?.inputLevel = rms
        }
    }

    // MARK: - Sample-rate conversion (T6)

    nonisolated private func downsample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = _converter else { return nil }

        let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1

        guard let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat, frameCapacity: outputFrames
        ) else { return nil }

        // convert(to:from:) does NOT support sample rate conversion — use callback API.
        // The callback is invoked synchronously (once) on the same thread as this call.
        let provided = SyncBox(false)
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard !provided.value else {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided.value = true
            outStatus.pointee = .haveData
            return buffer
        }
        return conversionError == nil && output.frameLength > 0 ? output : nil
    }

    // MARK: - Level metering (T7)

    nonisolated private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        var rms: Float = 0
        vDSP_measqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
        guard rms > 0 else { return -160 }
        return max(-160, 10 * log10f(rms))
    }

    // MARK: - Permissions

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - UserDefaults persistence

    private func restoreSelection() {
        if let uid = defaults.string(forKey: Self.inputDeviceUIDKey), !uid.isEmpty {
            if let match = inputDevices.first(where: { $0.uid == uid }) {
                selectedInput = match
            } else {
                defaults.removeObject(forKey: Self.inputDeviceUIDKey)
            }
        }
        if let uid = defaults.string(forKey: Self.outputDeviceUIDKey), !uid.isEmpty {
            if let match = outputDevices.first(where: { $0.uid == uid }) {
                selectedOutput = match
            } else {
                defaults.removeObject(forKey: Self.outputDeviceUIDKey)
            }
        }
    }

    // MARK: - CoreAudio helpers

    private func stringProperty(
        _ id: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var value: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, $0)
        }
        return status == noErr ? (value as String) : nil
    }

    private func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            id, &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return 0 }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(
            id, &address, 0, nil, &dataSize, bufferList
        ) == noErr else { return 0 }

        // UnsafeMutableAudioBufferListPointer is the safe way to iterate AudioBufferList
        return UnsafeMutableAudioBufferListPointer(bufferList)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
