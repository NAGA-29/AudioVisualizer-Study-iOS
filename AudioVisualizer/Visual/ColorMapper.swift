import Foundation

/// `BandEnergy` を HSB へマッピングする。
///
/// 初期実装の叩き台 (後で調整前提):
/// - Hue        : mid 帯のエネルギーで色相環を回す
/// - Saturation : overall に比例
/// - Brightness : low 帯 (ビート感) でパルス的に変化
///
/// ちらつき防止のため、Hue は 1 更新あたりの最大変化量を制限する。
struct ColorMapper {

    struct Configuration: Equatable {
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
        let hueTarget = lerp(configuration.hueRange, Double(clamp01(energy.mid)))
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
