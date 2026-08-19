import Accelerate
import Foundation

/// Accelerate (vDSP) による実数入力 FFT。
///
/// - 入力長は 2 の累乗 (足りなければゼロパディング、多ければ直近 `size` サンプルを使用)
/// - 窓関数は Hann 窓 (サイドローブ漏れ対策。実装が簡単で音楽用途には十分)
/// - 出力は linear magnitude 配列 (長さ `size / 2`)。dB 変換は `BandAnalyzer` 側のオプション。
///
/// スレッド安全ではない。専用の `DispatchQueue` 上からのみ触ること。
final class FFTProcessor {

    enum Failure: Error, Equatable {
        /// 2 の累乗でない / 小さすぎるサイズ
        case invalidSize(Int)
        case setupFailed
    }

    /// FFT 長 (サンプル数)。
    let size: Int
    /// 出力されるビン数。
    var binCount: Int { size / 2 }

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var input: [Float]
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]

    /// vDSP_fft_zrip の出力は真の DFT 係数の 2 倍。さらに Hann 窓のコヒーレントゲイン 0.5 を補正するため、
    /// `2 / size` を掛けると「振幅 A の正弦波 → 該当ビンの magnitude ≒ A」になる。
    private let normalizationScale: Float

    init(size: Int) throws {
        guard size >= 32, size.nonzeroBitCount == 1 else { throw Failure.invalidSize(size) }
        self.size = size
        self.log2n = vDSP_Length(round(log2(Double(size))))

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw Failure.setupFailed
        }
        self.setup = setup

        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        self.window = window

        self.input = [Float](repeating: 0, count: size)
        self.windowed = [Float](repeating: 0, count: size)
        self.realp = [Float](repeating: 0, count: size / 2)
        self.imagp = [Float](repeating: 0, count: size / 2)

        // Hann 窓のコヒーレントゲイン = 0.5
        let hannCoherentGain: Float = 0.5
        self.normalizationScale = 1 / (Float(size) * hannCoherentGain)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// linear magnitude スペクトルを返す (長さ `binCount`)。
    /// index 0 は DC 成分、index k の中心周波数は `frequency(forBin:sampleRate:)`。
    func magnitudes(of samples: [Float]) -> [Float] {
        // --- 入力を size に揃える (不足分はゼロパディング) ---
        if samples.count >= size {
            let start = samples.count - size
            for i in 0..<size { input[i] = samples[start + i] }
        } else {
            for i in 0..<samples.count { input[i] = samples[i] }
            for i in samples.count..<size { input[i] = 0 }
        }

        // --- Hann 窓 ---
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(size))

        var result = [Float](repeating: 0, count: binCount)
        let count = vDSP_Length(binCount)
        let log2n = self.log2n
        let setup = self.setup

        windowed.withUnsafeBufferPointer { windowedPtr in
            realp.withUnsafeMutableBufferPointer { realPtr in
                imagp.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                    // 実数列を偶数/奇数に分けて split complex に詰める (実数 FFT の前処理)。
                    windowedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: binCount) { interleaved in
                        vDSP_ctoz(interleaved, 2, &split, 1, count)
                    }

                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    // zrip は Nyquist 成分を imagp[0] に詰め込む仕様。
                    // ここで潰しておかないと bin 0 (DC) の magnitude に混ざる。
                    imagPtr[0] = 0

                    result.withUnsafeMutableBufferPointer { out in
                        vDSP_zvabs(&split, 1, out.baseAddress!, 1, count)
                    }
                }
            }
        }

        var scale = normalizationScale
        result.withUnsafeMutableBufferPointer { buffer in
            vDSP_vsmul(buffer.baseAddress!, 1, &scale, buffer.baseAddress!, 1, count)
        }
        return result
    }

    /// ビン index → 中心周波数 (Hz)。
    func frequency(forBin bin: Int, sampleRate: Double) -> Double {
        Double(bin) * sampleRate / Double(size)
    }

    /// 周波数 (Hz) → ビン index (0..<binCount にクランプ)。
    func binIndex(for frequency: Double, sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return 0 }
        let raw = Int((frequency * Double(size) / sampleRate).rounded())
        return min(max(raw, 0), binCount - 1)
    }
}
