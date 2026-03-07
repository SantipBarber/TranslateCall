import SwiftUI

struct LevelMeterView: View {
    var level: Float        // dBFS, expected -160..0
    var isActive: Bool

    private let minDB: Float = -60
    private let warnDB: Float = -12
    private let clipDB: Float = -3

    private var fraction: Double {
        guard isActive else { return 0 }
        let clamped = max(minDB, min(0, level))
        return Double((clamped - minDB) / (0 - minDB))
    }

    private var meterColor: Color {
        if level >= clipDB { return .red }
        if level >= warnDB { return .yellow }
        return .green
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)

                RoundedRectangle(cornerRadius: 3)
                    .fill(meterColor)
                    .frame(width: geo.size.width * fraction)
                    .animation(.linear(duration: 0.05), value: fraction)
            }
        }
        .frame(height: 8)
    }
}

#Preview("Active — normal") {
    LevelMeterView(level: -18, isActive: true)
        .padding()
        .frame(width: 300)
}

#Preview("Active — loud") {
    LevelMeterView(level: -6, isActive: true)
        .padding()
        .frame(width: 300)
}

#Preview("Idle") {
    LevelMeterView(level: -160, isActive: false)
        .padding()
        .frame(width: 300)
}
