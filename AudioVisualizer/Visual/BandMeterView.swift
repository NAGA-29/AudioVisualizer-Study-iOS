import SwiftUI

/// low / mid / high / overall の正規化値をそのまま出すデバッグ用メーター。
/// チューニング時に「色がおかしいのか値がおかしいのか」を切り分けるために置いている。
struct BandMeterView: View {
    var energy: BandEnergy

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("LOW", energy.low, .red)
            row("MID", energy.mid, .green)
            row("HIGH", energy.high, .blue)
            row("ALL", energy.overall, .white)
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white)
    }

    private func row(_ label: String, _ value: Float, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 34, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.2f", value)).frame(width: 38, alignment: .trailing)
        }
    }
}

#Preview {
    BandMeterView(energy: BandEnergy(low: 0.8, mid: 0.4, high: 0.2, overall: 0.6, isBeat: true))
        .padding()
        .background(.black)
}
