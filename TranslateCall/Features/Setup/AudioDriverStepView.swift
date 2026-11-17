import SwiftUI

/// Step 2: install BlackHole 2ch (REQ-FR-20, 21).
struct AudioDriverStepView: View {
    static let downloadURL = URL(string: "https://existential.audio/blackhole/")!

    let isPresent: Bool
    let hasOtherBlackHole: Bool
    let onDownload: () -> Void
    let onCheckAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SetupStepHeader(
                title: String(localized: "Install the audio cable"),
                subtitle: String(localized: """
                    TranslateCall uses BlackHole, a free virtual audio cable, to send your translated voice \
                    into the call app. You install it once.
                    """))
            CardBox { flow.padding(.vertical, 14).padding(.horizontal, 12) }
            detection
            HStack(spacing: 8) {
                Button("Download BlackHole 2ch", action: onDownload).buttonStyle(.borderedProminent)
                Button("Check again", action: onCheckAgain)
            }
        }
    }

    private var flow: some View {
        HStack(alignment: .top, spacing: 0) {
            node("mic.fill", String(localized: "Your voice"))
            arrow
            node("translate", String(localized: "TranslateCall"))
            arrow
            node("cable.connector", String(localized: "BlackHole"), highlighted: true)
            arrow
            node("video.fill", String(localized: "Call app"))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your voice, TranslateCall, BlackHole, call app")
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
            .frame(width: 20, height: 36)
    }

    private func node(_ symbol: String, _ title: String, highlighted: Bool = false) -> some View {
        let tint = highlighted ? Theme.Status.orange : Theme.accent
        return VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Theme.soft(tint), in: Circle())
                .overlay(Circle().stroke(highlighted ? tint : Color.clear, lineWidth: 1.5))
            Text(title).font(.system(size: 11, weight: highlighted ? .semibold : .regular))
                .foregroundStyle(highlighted ? tint : .secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var detection: some View {
        let tint = isPresent ? Theme.Status.green : Theme.Status.orange
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isPresent ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft(tint), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .stroke(tint.opacity(0.4), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if isPresent { return String(localized: "BlackHole 2ch is installed") }
        if hasOtherBlackHole {
            return String(localized: "BlackHole 2ch not found — TranslateCall needs the 2-channel version")
        }
        return String(localized: "BlackHole 2ch not found")
    }

    private var detail: String? {
        isPresent ? nil
            : String(localized: """
                Download the installer, run it, then come back. \
                TranslateCall checks again automatically.
                """)
    }
}
