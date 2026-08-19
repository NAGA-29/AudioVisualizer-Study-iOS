import XCTest
@testable import AudioVisualizer

final class BandAnalyzerTests: XCTestCase {

    private let sampleRate: Double = 44_100
    private let fftSize = 2048

    /// 低域だけにエネルギーを置いたら low だけが立つ。
    func testLowContentOnlyRaisesLowBand() {
        let analyzer = BandAnalyzer(configuration: linearConfiguration(smoothing: 0))
        let energy = analyzer.analyze(magnitudes: spectrum(energyIn: 50...200, value: 0.4), sampleRate: sampleRate)

        XCTAssertGreaterThan(energy.low, 0.1)
        XCTAssertEqual(energy.mid, 0, accuracy: 0.001)
        XCTAssertEqual(energy.high, 0, accuracy: 0.001)
        XCTAssertGreaterThan(energy.overall, 0)
    }

    /// 高域だけなら high だけが立つ。
    func testHighContentOnlyRaisesHighBand() {
        let analyzer = BandAnalyzer(configuration: linearConfiguration(smoothing: 0))
        let energy = analyzer.analyze(magnitudes: spectrum(energyIn: 8_000...16_000, value: 0.4), sampleRate: sampleRate)

        XCTAssertGreaterThan(energy.high, 0.1)
        XCTAssertEqual(energy.low, 0, accuracy: 0.001)
        XCTAssertEqual(energy.mid, 0, accuracy: 0.001)
    }

    /// 中域だけなら mid だけが立つ。
    func testMidContentOnlyRaisesMidBand() {
        let analyzer = BandAnalyzer(configuration: linearConfiguration(smoothing: 0))
        let energy = analyzer.analyze(magnitudes: spectrum(energyIn: 500...3_000, value: 0.4), sampleRate: sampleRate)

        XCTAssertGreaterThan(energy.mid, 0.1)
        XCTAssertEqual(energy.low, 0, accuracy: 0.001)
        XCTAssertEqual(energy.high, 0, accuracy: 0.001)
    }

    /// 巨大な値を入れても 0〜1 にクランプされる。
    func testValuesAreClampedToUnitRange() {
        let analyzer = BandAnalyzer(configuration: linearConfiguration(smoothing: 0, gain: 1_000))
        let energy = analyzer.analyze(magnitudes: spectrum(energyIn: 20...18_000, value: 5), sampleRate: sampleRate)

        XCTAssertEqual(energy.low, 1)
        XCTAssertEqual(energy.mid, 1)
        XCTAssertEqual(energy.high, 1)
        XCTAssertEqual(energy.overall, 1)
    }

    /// DC (bin 0) は無視する。マイクの DC オフセットで低域が張り付くのを防ぐため。
    func testDCBinIsIgnored() {
        let analyzer = BandAnalyzer(configuration: linearConfiguration(smoothing: 0, gain: 100))
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        magnitudes[0] = 10
        let energy = analyzer.analyze(magnitudes: magnitudes, sampleRate: sampleRate)

        XCTAssertEqual(energy.low, 0, accuracy: 0.001)
        XCTAssertEqual(energy.overall, 0, accuracy: 0.001)
    }

    /// 初回フレームは前値が無いので生値をそのまま採用する (0 からの立ち上がり待ちを作らない)。
    func testFirstFrameIsNotSmoothed() {
        let smoothingAnalyzer = BandAnalyzer(configuration: linearConfiguration(smoothing: 0.9))
        let rawAnalyzer = BandAnalyzer(configuration: linearConfiguration(smoothing: 0))
        let input = spectrum(energyIn: 50...200, value: 0.4)

        let smoothed = smoothingAnalyzer.analyze(magnitudes: input, sampleRate: sampleRate)
        let raw = rawAnalyzer.analyze(magnitudes: input, sampleRate: sampleRate)

        XCTAssertEqual(smoothed.low, raw.low, accuracy: 0.0001)
    }

    /// EMA は目標値へ徐々に近づく (滑らかさ vs 反応速度のトレードオフ)。
    func testEMAConvergesGraduallyTowardNewTarget() {
        let analyzer = BandAnalyzer(configuration: linearConfiguration(smoothing: 0.7))
        let loud = spectrum(energyIn: 50...200, value: 0.4)
        let silence = [Float](repeating: 0, count: fftSize / 2)

        let first = analyzer.analyze(magnitudes: loud, sampleRate: sampleRate)
        let second = analyzer.analyze(magnitudes: silence, sampleRate: sampleRate)
        let third = analyzer.analyze(magnitudes: silence, sampleRate: sampleRate)

        XCTAssertLessThan(second.low, first.low)
        XCTAssertLessThan(third.low, second.low)
        XCTAssertGreaterThan(third.low, 0)
        // 1 フレームで 0 に落ちない = 平滑化が効いている
        XCTAssertEqual(second.low, first.low * 0.7, accuracy: 0.0001)
    }

    /// 係数が大きいほど反応が鈍い。
    func testLargerSmoothingReactsSlower() {
        let slow = BandAnalyzer(configuration: linearConfiguration(smoothing: 0.9))
        let fast = BandAnalyzer(configuration: linearConfiguration(smoothing: 0.3))
        let silence = [Float](repeating: 0, count: fftSize / 2)
        let loud = spectrum(energyIn: 50...200, value: 0.4)

        _ = slow.analyze(magnitudes: loud, sampleRate: sampleRate)
        _ = fast.analyze(magnitudes: loud, sampleRate: sampleRate)
        let slowDecay = slow.analyze(magnitudes: silence, sampleRate: sampleRate)
        let fastDecay = fast.analyze(magnitudes: silence, sampleRate: sampleRate)

        XCTAssertGreaterThan(slowDecay.low, fastDecay.low)
    }

    /// reset() で内部状態 (EMA / ビートのベースライン) が消える。
    func testResetClearsSmoothingState() {
        let analyzer = BandAnalyzer(configuration: linearConfiguration(smoothing: 0.9))
        let loud = spectrum(energyIn: 50...200, value: 0.4)
        let silence = [Float](repeating: 0, count: fftSize / 2)

        _ = analyzer.analyze(magnitudes: loud, sampleRate: sampleRate)
        analyzer.reset()
        let afterReset = analyzer.analyze(magnitudes: silence, sampleRate: sampleRate)

        XCTAssertEqual(afterReset.low, 0, accuracy: 0.0001)
    }

    /// 静かな状態から急に低域が立ち上がったフレームでビートが立つ。
    func testBeatIsDetectedOnLowBandAttack() {
        var configuration = linearConfiguration(smoothing: 0.5, gain: 20)
        configuration.beat.baselineSmoothing = 0.9
        configuration.beat.threshold = 1.4
        configuration.beat.minimumEnergy = 0.1
        let analyzer = BandAnalyzer(configuration: configuration)

        let quiet = spectrum(energyIn: 50...200, value: 0.001)
        for _ in 0..<20 {
            _ = analyzer.analyze(magnitudes: quiet, sampleRate: sampleRate)
        }
        let attack = analyzer.analyze(magnitudes: spectrum(energyIn: 50...200, value: 0.5), sampleRate: sampleRate)

        XCTAssertTrue(attack.isBeat)
    }

    /// 定常音ではベースラインが追いつき、ビートが出続けない。
    func testSustainedToneStopsProducingBeats() {
        var configuration = linearConfiguration(smoothing: 0.5, gain: 20)
        configuration.beat.baselineSmoothing = 0.7
        let analyzer = BandAnalyzer(configuration: configuration)
        let steady = spectrum(energyIn: 50...200, value: 0.5)

        // 立ち上がり数フレームはアタックとして検出されて当然なので、ベースラインが追いつくまで空回しする。
        for _ in 0..<10 {
            _ = analyzer.analyze(magnitudes: steady, sampleRate: sampleRate)
        }

        var beats = 0
        for _ in 0..<20 where analyzer.analyze(magnitudes: steady, sampleRate: sampleRate).isBeat {
            beats += 1
        }

        XCTAssertEqual(beats, 0)
    }

    func testBeatDetectionCanBeDisabled() {
        var configuration = linearConfiguration(smoothing: 0, gain: 20)
        configuration.beat.isEnabled = false
        let analyzer = BandAnalyzer(configuration: configuration)

        let energy = analyzer.analyze(magnitudes: spectrum(energyIn: 50...200, value: 0.5), sampleRate: sampleRate)
        XCTAssertFalse(energy.isBeat)
    }

    /// dB スケーリングでは floor 以下が 0、ceiling 以上が 1 になる。
    func testDecibelScalingMapsFloorAndCeiling() {
        var configuration = BandAnalyzer.Configuration.default
        configuration.smoothing = 0
        configuration.scaling = .decibel(floor: -60, ceiling: -20)
        let analyzer = BandAnalyzer(configuration: configuration)

        // -60dB = 0.001, -20dB = 0.1
        let quiet = analyzer.analyze(magnitudes: spectrum(energyIn: 20...18_000, value: 0.0001), sampleRate: sampleRate)
        analyzer.reset()
        let loud = analyzer.analyze(magnitudes: spectrum(energyIn: 20...18_000, value: 1.0), sampleRate: sampleRate)

        XCTAssertEqual(quiet.overall, 0, accuracy: 0.001)
        XCTAssertEqual(loud.overall, 1, accuracy: 0.001)
    }

    /// サンプルレートが変わっても帯域は Hz 基準で解釈される。
    func testBandsFollowSampleRate() {
        let analyzer48 = BandAnalyzer(configuration: linearConfiguration(smoothing: 0))
        let energy = analyzer48.analyze(magnitudes: spectrum(energyIn: 50...200, value: 0.4, sampleRate: 48_000), sampleRate: 48_000)

        XCTAssertGreaterThan(energy.low, 0.1)
        XCTAssertEqual(energy.mid, 0, accuracy: 0.001)
    }

    func testEmptyInputReturnsPreviousValue() {
        let analyzer = BandAnalyzer(configuration: linearConfiguration(smoothing: 0))
        let energy = analyzer.analyze(magnitudes: [], sampleRate: sampleRate)
        XCTAssertEqual(energy, .silent)
    }

    // MARK: - Helpers

    private func linearConfiguration(smoothing: Float, gain: Float = 1) -> BandAnalyzer.Configuration {
        var configuration = BandAnalyzer.Configuration.default
        configuration.smoothing = smoothing
        configuration.scaling = .linear(gain: gain)
        return configuration
    }

    /// 指定した周波数レンジにだけ値を持つ magnitude 配列を作る。
    private func spectrum(energyIn range: ClosedRange<Float>, value: Float, sampleRate: Double? = nil) -> [Float] {
        let sampleRate = sampleRate ?? self.sampleRate
        let binCount = fftSize / 2
        let binWidth = Float(sampleRate) / Float(fftSize)
        var magnitudes = [Float](repeating: 0, count: binCount)
        for bin in 1..<binCount {
            let frequency = Float(bin) * binWidth
            if range.contains(frequency) { magnitudes[bin] = value }
        }
        return magnitudes
    }
}
