import SwiftUI

/// low / mid / high / overall の正規化値をそのまま出すデバッグ用メーター。
/// チューニング時に「色がおかしいのか値がおかしいのか」を切り分けるために置いている。
struct BandMeterView: View {
    var energy: BandEnergy
    /// FFT / 正規化を通す前の生入力ピーク。マイクが音を拾えているかの一次判定に使う。
    var inputPeak: Float = 0
    var inputPeakDb: Float = -120
    /// 波形に適用中の表示ゲイン倍率。
    var waveformGain: Float = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("LOW", energy.low, .red)
            row("MID", energy.mid, .green)
            row("HIGH", energy.high, .blue)
            row("ALL", energy.overall, .white)
            Divider().overlay(.white.opacity(0.25))
            rawRow
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white)
    }

    /// 生入力レベル。ここが 0 のままならマイクから音が来ていない (セッション/権限側の問題)。
    /// ここが動いているのに LOW〜ALL が 0 なら、正規化の floor が高すぎる (チューニングの問題)。
    private var rawRow: some View {
        HStack(spacing: 8) {
            Text("RAW").frame(width: 34, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(.orange.opacity(0.85))
                        // 生ピークは小さい値に張り付きやすいので、目視用に平方根で持ち上げる。
                        .frame(width: proxy.size.width * CGFloat(min(max(sqrt(inputPeak), 0), 1)))
                }
            }
            .frame(height: 6)
            Text(rawLabel)
                .frame(width: 86, alignment: .trailing)
        }
    }

    /// 「生入力レベル (dBFS) と、波形に掛かっている倍率」。
    private var rawLabel: String {
        guard inputPeak > 0 else { return "--" }
        let level = String(format: "%.0fdB", inputPeakDb)
        return waveformGain > 1.05 ? "\(level) ×\(String(format: "%.0f", waveformGain))" : level
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
    BandMeterView(
        energy: BandEnergy(low: 0.8, mid: 0.4, high: 0.2, overall: 0.6, isBeat: true),
        inputPeak: 0.35,
        inputPeakDb: -9,
        waveformGain: 12
    )
        .padding()
        .background(.black)
}
