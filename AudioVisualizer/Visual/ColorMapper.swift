import Foundation

/// `BandEnergy` を HSB へマッピングする。
///
/// - Hue        : low/mid/high の「比率」から決める (既定)。音量ではなく音色に反応する
/// - Saturation : overall に比例
/// - Brightness : low 帯 (ビート感) でパルス的に変化
///
/// ちらつき防止のため、Hue は 1 更新あたりの最大変化量を制限する。
struct ColorMapper {

    /// 色相を何から決めるか。
    enum HueSource: String, CaseIterable, Identifiable, Equatable {
        /// mid 帯のエネルギーをそのまま色相環に写す。
        ///
        /// 単一のスカラーなので、mid が実際に取る狭い範囲 (だいたい 0.3〜0.6) しか
        /// 色相環を使えず、結果として似た色ばかりになる。
        case midEnergy
        /// low/mid/high を色相環上の 3 点に置き、エネルギーを重みとした重心の向きを色相にする。
        ///
        /// ベースの効いた曲は低域アンカー寄り、シンバルが鳴れば高域アンカー寄りへ動く。
        /// 3 点が色相環を三等分しているので、重みの偏り方しだいで全色相に到達できる。
        case spectralBalance

        var id: String { rawValue }
        var label: String {
            switch self {
            case .midEnergy: return "中域のみ"
            case .spectralBalance: return "音色"
            }
        }
    }

    /// 各帯域を色相環上のどこに置くか。既定は三等分 (赤 / 緑 / 青)。
    struct BandHueAnchors: Equatable {
        var low: Double = 0.0
        var mid: Double = 1.0 / 3.0
        var high: Double = 2.0 / 3.0

        static let `default` = BandHueAnchors()
    }

    struct Configuration: Equatable {
        /// 色相の決め方。
        var hueSource: HueSource = .spectralBalance
        /// `.spectralBalance` で使う帯域アンカー。
        var bandHueAnchors = BandHueAnchors.default
        /// 重心ベクトルの長さがこれ未満なら色相を更新しない。
        ///
        /// 3 帯域が拮抗していると重心はほぼ原点に落ち、向きがノイズで暴れる。
        /// そのときは前回の色相を保つ。
        var minimumBalanceMagnitude: Double = 0.02
        /// 使う色相の範囲。`0...1` で色相環一周。
        var hueRange: ClosedRange<Double> = 0...1
        /// 1 更新あたりの Hue 最大変化量。小さいほど落ち着くが追従が遅れる。
        var maxHueChangePerUpdate: Double = 0.015
        var saturationRange: ClosedRange<Double> = 0.35...1.0
        var brightnessRange: ClosedRange<Double> = 0.10...1.0
        /// ビート検出フレームで brightness に上乗せする量。
        var beatBrightnessBoost: Double = 0.18

        static let `default` = Configuration()
    }

    var configuration: Configuration
    private(set) var current: HSBColor

    init(configuration: Configuration = .default, initial: HSBColor = .idle) {
        self.configuration = configuration
        self.current = initial
    }

    mutating func reset(to color: HSBColor = .idle) {
        current = color
    }

    @discardableResult
    mutating func map(_ energy: BandEnergy) -> HSBColor {
        let hueTarget = self.hueTarget(for: energy)
        let hue = Self.approach(
            current: current.hue,
            target: hueTarget,
            maxDelta: max(0, configuration.maxHueChangePerUpdate),
            wraps: configuration.hueRange == 0...1
        )

        let saturation = lerp(configuration.saturationRange, Double(clamp01(energy.overall)))

        var brightness = lerp(configuration.brightnessRange, Double(clamp01(energy.low)))
        if energy.isBeat {
            brightness = min(configuration.brightnessRange.upperBound, brightness + configuration.beatBrightnessBoost)
        }

        current = HSBColor(hue: hue, saturation: saturation, brightness: brightness)
        return current
    }

    /// 今回の目標色相。決められないときは現在値を返す (色相を動かさない)。
    private func hueTarget(for energy: BandEnergy) -> Double {
        switch configuration.hueSource {
        case .midEnergy:
            return lerp(configuration.hueRange, Double(clamp01(energy.mid)))

        case .spectralBalance:
            guard let balance = Self.spectralBalance(
                low: energy.low,
                mid: energy.mid,
                high: energy.high,
                anchors: configuration.bandHueAnchors
            ), balance.magnitude >= configuration.minimumBalanceMagnitude else {
                return current.hue
            }
            // 全色相を使う設定ならそのまま。範囲を絞っているならその中へ写す。
            return configuration.hueRange == 0...1
                ? balance.hue
                : lerp(configuration.hueRange, balance.hue)
        }
    }

    /// 帯域エネルギーを重みとした色相環上の重心を求める。
    ///
    /// 色相は角度なので単純な加重平均では 0/1 の境目で破綻する。
    /// 各アンカーを単位ベクトルに直して足し合わせ、その向きを色相に戻す。
    ///
    /// - Returns: 向き (0..<1) と長さ (0...1)。長さは「音色がどれだけ特定帯域に偏っているか」。
    ///            3 帯域が均等なら 0 に近づく。重みがすべて 0 のときは nil。
    static func spectralBalance(low: Float, mid: Float, high: Float, anchors: BandHueAnchors) -> (hue: Double, magnitude: Double)? {
        let weights = [
            (Double(clamp01(low)), anchors.low),
            (Double(clamp01(mid)), anchors.mid),
            (Double(clamp01(high)), anchors.high)
        ]
        let totalWeight = weights.reduce(0) { $0 + $1.0 }
        guard totalWeight > 0 else { return nil }

        var x = 0.0
        var y = 0.0
        for (weight, anchorHue) in weights {
            let angle = anchorHue * 2 * .pi
            x += weight * cos(angle)
            y += weight * sin(angle)
        }
        x /= totalWeight
        y /= totalWeight

        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > 0 else { return nil }

        var hue = atan2(y, x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        return (hue: hue, magnitude: min(magnitude, 1))
    }

    /// 色相環上を最短経路で `maxDelta` まで進める。
    /// `wraps` が false のときは単純に線形で寄せる (0/1 をまたがない範囲指定のとき)。
    static func approach(current: Double, target: Double, maxDelta: Double, wraps: Bool) -> Double {
        guard maxDelta > 0 else { return current }
        var delta = target - current
        if wraps {
            // -0.5...0.5 に畳んで最短方向を選ぶ。
            delta = delta - (delta + 0.5).rounded(.down)
        }
        let step = min(max(delta, -maxDelta), maxDelta)
        var next = current + step
        if wraps {
            next = next - next.rounded(.down)  // 0..<1 に正規化
        }
        return next
    }
}

private func clamp01(_ value: Float) -> Float {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
}

private func lerp(_ range: ClosedRange<Double>, _ t: Double) -> Double {
    let t = min(max(t, 0), 1)
    return range.lowerBound + (range.upperBound - range.lowerBound) * t
}
