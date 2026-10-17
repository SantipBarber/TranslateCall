import Foundation
import Testing
@testable import TranslateCall

@Suite("Legacy advanced settings")
@MainActor
struct LegacyAdvancedSettingsTests {
    @Test("Engine selection helper")
    func engineSelection() {
        #expect(
            LegacyEngineChoice<STTEngine>.selection(isAutomatic: true, preferred: .parakeet)
                == .automatic
        )
        #expect(
            LegacyEngineChoice<STTEngine>.selection(isAutomatic: false, preferred: .whisper)
                == .engine(.whisper)
        )
    }

    @Test("VAD label and usage guide")
    func labels() {
        #expect(LegacyAdvancedSettingsView.vadLabel(.silero) == "VAD: Silero")
        #expect(LegacyAdvancedSettingsView.vadLabel(.energy) == "VAD: Energy")
        #expect(LegacyAdvancedSettingsView.vadLabel(nil) == "VAD: —")
        #expect(LegacyAdvancedSettingsView.guideURL?.absoluteString.hasSuffix("docs/usage-guide.md") == true)
    }
}
