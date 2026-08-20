import SwiftUI

/// 生波形をラインで描く。FFT を通す前の疎通確認 (実装順序 2) がそのまま表示モードとして残っている。
struct WaveformCanvas: View {
    var samples: [Float]
    /// 線の基準色。左端から右端へ色相をずらしたグラデーションで描く。
    var baseColor: HSBColor
    var lineWidth: CGFloat = 2
    /// 左端から右端までの色相のずれ幅。0 なら単色。
    var hueSpread: Double = 0.3

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard samples.count > 1 else { return }

            let midY = size.height / 2
            let stepX = size.width / CGFloat(samples.count - 1)
            var path = Path()

            for (index, sample) in samples.enumerated() {
                let x = CGFloat(index) * stepX
                // 見やすさ優先で少し持ち上げる (0.9 は描画上のマージン)。
                let y = midY - CGFloat(max(-1, min(1, sample))) * midY * 0.9
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: Self.gradientColors(base: baseColor, hueSpread: hueSpread)),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// グラデーションの色停止点。色相を等間隔にずらしただけの単純な並び。
    static func gradientColors(base: HSBColor, hueSpread: Double, stops: Int = 5) -> [Color] {
        guard stops > 1 else { return [Color(base)] }
        return (0..<stops).map { index in
            let position = Double(index) / Double(stops - 1)
            return Color(base.shiftingHue(by: hueSpread * position))
        }
    }
}

#Preview {
    WaveformCanvas(
        samples: (0..<256).map { sinf(Float($0) / 256 * 8 * .pi) * 0.7 },
        baseColor: HSBColor(hue: 0.5, saturation: 0.8, brightness: 1.0)
    )
        .frame(height: 200)
        .background(.black)
}
