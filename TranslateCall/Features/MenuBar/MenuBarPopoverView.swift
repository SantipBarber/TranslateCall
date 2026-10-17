import SwiftUI

// MARK: - MenuBarStart

/// Shared start path used by the popover primary button and the status-item context menu.
@MainActor
enum MenuBarStart {
    static func start(setup: MainSetupModel, viewModel: AudioViewModel) {
        if MenuBarStartPolicy.needsMainWindow(readiness: setup.readiness,
                                              needsEdgeConsent: viewModel.needsEdgeConsentBeforeStart) {
            NSApp.showMainWindow()
        }
        Task { await setup.primaryAction() }
    }
}

// MARK: - MenuBarPopoverContent

/// The popover's layout, fed plain values so previews render from fixtures (REQ-UI-60).
struct MenuBarPopoverContent: View {
    /// Idle layout (grey dot, status line, primary button) or the translating one.
    var isTranslating = false
    let dot: MenuBarDot
    /// "Ready", the blocking reason, or the session title.
    let headline: String
    /// "Teams · Español ↔ Deutsch" (without the clock).
    let subtitle: String
    var startedAt: Date?
    /// The primary button's title and whether it is pressable (false while the call app opens, P24).
    var primaryTitle = ""
    var primaryDisabled = false
    var outgoing: DirectionRow?
    var incoming: DirectionRow?
    var onPrimary: () -> Void = {}
    var onStop: () -> Void = {}
    var onShowPanel: () -> Void = {}
    var onOpenMain: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}

    static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            header
            if isTranslating {
                if let outgoing { MenuBarMiniRow(row: outgoing) }
                if let incoming { MenuBarMiniRow(row: incoming) }
                Button(action: onStop) {
                    Label("Stop translating", systemImage: "stop")
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.Status.red)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(Theme.soft(Theme.Status.red))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(primaryDisabled)
            } else {
                Button(action: onPrimary) {
                    Label(primaryTitle, systemImage: "play")
                        .frame(maxWidth: .infinity, minHeight: 20)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(primaryDisabled)
            }
            Divider().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 2) {
                if isTranslating {
                    MenuBarItem("Show status panel", systemImage: "macwindow.on.rectangle", action: onShowPanel)
                }
                MenuBarItem("Open TranslateCall", systemImage: "macwindow", action: onOpenMain)
                MenuBarItem("Settings…", systemImage: "gearshape", action: onSettings)
                MenuBarItem("Quit", systemImage: "power", action: onQuit)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 5).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).fontWeight(.semibold).lineLimit(2)
                HStack(spacing: 0) {
                    Text(subtitle).lineLimit(1).truncationMode(.tail)
                    if isTranslating, let startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(" · \(CallSessionModel.elapsedText(from: startedAt, to: context.date))")
                                .monospacedDigit().fixedSize()
                        }
                        .layoutPriority(1)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Image(systemName: "lock")
                .font(.caption)
                .foregroundStyle(Theme.Status.green)
                .padding(.top, 2)
                .help("Everything runs on this Mac")
                .accessibilityLabel("Everything runs on this Mac")
        }
    }

    private var dotColor: Color {
        switch dot {
        case .green: Theme.Status.green
        case .orange: Theme.Status.orange
        case .none: Theme.Status.neutral
        }
    }
}

// MARK: - Rows

/// "You  ES → DE" with the state chip in its tint (no quote, unlike the panel).
struct MenuBarMiniRow: View {
    let row: DirectionRow

    var body: some View {
        CardBox {
            HStack(spacing: 6) {
                Text(row.direction == .outgoing ? "You" : "Them").fontWeight(.semibold)
                Text("\(DirectionRow.code(row.source)) → \(DirectionRow.code(row.target))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                let style = row.state.chipStyle
                Text(DirectionCopy.chip(row.state, direction: row.direction, appName: row.appName))
                    .font(.caption).fontWeight(.medium).foregroundStyle(style.tint).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MenuBarItem: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).frame(width: 16).foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(hovering ? Theme.soft(Color.primary) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - MenuBarPopoverView

/// The popover hosted by `MenuBarController` (REQ-UI-60).
struct MenuBarPopoverView: View {
    @ObservedObject var session: CallSessionModel
    @ObservedObject var setup: MainSetupModel
    let viewModel: AudioViewModel
    let panel: StatusPanelController

    var body: some View {
        let languages = setup.languagePairManager
        let (source, target) = (languages.sourceLanguage, languages.targetLanguage)
        let appName = setup.selectedRow?.appName ?? String(localized: "No call app")
        let pair = "\(languages.displayName(for: source)) ↔ \(languages.displayName(for: target))"
        let translating = session.phase == .running
        let dot = MenuBarDot.derive(phase: session.phase, title: session.title)
        // Start and Stop are both off while the call app opens: there is no cancel path (T13 carry-over).
        let busy = session.phase == .launching || session.phase == .starting
        MenuBarPopoverContent(
            isTranslating: translating, dot: translating ? dot : .none,
            headline: translating ? session.title.text : (setup.readiness.blockingReason ?? String(localized: "Ready")),
            subtitle: "\(appName) · \(pair)", startedAt: session.sessionStartedAt,
            primaryTitle: setup.readiness.primary.title, primaryDisabled: busy,
            outgoing: translating ? row(.outgoing, from: source, to: target, appName: appName) : nil,
            incoming: translating ? row(.incoming, from: target, to: source, appName: appName) : nil,
            onPrimary: { MenuBarStart.start(setup: setup, viewModel: viewModel) },
            onStop: { Task { await session.stop() } },
            onShowPanel: { panel.show() },
            onOpenMain: { NSApp.showMainWindow() },
            onSettings: { SettingsOpener.shared.open(tab: .general) },
            onQuit: { NSApp.terminate(nil) })
    }

    private func row(_ direction: TranscriptDirection, from source: Locale.Language, to target: Locale.Language,
                     appName: String) -> DirectionRow {
        let isOutgoing = direction == .outgoing
        return DirectionRow(direction: direction, source: source, target: target,
                            state: isOutgoing ? session.outgoing : session.incoming, appName: appName)
    }
}

// MARK: - Previews

#if DEBUG
/// Fixture-driven states of the popover (previews never start a real session).
enum MenuBarPopoverFixture {
    static let spanish = Locale.Language(identifier: "es")
    static let german = Locale.Language(identifier: "de")

    static func idle(app: String = "Teams", pair: String = "Español ↔ Deutsch", headline: String = "Ready",
                     title: String = "Start translating", disabled: Bool = false) -> MenuBarPopoverContent {
        MenuBarPopoverContent(dot: .none, headline: headline, subtitle: "\(app) · \(pair)",
                              primaryTitle: title, primaryDisabled: disabled)
    }

    static func translating(app: String = "Teams", pair: String = "Español ↔ Deutsch",
                            source: Locale.Language = spanish, target: Locale.Language = german)
        -> MenuBarPopoverContent {
        MenuBarPopoverContent(
            isTranslating: true, dot: .green, headline: "Translating", subtitle: "\(app) · \(pair)",
            startedAt: Date(timeIntervalSinceNow: -724),
            outgoing: DirectionRow(direction: .outgoing, source: source, target: target, state: .speaking,
                                   appName: app),
            incoming: DirectionRow(direction: .incoming, source: target, target: source, state: .listening,
                                   appName: app))
    }
}

#Preview("Idle") { MenuBarPopoverFixture.idle() }
#Preview("Idle, dark") { MenuBarPopoverFixture.idle().preferredColorScheme(.dark) }
#Preview("Translating") { MenuBarPopoverFixture.translating() }
#Preview("Translating, dark") { MenuBarPopoverFixture.translating().preferredColorScheme(.dark) }
#Preview("Longest") {
    MenuBarPopoverFixture.translating(app: "Microsoft Teams (work or school)",
                                      pair: "Portuguese (Brazil) ↔ Deutsch",
                                      source: Locale.Language(identifier: "pt-BR"))
}
#endif
