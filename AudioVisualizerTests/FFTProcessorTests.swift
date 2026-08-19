import XCTest
@testable import AudioVisualizer

final class FFTProcessorTests: XCTestCase {

    private let sampleRate: Double = 44_100

    /// FFT 長ちょうどに乗る周波数の正弦波を入れ、期待するビンにピークが立つか。
    func testSineWavePeaksAtExpectedBin() throws {
        let size = 2048
        let processor = try FFTProcessor(size: size)
        let targetBin = 100
        let frequency = processor.frequency(forBin: targetBin, sampleRate: sampleRate)

        let magnitudes = processor.magnitudes(of: sineWave(frequency: frequency, amplitude: 0.5, count: size))

        let peakBin = try XCTUnwrap(magnitudes.enumerated().max(by: { $0.element < $1.element })?.offset)
        XCTAssertEqual(peakBin, targetBin)
    }

    /// Hann 窓のコヒーレントゲイン補正込みで、ピーク magnitude が入力振幅に一致するか。
    func testPeakMagnitudeMatchesInputAmplitude() throws {
        let size = 2048
        let processor = try FFTProcessor(size: size)
        let amplitude: Float = 0.5
        let frequency = processor.frequency(forBin: 128, sampleRate: sampleRate)

        let magnitudes = processor.magnitudes(of: sineWave(frequency: frequency, amplitude: amplitude, count: size))

        // 正規化 (2 / size) が正しければ、ピークビンの値がそのまま入力振幅になる。
        XCTAssertEqual(magnitudes[128], amplitude, accuracy: 0.02)
        // Hann 窓なので隣接ビンには半分ほど漏れる (これは正常)。
        XCTAssertEqual(magnitudes[127], amplitude / 2, accuracy: 0.05)
        XCTAssertEqual(magnitudes[129], amplitude / 2, accuracy: 0.05)
    }

    /// 隣接ビンより十分離れたビンには漏れが乗らない (Hann 窓のサイドローブ確認)。
    func testLeakageIsSmallAwayFromPeak() throws {
        let size = 2048
        let processor = try FFTProcessor(size: size)
        let frequency = processor.frequency(forBin: 256, sampleRate: sampleRate)

        let magnitudes = processor.magnitudes(of: sineWave(frequency: frequency, amplitude: 1.0, count: size))

        XCTAssertLessThan(magnitudes[300], magnitudes[256] * 0.01)
        XCTAssertLessThan(magnitudes[100], magnitudes[256] * 0.01)
    }

    /// 2 音を混ぜたら両方のビンが立つか。
    func testTwoTonesProduceTwoPeaks() throws {
        let size = 4096
        let processor = try FFTProcessor(size: size)
        let lowBin = 40
        let highBin = 600
        let low = sineWave(frequency: processor.frequency(forBin: lowBin, sampleRate: sampleRate), amplitude: 0.4, count: size)
        let high = sineWave(frequency: processor.frequency(forBin: highBin, sampleRate: sampleRate), amplitude: 0.4, count: size)
        let mixed = zip(low, high).map { $0 + $1 }

        let magnitudes = processor.magnitudes(of: mixed)

        XCTAssertGreaterThan(magnitudes[lowBin], 0.3)
        XCTAssertGreaterThan(magnitudes[highBin], 0.3)
        XCTAssertLessThan(magnitudes[(lowBin + highBin) / 2], 0.05)
    }

    /// 無音入力では全ビンほぼ 0。
    func testSilenceProducesNearZeroMagnitudes() throws {
        let processor = try FFTProcessor(size: 1024)
        let magnitudes = processor.magnitudes(of: [Float](repeating: 0, count: 1024))
        XCTAssertEqual(magnitudes.count, 512)
        XCTAssertTrue(magnitudes.allSatisfy { $0 < 1e-6 })
    }

    /// DC (直流) 成分は bin 0 に出て、Nyquist の詰め込みが混ざらないこと。
    func testDCGoesToBinZeroOnly() throws {
        let processor = try FFTProcessor(size: 1024)
        let magnitudes = processor.magnitudes(of: [Float](repeating: 0.5, count: 1024))
        XCTAssertGreaterThan(magnitudes[0], 0.1)
        XCTAssertLessThan(magnitudes[5], 0.01)
    }

    /// 入力が FFT 長より短いときはゼロパディングされ、クラッシュしない。
    func testShorterInputIsZeroPadded() throws {
        let processor = try FFTProcessor(size: 2048)
        let magnitudes = processor.magnitudes(of: sineWave(frequency: 1_000, amplitude: 0.5, count: 500))
        XCTAssertEqual(magnitudes.count, 1024)
        XCTAssertTrue(magnitudes.contains { $0 > 0 })
    }

    /// 入力が長いときは直近 size サンプルだけを使う。
    func testLongerInputUsesMostRecentSamples() throws {
        let size = 1024
        let processor = try FFTProcessor(size: size)
        let frequency = processor.frequency(forBin: 64, sampleRate: sampleRate)
        // 前半は無音、後半だけ正弦波 → 直近 size を見ているならピークが立つ。
        let padded = [Float](repeating: 0, count: size) + sineWave(frequency: frequency, amplitude: 0.5, count: size)

        let magnitudes = processor.magnitudes(of: padded)

        let peakBin = magnitudes.enumerated().max(by: { $0.element < $1.element })?.offset
        XCTAssertEqual(peakBin, 64)
    }

    func testInvalidSizeThrows() {
        XCTAssertThrowsError(try FFTProcessor(size: 1000)) { error in
            XCTAssertEqual(error as? FFTProcessor.Failure, .invalidSize(1000))
        }
        XCTAssertThrowsError(try FFTProcessor(size: 16)) { error in
            XCTAssertEqual(error as? FFTProcessor.Failure, .invalidSize(16))
        }
    }

    func testFrequencyAndBinIndexRoundTrip() throws {
        let processor = try FFTProcessor(size: 2048)
        let frequency = processor.frequency(forBin: 200, sampleRate: sampleRate)
        XCTAssertEqual(processor.binIndex(for: frequency, sampleRate: sampleRate), 200)
        // 範囲外はクランプされる。
        XCTAssertEqual(processor.binIndex(for: 1_000_000, sampleRate: sampleRate), processor.binCount - 1)
        XCTAssertEqual(processor.binIndex(for: -100, sampleRate: sampleRate), 0)
    }

    // MARK: - Helpers

    private func sineWave(frequency: Double, amplitude: Float, count: Int) -> [Float] {
        (0..<count).map { index in
            amplitude * sinf(Float(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }
}
