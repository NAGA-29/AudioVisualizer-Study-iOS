import SwiftUI

/// スペクトラムを円環状に描く「リング」ビジュアル。
///
/// `SpectrumCanvas` が「左から右へ並ぶ棒グラフ」なのに対し、こちらは同じ対数バー値を
/// 円周へ写して外向きの棒として描く。値の作り方 (`SpectrumCanvas.logBars`) は共有し、
/// この型は **配置と発光の表現だけ** を持つ。
///
/// 設計上のポイント:
/// - 左右対称 (`isMirrored`): 低域を天頂、高域を真下に置き、右半分をそのまま左半分へ鏡像化する。
///   円周を一周ぶん使うより、対称のほうが「音の形」が図形として読み取りやすい。
/// - リングの内側半径をバー値で押し出す (`ringDeform`): 内周が真円ではなくなり、
///   鳴っている帯域の方向へ輪郭が膨らむ。
/// - 発光は「同じ絵をぼかして下に敷く」だけで作る。`.blur` フィルタを持つレイヤーを 1 枚重ねるので、
///   バー 1 本ごとに影を付けるより描画コストが読みやすい。
struct RadialSpectrumCanvas: View {
    var magnitudes: [Float]
    var sampleRate: Double
    /// バーの基準色。ここから周波数位置に応じて色相をずらす。
    var baseColor: HSBColor
    /// 鏡像展開する前のバー本数 (= 半周ぶん)。画面上には最大でこの 2 倍が並ぶ。
    var barCount: Int = 56
    /// 低域から高域までに色相を何周ぶん回すか。1.0 で色相環を一周する。
    var hueSpread: Double = 1.0
    /// 短辺の半分に対するリング内周の比率。
    var innerRadiusRatio: Double = 0.42
    /// 短辺の半分に対するバー最大長の比率。
    var barLengthRatio: Double = 0.3
    /// バー値で内周をどれだけ押し出すか。0 なら内周は真円。
    var ringDeform: Double = 0.35
    var isMirrored: Bool = true
    /// リング全体を膨らませる量 (0〜1)。低域エネルギーを渡して拍で脈打たせる。
    var pulse: Double = 0
    /// リング全体をどれだけ膨らませるかの上限比率。
    var pulseDepth: Double = 0.12
    /// 回転位相。1.0 で一周。
    var rotation: Double = 0
    /// 発光レイヤーのぼかし半径 (pt)。0 で発光なし。
    var glowRadius: Double = 12

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let source = SpectrumCanvas.logBars(
                magnitudes: magnitudes,
                sampleRate: sampleRate,
                barCount: barCount
            )
            guard source.count > 1 else { return }

            let bars = isMirrored ? Self.mirrored(source) : source
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let unit = min(size.width, size.height) / 2
            guard unit > 0 else { return }

            let baseRadius = unit * CGFloat(innerRadiusRatio) * CGFloat(1 + pulseDepth * clampUnit(pulse))
            let maxLength = unit * CGFloat(barLengthRatio)
            // 隣のバーと触れない太さ。本数が増えるほど自動的に細くなる。
            let slot = 2 * CGFloat.pi * baseRadius / CGFloat(bars.count)
            let lineWidth = max(1.5, slot * 0.55)

            if glowRadius > 0 {
                // 発光は同じ絵をぼかして下に敷くだけ。上に乗る本体が芯になり、周囲だけが滲む。
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: CGFloat(glowRadius)))
                    layer.opacity = 0.85
                    draw(bars, into: &layer, center: center, baseRadius: baseRadius, maxLength: maxLength, lineWidth: lineWidth)
                }
            }
            draw(bars, into: &context, center: center, baseRadius: baseRadius, maxLength: maxLength, lineWidth: lineWidth)
        }
    }

    private func draw(
        _ bars: [Float],
        into context: inout GraphicsContext,
        center: CGPoint,
        baseRadius: CGFloat,
        maxLength: CGFloat,
        lineWidth: CGFloat
    ) {
        for (index, value) in bars.enumerated() {
            let ends = Self.endpoints(
                center: center,
                index: index,
                count: bars.count,
                value: value,
                baseRadius: baseRadius,
                maxLength: maxLength,
                ringDeform: ringDeform,
                rotation: rotation
            )
            var path = Path()
            path.move(to: ends.start)
            path.addLine(to: ends.end)

            let position = Self.sourcePosition(index: index, count: bars.count, isMirrored: isMirrored)
            let color = Self.barColor(base: baseColor, position: position, value: value, hueSpread: hueSpread)
            context.stroke(
                path,
                with: .color(Color(color)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
        }
    }

    // MARK: - 配置 (純関数)

    /// 半周ぶんのバーを鏡像展開して一周ぶんにする。
    ///
    /// 先頭 (低域) が天頂、末尾 (高域) が真下に来るので、右回りで下りて左回りで戻る並びになる。
    static func mirrored(_ bars: [Float]) -> [Float] {
        guard !bars.isEmpty else { return [] }
        return bars + bars.reversed()
    }

    /// `index` 番目のバーが、鏡像展開前の並びのどこ (0〜1) に対応するか。色相の決定に使う。
    static func sourcePosition(index: Int, count: Int, isMirrored: Bool) -> Double {
        guard count > 1 else { return 0 }
        guard isMirrored else { return Double(index) / Double(count - 1) }

        let half = count / 2
        guard half > 1 else { return 0 }
        let sourceIndex = index < half ? index : max(0, count - 1 - index)
        return Double(sourceIndex) / Double(half - 1)
    }

    /// バー 1 本の始点 (内周側) と終点 (外周側)。
    ///
    /// 角度は天頂 0 から時計回り。画面座標は y 軸が下向きなので、方向ベクトルは (sin, -cos) になる。
    static func endpoints(
        center: CGPoint,
        index: Int,
        count: Int,
        value: Float,
        baseRadius: CGFloat,
        maxLength: CGFloat,
        ringDeform: Double = 0,
        rotation: Double = 0
    ) -> (start: CGPoint, end: CGPoint) {
        guard count > 0 else { return (center, center) }

        let turn = (Double(index) + 0.5) / Double(count) + rotation
        let angle = turn * 2 * .pi
        let direction = CGPoint(x: CGFloat(sin(angle)), y: CGFloat(-cos(angle)))

        let level = CGFloat(clampUnit(Double(value)))
        // 内周を値で押し出す → 鳴っている方向だけ輪郭が膨らむ。
        let start = baseRadius + level * maxLength * CGFloat(max(0, ringDeform))
        // 無音でも点として残す (完全に消えると輪郭が読めない)。
        let length = max(2, level * maxLength)

        return (
            start: CGPoint(x: center.x + direction.x * start, y: center.y + direction.y * start),
            end: CGPoint(x: center.x + direction.x * (start + length), y: center.y + direction.y * (start + length))
        )
    }

    /// バー 1 本の色。
    ///
    /// - 色相: 低域→高域で `hueSpread` のぶんだけ回す。1.0 なら一周して虹になる
    /// - 明度: 値で持ち上げる。鳴っていない帯域は黒背景へ沈む
    static func barColor(base: HSBColor, position: Double, value: Float, hueSpread: Double) -> HSBColor {
        let level = clampUnit(Double(value))
        let shifted = base.shiftingHue(by: hueSpread * clampUnit(position))
        return HSBColor(
            // 黒背景に置くので彩度は高めに固定する (背景と混ざらないため)。
            hue: shifted.hue,
            saturation: min(1, base.saturation * 0.3 + 0.7),
            brightness: min(1, 0.4 + 0.6 * level)
        )
    }
}

private func clampUnit(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
}

#Preview {
    RadialSpectrumCanvas(
        magnitudes: (0..<1024).map { index in
            0.4 / Float(index + 1) * 6 * (1 + sinf(Float(index) / 40))
        },
        sampleRate: 44_100,
        baseColor: HSBColor(hue: 0.35, saturation: 0.9, brightness: 1.0)
    )
    .frame(height: 420)
    .background(.black)
}
