import Accelerate
import AVFoundation
import Combine
import CoreAudio
import Foundation

// AVAudioPCMBuffer is safe to pass across concurrency boundaries when the sender
// does not mutate it after yielding. We declare this explicitly for Swift 6.
extension AVAudioPCMBuffer: @unchecked @retroactive Sendable {}

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

    // MARK: - Private — main-thread storage

    private let engine = AVAudioEngine()
    private let monitor = DeviceMonitor()

    // MARK: - Init

    init() {
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
        UserDefaults.standard.set(device.uid, forKey: "selectedInputUID")
        if wasCapturing { Task { try await self.startCapture() } }
    }

    func selectOutput(_ device: AudioDevice) throws {
        guard outputDevices.contains(device) else {
            throw AudioError.deviceUnavailable(device.name)
        }
        selectedOutput = device
        UserDefaults.standard.set(device.uid, forKey: "selectedOutputUID")
    }

    // MARK: - Engine configuration

    private func configureEngine() throws {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        let inputNode = engine.inputNode
        let captureFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { return }

        _converter = AVAudioConverter(from: captureFormat, to: targetFormat)

        // Touch lazy streams so continuations are ready before the tap fires
        _ = audioStream48kHz
        _ = audioStream16kHz

        inputNode.installTap(
            onBus: 0, bufferSize: 1024, format: captureFormat
        ) { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }

        do {
            try engine.start()
        } catch {
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
        let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat, frameCapacity: outputFrames
        ) else { return nil }

        // convert(to:from:) is synchronous PCM-to-PCM — no closure, no Sendable issues
        do {
            try converter.convert(to: output, from: buffer)
            return output.frameLength > 0 ? output : nil
        } catch {
            return nil
        }
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
        if let uid = UserDefaults.standard.string(forKey: "selectedInputUID") {
            selectedInput = inputDevices.first { $0.uid == uid }
        }
        if let uid = UserDefaults.standard.string(forKey: "selectedOutputUID") {
            selectedOutput = outputDevices.first { $0.uid == uid }
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
