import Foundation

/// FFT へ一定長のサンプルを供給するためのリングバッファ。
///
/// タップのバッファサイズと FFT 長を独立に扱うために挟む。
/// (例: tap=1024 / FFT=4096 でも、1024 サンプル入るたびに直近 4096 サンプルで FFT を回せる)
struct SampleRingBuffer {

    private var storage: [Float]
    private var writeIndex = 0
    /// これまでに書き込まれた有効サンプル数 (最大 `capacity`)。
    private(set) var count = 0

    var capacity: Int { storage.count }
    var isFull: Bool { count == capacity }

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        storage = [Float](repeating: 0, count: capacity)
    }

    mutating func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        // 容量より長い入力は、末尾 capacity 分だけ残せばよい。
        let incoming = min(samples.count, capacity)
        let offset = samples.count - incoming

        for i in 0..<incoming {
            storage[writeIndex] = base[offset + i]
            writeIndex = (writeIndex + 1) % capacity
        }
        count = min(count + incoming, capacity)
    }

    mutating func write(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { write($0) }
    }

    /// 直近 `n` サンプルを古い順に返す。埋まっていない分は 0 で前詰めされる。
    func latest(_ n: Int) -> [Float] {
        let n = min(n, capacity)
        var out = [Float](repeating: 0, count: n)
        let available = min(count, n)
        guard available > 0 else { return out }

        // writeIndex は「次に書く位置」= 最新サンプルの 1 つ後ろ。
        var readIndex = (writeIndex - available + capacity * 2) % capacity
        for i in (n - available)..<n {
            out[i] = storage[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        return out
    }

    mutating func reset() {
        for i in storage.indices { storage[i] = 0 }
        writeIndex = 0
        count = 0
    }

    mutating func resize(capacity newCapacity: Int) {
        guard newCapacity != capacity else { return }
        storage = [Float](repeating: 0, count: max(1, newCapacity))
        writeIndex = 0
        count = 0
    }
}
