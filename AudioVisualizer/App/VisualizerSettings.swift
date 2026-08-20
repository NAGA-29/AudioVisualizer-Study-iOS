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

    var isBeatDetectionEnabled: Bool = true

    var displayMode: DisplayMode = .spectrum

    /// 帯域メーター等のデバッグ表示。
    var showsDiagnostics: Bool = true

    static let `default` = VisualizerSettings()
}
