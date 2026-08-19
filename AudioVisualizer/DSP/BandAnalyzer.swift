import Foundation

/// magnitude スペクトルを低域/中域/高域に畳み込み、0.0〜1.0 に正規化 + EMA 平滑化する。
///
/// スレッド安全ではない。解析キュー上からのみ触ること。
final class BandAnalyzer {

    /// 正規化のかけ方。
    enum Scaling: Equatable {
        /// linear magnitude をそのままゲイン倍してクランプ。素直だが小音量で見た目が死にやすい。
        case linear(gain: Float)
        /// dBFS に変換して [floor, ceiling] を 0〜1 にマップ。聴感に近く、既定はこちら。
        case decibel(floor: Float, ceiling: Float)
    }

    struct BeatDetection: Equatable {
        var isEnabled = true
        /// 低域のベースライン (長い EMA) に対して何倍を超えたら「アタック」とみなすか。
        var threshold: Float = 1.4
        /// 無音時のノイズで拍が出続けないための下限。
        var minimumEnergy: Float = 0.12
        /// ベースライン側の EMA 係数 (大きいほど鈍い)。
        var baselineSmoothing: Float = 0.9
    }

    /// 帯域ごとのゲイン補正 (dB)。
    ///
    /// 平均 magnitude はビン数で割るため、帯域幅の広い high はどうしても値が小さく出る
    /// (low は 230Hz 幅 ≒ 12 ビン、high は 16kHz 幅 ≒ 745 ビン)。
    /// さらに音楽信号は高域ほどエネルギーが小さいので、既定で high を持ち上げておく。
    /// 実機で「高域が反応しない / しすぎる」と感じたら最初に触る値。
    struct BandGain: Equatable {
        var lowDb: Float = 0
        var midDb: Float = 4
        var highDb: Float = 10
    }

    struct Configuration: Equatable {
        // サンプルレート 44.1kHz を想定した目安。実機で要調整。
        var lowRange: ClosedRange<Float> = 20...250
        var midRange: ClosedRange<Float> = 250...4_000
        var highRange: ClosedRange<Float> = 4_000...20_000

        var scaling: Scaling = .decibel(floor: -72, ceiling: -12)

        var gain = BandGain()

        /// EMA 係数。`smoothed = prev * smoothing + current * (1 - smoothing)`。
        /// 0.7 付近から始めて実機で調整する (大きいほど滑らかで鈍い)。
        var smoothing: Float = 0.7

        var beat = BeatDetection()

        static let `default` = Configuration()
    }

    private(set) var configuration: Configuration
    private var smoothed = BandEnergy.silent
    private var lowBaseline: Float = 0
    private var hasSmoothedValue = false

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    func reset() {
        smoothed = .silent
        lowBaseline = 0
        hasSmoothedValue = false
    }

    /// magnitude 配列 (FFTProcessor の出力) を帯域エネルギーに変換する。
    func analyze(magnitudes: [Float], sampleRate: Double) -> BandEnergy {
        guard !magnitudes.isEmpty, sampleRate > 0 else { return smoothed }

        // FFT 長 = binCount * 2。ビン幅 = sampleRate / fftSize。
        let binWidth = Float(sampleRate) / Float(magnitudes.count * 2)
        let nyquist = Float(sampleRate) / 2

        let rawLow = normalized(meanMagnitude(magnitudes, in: configuration.lowRange, binWidth: binWidth, nyquist: nyquist), gainDb: configuration.gain.lowDb)
        let rawMid = normalized(meanMagnitude(magnitudes, in: configuration.midRange, binWidth: binWidth, nyquist: nyquist), gainDb: configuration.gain.midDb)
        let rawHigh = normalized(meanMagnitude(magnitudes, in: configuration.highRange, binWidth: binWidth, nyquist: nyquist), gainDb: configuration.gain.highDb)
        let overallRange = configuration.lowRange.lowerBound...configuration.highRange.upperBound
        let rawOverall = normalized(meanMagnitude(magnitudes, in: overallRange, binWidth: binWidth, nyquist: nyquist), gainDb: 0)

        let isBeat = detectBeat(rawLow: rawLow)

        // --- EMA 平滑化 ---
        let a = min(max(configuration.smoothing, 0), 0.99)
        if hasSmoothedValue {
            smoothed = BandEnergy(
                low: smoothed.low * a + rawLow * (1 - a),
                mid: smoothed.mid * a + rawMid * (1 - a),
                high: smoothed.high * a + rawHigh * (1 - a),
                overall: smoothed.overall * a + rawOverall * (1 - a),
                isBeat: isBeat
            )
        } else {
            // 初回は前値が無いので生値をそのまま採用する (0 からの立ち上がりを待たせない)。
            smoothed = BandEnergy(low: rawLow, mid: rawMid, high: rawHigh, overall: rawOverall, isBeat: isBeat)
            hasSmoothedValue = true
        }
        return smoothed
    }

    // MARK: - Private

    /// 指定周波数レンジに含まれるビンの平均 magnitude。
    private func meanMagnitude(_ magnitudes: [Float], in range: ClosedRange<Float>, binWidth: Float, nyquist: Float) -> Float {
        guard binWidth > 0 else { return 0 }
        let upperHz = min(range.upperBound, nyquist)
        guard range.lowerBound < upperHz else { return 0 }

        // bin 0 は DC なので必ず除外する (マイクの DC オフセットで低域が張り付くのを防ぐ)。
        let lowerBin = max(1, Int((range.lowerBound / binWidth).rounded(.down)))
        let upperBin = min(magnitudes.count - 1, Int((upperHz / binWidth).rounded(.up)))
        guard lowerBin <= upperBin else { return 0 }

        var sum: Float = 0
        for i in lowerBin...upperBin { sum += magnitudes[i] }
        return sum / Float(upperBin - lowerBin + 1)
    }

    private func normalized(_ magnitude: Float, gainDb: Float) -> Float {
        switch configuration.scaling {
        case let .linear(gain):
            return clamp01(magnitude * gain * pow(10, gainDb / 20))
        case let .decibel(floor, ceiling):
            guard ceiling > floor else { return 0 }
            let db = 20 * log10(max(magnitude, 1e-9)) + gainDb
            return clamp01((db - floor) / (ceiling - floor))
        }
    }

    private func detectBeat(rawLow: Float) -> Bool {
        guard configuration.beat.isEnabled else {
            lowBaseline = 0
            return false
        }
        let b = min(max(configuration.beat.baselineSmoothing, 0), 0.99)
        let isBeat = rawLow > configuration.beat.minimumEnergy
            && rawLow > lowBaseline * configuration.beat.threshold
        // ベースラインは平滑化前の値で更新する (平滑後だとアタックが埋もれる)。
        lowBaseline = lowBaseline * b + rawLow * (1 - b)
        return isBeat
    }

    private func clamp01(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
