#if DEBUG
import SwiftUI

/// One state of the compact panel, fixture-driven (previews never start a real session).
struct StatusPanelFixture {
    var title = "Translating"
    var dot = MenuBarDot.green
    var appName = "Teams"
    var isPaused = false
    var outgoingState = DirectionState.speaking
    var incomingState = DirectionState.listening
    var incomingStatus = IncomingStatus.active
    var notices: [String] = []
    var source = Locale.Language(identifier: "es")
    var target = Locale.Language(identifier: "de")
    var outgoingQuote = "Ich schicke Ihnen den Vertrag heute Nachmittag."
    var incomingQuote = "Perfecto, lo reviso mañana a primera hora."

    @MainActor var content: StatusPanelContent {
        let line = DirectionCopy.incomingLine(incomingStatus, appName: appName)
        return StatusPanelContent(
            dot: dot, title: title, appName: appName, startedAt: Date(timeIntervalSinceNow: -724),
            isPaused: isPaused, isExpanded: false,
            outgoing: DirectionRow(direction: .outgoing, source: source, target: target, state: outgoingState,
                                   latency: "0.9 s", quote: PanelQuote.wrap(outgoingQuote, languageCode: "de"),
                                   appName: appName),
            incoming: DirectionRow(direction: .incoming, source: target, target: source, state: incomingState,
                                   latency: "0.8 s", quote: incomingQuote.isEmpty ? nil
                                       : PanelQuote.wrap(incomingQuote, languageCode: "es"),
                                   line: line, showsChip: incomingStatus != .disabled,
                                   showsRetry: DirectionCopy.showsRetry(incomingStatus), appName: appName),
            notices: notices)
    }

    static let translating = Self()
    static let lost = Self(title: "Partly working", dot: .orange,
                           incomingState: .unavailable(.targetNotFound(bundleID: "com.microsoft.teams2")),
                           incomingStatus: .stopped(.targetNotFound(bundleID: "com.microsoft.teams2")),
                           incomingQuote: "")
    static let speakers = Self(outgoingState: .micPaused, incomingState: .speaking, notices: [
        CallSessionModel.composeNotices(listeningMode: .speakers, transient: nil)[0],
        "1 sentence was too long to voice — shown in the transcript."
    ])
    static let paused = Self(title: "Paused", dot: .orange, isPaused: true, outgoingState: .paused,
                             incomingState: .paused)
    /// The longest strings the panel must hold.
    static let longest = Self(appName: "Microsoft Teams (work or school)",
                              source: Locale.Language(identifier: "pt-BR"), target: Locale.Language(identifier: "de"))
}

private struct PanelPreviewFrame: View {
    let fixture: StatusPanelFixture
    var body: some View {
        fixture.content.background(Color(.windowBackgroundColor)).padding(24)
    }
}

#Preview("Translating") { PanelPreviewFrame(fixture: .translating) }
#Preview("Translating, dark") { PanelPreviewFrame(fixture: .translating).preferredColorScheme(.dark) }
#Preview("Incoming lost") { PanelPreviewFrame(fixture: .lost) }
#Preview("Incoming lost, dark") { PanelPreviewFrame(fixture: .lost).preferredColorScheme(.dark) }
#Preview("Speakers and skipped") { PanelPreviewFrame(fixture: .speakers) }
#Preview("Speakers and skipped, dark") { PanelPreviewFrame(fixture: .speakers).preferredColorScheme(.dark) }
#Preview("Paused") { PanelPreviewFrame(fixture: .paused) }
#Preview("Longest strings") { PanelPreviewFrame(fixture: .longest) }
#endif
