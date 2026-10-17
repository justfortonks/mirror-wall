import Darwin
import Foundation

/// Receives UDP datagrams on 127.0.0.1:port on a dedicated thread.
final class UDPReceiver {
    enum Failure: Error, CustomStringConvertible {
        case socket(Int32)
        case bind(port: UInt16, errno: Int32)

        var description: String {
            switch self {
            case .socket(let code): return "couldn't open a UDP socket (\(String(cString: strerror(code))))"
            case .bind(let port, let code): return "couldn't listen on UDP port \(port) (\(String(cString: strerror(code))))"
            }
        }
    }

    let port: UInt16
    private let onDatagram: ([UInt8]) -> Void
    private let lock = NSLock()
    private var running = false
    private let finished = DispatchGroup()

    /// `onDatagram` is called on the receiver's own thread.
    init(port: UInt16, onDatagram: @escaping ([UInt8]) -> Void) {
        self.port = port
        self.onDatagram = onDatagram
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var bufferSize: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        // Wake up regularly so stop() takes effect even when nothing is arriving.
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw Failure.bind(port: port, errno: code)
        }

        finished.enter()
        setRunning(true)
        let thread = Thread { [self] in receiveLoop(fd) }
        thread.name = "MirrorWall UDP \(port)"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops receiving and waits for the receive thread to finish, so no callback runs after this returns.
    func stop() {
        setRunning(false)
        finished.wait()
    }

    private func receiveLoop(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while isRunning {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0, isRunning {
                onDatagram(Array(buffer[0..<count]))
            }
        }
        close(fd)
        finished.leave()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func setRunning(_ value: Bool) {
        lock.lock()
        running = value
        lock.unlock()
    }
}
