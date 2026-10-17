import Foundation
import Testing
@testable import TranslateCall

@Suite("UI copy and ordering (M9 UI core)")
struct UICopyTests {

    @Test("chip texts per state and direction (REQ-UI-43)")
    func chips() {
        #expect(DirectionCopy.chip(.unavailable(.permissionDenied), direction: .incoming, appName: "Teams")
                == "Can't hear Teams")
        #expect(DirectionCopy.chip(.hearing, direction: .outgoing, appName: "Teams") == "Hearing you")
        #expect(DirectionCopy.chip(.hearing, direction: .incoming, appName: "Teams") == "Hearing them")
        #expect(DirectionCopy.chip(.translating, direction: .outgoing, appName: "") == "Translating…")
        #expect(DirectionCopy.chip(.micPaused, direction: .outgoing, appName: "") == "Mic paused")
    }

    @Test("unavailable lines name the cause")
    func unavailableLines() {
        #expect(DirectionCopy.unavailableLine(.targetNotFound(bundleID: "us.zoom.xos"), appName: "Zoom")
                == "Zoom isn't running. Open it, then Retry.")
        #expect(DirectionCopy.unavailableLine(.streamError("boom"), appName: "Zoom") == "Call audio stopped: boom")
    }

    @Test("the Them row's line and Retry per incoming status (ported from IncomingStatusBannerTests)")
    func incomingLines() {
        #expect(DirectionCopy.incomingLine(.idle, appName: "Zoom") == nil)
        #expect(DirectionCopy.incomingLine(.active, appName: "Zoom") == nil)
        #expect(DirectionCopy.incomingLine(.disabled, appName: "Zoom") == "Only your voice is translated")
        #expect(DirectionCopy.incomingLine(.starting, appName: "Zoom") == "Connecting to Zoom…")
        let stopped = IncomingStatus.stopped(.targetNotFound(bundleID: "us.zoom.xos"))
        #expect(DirectionCopy.incomingLine(stopped, appName: "Zoom") == "Zoom isn't running. Open it, then Retry.")
        #expect(DirectionCopy.showsRetry(stopped))
        #expect(!DirectionCopy.showsRetry(.disabled))
        #expect(!DirectionCopy.showsRetry(.starting))
        #expect(!DirectionCopy.showsRetry(.active))
    }

    @Test("VoiceOver label reads direction, languages and state (NFR-UI-04)")
    func accessibility() {
        #expect(DirectionCopy.accessibilityLabel(direction: .outgoing, from: "Spanish", to: "German", state: "Speaking")
                == "You, Spanish to German, speaking")
        // Incoming off (no call app): no chip, so no state word; the row's line is its value.
        #expect(DirectionCopy.accessibilityLabel(direction: .incoming, from: "German", to: "Spanish", state: nil)
                == "Them, German to Spanish")
    }

    @Test("pickers list Español, English, Deutsch first, then the rest by name (REQ-UI-06)")
    func languageOrdering() {
        let supported = ["uk", "de", "fr", "en", "es", "ja"].map { Locale.Language(identifier: $0) }
        let names = ["uk": "Ukrainian", "de": "German", "fr": "French", "en": "English", "es": "Spanish", "ja": "Japanese"]
        let result = LanguageOrdering.ordered(supported) { names[$0.languageCode?.identifier ?? ""] ?? "" }
        #expect(result.priority.map(\.minimalIdentifier) == ["es", "en", "de"])
        #expect(result.others.map(\.minimalIdentifier) == ["fr", "ja", "uk"])
    }

    @Test("no priority language supported → an empty first group")
    func noPriority() {
        let result = LanguageOrdering.ordered([Locale.Language(identifier: "fr")]) { _ in "French" }
        #expect(result.priority.isEmpty)
        #expect(result.others.count == 1)
    }
}

@Suite("Menu bar dot (M9 UI core REQ-UI-61)")
struct MenuBarDotTests {
    @Test("translating → green; paused or partly working → orange; idle, launching or starting → no dot")
    func dots() {
        #expect(MenuBarDot.derive(phase: .idle, title: .translating) == MenuBarDot.none)
        #expect(MenuBarDot.derive(phase: .running, title: .translating) == .green)
        #expect(MenuBarDot.derive(phase: .running, title: .paused) == .orange)
        #expect(MenuBarDot.derive(phase: .running, title: .partlyWorking) == .orange)
        #expect(MenuBarDot.derive(phase: .launching, title: .translating) == MenuBarDot.none)
        #expect(MenuBarDot.derive(phase: .starting, title: .starting) == MenuBarDot.none)
    }
}
