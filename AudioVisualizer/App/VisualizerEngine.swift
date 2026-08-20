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
    /// 解析結果を main へ流す頻度の上限 (画面のリフレッシュレートを超えて送っても意味がない)。
    @ObservationIgnored private nonisolated let uiGate = UIUpdateGate(minimumInterval: 1.0 / 60.0)
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    /// 割り込み/バックグラウンド遷移で止めたとき、復帰後に再開すべきかどうか。
    @ObservationIgnored private var shouldResumeAfterInterruption = false
    /// 自前のセッション再構成が落ち着くまでルート変更起因の再起動を抑止する期限。
    @ObservationIgnored private var routeChangeSuppressedUntil: Date = .distantPast
    /// 直近にルート変更で再起動した時刻。連続再起動の歯止め。
    @ObservationIgnored private var lastRouteDrivenRestart: Date = .distantPast

    init(settings: VisualizerSettings = .default) {
        self.settings = settings
        self.source = MicInputSource(configuration: Self.inputConfiguration(from: settings))
        self.analyzer = AudioAnalyzer(configuration: Self.analyzerConfiguration(from: settings))
        self.colorMapper = ColorMapper(configuration: Self.colorConfiguration(from: settings))

        analyzer.onResult = { @Sendable [weak self, uiGate] result in
            // 解析キュー上。
            //
            // 解析は hop ごとに走るので 48kHz / hop 512 だと毎秒 94 回結果が出る。
            // これを全部 main へ投げると、1 回あたり数 KB の AnalysisResult のコピーと
            // SwiftUI の無効化が毎秒 94 回積み上がり、main が詰まって
            // 「設定シートが開かない / 操作に反応しない」状態になる。
            // 画面は 60fps が上限なので、間引いて最新の結果だけを反映する。
            guard uiGate.shouldForward() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(result)
                }
                uiGate.markDelivered()
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
        // 停止時の setActive(false) もルート変更通知を出すので同様に抑止する。
        routeChangeSuppressedUntil = Date().addingTimeInterval(1.0)
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
            // 設定アプリでマイクを許可して戻ってきたケースを拾う。
            refreshPermissionStatus()
            if shouldResumeAfterInterruption, status != .permissionDenied {
                startCapture()
            }
        } else if status.isRunning {
            shouldResumeAfterInterruption = true
            stop(preserveResumeIntent: true)
        }
    }

    /// マイク権限の状態を再評価する。
    ///
    /// 権限拒否画面から設定アプリへ行って許可した場合、アプリが再起動されないこともあるため、
    /// フォアグラウンド復帰時と「再確認」ボタンから呼んで拒否画面から抜けられるようにする。
    func refreshPermissionStatus() {
        switch MicrophonePermission.current {
        case .granted, .undetermined:
            if status == .permissionDenied { status = .idle }
        case .denied:
            status = .permissionDenied
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
            // 再開は startCapture() 経由にして、失敗したら status に出す (無音のまま「解析中」を防ぐ)。
            let wasRunning = status.isRunning
            source.updateConfiguration(Self.inputConfiguration(from: newValue))
            if wasRunning { startCapture() }
        }
    }

    // MARK: - Private

    private func startCapture() {
        // setCategory / setActive は自分でもルート変更通知を発生させる。
        // それを外部要因と誤認して再起動すると無限ループになるため、直後の通知は無視する。
        routeChangeSuppressedUntil = Date().addingTimeInterval(1.0)
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
            // 表示用のフラグは常に最新化する (再起動するかどうかとは別問題)。
            isHeadphoneOutputActive = AudioSessionObserver.isUsingHeadphoneOutput

            // `.categoryChange` は実質すべて自分の `setCategory` が原因。
            // ここで再起動すると再び `setCategory` が走って通知が返ってくるため、
            // 「再起動 → 通知 → 再起動」で main が詰まりアプリが固まる。対象から外す。
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override:
                // 入力フォーマット (サンプルレート/チャンネル数) が変わり得るのでタップを貼り直す。
                guard status.isRunning else { return }

                let now = Date()
                // 自前のセッション操作の直後は無視する。
                guard now >= routeChangeSuppressedUntil else {
                    logger.info("route change ignored (self-inflicted)")
                    return
                }
                // 万一抑止をすり抜けても暴走させないための歯止め。
                guard now.timeIntervalSince(lastRouteDrivenRestart) >= 1.0 else {
                    logger.warning("route change restart throttled")
                    return
                }
                lastRouteDrivenRestart = now

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
        configuration.hueSource = settings.hueSource
        return configuration
    }
}

/// 解析キューから main へ結果を流す量を制限するゲート。
///
/// 解析は hop ごとに走るため 48kHz / hop 512 では毎秒約 94 回結果が出る。
/// 一方 main が描画できるのは 60fps が上限。差分を無制限に `DispatchQueue.main.async` へ
/// 積むと main のキューが延々と伸び続け、数秒で操作を一切受け付けなくなる
/// (症状: 波形が一瞬動いた後に固まる / 設定シートが開かない)。
///
/// そこで 2 段で絞る:
/// 1. 時間による間引き — 画面のリフレッシュレートを超える分は捨てる
/// 2. バックプレッシャー — main がまだ前回分を処理していなければ送らない
///
/// これで main に積まれる更新は常に高々 1 件になり、キューが伸びなくなる。
private final class UIUpdateGate: @unchecked Sendable {

    private let minimumInterval: Double
    private let lock = NSLock()
    private var lastForwardedUptime: UInt64 = 0
    private var isDeliveryInFlight = false

    init(minimumInterval: Double) {
        self.minimumInterval = minimumInterval
    }

    /// 解析キュー上から呼ぶ。true を返したときだけ main へ送ること。
    func shouldForward() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }

        // main がまだ前回分を反映していないなら、今回は捨てる (最新値は次の機会に届く)。
        guard !isDeliveryInFlight else { return false }

        if lastForwardedUptime > 0 {
            let elapsed = Double(now - lastForwardedUptime) / 1_000_000_000
            guard elapsed >= minimumInterval else { return false }
        }

        lastForwardedUptime = now
        isDeliveryInFlight = true
        return true
    }

    /// main 側で反映が終わったら呼ぶ。次の転送を許可する。
    func markDelivered() {
        lock.lock()
        isDeliveryInFlight = false
        lock.unlock()
    }
}
