import Darwin
import Foundation

/// A process-owned advisory lock, released by the OS even if the app crashes.
final class InstanceLock {
    private var fd: Int32 = -1
    func acquire(at url: URL) -> Bool {
        guard fd < 0 else { return true }
        let candidate = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard candidate >= 0 else { return false }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else { close(candidate); return false }
        fd = candidate
        return true
    }
    deinit { if fd >= 0 { close(fd) } }
}
