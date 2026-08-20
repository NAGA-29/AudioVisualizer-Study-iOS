import SwiftUI

/// magnitude スペクトルをバーグラフで描く。
///
/// 人間の聴覚に合わせて対数周波数軸でビンをまとめる (線形のままだと低域が左端に潰れる)。
struct SpectrumCanvas: View {
    var magnitudes: [Float]
    var sampleRate: Double
    /// バー全体の基準色。ここから周波数に応じて色相をずらしていく。
    var baseColor: HSBColor
    var barCount: Int = 48
    /// 左端から右端までに色相を何周ぶんずらすか。0 なら従来どおりの単色。
    var hueSpread: Double = 0.5

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let bars = Self.logBars(magnitudes: magnitudes, sampleRate: sampleRate, barCount: barCount)
            guard !bars.isEmpty else { return }

            let slotWidth = size.width / CGFloat(bars.count)
            let barWidth = max(1, slotWidth * 0.72)
            let radius = min(barWidth / 2, 4)

            for (index, value) in bars.enumerated() {
                let height = max(2, CGFloat(value) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * slotWidth + (slotWidth - barWidth) / 2,
                    y: size.height - height,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: radius),
                    with: .color(Color(Self.barColor(base: baseColor, index: index, barCount: bars.count, value: value, hueSpread: hueSpread)))
                )
            }
        }
    }

    /// バー 1 本の色。
    ///
    /// - 色相: 低域から高域へ向かって `hueSpread` のぶんだけ回す。これで 1 画面に複数の色相が並ぶ
    /// - 明度: そのバーの値で持ち上げる。小さいバーが背景に沈み、鳴っている帯域だけが光る
    static func barColor(base: HSBColor, index: Int, barCount: Int, value: Float, hueSpread: Double) -> HSBColor {
        let position = barCount > 1 ? Double(index) / Double(barCount - 1) : 0
        let level = Double(min(max(value, 0), 1))
        return base
            .shiftingHue(by: hueSpread * position)
            .adjusted(
                saturation: 0.75 + 0.25 * level,
                brightness: 0.55 + 0.45 * level
            )
    }

    /// 対数周波数軸で magnitude をまとめ、dB スケールで 0〜1 に落とす。
    /// 表示専用の正規化なので `BandAnalyzer` とは独立 (あちらは色に使う値)。
    static func logBars(
        magnitudes: [Float],
        sampleRate: Double,
        barCount: Int,
        minFrequency: Double = 40,
        maxFrequency: Double = 18_000,
        floorDb: Float = -78,
        ceilingDb: Float = -12
    ) -> [Float] {
        guard barCount > 0, magnitudes.count > 1, sampleRate > 0 else { return [] }

        let binWidth = sampleRate / Double(magnitudes.count * 2)
        let upperFrequency = min(maxFrequency, sampleRate / 2)
        guard upperFrequency > minFrequency, binWidth > 0 else { return [] }

        let logMin = log10(minFrequency)
        let logMax = log10(upperFrequency)
        var bars = [Float](repeating: 0, count: barCount)

        for i in 0..<barCount {
            let fromHz = pow(10, logMin + (logMax - logMin) * Double(i) / Double(barCount))
            let toHz = pow(10, logMin + (logMax - logMin) * Double(i + 1) / Double(barCount))
            let lowerBin = max(1, Int(fromHz / binWidth))
            let upperBin = min(magnitudes.count - 1, max(lowerBin, Int(toHz / binWidth)))

            var peak: Float = 0
            for bin in lowerBin...upperBin { peak = max(peak, magnitudes[bin]) }

            let db = 20 * log10(max(peak, 1e-9))
            bars[i] = min(max((db - floorDb) / (ceilingDb - floorDb), 0), 1)
        }
        return bars
    }
}

#Preview {
    SpectrumCanvas(
        magnitudes: (0..<1024).map { 0.02 / Float($0 + 1) * 20 },
        sampleRate: 44_100,
        baseColor: HSBColor(hue: 0.55, saturation: 0.9, brightness: 1.0)
    )
    .frame(height: 220)
    .background(.black)
}
