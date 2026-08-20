import XCTest
@testable import AudioVisualizer

final class ColorMapperTests: XCTestCase {

    /// Hue は 1 更新あたりの最大変化量を超えて動かない (ちらつき防止)。
    func testHueChangeIsRateLimited() {
        var mapper = ColorMapper(configuration: configuration(maxHueChange: 0.01, hueSource: .midEnergy), initial: HSBColor(hue: 0.5, saturation: 0, brightness: 0))
        // 目標は hue 0.8 (mid = 0.8) だが、1 回では 0.01 しか進まない。
        let result = mapper.map(BandEnergy(low: 0, mid: 0.8, high: 0, overall: 0))
        XCTAssertEqual(result.hue, 0.51, accuracy: 0.0001)
    }

    /// 何度更新しても目標へ向かって進み続ける。
    func testHueEventuallyReachesTarget() {
        var mapper = ColorMapper(configuration: configuration(maxHueChange: 0.05, hueSource: .midEnergy), initial: HSBColor(hue: 0.0, saturation: 0, brightness: 0))
        for _ in 0..<20 {
            _ = mapper.map(BandEnergy(low: 0, mid: 0.5, high: 0, overall: 0))
        }
        XCTAssertEqual(mapper.current.hue, 0.5, accuracy: 0.001)
    }

    /// 色相環をまたぐときは最短経路を通る (0.95 → 0.05 は 0 方向へ進む)。
    func testHueTakesShortestPathAcrossWrapAround() {
        let next = ColorMapper.approach(current: 0.95, target: 0.05, maxDelta: 0.02, wraps: true)
        XCTAssertEqual(next, 0.97, accuracy: 0.0001)
    }

    /// 1.0 を超えたら 0 側へ回り込む。
    func testHueWrapsPastOne() {
        let next = ColorMapper.approach(current: 0.995, target: 0.05, maxDelta: 0.02, wraps: true)
        XCTAssertEqual(next, 0.015, accuracy: 0.0001)
    }

    /// 逆方向 (0.05 → 0.95) も最短経路で 0 を割り込む。
    func testHueWrapsBelowZero() {
        let next = ColorMapper.approach(current: 0.005, target: 0.95, maxDelta: 0.02, wraps: true)
        XCTAssertEqual(next, 0.985, accuracy: 0.0001)
    }

    /// wraps = false のときは折り返さず線形に寄せる。
    func testNonWrappingApproachDoesNotCrossZero() {
        let next = ColorMapper.approach(current: 0.2, target: 0.9, maxDelta: 0.1, wraps: false)
        XCTAssertEqual(next, 0.3, accuracy: 0.0001)
    }

    /// Saturation は overall に比例する。
    func testSaturationFollowsOverallEnergy() {
        var mapper = ColorMapper(configuration: configuration())
        let quiet = mapper.map(BandEnergy(low: 0, mid: 0, high: 0, overall: 0))
        let loud = mapper.map(BandEnergy(low: 0, mid: 0, high: 0, overall: 1))

        XCTAssertEqual(quiet.saturation, 0.35, accuracy: 0.0001)
        XCTAssertEqual(loud.saturation, 1.0, accuracy: 0.0001)
    }

    /// Brightness は low 帯に追従する。
    func testBrightnessFollowsLowBand() {
        var mapper = ColorMapper(configuration: configuration())
        let dark = mapper.map(BandEnergy(low: 0, mid: 0, high: 0, overall: 0))
        let bright = mapper.map(BandEnergy(low: 1, mid: 0, high: 0, overall: 0))

        XCTAssertEqual(dark.brightness, 0.10, accuracy: 0.0001)
        XCTAssertEqual(bright.brightness, 1.0, accuracy: 0.0001)
    }

    /// ビート検出フレームでは brightness が持ち上がる。
    func testBeatBoostsBrightness() {
        var mapper = ColorMapper(configuration: configuration())
        let normal = mapper.map(BandEnergy(low: 0.5, mid: 0, high: 0, overall: 0, isBeat: false))
        let beat = mapper.map(BandEnergy(low: 0.5, mid: 0, high: 0, overall: 0, isBeat: true))

        XCTAssertGreaterThan(beat.brightness, normal.brightness)
        XCTAssertLessThanOrEqual(beat.brightness, 1.0)
    }

    /// 異常値 (NaN / 範囲外) を入れても HSB は 0〜1 に収まる。
    func testOutputStaysInUnitRangeForInvalidInput() {
        var mapper = ColorMapper(configuration: configuration(maxHueChange: 0.5))
        let inputs: [BandEnergy] = [
            BandEnergy(low: .nan, mid: .nan, high: .nan, overall: .nan),
            BandEnergy(low: 10, mid: 10, high: 10, overall: 10, isBeat: true),
            BandEnergy(low: -5, mid: -5, high: -5, overall: -5)
        ]

        for input in inputs {
            let color = mapper.map(input)
            XCTAssertTrue((0...1).contains(color.hue), "hue: \(color.hue)")
            XCTAssertTrue((0...1).contains(color.saturation), "saturation: \(color.saturation)")
            XCTAssertTrue((0...1).contains(color.brightness), "brightness: \(color.brightness)")
        }
    }

    func testResetRestoresInitialColor() {
        var mapper = ColorMapper(configuration: configuration())
        _ = mapper.map(BandEnergy(low: 1, mid: 1, high: 1, overall: 1))
        mapper.reset()
        XCTAssertEqual(mapper.current, .idle)
    }

    // MARK: - 音色ベースの色相 (spectralBalance)

    /// 単一帯域だけが鳴っていれば、その帯域のアンカー色相そのものになる。
    func testSingleBandLandsOnItsAnchorHue() throws {
        let anchors = ColorMapper.BandHueAnchors.default

        let low = try XCTUnwrap(ColorMapper.spectralBalance(low: 1, mid: 0, high: 0, anchors: anchors))
        XCTAssertEqual(low.hue, anchors.low, accuracy: 0.0001)

        let mid = try XCTUnwrap(ColorMapper.spectralBalance(low: 0, mid: 1, high: 0, anchors: anchors))
        XCTAssertEqual(mid.hue, anchors.mid, accuracy: 0.0001)

        let high = try XCTUnwrap(ColorMapper.spectralBalance(low: 0, mid: 0, high: 1, anchors: anchors))
        XCTAssertEqual(high.hue, anchors.high, accuracy: 0.0001)
    }

    /// 単一帯域なら重心の長さは最大 (1)。音色がその帯域に振り切っている状態。
    func testSingleBandHasFullMagnitude() throws {
        let balance = try XCTUnwrap(ColorMapper.spectralBalance(low: 0, mid: 1, high: 0, anchors: .default))
        XCTAssertEqual(balance.magnitude, 1, accuracy: 0.0001)
    }

    /// 3 帯域が拮抗していると重心はほぼ原点に落ちる (向きが定まらない)。
    func testBalancedBandsCollapseToOrigin() throws {
        let balance = try XCTUnwrap(ColorMapper.spectralBalance(low: 0.5, mid: 0.5, high: 0.5, anchors: .default))
        XCTAssertEqual(balance.magnitude, 0, accuracy: 0.0001)
    }

    /// 全帯域が無音なら重心を決められない。
    func testSilenceHasNoBalance() {
        XCTAssertNil(ColorMapper.spectralBalance(low: 0, mid: 0, high: 0, anchors: .default))
    }

    /// 帯域の比率が変われば色相も変わる。低域寄りと高域寄りで別の色になること。
    func testDifferentTimbresProduceDifferentHues() throws {
        let bassHeavy = try XCTUnwrap(ColorMapper.spectralBalance(low: 1.0, mid: 0.2, high: 0.1, anchors: .default))
        let trebleHeavy = try XCTUnwrap(ColorMapper.spectralBalance(low: 0.1, mid: 0.2, high: 1.0, anchors: .default))
        XCTAssertNotEqual(bassHeavy.hue, trebleHeavy.hue, accuracy: 0.05)
    }

    /// 帯域比が同じなら音量が変わっても色相は変わらない (音量ではなく音色に反応する)。
    func testHueIsInvariantToOverallLevel() throws {
        let quiet = try XCTUnwrap(ColorMapper.spectralBalance(low: 0.2, mid: 0.1, high: 0.05, anchors: .default))
        let loud = try XCTUnwrap(ColorMapper.spectralBalance(low: 0.8, mid: 0.4, high: 0.2, anchors: .default))
        XCTAssertEqual(quiet.hue, loud.hue, accuracy: 0.0001)
    }

    /// 重心が小さすぎるフレームでは色相を動かさない (拮抗時のちらつき防止)。
    func testHueHoldsStillWhenBandsAreBalanced() {
        var configuration = self.configuration(maxHueChange: 0.5)
        configuration.minimumBalanceMagnitude = 0.02
        var mapper = ColorMapper(configuration: configuration, initial: HSBColor(hue: 0.42, saturation: 0, brightness: 0))

        let result = mapper.map(BandEnergy(low: 0.5, mid: 0.5, high: 0.5, overall: 0.5))
        XCTAssertEqual(result.hue, 0.42, accuracy: 0.0001)
    }

    /// 色相環を三等分しているので、重みの偏り方しだいで全域に到達できる。
    func testFullHueWheelIsReachable() {
        var seen = Set<Int>()
        for low in stride(from: 0.0, through: 1.0, by: 0.1) {
            for mid in stride(from: 0.0, through: 1.0, by: 0.1) {
                for high in stride(from: 0.0, through: 1.0, by: 0.1) {
                    guard let balance = ColorMapper.spectralBalance(
                        low: Float(low), mid: Float(mid), high: Float(high), anchors: .default
                    ), balance.magnitude >= 0.02 else { continue }
                    seen.insert(Int(balance.hue * 12) % 12)
                }
            }
        }
        // 色相環を 12 分割したセクタすべてに到達できること。
        XCTAssertEqual(seen.count, 12, "到達できない色相セクタがある: \(Set(0..<12).subtracting(seen).sorted())")
    }

    // MARK: - Helpers

    private func configuration(
        maxHueChange: Double = 0.015,
        hueSource: ColorMapper.HueSource = .spectralBalance
    ) -> ColorMapper.Configuration {
        var configuration = ColorMapper.Configuration.default
        configuration.maxHueChangePerUpdate = maxHueChange
        configuration.hueSource = hueSource
        return configuration
    }
}
