import SwiftUI

private struct ComponentGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.small) {
                Chip("Speaking", systemImage: "waveform", tint: Theme.Status.info)
                Chip("Listening", systemImage: "mic.fill", tint: Theme.Status.green)
                Chip("Mic paused", systemImage: "mic.slash.fill", tint: .gray)
                Chip("Can't hear Teams", systemImage: "exclamationmark.triangle.fill", tint: Theme.Status.orange)
            }

            SectionHeader("Session")

            CardBox {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Text("Active conversation")
                        .font(.headline)
                    Text("Translations appear here in real time.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.Spacing.medium)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 420)
    }
}

#Preview("Components") {
    Group {
        ComponentGallery()
            .preferredColorScheme(.light)
        ComponentGallery()
            .preferredColorScheme(.dark)
    }
    .padding()
}
