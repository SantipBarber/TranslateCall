import SwiftUI

struct Chip: View {
    private let text: String
    private let systemImage: String
    private let tint: Color

    init(_ text: String, systemImage: String, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(text)
                .font(.caption)
                .lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
                .font(.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 4)
        .background(Theme.soft(tint))
        .clipShape(Capsule())
    }
}
