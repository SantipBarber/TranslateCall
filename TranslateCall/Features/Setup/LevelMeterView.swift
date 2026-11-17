import SwiftUI

/// The microphone level bars of step 4 (REQ-FR-40): the latest peak levels in dBFS, oldest first.
/// Unfilled slots show as faded minimum bars. VoiceOver reads one summary, not the bars.
struct LevelMeterView: View {
    static let barCount = 22
    static let floorDBFS: Float = -60

    let levels: [Float]
    var color: Color = Theme.Status.green

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                let level = index < shown.count ? shown[index] : nil
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color.opacity(level == nil ? 0.25 : 1))
                    .frame(width: 5, height: Self.height(for: level))
            }
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Microphone level"))
        .accessibilityValue(Text(Self.spoken(levels.last)))
    }

    private var shown: [Float] { Array(levels.suffix(Self.barCount)) }

    /// 3…18 pt from −60 dBFS up to 0.
    static func height(for level: Float?) -> CGFloat {
        guard let level else { return 3 }
        let clamped = min(max(level, floorDBFS), 0)
        return 3 + CGFloat((clamped - floorDBFS) / -floorDBFS) * 15
    }

    static func spoken(_ level: Float?) -> String {
        guard let level, level > -40 else { return String(localized: "Silent") }
        return level > -20 ? String(localized: "Loud") : String(localized: "Speaking")
    }
}
