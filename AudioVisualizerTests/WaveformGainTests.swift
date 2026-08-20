import AVFoundation
import XCTest
@testable import AudioVisualizer

/// 波形表示の自動ゲインを検証する。
///
/// 波形はフルスケール前提で描かれるため、離れた音源 (振幅 0.03 程度) を素のまま描くと
/// ほぼ直線に見える。自動ゲインは表示上だけ持ち上げる仕組みで、FFT や帯域エネルギーには
/// 影響してはいけない。
final class WaveformGainTests: XCTestCase {

    private let sampleRate: Double = 48_000

    /// 指定振幅のサイン波バッファを作る。
    private func makeBuffer(amplitude: Float, frames: AVAudioFrameCount = 2048) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            data[i] = amplitude * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }
        return buffer
    }

    /// 解析器に何度か流し込み、最後の結果を返す。
    private func lastResult(amplitude: Float, configuration: AudioAnalyzer.Configuration, iterations: Int = 40) -> AnalysisResult? {
        let analyzer = AudioAnalyzer(configuration: configuration)
        var result: AnalysisResult?
        analyzer.onResult = { result = $0 }
        for _ in 0..<iterations {
            analyzer.ingest(makeBuffer(amplitude: amplitude))
        }
        return result
    }

    private func configuration(automatic: Bool = true, manualGain: Float = 1) -> AudioAnalyzer.Configuration {
        var configuration = AudioAnalyzer.Configuration.default
        configuration.waveformGain.isAutomatic = automatic
        configuration.waveformGain.manualGain = manualGain
        return configuration
    }

    /// 小さい入力でも波形が目に見える振幅まで持ち上がる。
    func testQuietInputIsAmplifiedToVisibleAmplitude() throws {
        let result = try XCTUnwrap(lastResult(amplitude: 0.03, configuration: configuration()))
        let peak = result.waveform.map(abs).max() ?? 0

        XCTAssertGreaterThan(result.waveformGain, 5, "小音量なのにゲインが掛かっていない")
        XCTAssertGreaterThan(peak, 0.4, "増幅後も波形が小さすぎる: \(peak)")
    }

    /// 大きい入力ではゲインを掛けない (歪ませない)。
    func testLoudInputIsNotAmplified() throws {
        let result = try XCTUnwrap(lastResult(amplitude: 0.9, configuration: configuration()))
        XCTAssertEqual(result.waveformGain, 1, accuracy: 0.001)
    }

    /// 音量が違っても、増幅後の波形はおおむね同じ振れ幅に揃う。
    func testDifferentLevelsConvergeToSimilarAmplitude() throws {
        let quiet = try XCTUnwrap(lastResult(amplitude: 0.02, configuration: configuration()))
        let medium = try XCTUnwrap(lastResult(amplitude: 0.2, configuration: configuration()))

        let quietPeak = quiet.waveform.map(abs).max() ?? 0
        let mediumPeak = medium.waveform.map(abs).max() ?? 0
        XCTAssertEqual(quietPeak, mediumPeak, accuracy: 0.2)
    }

    /// 無音はノイズごと持ち上げない。
    func testSilenceIsNotAmplified() throws {
        let result = try XCTUnwrap(lastResult(amplitude: 0, configuration: configuration()))
        XCTAssertEqual(result.waveformGain, 1, accuracy: 0.001)
        XCTAssertEqual(result.waveform.map(abs).max() ?? 0, 0, accuracy: 0.0001)
    }

    /// 増幅してもクリップ範囲を超えない。
    func testAmplifiedWaveformStaysInUnitRange() throws {
        let result = try XCTUnwrap(lastResult(amplitude: 0.001, configuration: configuration()))
        for sample in result.waveform {
            XCTAssertTrue((-1...1).contains(sample), "範囲外: \(sample)")
        }
    }

    /// 自動を切れば固定倍率がそのまま適用される。
    func testManualGainIsAppliedWhenAutomaticIsOff() throws {
        let result = try XCTUnwrap(lastResult(amplitude: 0.1, configuration: configuration(automatic: false, manualGain: 6)))
        XCTAssertEqual(result.waveformGain, 6, accuracy: 0.001)
    }

    /// 表示ゲインは解析結果 (FFT / 帯域エネルギー) に影響しない。
    /// ここが崩れると「見た目を上げたら色まで変わる」ことになる。
    func testGainDoesNotAffectSpectrumOrEnergy() throws {
        let amplified = try XCTUnwrap(lastResult(amplitude: 0.05, configuration: configuration()))
        let plain = try XCTUnwrap(lastResult(amplitude: 0.05, configuration: configuration(automatic: false, manualGain: 1)))

        XCTAssertGreaterThan(amplified.waveformGain, 1, "前提: 自動ゲインが掛かっていること")
        XCTAssertEqual(amplified.energy.overall, plain.energy.overall, accuracy: 0.0001)
        XCTAssertEqual(amplified.magnitudes.count, plain.magnitudes.count)
        for (a, b) in zip(amplified.magnitudes, plain.magnitudes) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
    }
}
