import Foundation

/// 実機チューニング用のパラメータ一式。実験ノート (docs/EXPERIMENT_NOTES.md) の各観点に対応する。
struct VisualizerSettings: Equatable {

    enum DisplayMode: String, CaseIterable, Identifiable {
        case waveform
        case spectrum
        case both
        /// 円環状のスペクトラム (RadialSpectrumCanvas)。背景も暗転させて発光を見せる。
        case radial

        var id: String { rawValue }
        var label: String {
            switch self {
            case .waveform: return "波形"
            case .spectrum: return "スペクトラム"
            case .both: return "両方"
            case .radial: return "リング"
            }
        }

        /// 波形ラインを描くモードか。
        var showsWaveform: Bool { self == .waveform || self == .both }
        /// 横並びのバーを描くモードか。
        var showsLinearSpectrum: Bool { self == .spectrum || self == .both }
        /// 円環スペクトラムを描くモードか。
        var showsRadialSpectrum: Bool { self == .radial }
        /// 背景を暗くするモードか。発光表現は明るい背景だと沈む。
        var prefersDarkBackground: Bool { self == .radial }
    }

    /// リング表示のパラメータ。他モードには影響しないのでまとめて分けておく。
    struct RadialSettings: Equatable {
        /// 鏡像展開する前のバー本数 (半周ぶん)。画面上はこの 2 倍が並ぶ。
        var barCount: Int = 56
        static let availableBarCounts = [32, 56, 80]

        /// 短辺の半分に対するリング内周の比率。
        var innerRadiusRatio: Double = 0.42
        /// 短辺の半分に対するバー最大長の比率。
        var barLengthRatio: Double = 0.3
        /// 低域から高域までに色相を何周ぶん回すか。1.0 で虹一周。
        var hueSpread: Double = 1.0
        /// 左右対称に展開するか。false なら円周一周を低域→高域で使う。
        var isMirrored: Bool = true
        /// 1 秒あたりの回転量 (1.0 で毎秒一周)。0 で静止。
        var rotationSpeed: Double = 0.01
        /// 発光のぼかし半径 (pt)。0 で発光なし。
        var glowRadius: Double = 12
        /// 低域エネルギーでリング全体を膨らませる最大比率。
        var pulseDepth: Double = 0.12

        static let `default` = RadialSettings()
    }

    /// 検証観点 1: 1024 / 2048 / 4096 でレスポンス感を比較する。
    var fftSize: Int = 2048
    static let availableFFTSizes = [1024, 2048, 4096]

    /// installTap のバッファサイズ。FFT 長とは独立に指定できる。
    var tapBufferSize: UInt32 = 1024
    static let availableTapBufferSizes: [UInt32] = [1024, 2048, 4096]

    /// 検証観点 2: EMA 係数。大きいほど滑らか (鈍い)。
    var smoothing: Float = 0.7

    /// dB → 0〜1 のマッピング範囲。環境ノイズが多い場所では floor を上げる。
    var floorDb: Float = -72
    var ceilingDb: Float = -12

    /// Hue の 1 更新あたり最大変化量 (ちらつき抑制)。
    var maxHueChangePerUpdate: Double = 0.015

    /// 色相を何から決めるか。`.spectralBalance` は音量ではなく音色 (帯域比) に反応する。
    var hueSource: ColorMapper.HueSource = .spectralBalance

    /// 波形/スペクトラムを左端から右端へ何色相ぶん散らすか。0 で単色に戻る。
    var hueSpread: Double = 0.5

    /// 波形表示の自動ゲイン。離れた音源でも波形が振れるように、直近のピークで正規化する。
    var isWaveformAutoGainEnabled: Bool = true

    /// 自動ゲインを切ったときの固定倍率。
    var waveformManualGain: Float = 8

    var isBeatDetectionEnabled: Bool = true

    var displayMode: DisplayMode = .spectrum

    var radial = RadialSettings.default

    /// 帯域メーター等のデバッグ表示。
    var showsDiagnostics: Bool = true

    static let `default` = VisualizerSettings()
}
