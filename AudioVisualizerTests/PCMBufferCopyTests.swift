import AVFoundation
import XCTest
@testable import AudioVisualizer

/// `installTap` のバッファを別スレッドへ渡すためのコピーを検証する。
///
/// タップに渡る `AVAudioPCMBuffer` はエンジンが使い回すため、コピーを取らずに
/// `receive(on:)` で別キューへ流すと、読む頃には中身も frameLength も失われている。
/// (症状: 解析結果が一切出ず、波形も背景色も動かない)
final class PCMBufferCopyTests: XCTestCase {

    private func makeBuffer(frames: AVAudioFrameCount, channels: AVAudioChannelCount, fill: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) { data[c][i] = fill(c, i) }
        }
        return buffer
    }

    func testCopyPreservesSamplesAndFrameLength() throws {
        let original = makeBuffer(frames: 512, channels: 1) { _, i in sinf(Float(i) / 512 * 4 * .pi) }
        let copy = try XCTUnwrap(original.copyForAsyncDelivery())

        XCTAssertEqual(copy.frameLength, original.frameLength)
        XCTAssertEqual(copy.format.channelCount, original.format.channelCount)
        XCTAssertEqual(copy.format.sampleRate, original.format.sampleRate)

        let source = original.floatChannelData![0]
        let copied = copy.floatChannelData![0]
        for i in 0..<Int(original.frameLength) {
            XCTAssertEqual(copied[i], source[i], accuracy: 1e-6)
        }
    }

    func testCopyIsIndependentOfEngineBufferReuse() throws {
        let original = makeBuffer(frames: 256, channels: 1) { _, i in Float(i) }
        let copy = try XCTUnwrap(original.copyForAsyncDelivery())

        // エンジンがバッファを使い回す状況を再現する。
        let data = original.floatChannelData![0]
        for i in 0..<256 { data[i] = 0 }
        original.frameLength = 0

        XCTAssertEqual(copy.frameLength, 256, "コピー側が元バッファの再利用に巻き込まれている")
        let copied = copy.floatChannelData![0]
        for i in 0..<256 {
            XCTAssertEqual(copied[i], Float(i), accuracy: 1e-6)
        }
    }

    func testCopyHandlesMultipleChannels() throws {
        let original = makeBuffer(frames: 128, channels: 2) { c, i in Float(c) * 100 + Float(i) }
        let copy = try XCTUnwrap(original.copyForAsyncDelivery())

        XCTAssertEqual(copy.format.channelCount, 2)
        let copied = copy.floatChannelData!
        for c in 0..<2 {
            for i in 0..<128 {
                XCTAssertEqual(copied[c][i], Float(c) * 100 + Float(i), accuracy: 1e-6)
            }
        }
    }

    func testEmptyBufferIsNotCopied() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        empty.frameLength = 0

        XCTAssertNil(empty.copyForAsyncDelivery())
    }
}
