import Foundation
import Testing
@testable import TranslateCall

@Suite("Conversation settings view")
struct ConversationSettingsViewTests {
    @Test("VAD and pause labels (REQ-V-03, REQ-V-05)")
    func labels() {
        #expect(ConversationSettingsView.vadLabel(.silero) == "VAD: Silero")
        #expect(ConversationSettingsView.vadLabel(.energy) == "VAD: Energy")
        #expect(ConversationSettingsView.vadLabel(nil) == "VAD: —")
        #expect(ConversationSettingsView.pauseLabel(0.6) == "Pause to translate: 0.6 s")
        #expect(ConversationSettingsView.guideURL?.absoluteString.hasSuffix("docs/usage-guide.md") == true)
    }
}
