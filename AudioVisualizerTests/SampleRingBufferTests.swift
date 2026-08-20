import XCTest
@testable import AudioVisualizer

final class SampleRingBufferTests: XCTestCase {

    func testLatestIsZeroPaddedBeforeBufferIsFull() {
        var ring = SampleRingBuffer(capacity: 8)
        ring.write([1, 2, 3])

        XCTAssertEqual(ring.count, 3)
        XCTAssertFalse(ring.isFull)
        XCTAssertEqual(ring.latest(8), [0, 0, 0, 0, 0, 1, 2, 3])
    }

    func testLatestReturnsSamplesInChronologicalOrder() {
        var ring = SampleRingBuffer(capacity: 4)
        ring.write([1, 2, 3, 4])
        XCTAssertEqual(ring.latest(4), [1, 2, 3, 4])
    }

    /// 書き込みが一周しても、直近 capacity 分が古い順で取り出せる。
    func testWrapAroundKeepsMostRecentSamples() {
        var ring = SampleRingBuffer(capacity: 4)
        ring.write([1, 2, 3, 4])
        ring.write([5, 6])

        XCTAssertTrue(ring.isFull)
        XCTAssertEqual(ring.latest(4), [3, 4, 5, 6])
    }

    /// capacity より長い入力は末尾だけ残る。
    func testWritingMoreThanCapacityKeepsTail() {
        var ring = SampleRingBuffer(capacity: 4)
        ring.write([1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(ring.latest(4), [6, 7, 8, 9])
    }

    func testLatestSmallerThanCapacity() {
        var ring = SampleRingBuffer(capacity: 8)
        ring.write([1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(ring.latest(3), [6, 7, 8])
    }

    func testResetClearsContents() {
        var ring = SampleRingBuffer(capacity: 4)
        ring.write([1, 2, 3, 4])
        ring.reset()

        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.latest(4), [0, 0, 0, 0])
    }

    func testResizeChangesCapacityAndClears() {
        var ring = SampleRingBuffer(capacity: 4)
        ring.write([1, 2, 3, 4])
        ring.resize(capacity: 8)

        XCTAssertEqual(ring.capacity, 8)
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.latest(8), [Float](repeating: 0, count: 8))
    }

    func testEmptyWriteIsIgnored() {
        var ring = SampleRingBuffer(capacity: 4)
        ring.write([])
        XCTAssertEqual(ring.count, 0)
    }
}
