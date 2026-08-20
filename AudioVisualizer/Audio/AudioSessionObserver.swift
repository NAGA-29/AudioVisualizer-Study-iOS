import AVFoundation
import Combine
import os

/// `AVAudioSession` の割り込み / ルート変更を Combine のイベントとして流す。
///
/// - 割り込み (電話着信、他アプリの再生開始など): `.began` で停止、`.ended` は
///   `shouldResume` が true のときだけ再開する。
/// - ルート変更 (イヤホン抜き差し、Bluetooth 接続): 入力ノードのフォーマットが変わり得るので、
///   AVAudioEngine を作り直す/貼り直す必要がある。
final class AudioSessionObserver {

    enum Event {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case routeChanged(reason: AVAudioSession.RouteChangeReason, isHeadphoneInput: Bool)
        case mediaServicesReset
    }

    private let logger = Logger(subsystem: "AudioVisualizer", category: "AudioSessionObserver")
    private let subject = PassthroughSubject<Event, Never>()
    private var cancellables = Set<AnyCancellable>()

    var events: AnyPublisher<Event, Never> { subject.eraseToAnyPublisher() }

    init(notificationCenter: NotificationCenter = .default) {
        notificationCenter.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] note in self?.handleInterruption(note) }
            .store(in: &cancellables)

        notificationCenter.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] note in self?.handleRouteChange(note) }
            .store(in: &cancellables)

        // メディアサービス自体が落ちた場合はエンジンもセッションも全部組み直しになる。
        notificationCenter.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .sink { [weak self] _ in
                self?.logger.warning("media services were reset")
                self?.subject.send(.mediaServicesReset)
            }
            .store(in: &cancellables)
    }

    /// 現在の入力ルートがヘッドセットマイク等の外部マイクかどうか。
    /// イヤホン使用時は内蔵マイクよりスピーカー音の拾いが弱くなるため、UI で注意表示する。
    static var isUsingExternalInput: Bool {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        return inputs.contains { input in
            switch input.portType {
            case .headsetMic, .bluetoothHFP, .usbAudio, .lineIn:
                return true
            default:
                return false
            }
        }
    }

    /// 出力がイヤホン/ヘッドフォン側に向いているか。スピーカー再生でないと、
    /// マイクはほぼ環境音しか拾えない (検証観点 3)。
    static var isUsingHeadphoneOutput: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { output in
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Private

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            logger.info("interruption began")
            subject.send(.interruptionBegan)
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            logger.info("interruption ended (shouldResume: \(shouldResume))")
            subject.send(.interruptionEnded(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        logger.info("route changed (reason: \(raw))")
        subject.send(.routeChanged(reason: reason, isHeadphoneInput: Self.isUsingExternalInput))
    }
}
