import SwiftUI

// MARK: - Chip style

extension DirectionState {
    /// The chip's icon and tint (REQ-UI-42, design §7.2).
    var chipStyle: (systemImage: String, tint: Color) {
        switch self {
        case .speaking: ("speaker.wave.2", Theme.Status.info)
        case .listening: ("ear", Theme.Status.green)
        case .hearing: ("waveform", Theme.Status.green)
        case .translating: ("ellipsis", Theme.Status.info)
        case .paused: ("pause", Color.secondary)
        case .micPaused: ("mic.slash", Color.secondary)
        case .unavailable: ("speaker.slash", Theme.Status.orange)
        }
    }
}

// MARK: - Quotes

/// Wraps a sentence in the quotation marks of its language, as in the frame («» Spanish, „“ German).
nonisolated enum PanelQuote {
    static func wrap(_ text: String, languageCode: String?) -> String {
        let (open, close): (String, String) = switch languageCode {
        case "de", "cs", "sk", "sl": ("„", "“")
        case "es", "fr", "it", "pt", "ca", "ru", "uk", "el": ("«", "»")
        default: ("“", "”")
        }
        return open + text + close
    }
}

// MARK: - DirectionRow

/// One direction of the panel: who, the language route, the latency, the state chip and the last
/// sentence (REQ-UI-42/43). Pure: `StatusPanelView` fills it from the session.
struct DirectionRow: View {
    let direction: TranscriptDirection
    let source: Locale.Language
    let target: Locale.Language
    let state: DirectionState
    /// "0.9 s", only when the latency provider can provide and the setting is on.
    var latency: String?
    /// The last sentence, already quoted.
    var quote: String?
    /// The line under the quote (the "Them" row only).
    var line: String?
    var showsChip = true
    var showsRetry = false
    let appName: String
    var onRetry: () -> Void = {}
    var onChooseApp: () -> Void = {}

    private var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 4) {
                header
                if let quote {
                    Text(quote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line {
                    Text(line)
                        .font(isUnavailable ? .body : .callout)
                        .foregroundStyle(isUnavailable ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isUnavailable { actions }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isUnavailable ? Theme.soft(Theme.Status.orange) : Color.clear)
        }
        .overlay {
            if isUnavailable {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .stroke(Theme.Status.orange, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DirectionCopy.accessibilityLabel(
            direction: direction, from: Self.name(of: source), to: Self.name(of: target),
            state: DirectionCopy.chip(state, direction: direction, appName: appName)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(direction == .outgoing ? "You" : "Them").fontWeight(.semibold)
            Text("\(Self.code(source)) → \(Self.code(target))").foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let latency {
                Text(latency).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
            if showsChip {
                let style = state.chipStyle
                Chip(DirectionCopy.chip(state, direction: direction, appName: appName),
                     systemImage: style.systemImage, tint: style.tint)
            }
        }
        .lineLimit(1)
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.medium) {
            if showsRetry {
                Button("Retry", action: onRetry)
                    .help("Try to hear \(appName) again")
            }
            Button("Choose another app…", action: onChooseApp)
                .help("Open the setup window to pick the call app")
        }
        .buttonStyle(.plain)
        .fontWeight(.medium)
        .foregroundStyle(Theme.accent)
        .padding(.top, 2)
    }

    static func code(_ language: Locale.Language) -> String {
        (language.languageCode?.identifier ?? language.minimalIdentifier).uppercased()
    }

    static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forLanguageCode: language.minimalIdentifier) ?? code(language)
    }
}
