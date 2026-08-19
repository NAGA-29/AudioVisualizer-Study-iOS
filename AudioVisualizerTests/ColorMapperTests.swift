import XCTest
@testable import AudioVisualizer

final class ColorMapperTests: XCTestCase {

    /// Hue は 1 更新あたりの最大変化量を超えて動かない (ちらつき防止)。
    func testHueChangeIsRateLimited() {
        var mapper = ColorMapper(configuration: configuration(maxHueChange: 0.01), initial: HSBColor(hue: 0.5, saturation: 0, brightness: 0))
        // 目標は hue 0.8 (mid = 0.8) だが、1 回では 0.01 しか進まない。
        let result = mapper.map(BandEnergy(low: 0, mid: 0.8, high: 0, overall: 0))
        XCTAssertEqual(result.hue, 0.51, accuracy: 0.0001)
    }

    /// 何度更新しても目標へ向かって進み続ける。
    func testHueEventuallyReachesTarget() {
        var mapper = ColorMapper(configuration: configuration(maxHueChange: 0.05), initial: HSBColor(hue: 0.0, saturation: 0, brightness: 0))
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

    // MARK: - Helpers

    private func configuration(maxHueChange: Double = 0.015) -> ColorMapper.Configuration {
        var configuration = ColorMapper.Configuration.default
        configuration.maxHueChangePerUpdate = maxHueChange
        return configuration
    }
}
