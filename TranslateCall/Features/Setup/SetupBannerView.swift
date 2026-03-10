import SwiftUI

struct SetupBannerView: View {
    let onSetupTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("BlackHole not detected")
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Button("Setup…", action: onSetupTap)
                .buttonStyle(.borderless)
                .font(.subheadline)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Preview

#Preview {
    SetupBannerView { }
        .padding()
        .frame(width: 430)
}
