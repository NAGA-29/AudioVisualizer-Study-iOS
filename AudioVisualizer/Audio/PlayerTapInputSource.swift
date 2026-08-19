import AVFoundation
import Combine
import os

/// 将来用: 自前音源 (アプリにバンドルした音声ファイル) を再生しつつ、
/// その出力を直接タップして解析に流す `AudioInputSource` 実装。
///
/// マイクを経由しないので room noise / スピーカー特性の影響を受けず、
/// 「解析パイプラインそのものの検証」に使える。差し替えが無改修で通るかの検証用でもある
/// (`docs/EXPERIMENT_NOTES.md` の検証観点 5)。
final class PlayerTapInputSource: AudioInputSource {

    struct Configuration {
        var tapBufferSize: AVAudioFrameCount = 1024
        var loops: Bool = true
        /// 解析だけしたい場合は 0 にすればミュート再生になる (タップは効いたまま)。
        var volume: Float = 1.0
        static let `default` = Configuration()
    }

    private let logger = Logger(subsystem: "AudioVisualizer", category: "PlayerTapInputSource")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let subject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private let fileURL: URL
    private var configuration: Configuration

    private(set) var isRunning = false
    private var tapInstalled = false

    init(fileURL: URL, configuration: Configuration = .default) {
        self.fileURL = fileURL
        self.configuration = configuration
    }

    deinit {
        removeTap()
        if engine.isRunning { engine.stop() }
    }

    var bufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> {
        subject.eraseToAnyPublisher()
    }

    func start() throws {
        guard !isRunning else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AudioInputError.fileNotFound(fileURL)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw AudioInputError.engineStartFailed(underlying: error)
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // こちらは録音しないので `.playback` で十分。マイク権限も不要。
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            throw AudioInputError.sessionConfigurationFailed(underlying: error)
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        player.volume = configuration.volume

        removeTap()
        // マイクではなくプレイヤーノードの出力を直接タップする。
        // 下流に流れるのは同じ `AVAudioPCMBuffer` なので、解析層以降は完全に共通。
        player.installTap(onBus: 0, bufferSize: configuration.tapBufferSize, format: file.processingFormat) { [weak self] buffer, _ in
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

        schedule(file: file)
        player.play()
        isRunning = true
        logger.info("player tap started: \(self.fileURL.lastPathComponent)")
    }

    func stop() {
        guard isRunning || engine.isRunning || tapInstalled else { return }
        player.stop()
        removeTap()
        engine.stop()
        engine.reset()
        isRunning = false
        logger.info("player tap stopped")
    }

    // MARK: - Private

    private func schedule(file: AVAudioFile) {
        player.scheduleFile(file, at: nil) { [weak self] in
            guard let self, self.configuration.loops, self.isRunning else { return }
            // 完了ハンドラはレンダースレッド寄りなので、再スケジュールは別キューへ逃がす。
            DispatchQueue.main.async {
                guard self.isRunning, let reopened = try? AVAudioFile(forReading: self.fileURL) else { return }
                self.schedule(file: reopened)
            }
        }
    }

    private func removeTap() {
        guard tapInstalled else { return }
        player.removeTap(onBus: 0)
        tapInstalled = false
    }
}
