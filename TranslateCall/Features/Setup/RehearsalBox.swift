import SwiftUI

/// The test card of step 4: the live level, then "You said" / "<App> receives" and the rehearsal's
/// state (REQ-FR-50…55). Pure inputs, so it renders from fixtures.
struct RehearsalBox: View {
    let state: RehearsalState
    let micState: CheckState
    let levels: [Float]
    let appName: String
    let myLanguage: String
    /// The route test runs: both use BlackHole, so the rehearsal waits.
    let routeBusy: Bool
    let onRehearse: () -> Void
    let onPlay: () -> Void

    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 10) {
                header
                Divider()
                transcript
                actions
            }
            .padding(14)
        }
        .accessibilityElement(children: .contain)
    }

    private var lines: [String] {
        TestStepPresentation.rehearsalLines(state, appName: appName, myLanguage: myLanguage)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(headerColor).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(headerText).font(.system(size: 12, weight: .semibold)).foregroundStyle(headerColor)
                .lineLimit(1)
            Spacer(minLength: 8)
            LevelMeterView(levels: levels, color: headerColor)
        }
    }

    private var headerText: String {
        switch state {
        case .preparing: return lines[0]
        case .listening: return lines[0]
        case .translating: return String(localized: "Translating…")
        case .passed: return String(localized: "Heard and translated")
        default: return TestStepPresentation.micLine(micState)
        }
    }

    private var headerColor: Color {
        switch state {
        case .preparing: return .secondary
        case .listening, .translating, .passed: return Theme.Status.green
        default:
            if case .failed = micState { return Theme.Status.orange }
            return micState == .passed ? Theme.Status.green : .secondary
        }
    }

    @ViewBuilder
    private var transcript: some View {
        switch state {
        case .translating(let said):
            fields(said, received: nil)
        case .passed(let said, let received):
            fields(said, received: received)
        case .unavailable(let reason):
            note(reason, color: .secondary)
        case .failed(let failure):
            note(failure.message, color: Theme.Status.orange)
        default:
            fields(nil, received: nil)
        }
    }

    private func fields(_ said: String?, received: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            field("You said", value: said.map { "«\($0)»" })
            Divider()
            field("\(appName) receives", value: received, accent: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(lines.isEmpty ? String(localized: "Nothing yet") : lines.joined(separator: ". ")))
    }

    private func field(_ title: LocalizedStringKey, value: String?, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.tertiary)
            Text(value ?? "…")
                .font(.system(size: 15, weight: accent ? .semibold : .regular))
                .foregroundStyle(value == nil ? AnyShapeStyle(.quaternary) : accent
                                 ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                .lineLimit(2)
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .ready, .needsConsent:
            Button("Test translation", action: onRehearse).disabled(routeBusy || state == .needsConsent)
        case .passed:
            HStack {
                Button("Play", systemImage: "play.fill", action: onPlay)
                Button("Try again", action: onRehearse).disabled(routeBusy)
            }
        case .failed:
            Button("Try again", action: onRehearse).disabled(routeBusy)
        default:
            EmptyView()
        }
    }
}
