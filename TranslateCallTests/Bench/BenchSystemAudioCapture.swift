import AVFoundation
import ScreenCaptureKit
@testable import TranslateCall

/// The call-app side of a bench session: production `SystemAudioCapture`, fed by a `BenchClipPlayer`
/// (M9 design §3.2). Accepts any target; never reports a stop on its own.
actor BenchSystemAudioCapture: SystemAudioCapture {
    nonisolated let player = BenchClipPlayer()
    /// Never yields: a file-backed capture cannot stop by itself.
    nonisolated let events = AsyncStream<SystemCaptureEvent> { _ in }

    func requestPermissionAndLoadApps() async throws -> [SCRunningApplication] { [] }

    func activate(target: CaptureTarget) async throws -> AsyncStream<AVAudioPCMBuffer> {
        player.start()
    }

    func deactivate() async {
        player.stop()
    }
}
