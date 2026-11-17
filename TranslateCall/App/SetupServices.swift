import CoreAudio
import Foundation

/// The setup assistant's live checks and rehearsal (M9 UI first-run, design §5–6). Built once;
/// both stop when the window closes, the step is left or a call starts.
@MainActor
struct SetupServices {
    let checks: SetupChecks
    let rehearsal: Rehearsal

    init(coordinator: AudioCoordinator, viewModel: AudioViewModel, callSession: CallSessionModel,
         tts: TTSEngineSelector) {
        let micDevice: () -> AudioDeviceID? = {
            viewModel.selectedInput?.id ?? CoreAudioDevices.defaultInputDeviceID()
        }
        let micSource: () throws -> any LevelSource = {
            guard let id = micDevice() else { throw SetupAudioError.noInputUnit }
            return InputLevelSource(deviceID: id, records: false)
        }
        let callRunning: () -> Bool = { [.launching, .starting, .running].contains(callSession.phase) }
        checks = SetupChecks(
            micSource: micSource,
            blackHoleSource: { InputLevelSource(deviceID: $0, records: false) },
            phrasePlayer: SystemVoicePhrasePlayer(), callRunning: callRunning)
        rehearsal = Rehearsal(
            host: coordinator,
            listener: { InputLevelSource(deviceID: $0, records: true) },
            player: RecordingPlayer(),
            needsConsent: { viewModel.needsEdgeConsentBeforeStart },
            grantConsent: { tts.grantEdgeTTSConsent() })
    }
}
