import SwiftUI

/// 生波形をラインで描く。FFT を通す前の疎通確認 (実装順序 2) がそのまま表示モードとして残っている。
struct WaveformCanvas: View {
    var samples: [Float]
    var color: Color
    var lineWidth: CGFloat = 2

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

            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

#Preview {
    WaveformCanvas(samples: (0..<256).map { sinf(Float($0) / 256 * 8 * .pi) * 0.7 }, color: .white)
        .frame(height: 200)
        .background(.black)
}
