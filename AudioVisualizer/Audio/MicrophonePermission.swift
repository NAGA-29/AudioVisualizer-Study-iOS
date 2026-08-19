import AVFoundation

/// マイク権限の状態。`AVAudioApplication` (iOS 17+) を薄くラップする。
enum MicrophonePermission {
    case undetermined
    case granted
    case denied

    /// 現在の権限状態。
    /// - Note: `Info.plist` に `NSMicrophoneUsageDescription` が無いと、要求した瞬間にクラッシュする。
    ///         本プロジェクトでは `INFOPLIST_KEY_NSMicrophoneUsageDescription` (Build Settings) で設定済み。
    static var current: MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    static func request() async -> MicrophonePermission {
        guard current == .undetermined else { return current }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .granted : .denied
    }
}
