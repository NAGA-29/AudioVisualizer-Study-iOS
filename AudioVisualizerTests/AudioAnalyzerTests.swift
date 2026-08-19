import AVFoundation
import XCTest
@testable import AudioVisualizer

final class AudioAnalyzerTests: XCTestCase {

    private let sampleRate: Double = 44_100

    /// 100Hz の正弦波を流し込むと low 帯だけが立つ (パイプライン全体の疎通確認)。
    func testLowFrequencyToneRaisesLowBand() throws {
        var configuration = AudioAnalyzer.Configuration.default
        configuration.fftSize = 2048
        let analyzer = AudioAnalyzer(configuration: configuration)

        var results: [AnalysisResult] = []
        analyzer.onResult = { results.append($0) }

        analyzer.ingest(try buffer(frequency: 100, amplitude: 0.5, frames: 2048))

        let result = try XCTUnwrap(results.last)
        XCTAssertEqual(result.fftSize, 2048)
        XCTAssertEqual(result.magnitudes.count, 1024)
        XCTAssertEqual(result.sampleRate, sampleRate)
        XCTAssertGreaterThan(result.energy.low, 0.5)
        XCTAssertLessThan(result.energy.mid, 0.2)
    }

    /// 10kHz なら high 帯が立つ。
    func testHighFrequencyToneRaisesHighBand() throws {
        let analyzer = AudioAnalyzer()
        var results: [AnalysisResult] = []
        analyzer.onResult = { results.append($0) }

        analyzer.ingest(try buffer(frequency: 10_000, amplitude: 0.5, frames: 2048))

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
