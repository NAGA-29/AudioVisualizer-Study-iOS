import Foundation

/// 実機チューニング用のパラメータ一式。実験ノート (docs/EXPERIMENT_NOTES.md) の各観点に対応する。
struct VisualizerSettings: Equatable {

    enum DisplayMode: String, CaseIterable, Identifiable {
        case waveform
        case spectrum
        case both

        var id: String { rawValue }
        var label: String {
            switch self {
            case .waveform: return "波形"
            case .spectrum: return "スペクトラム"
            case .both: return "両方"
            }
        }
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

    /// 帯域メーター等のデバッグ表示。
    var showsDiagnostics: Bool = true

    static let `default` = VisualizerSettings()
}
