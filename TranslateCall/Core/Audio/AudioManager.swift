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
    /// Starts a capture session and returns its 16 kHz mono stream; `stopCapture()` finishes it.
    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer>
    func stopCapture()
    /// True while a capture session is live; false once it stopped (asked for or on its own).
    var isCapturing: Bool { get }
}

extension AudioManager: AudioCapture {}

/// Central audio hub: device enumeration, capture, routing, sample-rate conversion, and metering.
///
/// All public API is `@MainActor` for safe use from SwiftUI.
/// Audio tap callbacks run on a real-time thread via `MicTap`, which holds no MainActor state.
@MainActor
final class AudioManager: ObservableObject {

    // MARK: - Published state

    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published var selectedInput: AudioDevice?
    @Published var selectedOutput: AudioDevice?
    @Published private(set) var inputLevel: Float = -160     // RMS dBFS
    @Published private(set) var isCapturing = false
    /// User-facing notice about an automatic device change or a capture stop (REQ-C-13).
    @Published private(set) var deviceNotice: String?

    // MARK: - Capture session

    /// The current capture session's 16 kHz stream; created per `startCapture()`, finished by `stopCapture()`.
    private var session: SessionAudioStream?
    /// The device the engine input unit is currently bound to (nil when not capturing).
    private var activeDevice: AudioDevice?
    private var configChangeObserver: NSObjectProtocol?
    /// Engine (re)configuration; injectable so tests can exercise switching without hardware.
    /// `var` (not `let`) because the default captures `self`, which needs two-phase init.
    private var configure: (AudioDeviceID, SessionAudioStream) throws -> Void
    /// When true, refreshDevices() keeps the injected list (tests only).
    private var devicesInjected = false

    // MARK: - Private — engine (nonisolated so configureEngine can be nonisolated too)

    // SAFETY: mutated only from MainActor callers; `configureEngine` is nonisolated solely so the
    // tap closure does not inherit @MainActor (AVAudioEngine calls it off the main thread).
    nonisolated(unsafe) private let engine = AVAudioEngine()
    private let monitor = DeviceMonitor()
    private let defaults: UserDefaults

    // MARK: - UserDefaults keys

    private static let inputDeviceUIDKey  = "tlk.input.deviceUID"
    private static let outputDeviceUIDKey = "tlk.output.deviceUID"

    // MARK: - Init

    init(defaults: UserDefaults = .standard,
         configure: ((AudioDeviceID, SessionAudioStream) throws -> Void)? = nil) {
        self.defaults = defaults
        self.configure = configure ?? { _, _ in }   // replaced below; Swift needs all stored props first

        monitor.onDevicesChanged = { [weak self] in
            self?.refreshDevices()
        }
        refreshDevices()
        restoreSelection()
        if configure == nil {
            self.configure = { [unowned self] id, session in
                try self.configureEngine(deviceID: id, session: session)
            }
        }
    }

    // MARK: - Device enumeration (T4)

    private func refreshDevices() {
        guard !devicesInjected else { return }
        let all = CoreAudioDevices.allDevices()
        inputDevices = all.filter(\.hasInput)
        outputDevices = all.filter(\.hasOutput)
    }

    // MARK: - Capture control (T5)

    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard !isCapturing else { throw AudioError.alreadyCapturing }
        guard await requestMicrophonePermission() else { throw AudioError.permissionDenied }
        guard !isCapturing else { throw AudioError.alreadyCapturing }   // re-check after the await
        guard let device = Self.chooseInput(selectedUID: selectedInput?.uid, available: inputDevices,
                                            defaultID: CoreAudioDevices.defaultInputDeviceID())
        else { throw AudioError.noInputDevice }
        return try beginSession(on: device)
    }

    /// Test-only: same as startCapture() without the TCC microphone prompt.
    func startCaptureSkippingPermissionForTesting() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard !isCapturing else { throw AudioError.alreadyCapturing }
        guard let device = Self.chooseInput(selectedUID: selectedInput?.uid, available: inputDevices, defaultID: nil)
        else { throw AudioError.noInputDevice }
        return try beginSession(on: device)
    }

    /// Test-only: replaces the enumerated input devices; refreshDevices() then leaves them alone.
    func injectInputDevicesForTesting(_ devices: [AudioDevice]) {
        devicesInjected = true
        inputDevices = devices
    }

    private func beginSession(on device: AudioDevice) throws -> AsyncStream<AVAudioPCMBuffer> {
        let session = SessionAudioStream(label: "mic")
        do {
            try configure(device.id, session)
        } catch {
            session.finish()
            if error is AudioError { throw error }
            throw AudioError.engineStartFailed(error)
        }
        self.session = session
        activeDevice = device
        // Reflect the device actually in use (e.g. selection unplugged while idle); not persisted.
        if selectedInput != device { selectedInput = device }
        isCapturing = true
        observeConfigurationChanges()
        return session.stream
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()      // clean state so next configureEngine() starts fresh
        session?.finish()   // downstream for-await loops exit
        session = nil
        activeDevice = nil
        isCapturing = false
        inputLevel = -160
    }

    // MARK: - Device selection (T8)

    /// Selects (and persists) the mic; mid-session it hot-swaps synchronously on the same stream.
    func selectInput(_ device: AudioDevice) throws {
        guard inputDevices.contains(device) else {
            throw AudioError.deviceUnavailable(device.name)
        }
        if isCapturing, let session, device != activeDevice {
            try switchCapture(to: device, session: session)
        }
        selectedInput = device
        defaults.set(device.uid, forKey: Self.inputDeviceUIDKey)
    }

    func selectOutput(_ device: AudioDevice) throws {
        guard outputDevices.contains(device) else {
            throw AudioError.deviceUnavailable(device.name)
        }
        selectedOutput = device
        defaults.set(device.uid, forKey: Self.outputDeviceUIDKey)
    }

    // MARK: - Device choice, hot swap and fallback (A5, A5b, REQ-C-10…13)

    /// Selected device if present, else the system default input, else the first input.
    /// Automatic fallback never picks BlackHole (it carries our own TTS: capturing it would loop);
    /// an explicitly selected BlackHole is still honored.
    nonisolated static func chooseInput(selectedUID: String?, available: [AudioDevice],
                                        defaultID: AudioDeviceID?) -> AudioDevice? {
        if let selectedUID, let selected = available.first(where: { $0.uid == selectedUID }) { return selected }
        let candidates = available.filter { !$0.isBlackHole }
        if let defaultID, let fallback = candidates.first(where: { $0.id == defaultID }) { return fallback }
        return candidates.first
    }

    /// The device the engine's input unit is bound to (reads `CurrentDevice`; integration tests).
    var activeInputDeviceID: AudioDeviceID? {
        engine.inputNode.audioUnit.flatMap(CoreAudioDevices.currentDevice(of:))
    }

    /// Hot swap (REQ-C-11/12): same session stream, engine reconfigured on the new device;
    /// on failure the previous device is restored and the error rethrown.
    private func switchCapture(to device: AudioDevice, session: SessionAudioStream) throws {
        let previous = activeDevice
        engine.stop()
        do {
            try configure(device.id, session)
            activeDevice = device
        } catch {
            if let previous {
                engine.stop()
                do {
                    try configure(previous.id, session)
                } catch let restoreError {
                    stopCapture()
                    deviceNotice = "Microphone capture stopped: \(restoreError.localizedDescription)"
                    throw AudioError.deviceSwitchFailedCaptureStopped(device.name, error)
                }
            }
            throw AudioError.deviceSwitchFailed(device.name, error)
        }
    }

    private func observeConfigurationChanges() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleConfigurationChange(engineRunning: self.engine.isRunning)
            }
        }
    }

    /// REQ-C-13: keep the session alive on the selected device if present, else the default.
    func handleConfigurationChange(engineRunning: Bool) {
        guard isCapturing, let session else { return }
        refreshDevices()
        guard let target = Self.chooseInput(selectedUID: selectedInput?.uid, available: inputDevices,
                                            defaultID: CoreAudioDevices.defaultInputDeviceID())
        else {
            stopCapture()
            deviceNotice = "No microphone available — capture stopped."
            return
        }
        // Our own reconfiguration also posts this notification: nothing to do if unchanged.
        if engineRunning, target.id == activeDevice?.id { return }
        let previous = activeDevice
        engine.stop()
        do {
            try configure(target.id, session)
        } catch {
            stopCapture()
            deviceNotice = "Microphone capture stopped: \(error.localizedDescription)"
            return
        }
        activeDevice = target
        if let previous, previous.id != target.id {
            selectedInput = target   // not persisted: the saved choice is restored on next launch
            deviceNotice = "Microphone '\(previous.name)' disconnected — using '\(target.name)'."
        }
    }

    // MARK: - Engine configuration
    //
    // nonisolated is REQUIRED here. Because this function is nonisolated, any closure
    // defined inside it (including the tap block) also has no actor isolation.
    // If configureEngine() were @MainActor, the tap closure would inherit @MainActor,
    // and AVAudioEngine would crash with _dispatch_assert_queue_fail when it calls the
    // tap from the audio thread (not the main thread).

    nonisolated private func configureEngine(deviceID: AudioDeviceID, session: SessionAudioStream) throws {
        // Engine is already stopped by the caller (stopCapture / switch / config change) or was never
        // started. Do NOT call engine.stop() here — doing so before outputFormat(forBus:) can
        // return a zeroed-out format which causes installTap to assert internally.
        engine.inputNode.removeTap(onBus: 0)
        let inputNode = engine.inputNode
        guard let unit = inputNode.audioUnit else {
            throw AudioError.engineStartFailed(NSError(domain: "AudioManager", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Input node has no audio unit"]))
        }
        do {
            try CoreAudioDevices.setCurrentDevice(deviceID, on: unit)
        } catch {
            throw AudioError.engineStartFailed(error)
        }
        // After rebinding, outputFormat(forBus:) keeps the rate of the device the node was created on
        // (even on a fresh engine), while inputFormat(forBus:) reports the new hardware. Tap at the
        // hardware rate, otherwise a different-rate mic hears nothing or installTap throws (Task 8).
        let clientFormat = inputNode.outputFormat(forBus: 0)
        let hardwareRate = inputNode.inputFormat(forBus: 0).sampleRate   // read AFTER binding
        guard hardwareRate > 0, clientFormat.channelCount > 0,
              let captureFormat = AVAudioFormat(commonFormat: clientFormat.commonFormat, sampleRate: hardwareRate,
                                                channels: clientFormat.channelCount,
                                                interleaved: clientFormat.isInterleaved) else {
            throw AudioError.engineStartFailed(NSError(domain: "AudioManager", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Device \(deviceID) reports no input format"]))
        }
        guard let tap = MicTap(session: session, inputFormat: captureFormat, onLevel: { [weak self] rms in
            Task { @MainActor [weak self] in self?.inputLevel = rms }
        }) else {
            throw AudioError.engineStartFailed(
                NSError(domain: "AudioManager", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not create 16 kHz converter for \(captureFormat)"])
            )
        }
        // Closure is nonisolated (defined in nonisolated context) — safe to call
        // from AVAudioEngine's real-time audio thread without queue assertions.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: captureFormat) { buffer, _ in
            tap.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioError.engineStartFailed(error)
        }
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
}
