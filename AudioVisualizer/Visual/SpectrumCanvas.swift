import SwiftUI

/// magnitude スペクトルをバーグラフで描く。
///
/// 人間の聴覚に合わせて対数周波数軸でビンをまとめる (線形のままだと低域が左端に潰れる)。
struct SpectrumCanvas: View {
    var magnitudes: [Float]
    var sampleRate: Double
    var color: Color
    var barCount: Int = 48

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
                context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
            }
        }
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
        color: .white
    )
    .frame(height: 220)
    .background(.black)
}
