import AVFoundation
import Combine

/// 音声入力の抽象化。
///
/// 現状の実装はマイク入力 (`MicInputSource`) だが、将来的に自前音源を直接タップする
/// `PlayerTapInputSource` へ差し替えられるよう、パイプラインの上流はこのプロトコルのみに依存する。
/// 下流 (FFT / 解析 / 描画) は `AVAudioPCMBuffer` しか知らないため、入力の出自が変わっても無改修で通る。
protocol AudioInputSource: AnyObject {
    /// タップで取得した PCM バッファを流す。オーディオスレッド上から送出される点に注意
    /// (購読側で `receive(on:)` を挟むこと)。
    var bufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> { get }

    /// 現在キャプチャ中かどうか。割り込み復帰の判断に使う。
    var isRunning: Bool { get }

    func start() throws
    func stop()
}

enum AudioInputError: LocalizedError {
    case microphonePermissionDenied
    case invalidInputFormat(sampleRate: Double, channels: AVAudioChannelCount)
    case engineStartFailed(underlying: Error)
    case sessionConfigurationFailed(underlying: Error)
    case fileNotFound(URL)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "マイクの使用が許可されていません。設定アプリから許可してください。"
        case let .invalidInputFormat(sampleRate, channels):
            return "入力フォーマットが不正です (sampleRate: \(sampleRate), channels: \(channels))。"
        case let .engineStartFailed(underlying):
            return "AVAudioEngine の開始に失敗しました: \(underlying.localizedDescription)"
        case let .sessionConfigurationFailed(underlying):
            return "AVAudioSession の設定に失敗しました: \(underlying.localizedDescription)"
        case let .fileNotFound(url):
            return "音源ファイルが見つかりません: \(url.lastPathComponent)"
        }
    }
}
