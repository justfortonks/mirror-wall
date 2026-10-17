import Foundation

/// Captured by each transport and its queued UI work. Invalidating it prevents stale delivery;
/// teardown still drains in-flight work before resetting the decoder.
final class StreamLifetime {
    private let lock = NSLock()
    private var active = true
    private var revision = 0
    var stamp: Int { lock.withLock { revision } }
    func advance() { lock.withLock { revision += 1 } }
    func isCurrent(_ stamp: Int) -> Bool { lock.withLock { active && revision == stamp } }
    var isActive: Bool { lock.withLock { active } }
    func invalidate() { lock.withLock { active = false } }
}
