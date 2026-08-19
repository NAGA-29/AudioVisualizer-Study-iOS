import AVFoundation
import Combine
import os

/// マイク入力から PCM バッファを取り出す `AudioInputSource` 実装。
///
/// Apple Music などの再生ストリームは DRM 保護のため直接タップできないので、
/// 「スピーカーから出た音をマイクで拾う」方式でスペクトラムを得る。
final class MicInputSource: AudioInputSource {

    struct Configuration {
        /// `installTap` に渡すバッファサイズ。1024〜4096 を想定。
        /// ここはあくまで「タップの粒度」で、FFT 長とは独立に調整できる (FFT 側はリングバッファで供給する)。
        var tapBufferSize: AVAudioFrameCount = 1024

        /// 再生中の他アプリ (音楽アプリ) を止めないよう `.playAndRecord` + `.mixWithOthers` を既定にする。
        /// `.record` にすると他アプリの再生が止まり、そもそも解析対象の音が鳴らなくなる。
        var category: AVAudioSession.Category = .playAndRecord

        /// `.allowBluetooth` は入れない: HFP に落ちて入出力とも 8/16kHz の狭帯域になり、
        /// 高域の解析がまったく成立しなくなるため。出力だけ A2DP を許可する。
        var categoryOptions: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]

        /// `.measurement` は AGC / EQ など OS 側の信号処理を最小化するので、解析用途では素直な波形が得られる。
        /// ただし出力音量が下がる端末があるため、見た目重視なら `.default` も試す価値あり (実験項目)。
        var mode: AVAudioSession.Mode = .measurement

        static let `default` = Configuration()
    }

    private let logger = Logger(subsystem: "AudioVisualizer", category: "MicInputSource")
    private let engine = AVAudioEngine()
    private let subject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private(set) var configuration: Configuration

    private(set) var isRunning = false
    private var tapInstalled = false

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    deinit {
        // deinit からは stop() の副作用 (セッション非アクティブ化) を避け、エンジンだけ畳む。
        removeTap()
        if engine.isRunning { engine.stop() }
    }

    var bufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> {
        subject.eraseToAnyPublisher()
    }

    /// 実際に使われているハードウェアのサンプルレート。決め打ちせず毎回セッションから取得する。
    var sampleRate: Double {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 ? format.sampleRate : AVAudioSession.sharedInstance().sampleRate
    }

    func updateConfiguration(_ configuration: Configuration) {
        let wasRunning = isRunning
        if wasRunning { stop() }
        self.configuration = configuration
        if wasRunning { try? start() }
    }

    func start() throws {
        guard !isRunning else { return }

        guard MicrophonePermission.current == .granted else {
            throw AudioInputError.microphonePermissionDenied
        }

        try configureSession()

        let input = engine.inputNode
        // タップのフォーマットは入力ノードの実フォーマットに合わせる (nil 指定でも良いが明示しておく)。
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioInputError.invalidInputFormat(sampleRate: format.sampleRate, channels: format.channelCount)
        }

        removeTap()
        input.installTap(onBus: 0, bufferSize: configuration.tapBufferSize, format: format) { [weak self] buffer, _ in
            // ここはオーディオスレッド。重い処理は絶対に書かない (送るだけ)。
            self?.subject.send(buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeTap()
            throw AudioInputError.engineStartFailed(underlying: error)
        }

        isRunning = true
        logger.info("mic started: sampleRate=\(format.sampleRate), channels=\(format.channelCount), tapBufferSize=\(self.configuration.tapBufferSize)")
    }

    func stop() {
        guard isRunning || engine.isRunning || tapInstalled else { return }
        removeTap()
        engine.stop()
        engine.reset()
        isRunning = false

        // 他アプリの再生を邪魔しないよう、明示的に非アクティブ化して復帰通知を出す。
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            logger.warning("session deactivation failed: \(error.localizedDescription)")
        }
        logger.info("mic stopped")
    }

    // MARK: - Private

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(configuration.category, mode: configuration.mode, options: configuration.categoryOptions)
            // サンプルレートは端末依存。setPreferredSampleRate で決め打ちせず、OS の選択をそのまま使う。
            try session.setActive(true)
        } catch {
            throw AudioInputError.sessionConfigurationFailed(underlying: error)
        }
    }

    private func removeTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }
}
