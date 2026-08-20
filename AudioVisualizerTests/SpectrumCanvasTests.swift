import XCTest
@testable import AudioVisualizer

/// 描画用の対数バー変換 (表示専用の正規化) の検証。
final class SpectrumCanvasTests: XCTestCase {

    private let sampleRate: Double = 44_100
    private let fftSize = 2048

    func testBarCountMatchesRequest() {
        let bars = SpectrumCanvas.logBars(magnitudes: flat(0.1), sampleRate: sampleRate, barCount: 32)
        XCTAssertEqual(bars.count, 32)
    }

    func testAllBarsAreWithinUnitRange() {
        let bars = SpectrumCanvas.logBars(magnitudes: flat(10), sampleRate: sampleRate, barCount: 48)
        XCTAssertTrue(bars.allSatisfy { (0...1).contains($0) })
    }

    /// 低域だけにエネルギーがあれば、左端のバーだけが立つ。
    func testLowFrequencyEnergyFillsLeftBars() {
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        let binWidth = Float(sampleRate) / Float(fftSize)
        for bin in 1..<magnitudes.count where Float(bin) * binWidth < 200 {
            magnitudes[bin] = 0.5
        }

        let bars = SpectrumCanvas.logBars(magnitudes: magnitudes, sampleRate: sampleRate, barCount: 40)

        XCTAssertGreaterThan(bars[0], 0.5)
        XCTAssertEqual(bars[39], 0, accuracy: 0.0001)
    }

    func testSilenceProducesZeroBars() {
        let bars = SpectrumCanvas.logBars(magnitudes: flat(0), sampleRate: sampleRate, barCount: 24)
        XCTAssertTrue(bars.allSatisfy { $0 == 0 })
    }

    func testInvalidInputReturnsEmpty() {
        XCTAssertTrue(SpectrumCanvas.logBars(magnitudes: [], sampleRate: sampleRate, barCount: 24).isEmpty)
        XCTAssertTrue(SpectrumCanvas.logBars(magnitudes: flat(0.1), sampleRate: 0, barCount: 24).isEmpty)
        XCTAssertTrue(SpectrumCanvas.logBars(magnitudes: flat(0.1), sampleRate: sampleRate, barCount: 0).isEmpty)
    }

    private func flat(_ value: Float) -> [Float] {
        [Float](repeating: value, count: fftSize / 2)
    }
}
