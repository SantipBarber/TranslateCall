import Foundation

// MARK: - TTS monitor (local playback + recording of outgoing TTS)

extension AudioCoordinator {
    /// Initializes the monitor (lazy — only created when first enabled).
    func enableTTSMonitor() {
        if ttsMonitor == nil {
            do {
                ttsMonitor = try TTSAudioMonitor()
            } catch {
                errorAlert = makeAlertItem(for: error)
                return
            }
        }
        ttsMonitor?.isEnabled = true
        ttsMonitorEnabled = true
        Task { await outgoingTTS?.setAudioMonitor(ttsMonitor) }
    }

    func disableTTSMonitor() {
        ttsMonitor?.isEnabled = false
        ttsMonitorEnabled = false
        Task { await outgoingTTS?.setAudioMonitor(nil) }
    }

    func toggleTTSRecording() {
        guard let monitor = ttsMonitor else { return }
        if monitor.isRecording {
            monitor.stopRecording()
            ttsMonitorRecording = false
        } else {
            do {
                try monitor.startRecording()
                ttsMonitorRecording = true
            } catch {
                errorAlert = makeAlertItem(for: error)
            }
        }
    }

    func playLastRecording() {
        ttsMonitor?.playLastRecording()
    }
}
