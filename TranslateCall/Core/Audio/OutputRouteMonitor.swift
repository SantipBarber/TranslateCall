import Combine
import CoreAudio
import Foundation

/// Publishes the route of the device the other side's translation plays on: the chosen output, or
/// the system default when none is chosen. Re-reads it when the default output changes, or when a
/// built-in output switches between speakers and the headphone jack (its data source).
@MainActor
final class OutputRouteMonitor: ObservableObject {
    @Published private(set) var route: OutputRoute = .unknown

    private let resolve: (AudioDeviceID?) -> OutputRoute
    private let observesSystem: Bool
    private var chosen: AudioDeviceID?
    private var sourceListener: (device: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?
    private var defaultListener: AudioObjectPropertyListenerBlock?

    /// - Parameter resolve: the route of a device (nil: the system default); CoreAudio by default.
    init(resolve: ((AudioDeviceID?) -> OutputRoute)? = nil) {
        observesSystem = resolve == nil
        self.resolve = resolve ?? { id in
            (id ?? OutputRoute.defaultOutputDeviceID()).map(OutputRoute.of) ?? .unknown
        }
        if observesSystem { listenToDefaultOutput() }
        refresh()
    }

    /// The output the user chose (nil: the system default).
    func watch(_ device: AudioDeviceID?) {
        chosen = device
        refresh()
    }

    func refresh() {
        let next = resolve(chosen)
        if next != route { route = next }
        if observesSystem { listenToDataSource(of: chosen ?? OutputRoute.defaultOutputDeviceID()) }
    }

    // MARK: - CoreAudio listeners

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func listenToDefaultOutput() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        defaultListener = block
    }

    private func listenToDataSource(of device: AudioDeviceID?) {
        guard sourceListener?.device != device else { return }
        var address = Self.address(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
        if let old = sourceListener {
            AudioObjectRemovePropertyListenerBlock(old.device, &address, .main, old.block)
            sourceListener = nil
        }
        guard let device, AudioObjectHasProperty(device, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
        sourceListener = (device, block)
    }
}
