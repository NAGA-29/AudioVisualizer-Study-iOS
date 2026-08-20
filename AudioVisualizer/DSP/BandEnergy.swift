import Foundation

/// 帯域ごとの正規化済みエネルギー (すべて 0.0〜1.0)。
struct BandEnergy: Equatable, Sendable {
    /// 20Hz〜250Hz 目安。ビート/ベース感。
    var low: Float
    /// 250Hz〜4kHz 目安。ボーカル/主旋律。
    var mid: Float
    /// 4kHz〜20kHz 目安。シンバル/空気感。
    var high: Float
    /// 全帯域。全体の音量感。
    var overall: Float
    /// 低域のアタック (拍) を検出したフレームで true。
    var isBeat: Bool

    static let silent = BandEnergy(low: 0, mid: 0, high: 0, overall: 0, isBeat: false)

    init(low: Float, mid: Float, high: Float, overall: Float, isBeat: Bool = false) {
        self.low = low
        self.mid = mid
        self.high = high
        self.overall = overall
        self.isBeat = isBeat
    }
}
