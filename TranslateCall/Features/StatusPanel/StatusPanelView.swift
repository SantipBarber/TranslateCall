import AppKit
import SwiftUI

// MARK: - StatusPanelContent

/// The panel's layout, fed plain values so previews render from fixtures (REQ-UI-41…45).
struct StatusPanelContent: View {
    let dot: MenuBarDot
    let title: String
    let appName: String
    let startedAt: Date?
    let isPaused: Bool
    let isExpanded: Bool
    let outgoing: DirectionRow
    let incoming: DirectionRow
    let notices: [String]
    var transcript: [TranscriptEntry] = []
    var isTranslating = false
    var sessionActive = true
    var showsLatency = true
    var onTogglePause: () -> Void = {}
    var onStop: () -> Void = {}
    var onToggleExpanded: () -> Void = {}

    static let width: CGFloat = 320

    var body: some View {
        if isExpanded {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(Theme.Spacing.medium)
                Divider()
                TranscriptView(entries: transcript, isTranslating: isTranslating, sessionActive: sessionActive,
                               showsLatency: showsLatency)
            }
            .frame(width: TranscriptView.width)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                header
                outgoing
                incoming
                PanelNotices(notices: notices)
            }
            .padding(Theme.Spacing.medium)
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Circle().fill(dotColor).frame(width: 8, height: 8).padding(.trailing, 2).accessibilityHidden(true)
            Text(title).fontWeight(.semibold).lineLimit(1).fixedSize()
            subtitle
            Spacer(minLength: 2)
            Image(systemName: "lock")
                .padding(.horizontal, 2)
                .font(.caption)
                .foregroundStyle(Theme.Status.green)
                .help("Everything runs on this Mac")
                .accessibilityLabel("Everything runs on this Mac")
            PanelButton(systemImage: isPaused ? "play" : "pause", label: isPaused ? "Resume" : "Pause",
                        action: onTogglePause)
            PanelButton(systemImage: "stop", label: "Stop", tint: Theme.Status.red, action: onStop)
            PanelButton(systemImage: isExpanded ? "chevron.up" : "chevron.down",
                        label: isExpanded ? "Collapse" : "Expand", action: onToggleExpanded)
        }
    }

    /// "Teams · 12:04": a long app name truncates, the clock never does; it ticks only while the panel
    /// is on screen (NFR-UI-03).
    private var subtitle: some View {
        HStack(spacing: 0) {
            Text(appName).lineLimit(1).truncationMode(.tail)
            if let startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(" · \(CallSessionModel.elapsedText(from: startedAt, to: context.date))")
                        .monospacedDigit()
                        .fixedSize()
                }
                .layoutPriority(1)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private var dotColor: Color {
        switch dot {
        case .green: Theme.Status.green
        case .orange: Theme.Status.orange
        case .none: Theme.Status.neutral
        }
    }
}

// MARK: - PanelButton

/// A 24 pt square icon button. Plain style with an explicit hit area; it acts on the first click
/// because the host is a `PanelHostingView`.
private struct PanelButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint ?? Color.primary)
                .frame(width: 24, height: 24)
                .background(Theme.soft(tint ?? Theme.Status.neutral))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - StatusPanelView

/// The panel hosted by `StatusPanelController`: direction rows, or the transcript when `panel.isExpanded`.
struct StatusPanelView: View {
    @EnvironmentObject private var session: CallSessionModel
    @EnvironmentObject private var model: MainSetupModel
    @EnvironmentObject private var panel: StatusPanelController
    @AppStorage(UISettingsKeys.showLatency) private var showLatency = true

    var body: some View {
        let (source, target) = (model.sourceLanguage, model.targetLanguage)
        let appName = model.selectedRow?.appName ?? String(localized: "No call app")
        StatusPanelContent(
            dot: MenuBarDot.derive(phase: session.phase, title: session.title),
            title: session.title.text, appName: appName, startedAt: session.sessionStartedAt,
            isPaused: session.isPaused, isExpanded: panel.isExpanded,
            outgoing: row(.outgoing, from: source, to: target, appName: appName),
            incoming: row(.incoming, from: target, to: source, appName: appName),
            notices: session.notices, transcript: session.transcript,
            isTranslating: session.isTranslating,
            sessionActive: TranscriptRules.isSessionActive(session.phase), showsLatency: showLatency,
            onTogglePause: { Task { await session.togglePause() } },
            onStop: { Task { await session.stop() } },
            onToggleExpanded: { panel.toggleExpanded() }
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { panel.resize(to: $0) }
    }

    private func row(_ direction: TranscriptDirection, from source: Locale.Language, to target: Locale.Language,
                     appName: String) -> DirectionRow {
        let isOutgoing = direction == .outgoing
        let status = session.incomingStatus
        let last = session.transcript.last { $0.direction == direction }
        let quote = last.map { entry -> String in
            let shown = entry.translation ?? entry.original
            let language = entry.translation == nil ? source : target
            return PanelQuote.wrap(shown, languageCode: language.languageCode?.identifier)
        }
        let latency = session.latency.canProvide && showLatency
            ? session.latency.latestLatency(for: direction)?.latencyLabel : nil
        return DirectionRow(
            direction: direction, source: source, target: target,
            state: isOutgoing ? session.outgoing : session.incoming,
            latency: latency, quote: quote,
            line: isOutgoing ? nil : DirectionCopy.incomingLine(status, appName: appName),
            showsChip: isOutgoing || status != .disabled,
            showsRetry: !isOutgoing && DirectionCopy.showsRetry(status), appName: appName,
            onRetry: { session.viewModel.retryIncoming() }, onChooseApp: { NSApp.showMainWindow() })
    }
}
