import Foundation
import CoreMedia
import IOSDirectShared

/// Only metadata and at most 1 MiB of compressed data are admitted under this lock.
/// Dispatch blocks capture self, never an access unit, so dispatch cannot bypass the bound.
final class StubSink {
    private struct Unit { let data: Data; let pts: Double; let generation: Int }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "iosdirect.stub")
    private var pending = BoundedQueue<Unit>()
    private var scheduled = false
    private var generation = 0
    private var hash: UInt64 = 0xcbf29ce484222325
    private let metrics: Telemetry
    var requestIDR: (() -> Void)? // Assigned once before capture begins; no payload captured.
    init(metrics: Telemetry) { self.metrics = metrics }

    func begin(generation: Int) {
        lock.lock(); self.generation = generation; pending.removeAll(); publish(); lock.unlock()
        // Finish an already draining unit before returning from stop/reconfiguration.
        queue.sync {}
    }
    func resetHash() {
        queue.sync { hash = 0xcbf29ce484222325 }
    }
    func sampleQueue() {
        lock.lock()
        let before = pending.drops
        pending.expire(now: uptime())
        let dropped = pending.drops - before
        metrics.update { $0.sinkDrops += dropped }
        publish(); lock.unlock()
        if dropped > 0 { requestIDR?() }
    }
    func enqueue(_ data: Data, pts: Double, generation: Int) {
        lock.lock()
        guard generation == self.generation else { lock.unlock(); return }
        let before = pending.drops
        let accepted = pending.enqueue(Unit(data: data, pts: pts, generation: generation), bytes: data.count, now: uptime())
        let dropped = pending.drops - before
        metrics.update { $0.sinkDrops += dropped; if accepted { $0.sinkEnqueued += 1 } }
        publish()
        if !scheduled && pending.count > 0 { scheduled = true; queue.async { self.drain() } }
        lock.unlock()
        if dropped > 0 { requestIDR?() }
    }
    private func publish() {
        metrics.update { $0.sinkQueueBytes = pending.bytes; $0.sinkQueueAgeMS = pending.age(now: uptime()) * 1000 }
    }
    private func drain() {
        while true {
            lock.lock()
            let before = pending.drops
            let unit = pending.dequeue(now: uptime())
            let dropped = pending.drops - before
            metrics.update { $0.sinkDrops += dropped }
            publish()
            guard let unit else {
                scheduled = false; lock.unlock()
                if dropped > 0 { requestIDR?() }; return
            }
            // Hash while locked: stop cannot admit an obsolete unit after its barrier.
            if unit.generation == generation {
                for byte in unit.data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
                metrics.update {
                    $0.sinkDrained += 1; $0.sinkBytes += unit.data.count
                    $0.sinkLatestPTS = unit.pts; $0.sinkHash = String(hash, radix: 16)
                }
            }
            lock.unlock()
            if dropped > 0 { requestIDR?() }
        }
    }
}
