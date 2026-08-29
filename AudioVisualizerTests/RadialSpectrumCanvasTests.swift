import CoreGraphics
import XCTest
@testable import AudioVisualizer

/// リング表示の配置ロジック (純関数) の検証。
///
/// 値そのものの作り方は `SpectrumCanvas.logBars` と共有しているので、ここでは
/// 「円周への写し方」「鏡像展開」「色相の割り当て」だけを見る。
final class RadialSpectrumCanvasTests: XCTestCase {

    private let center = CGPoint(x: 100, y: 100)

    // MARK: - 最大長のクランプ (キャンバスからのはみ出し防止)

    /// 内周半径 + 要求長がキャンバス半径に収まるなら、要求どおりの長さを返す。
    func testClampedBarLengthKeepsRequestWhenItFits() {
        let length = RadialSpectrumCanvas.clampedBarLength(
            unit: 100, baseRadius: 40, requestedLength: 30, ringDeform: 0.35
        )
        XCTAssertEqual(length, 30, accuracy: 0.0001)
    }

    /// 内周半径比 (0.6) + バー長比 (0.5) のように、チューニングパネルの上限同士を
    /// 組み合わせただけで合計が 1.0 を超えるケース。外周がキャンバス半径を超えないよう絞る。
    func testClampedBarLengthShrinksWhenRequestOverflowsCanvas() {
        let unit: CGFloat = 100
        let baseRadius = unit * 0.6
        let requested = unit * 0.5

        let length = RadialSpectrumCanvas.clampedBarLength(
            unit: unit, baseRadius: baseRadius, requestedLength: requested, ringDeform: 0.35
        )

        XCTAssertLessThan(length, requested)
        // 押し出し込みの最大到達点 (baseRadius + length * (1 + ringDeform)) がキャンバス半径以内。
        XCTAssertLessThanOrEqual(baseRadius + length * (1 + 0.35), unit + 0.0001)
    }

    /// 内周だけでキャンバス半径を使い切っている場合、長さは 0 まで絞られる (負の長さにはしない)。
    func testClampedBarLengthNeverGoesNegative() {
        let length = RadialSpectrumCanvas.clampedBarLength(
            unit: 100, baseRadius: 130, requestedLength: 40, ringDeform: 0.35
        )
        XCTAssertEqual(length, 0, accuracy: 0.0001)
    }

    func testClampedBarLengthWithZeroUnitIsZero() {
        let length = RadialSpectrumCanvas.clampedBarLength(
            unit: 0, baseRadius: 10, requestedLength: 40, ringDeform: 0.35
        )
        XCTAssertEqual(length, 0, accuracy: 0.0001)
    }

    // MARK: - 鏡像展開

    func testMirroredDoublesCountAndIsSymmetric() {
        let bars: [Float] = [0.1, 0.2, 0.3]
        let mirrored = RadialSpectrumCanvas.mirrored(bars)

        XCTAssertEqual(mirrored, [0.1, 0.2, 0.3, 0.3, 0.2, 0.1])
    }

    func testMirroredOfEmptyIsEmpty() {
        XCTAssertTrue(RadialSpectrumCanvas.mirrored([]).isEmpty)
    }

    /// 鏡像展開後は、対称位置のバーが同じ色相位置 (= 同じ周波数) を指す。
    func testSourcePositionIsSymmetricWhenMirrored() {
        let count = 8  // 半周 4 本の鏡像
        for index in 0..<(count / 2) {
            let left = RadialSpectrumCanvas.sourcePosition(index: index, count: count, isMirrored: true)
            let right = RadialSpectrumCanvas.sourcePosition(index: count - 1 - index, count: count, isMirrored: true)
            XCTAssertEqual(left, right, accuracy: 0.0001)
        }
    }

    func testSourcePositionSpansUnitRange() {
        let count = 8
        XCTAssertEqual(RadialSpectrumCanvas.sourcePosition(index: 0, count: count, isMirrored: true), 0, accuracy: 0.0001)
        XCTAssertEqual(RadialSpectrumCanvas.sourcePosition(index: 3, count: count, isMirrored: true), 1, accuracy: 0.0001)

        XCTAssertEqual(RadialSpectrumCanvas.sourcePosition(index: 0, count: count, isMirrored: false), 0, accuracy: 0.0001)
        XCTAssertEqual(RadialSpectrumCanvas.sourcePosition(index: count - 1, count: count, isMirrored: false), 1, accuracy: 0.0001)
    }

    // MARK: - 配置

    /// 先頭のバーは天頂付近 (中心より上) を向いて外向きに伸びる。
    ///
    /// 半スロットぶんずらしているので真上ちょうどではない。天頂を「バーの中心」ではなく
    /// 「バーとバーの隙間」にすることで、鏡像展開したときに左右が完全に対称になる。
    func testFirstBarPointsUpward() {
        let ends = RadialSpectrumCanvas.endpoints(
            center: center,
            index: 0,
            count: 64,
            value: 1,
            baseRadius: 40,
            maxLength: 20
        )

        XCTAssertLessThan(ends.start.y, center.y)
        XCTAssertLessThan(ends.end.y, ends.start.y)  // 外向きに伸びる
        XCTAssertEqual(ends.start.x, center.x, accuracy: 3.0)
    }

    /// 鏡像展開後の並びでは、半周ぶん進んだあたりで真下へ回り、以降は左半分へ戻る。
    func testBarsWrapAroundTheCircle() {
        let count = 8  // 半周 4 本の鏡像
        func start(_ index: Int) -> CGPoint {
            RadialSpectrumCanvas.endpoints(
                center: center, index: index, count: count, value: 1,
                baseRadius: 40, maxLength: 20
            ).start
        }

        // 右回りで下りきる直前 (右下) と、そこから 1 本進んだ左下。
        XCTAssertGreaterThan(start(count / 2 - 1).x, center.x)
        XCTAssertGreaterThan(start(count / 2 - 1).y, center.y)
        XCTAssertLessThan(start(count / 2).x, center.x)
        XCTAssertGreaterThan(start(count / 2).y, center.y)

        // 対称位置のバーは縦軸に対する鏡像になる。
        XCTAssertEqual(start(0).x, 2 * center.x - start(count - 1).x, accuracy: 0.001)
        XCTAssertEqual(start(0).y, start(count - 1).y, accuracy: 0.001)
    }

    /// バー長は値に比例し、内周からの押し出しも値に比例する。
    func testLengthAndOffsetScaleWithValue() {
        func length(_ value: Float) -> CGFloat {
            let ends = RadialSpectrumCanvas.endpoints(
                center: center,
                index: 0,
                count: 8,
                value: value,
                baseRadius: 40,
                maxLength: 40,
                ringDeform: 0.5
            )
            return hypot(ends.end.x - ends.start.x, ends.end.y - ends.start.y)
        }

        XCTAssertGreaterThan(length(1.0), length(0.5))
        XCTAssertGreaterThan(length(0.5), length(0.0))

        let quiet = RadialSpectrumCanvas.endpoints(
            center: center, index: 0, count: 8, value: 0,
            baseRadius: 40, maxLength: 40, ringDeform: 0.5
        )
        let loud = RadialSpectrumCanvas.endpoints(
            center: center, index: 0, count: 8, value: 1,
            baseRadius: 40, maxLength: 40, ringDeform: 0.5
        )
        // 鳴っている方向は内周が押し出される (輪郭が膨らむ)。
        XCTAssertLessThan(loud.start.y, quiet.start.y)
    }

    /// 無音でも点として残す (完全に消えると輪郭が読めなくなる)。
    func testSilentBarKeepsMinimumLength() {
        let ends = RadialSpectrumCanvas.endpoints(
            center: center, index: 0, count: 8, value: 0,
            baseRadius: 40, maxLength: 40
        )
        let length = hypot(ends.end.x - ends.start.x, ends.end.y - ends.start.y)
        XCTAssertEqual(length, 2, accuracy: 0.0001)
    }

    /// 回転位相 0.5 は半周ぶんの回転 = 中心対称の位置になる。
    func testRotationShiftsPlacement() {
        let base = RadialSpectrumCanvas.endpoints(
            center: center, index: 0, count: 8, value: 1,
            baseRadius: 40, maxLength: 20
        )
        let rotated = RadialSpectrumCanvas.endpoints(
            center: center, index: 0, count: 8, value: 1,
            baseRadius: 40, maxLength: 20, rotation: 0.5
        )

        XCTAssertEqual(rotated.start.x, 2 * center.x - base.start.x, accuracy: 0.001)
        XCTAssertEqual(rotated.start.y, 2 * center.y - base.start.y, accuracy: 0.001)
    }

    func testInvalidValueDoesNotProduceNaN() {
        let ends = RadialSpectrumCanvas.endpoints(
            center: center, index: 0, count: 8, value: .nan,
            baseRadius: 40, maxLength: 20, ringDeform: 0.5
        )
        XCTAssertTrue(ends.start.x.isFinite && ends.start.y.isFinite)
        XCTAssertTrue(ends.end.x.isFinite && ends.end.y.isFinite)
    }

    // MARK: - 色

    /// 色相の一周量 1.0 なら、低域と高域は色相環をほぼ一周ぶん離れる (= 元の色相へ戻る)。
    func testHueSpreadWrapsFullCircle() {
        let base = HSBColor(hue: 0.2, saturation: 0.8, brightness: 0.9)
        let low = RadialSpectrumCanvas.barColor(base: base, position: 0, value: 1, hueSpread: 1)
        let mid = RadialSpectrumCanvas.barColor(base: base, position: 0.5, value: 1, hueSpread: 1)
        let high = RadialSpectrumCanvas.barColor(base: base, position: 1, value: 1, hueSpread: 1)

        XCTAssertEqual(low.hue, base.hue, accuracy: 0.0001)
        XCTAssertEqual(mid.hue, 0.7, accuracy: 0.0001)
        XCTAssertEqual(high.hue, base.hue, accuracy: 0.0001)  // 一周して戻る
    }

    func testHueSpreadZeroKeepsSingleHue() {
        let base = HSBColor(hue: 0.2, saturation: 0.8, brightness: 0.9)
        for position in [0.0, 0.25, 0.5, 1.0] {
            let color = RadialSpectrumCanvas.barColor(base: base, position: position, value: 0.5, hueSpread: 0)
            XCTAssertEqual(color.hue, base.hue, accuracy: 0.0001)
        }
    }

    /// 値が大きいバーほど明るい。小さいバーは黒背景へ沈む。
    func testBrightnessTracksValue() {
        let base = HSBColor(hue: 0.2, saturation: 0.8, brightness: 0.9)
        let quiet = RadialSpectrumCanvas.barColor(base: base, position: 0, value: 0, hueSpread: 1)
        let loud = RadialSpectrumCanvas.barColor(base: base, position: 0, value: 1, hueSpread: 1)

        XCTAssertGreaterThan(loud.brightness, quiet.brightness)
        XCTAssertTrue((0...1).contains(quiet.brightness))
        XCTAssertTrue((0...1).contains(loud.brightness))
        XCTAssertTrue((0...1).contains(loud.saturation))
    }
}
