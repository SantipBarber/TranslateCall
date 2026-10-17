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
    var isExpanded = false
    var transcript: [TranscriptEntry] = []
    var isTranslating = false
    var sessionActive = true

    @MainActor var content: StatusPanelContent {
        let line = DirectionCopy.incomingLine(incomingStatus, appName: appName)
        return StatusPanelContent(
            dot: dot, title: title, appName: appName, startedAt: Date(timeIntervalSinceNow: -724),
            isPaused: isPaused, isExpanded: isExpanded,
            outgoing: DirectionRow(direction: .outgoing, source: source, target: target, state: outgoingState,
                                   latency: "0.9 s", quote: PanelQuote.wrap(outgoingQuote, languageCode: "de"),
                                   appName: appName),
            incoming: DirectionRow(direction: .incoming, source: target, target: source, state: incomingState,
                                   latency: "0.8 s", quote: incomingQuote.isEmpty ? nil
                                       : PanelQuote.wrap(incomingQuote, languageCode: "es"),
                                   line: line, showsChip: incomingStatus != .disabled,
                                   showsRetry: DirectionCopy.showsRetry(incomingStatus), appName: appName),
            notices: notices, transcript: transcript, isTranslating: isTranslating,
            sessionActive: sessionActive)
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

extension StatusPanelFixture {
    private static func entry(_ direction: TranscriptDirection, _ original: String, _ translation: String?,
                              _ minute: Int, latency: Double? = nil, skipped: Bool = false) -> TranscriptEntry {
        var entry = TranscriptEntry(direction: direction, original: original,
                                    date: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 17,
                                                                                     hour: 12, minute: minute)) ?? .now)
        entry.translation = translation
        entry.skipped = skipped
        entry.latency = latency.map { .seconds($0) }
        return entry
    }

    /// The frame's three bubbles.
    static let frameEntries = [
        entry(.incoming, "Buenas tardes, ¿podemos empezar con el contrato?",
              "Guten Tag, können wir mit dem Vertrag anfangen?", 2),
        entry(.outgoing, "Ja, natürlich. Ich schicke Ihnen den Vertrag heute Nachmittag.",
              "Sí, claro. Le envío el contrato esta tarde.", 3, latency: 0.9),
        entry(.incoming, "Perfecto, lo reviso mañana a primera hora.",
              "Perfekt, ich schaue es mir morgen früh an.", 4, latency: 0.8)
    ]

    static let transcriptTranslating = Self(isExpanded: true, transcript: frameEntries, isTranslating: true)
    static let transcriptSkipped = Self(isExpanded: true, transcript: frameEntries + [
        entry(.outgoing, "Eso no se puede traducir.", nil, 5, skipped: true),
        entry(.incoming, "Cancelled by Stop.", nil, 6)
    ], sessionActive: false)
    static let transcriptLong = Self(isExpanded: true, transcript: (0..<50).map { index in
        entry(index.isMultiple(of: 2) ? .incoming : .outgoing, "Sentence number \(index + 1) of the call.",
              "Satz Nummer \(index + 1) des Gesprächs.", index % 60, latency: 0.8)
    })
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
#Preview("Transcript") { PanelPreviewFrame(fixture: .transcriptTranslating) }
#Preview("Transcript, dark") { PanelPreviewFrame(fixture: .transcriptTranslating).preferredColorScheme(.dark) }
#Preview("Transcript, skipped and cancelled") { PanelPreviewFrame(fixture: .transcriptSkipped) }
#Preview("Transcript, skipped, dark") { PanelPreviewFrame(fixture: .transcriptSkipped).preferredColorScheme(.dark) }
#Preview("Transcript, 50 entries") { PanelPreviewFrame(fixture: .transcriptLong) }
#Preview("Transcript, 50 entries, dark") { PanelPreviewFrame(fixture: .transcriptLong).preferredColorScheme(.dark) }
#Preview("Longest strings") { PanelPreviewFrame(fixture: .longest) }
#endif
