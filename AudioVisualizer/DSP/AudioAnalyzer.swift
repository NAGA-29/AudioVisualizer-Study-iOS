import AVFoundation
import Foundation

/// 1 回の解析結果。描画層はこれだけ見ればよい。
struct AnalysisResult: Sendable {
    /// 描画用にダウンサンプルした波形 (-1.0〜1.0 目安)。
    var waveform: [Float]
    /// linear magnitude スペクトル (長さ fftSize / 2)。
    var magnitudes: [Float]
    var energy: BandEnergy
    var sampleRate: Double
    var fftSize: Int
    /// FFT / 正規化を通す前の生サンプルのピーク絶対値 (0.0〜1.0)。
    ///
    /// 「マイクが本当に無音を返しているのか、拾えているが正規化で潰れているのか」を
    /// 切り分けるための診断値。帯域エネルギーとは独立で、一切の平滑化もかけない。
    var inputPeak: Float

    static let empty = AnalysisResult(waveform: [], magnitudes: [], energy: .silent, sampleRate: 0, fftSize: 0, inputPeak: 0)

    /// 生入力のピークを dBFS で返す。無音のときは -infinity ではなく -120 に丸める。
    var inputPeakDb: Float { inputPeak > 0 ? max(-120, 20 * log10(inputPeak)) : -120 }
}

/// PCM バッファ → FFT → 帯域エネルギー までを担う解析パイプライン。
///
/// `AudioInputSource` の実装 (マイク / プレイヤータップ) には依存しない。
///
/// スレッド安全ではない。呼び出しは常に同じ専用キュー (`VisualizerEngine` の解析キュー) に閉じている
/// 前提で `@unchecked Sendable` にしている。他のスレッドから直接触らないこと。
final class AudioAnalyzer: @unchecked Sendable {

    struct Configuration: Equatable {
        /// FFT 長。1024 / 2048 / 4096 を比較するのが検証観点 1。
        var fftSize: Int = 2048
        /// 何サンプル溜まるごとに FFT を回すか。小さいほど更新が滑らか (CPU は増える)。
        /// nil のときは fftSize / 4 を使う。
        var hopSize: Int?
        /// 描画用波形の点数。
        var waveformPoints: Int = 256
        var band = BandAnalyzer.Configuration.default

        static let `default` = Configuration()

        func resolvedHopSize() -> Int {
            max(64, hopSize ?? fftSize / 4)
        }
    }

    /// 解析結果のコールバック。呼び出しは `ingest(_:)` と同じキュー上。
    var onResult: ((AnalysisResult) -> Void)?

    private(set) var configuration: Configuration
    private var fft: FFTProcessor
    private let bandAnalyzer: BandAnalyzer
    private var ring: SampleRingBuffer
    private var samplesSinceLastFFT = 0
    private var monoScratch: [Float] = []
    /// 前回の emit 以降に流れ込んだ生サンプルのピーク。emit のたびにリセットする。
    private var inputPeakSinceLastFFT: Float = 0

    init(configuration: Configuration = .default) {
        self.configuration = configuration
        // 既定サイズは 2 の累乗を保証しているので失敗しないが、念のため 2048 にフォールバック。
        self.fft = (try? FFTProcessor(size: configuration.fftSize)) ?? (try! FFTProcessor(size: 2048))
        self.bandAnalyzer = BandAnalyzer(configuration: configuration.band)
        self.ring = SampleRingBuffer(capacity: self.fft.size)
    }

    func updateConfiguration(_ newValue: Configuration) {
        let sizeChanged = newValue.fftSize != configuration.fftSize
        configuration = newValue
        bandAnalyzer.updateConfiguration(newValue.band)

        if sizeChanged, let processor = try? FFTProcessor(size: newValue.fftSize) {
            fft = processor
            ring.resize(capacity: processor.size)
            samplesSinceLastFFT = 0
            bandAnalyzer.reset()
        }
    }

    func reset() {
        ring.reset()
        samplesSinceLastFFT = 0
        inputPeakSinceLastFFT = 0
        bandAnalyzer.reset()
    }

    /// タップから来た PCM バッファを取り込み、hop ごとに解析結果を `onResult` へ返す。
    func ingest(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channels = buffer.floatChannelData else { return }

        // マルチチャンネルは平均してモノラル化する。
        let channelCount = Int(buffer.format.channelCount)
        if monoScratch.count != frameCount {
            monoScratch = [Float](repeating: 0, count: frameCount)
        }
        if channelCount == 1 {
            let source = channels[0]
            for i in 0..<frameCount { monoScratch[i] = source[i] }
        } else {
            let scale = 1 / Float(channelCount)
            for i in 0..<frameCount {
                var sum: Float = 0
                for c in 0..<channelCount { sum += channels[c][i] }
                monoScratch[i] = sum * scale
            }
        }

        // 生サンプルのピークを控えておく (診断用。ここは FFT も正規化も通っていない値)。
        for i in 0..<frameCount {
            let magnitude = abs(monoScratch[i])
            if magnitude > inputPeakSinceLastFFT { inputPeakSinceLastFFT = magnitude }
        }

        // hop 単位で区切って書き込む。
        // 1 バッファに複数 hop 含まれる場合 (例: tap 4096 / hop 256) にまとめて 1 回しか解析しないと、
        // 更新間隔が hop ではなくタップ間隔になってしまう。区切って処理することで
        // 「更新頻度は hop で決まる」という前提を実際に守る。
        let hop = configuration.resolvedHopSize()
        let sampleRate = buffer.format.sampleRate
        var offset = 0

        while offset < frameCount {
            let chunk = min(hop - samplesSinceLastFFT, frameCount - offset)
            monoScratch.withUnsafeBufferPointer { pointer in
                ring.write(UnsafeBufferPointer(rebasing: pointer[offset..<(offset + chunk)]))
            }
            offset += chunk
            samplesSinceLastFFT += chunk

            guard samplesSinceLastFFT >= hop else { break }
            samplesSinceLastFFT = 0
            emitResult(sampleRate: sampleRate)
        }
    }

    private func emitResult(sampleRate: Double) {
        guard onResult != nil else { return }

        let window = ring.latest(fft.size)
        let magnitudes = fft.magnitudes(of: window)
        let energy = bandAnalyzer.analyze(magnitudes: magnitudes, sampleRate: sampleRate)

        onResult?(AnalysisResult(
            waveform: Self.downsample(window, to: configuration.waveformPoints),
            magnitudes: magnitudes,
            energy: energy,
            sampleRate: sampleRate,
            fftSize: fft.size,
            inputPeak: inputPeakSinceLastFFT
        ))
        inputPeakSinceLastFFT = 0
    }

    /// 波形描画用の間引き。ブロックごとに絶対値最大のサンプルを採用し、ピークを潰さない。
    static func downsample(_ samples: [Float], to points: Int) -> [Float] {
        guard points > 0 else { return [] }
        guard samples.count > points else { return samples }

        var out = [Float](repeating: 0, count: points)
        let blockSize = Double(samples.count) / Double(points)
        for i in 0..<points {
            let start = Int(Double(i) * blockSize)
            let end = min(samples.count, max(start + 1, Int(Double(i + 1) * blockSize)))
            var peak: Float = 0
            for j in start..<end where abs(samples[j]) > abs(peak) {
                peak = samples[j]
            }
            out[i] = peak
        }
        return out
    }
}
