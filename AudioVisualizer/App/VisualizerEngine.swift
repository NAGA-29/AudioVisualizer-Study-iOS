import AVFoundation
import Combine
import Foundation
import Observation
import os

/// 入力ソース → 解析 → 色/波形 を束ねるアプリ層のファサード。
///
/// - 音声のキャプチャはオーディオスレッド、FFT/帯域解析は専用キュー、
///   状態の公開だけが MainActor という 3 段構成。
/// - `AudioInputSource` にしか依存しないので、マイク以外の入力へ差し替えても
///   この下 (解析・描画) は無改修で通る。
@MainActor
@Observable
final class VisualizerEngine {

    enum Status: Equatable {
        case idle
        case running
        case permissionDenied
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    // MARK: - 公開状態 (SwiftUI が観測する)

    private(set) var status: Status = .idle
    private(set) var snapshot: AnalysisResult = .empty
    private(set) var color: HSBColor = .idle
    /// イヤホン出力中はスピーカー音をマイクで拾えないため、UI で注意喚起する。
    private(set) var isHeadphoneOutputActive = false
    private(set) var settings: VisualizerSettings

    // MARK: - 内部

    @ObservationIgnored private let logger = Logger(subsystem: "AudioVisualizer", category: "VisualizerEngine")
    // 解析キューと解析器は MainActor から切り離す (オーディオ由来のバッファを main で処理しないため)。
    @ObservationIgnored private nonisolated let analysisQueue = DispatchQueue(label: "com.example.AudioVisualizer.analysis", qos: .userInitiated)
    @ObservationIgnored private nonisolated let analyzer: AudioAnalyzer
    @ObservationIgnored private let source: MicInputSource
    @ObservationIgnored private var colorMapper: ColorMapper
    @ObservationIgnored private let sessionObserver = AudioSessionObserver()
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    /// 割り込み/バックグラウンド遷移で止めたとき、復帰後に再開すべきかどうか。
    @ObservationIgnored private var shouldResumeAfterInterruption = false

    init(settings: VisualizerSettings = .default) {
        self.settings = settings
        self.source = MicInputSource(configuration: Self.inputConfiguration(from: settings))
        self.analyzer = AudioAnalyzer(configuration: Self.analyzerConfiguration(from: settings))
        self.colorMapper = ColorMapper(configuration: Self.colorConfiguration(from: settings))

        analyzer.onResult = { @Sendable [weak self] result in
            // 解析キュー上。UI 反映は main へ渡す。
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(result)
                }
            }
        }

        source.bufferPublisher
            // タップはオーディオスレッドなので、必ず解析キューへ逃がしてから重い処理をする。
            .receive(on: analysisQueue)
            .sink { @Sendable [weak self] buffer in
                self?.analyzer.ingest(buffer)
            }
            .store(in: &cancellables)

        sessionObserver.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handle(event)
                }
            }
            .store(in: &cancellables)

        isHeadphoneOutputActive = AudioSessionObserver.isUsingHeadphoneOutput
    }

    // MARK: - 制御

    func start() async {
        let permission = await MicrophonePermission.request()
        guard permission == .granted else {
            status = .permissionDenied
            return
        }
        startCapture()
    }

    func stop(preserveResumeIntent: Bool = false) {
        if !preserveResumeIntent { shouldResumeAfterInterruption = false }
        source.stop()
        analysisQueue.async { [analyzer] in analyzer.reset() }
        if status.isRunning { status = .idle }
        snapshot = .empty
        colorMapper.reset()
        color = colorMapper.current
    }

    func toggle() async {
        if status.isRunning {
            stop()
        } else {
            await start()
        }
    }

    /// バックグラウンド遷移時に呼ぶ。復帰時に自動再開できるよう意図だけ残す。
    func handleScenePhaseChange(isActive: Bool) {
        if isActive {
            if shouldResumeAfterInterruption, status != .permissionDenied {
                startCapture()
            }
        } else if status.isRunning {
            shouldResumeAfterInterruption = true
            stop(preserveResumeIntent: true)
        }
    }

    func update(settings newValue: VisualizerSettings) {
        guard newValue != settings else { return }
        let needsSourceRestart = newValue.tapBufferSize != settings.tapBufferSize
        settings = newValue

        let analyzerConfiguration = Self.analyzerConfiguration(from: newValue)
        analysisQueue.async { [analyzer] in
            analyzer.updateConfiguration(analyzerConfiguration)
        }
        colorMapper.configuration = Self.colorConfiguration(from: newValue)

        if needsSourceRestart {
            // タップのバッファサイズはインストール時にしか効かないので貼り直す。
            source.updateConfiguration(Self.inputConfiguration(from: newValue))
        }
    }

    // MARK: - Private

    private func startCapture() {
        do {
            try source.start()
            status = .running
            shouldResumeAfterInterruption = true
            isHeadphoneOutputActive = AudioSessionObserver.isUsingHeadphoneOutput
        } catch AudioInputError.microphonePermissionDenied {
            status = .permissionDenied
        } catch {
            logger.error("start failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
        }
    }

    private func apply(_ result: AnalysisResult) {
        snapshot = result
        color = colorMapper.map(result.energy)
    }

    private func handle(_ event: AudioSessionObserver.Event) {
        switch event {
        case .interruptionBegan:
            // 電話着信など。再開意図は残したまま止める。
            if status.isRunning {
                shouldResumeAfterInterruption = true
                stop(preserveResumeIntent: true)
            }

        case let .interruptionEnded(shouldResume):
            // OS が「再開してよい」と言っている & こちらも再開したいときだけ戻す。
            if shouldResume, shouldResumeAfterInterruption {
                startCapture()
            }

        case let .routeChanged(reason, _):
            isHeadphoneOutputActive = AudioSessionObserver.isUsingHeadphoneOutput
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override, .categoryChange:
                // 入力フォーマット (サンプルレート/チャンネル数) が変わり得るのでタップを貼り直す。
                guard status.isRunning else { return }
                source.stop()
                startCapture()
            default:
                break
            }

        case .mediaServicesReset:
            // セッションもエンジンも作り直しが必要。ここでは一度止めて再開を試みる。
            let wasRunning = status.isRunning
            stop(preserveResumeIntent: true)
            if wasRunning { startCapture() }
        }
    }

    private static func inputConfiguration(from settings: VisualizerSettings) -> MicInputSource.Configuration {
        var configuration = MicInputSource.Configuration.default
        configuration.tapBufferSize = AVAudioFrameCount(settings.tapBufferSize)
        return configuration
    }

    private static func analyzerConfiguration(from settings: VisualizerSettings) -> AudioAnalyzer.Configuration {
        var configuration = AudioAnalyzer.Configuration.default
        configuration.fftSize = settings.fftSize
        configuration.band.smoothing = settings.smoothing
        configuration.band.scaling = .decibel(floor: settings.floorDb, ceiling: settings.ceilingDb)
        configuration.band.beat.isEnabled = settings.isBeatDetectionEnabled
        return configuration
    }

    private static func colorConfiguration(from settings: VisualizerSettings) -> ColorMapper.Configuration {
        var configuration = ColorMapper.Configuration.default
        configuration.maxHueChangePerUpdate = settings.maxHueChangePerUpdate
        return configuration
    }
}
