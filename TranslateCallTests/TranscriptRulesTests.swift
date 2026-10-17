import Foundation
import Testing
@testable import TranslateCall

@Suite("TranscriptRules (M9 UI core REQ-UI-44)")
struct TranscriptRulesTests {
    private func entry(_ direction: TranscriptDirection = .incoming) -> TranscriptEntry {
        TranscriptEntry(direction: direction, original: "Hola")
    }

    @Test("a translated entry is translated; skipped wins")
    func translatedAndSkipped() {
        var translated = entry()
        translated.translation = "Hallo"
        #expect(TranscriptRules.state(of: translated, sessionActive: true) == .translated)
        #expect(TranscriptRules.state(of: translated, sessionActive: false) == .translated)
        var skipped = entry()
        skipped.skipped = true
        #expect(TranscriptRules.state(of: skipped, sessionActive: false) == .skipped)
    }

    @Test("a pending entry is Translating only while a session is active; otherwise neutral")
    func pendingVersusNeutral() {
        #expect(TranscriptRules.state(of: entry(), sessionActive: true) == .pending)
        #expect(TranscriptRules.state(of: entry(), sessionActive: false) == .neutral)
    }

    @Test("running and starting are active; idle and launching are not")
    func activePhases() {
        #expect(TranscriptRules.isSessionActive(.running))
        #expect(TranscriptRules.isSessionActive(.starting))
        #expect(!TranscriptRules.isSessionActive(.idle))
        #expect(!TranscriptRules.isSessionActive(.launching))
    }

    @Test("near the bottom: within 24 pt follows, further up does not")
    func nearBottom() {
        #expect(TranscriptRules.isNearBottom(contentHeight: 1000, offsetY: 662, viewportHeight: 338))
        #expect(TranscriptRules.isNearBottom(contentHeight: 1000, offsetY: 638, viewportHeight: 338))
        #expect(!TranscriptRules.isNearBottom(contentHeight: 1000, offsetY: 637, viewportHeight: 338))
        #expect(TranscriptRules.isNearBottom(contentHeight: 100, offsetY: 0, viewportHeight: 338))
    }

    @Test("follow-bottom ignores the geometry of its own scroll animation; the user's scroll decides otherwise")
    func followsBottomIgnoresProgrammaticScroll() {
        #expect(TranscriptRules.followsBottom(current: true, nearBottom: false, programmaticScroll: true))
        #expect(!TranscriptRules.followsBottom(current: true, nearBottom: false, programmaticScroll: false))
        #expect(TranscriptRules.followsBottom(current: false, nearBottom: true, programmaticScroll: false))
    }

    @Test("footer: speaker, time, and the latency only when known and wanted")
    func footer() {
        var incoming = entry(.incoming)
        let time = incoming.date.formatted(.dateTime.hour().minute())
        #expect(TranscriptRules.footer(for: incoming) == "Them · \(time)")
        incoming.latency = .milliseconds(800)
        #expect(TranscriptRules.footer(for: incoming) == "Them · \(time) · 0.8 s")
        #expect(TranscriptRules.footer(for: incoming, showsLatency: false) == "Them · \(time)")
        let outgoing = entry(.outgoing)
        #expect(TranscriptRules.footer(for: outgoing).hasPrefix("You · "))
    }
}
