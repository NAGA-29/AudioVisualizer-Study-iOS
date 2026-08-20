import AVFoundation
import XCTest
@testable import AudioVisualizer

final class AudioAnalyzerTests: XCTestCase {

    private let sampleRate: Double = 44_100

    /// 低域の正弦波を流し込むと low 帯だけが立つ (パイプライン全体の疎通確認)。
    func testLowFrequencyToneRaisesLowBand() throws {
        var configuration = AudioAnalyzer.Configuration.default
        configuration.fftSize = 2048
        let analyzer = AudioAnalyzer(configuration: configuration)

        var results: [AnalysisResult] = []
        analyzer.onResult = { results.append($0) }

        // EMA が収束するまで定常音を流す。周波数はビン境界に合わせ、
        // バッファを繰り返しても位相が途切れない (= 余計な漏れが出ない) ようにしている。
        try feed(analyzer, frequency: binAlignedFrequency(bin: 5, frames: 2048), frames: 2048, times: 8)

        let result = try XCTUnwrap(results.last)
        XCTAssertEqual(result.fftSize, 2048)
        XCTAssertEqual(result.magnitudes.count, 1024)
        XCTAssertEqual(result.sampleRate, sampleRate)
        XCTAssertGreaterThan(result.energy.low, 0.5)
        XCTAssertLessThan(result.energy.mid, 0.2)
    }

    /// 約 10kHz なら high 帯が立つ。
    func testHighFrequencyToneRaisesHighBand() throws {
        let analyzer = AudioAnalyzer()
        var results: [AnalysisResult] = []
        analyzer.onResult = { results.append($0) }

        try feed(analyzer, frequency: binAlignedFrequency(bin: 464, frames: 2048), frames: 2048, times: 8)

        let result = try XCTUnwrap(results.last)
        XCTAssertGreaterThan(result.energy.high, 0.3)
        XCTAssertGreaterThan(result.energy.high, result.energy.low)
        XCTAssertLessThan(result.energy.low, 0.2)
    }

    /// hop に満たないバッファでは結果を出さず、溜まった時点で 1 回だけ出す。
    func testResultIsEmittedOncePerHop() throws {
        var configuration = AudioAnalyzer.Configuration.default
        configuration.fftSize = 2048
        configuration.hopSize = 1024
        let analyzer = AudioAnalyzer(configuration: configuration)

        var callCount = 0
        analyzer.onResult = { _ in callCount += 1 }

        analyzer.ingest(try buffer(frequency: 440, amplitude: 0.5, frames: 512))
        XCTAssertEqual(callCount, 0)

        analyzer.ingest(try buffer(frequency: 440, amplitude: 0.5, frames: 512))
        XCTAssertEqual(callCount, 1)

        analyzer.ingest(try buffer(frequency: 440, amplitude: 0.5, frames: 1024))
        XCTAssertEqual(callCount, 2)
    }

    /// 1 バッファに複数 hop 含まれる場合は、その回数だけ解析結果が出る。
    /// (まとめて 1 回にすると更新間隔が hop ではなくタップ間隔になってしまう)
    func testBufferSpanningMultipleHopsEmitsOnePerHop() throws {
        var configuration = AudioAnalyzer.Configuration.default
        configuration.fftSize = 1024
        configuration.hopSize = 256
        let analyzer = AudioAnalyzer(configuration: configuration)

        var callCount = 0
        analyzer.onResult = { _ in callCount += 1 }

        analyzer.ingest(try buffer(frequency: 440, amplitude: 0.5, frames: 4096))

        XCTAssertEqual(callCount, 16)
    }

    /// hop に満たない端数は次のバッファへ持ち越される (切り捨てない)。
    func testRemainderCarriesOverToNextBuffer() throws {
        var configuration = AudioAnalyzer.Configuration.default
        configuration.fftSize = 1024
        configuration.hopSize = 512
        let analyzer = AudioAnalyzer(configuration: configuration)

        var callCount = 0
        analyzer.onResult = { _ in callCount += 1 }

        // 768 = 512 (1 回) + 端数 256
        analyzer.ingest(try buffer(frequency: 440, amplitude: 0.5, frames: 768))
        XCTAssertEqual(callCount, 1)

        // 端数 256 が残っているので、さらに 256 で hop に到達する。
        analyzer.ingest(try buffer(frequency: 440, amplitude: 0.5, frames: 256))
        XCTAssertEqual(callCount, 2)
    }

    /// hop ごとの窓は「その時点までのサンプル」で切られる。
    /// 無音 → 正弦波と流したとき、最初の hop はまだ無音を多く含み、後の hop ほどエネルギーが上がる。
    func testEachHopUsesItsOwnWindow() throws {
        var configuration = AudioAnalyzer.Configuration.default
        configuration.fftSize = 1024
        configuration.hopSize = 256
        let analyzer = AudioAnalyzer(configuration: configuration)

        var results: [AnalysisResult] = []
        analyzer.onResult = { results.append($0) }

        analyzer.ingest(try silentBuffer(frames: 1024))
        results.removeAll()
        analyzer.ingest(try buffer(frequency: 100, amplitude: 0.5, frames: 1024))

        XCTAssertEqual(results.count, 4)
        // 4 つの窓がすべて同一なら「まとめて 1 回」と変わらない。異なることを確認する。
        XCTAssertNotEqual(results[0].waveform, results[3].waveform)
        XCTAssertGreaterThan(results[3].energy.low, results[0].energy.low)
    }

    /// ステレオ入力はモノラルに畳まれる (逆位相を入れると打ち消し合う)。
    func testStereoIsMixedDownToMono() throws {
        let analyzer = AudioAnalyzer()
        var results: [AnalysisResult] = []
        analyzer.onResult = { results.append($0) }

        analyzer.ingest(try stereoBuffer(frequency: 100, amplitude: 0.5, frames: 2048, invertRightChannel: true))

        let result = try XCTUnwrap(results.last)
        XCTAssertTrue(result.waveform.allSatisfy { abs($0) < 0.001 })
    }

    /// FFT サイズを変えると出力ビン数も変わる。
    func testUpdatingFFTSizeChangesBinCount() throws {
        let analyzer = AudioAnalyzer()
        var results: [AnalysisResult] = []
        analyzer.onResult = { results.append($0) }

        var configuration = AudioAnalyzer.Configuration.default
        configuration.fftSize = 4096
        analyzer.updateConfiguration(configuration)

        analyzer.ingest(try buffer(frequency: 440, amplitude: 0.5, frames: 4096))

        let result = try XCTUnwrap(results.last)
        XCTAssertEqual(result.fftSize, 4096)
        XCTAssertEqual(result.magnitudes.count, 2048)
    }

    /// 描画用の間引きはピークを保つ。
    func testDownsampleKeepsPeaks() {
        var samples = [Float](repeating: 0, count: 1000)
        samples[10] = 0.9
        samples[900] = -0.8

        let downsampled = AudioAnalyzer.downsample(samples, to: 100)

        XCTAssertEqual(downsampled.count, 100)
        XCTAssertEqual(downsampled[1], 0.9, accuracy: 0.0001)
        XCTAssertEqual(downsampled[90], -0.8, accuracy: 0.0001)
    }

    func testDownsampleReturnsInputWhenAlreadyShort() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        XCTAssertEqual(AudioAnalyzer.downsample(samples, to: 100), samples)
        XCTAssertEqual(AudioAnalyzer.downsample(samples, to: 0), [])
    }

    // MARK: - Helpers

    private func buffer(frequency: Double, amplitude: Float, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames

        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) {
            channel[index] = amplitude * sinf(Float(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
        return buffer
    }

    /// `frames` サンプルにちょうど整数周期入る周波数。バッファを繰り返しても波形が連続する。
    private func binAlignedFrequency(bin: Int, frames: Int) -> Double {
        Double(bin) * sampleRate / Double(frames)
    }

    private func feed(_ analyzer: AudioAnalyzer, frequency: Double, frames: AVAudioFrameCount, times: Int) throws {
        let input = try buffer(frequency: frequency, amplitude: 0.5, frames: frames)
        for _ in 0..<times { analyzer.ingest(input) }
    }

    private func silentBuffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        try buffer(frequency: 0, amplitude: 0, frames: frames)
    }

    private func stereoBuffer(frequency: Double, amplitude: Float, frames: AVAudioFrameCount, invertRightChannel: Bool) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames

        let channels = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<Int(frames) {
            let value = amplitude * sinf(Float(2 * Double.pi * frequency * Double(index) / sampleRate))
            channels[0][index] = value
            channels[1][index] = invertRightChannel ? -value : value
        }
        return buffer
    }
}
