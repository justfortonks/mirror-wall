import XCTest
import Darwin
@testable import MirrorWall

final class ReceiverLifecycleTests: XCTestCase {
    func testStopDrainsSlowCallback() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let receiver = UDPReceiver(port: 59647) { _ in
            entered.signal()
            release.wait()
            completed.signal()
        }
        try receiver.start()
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(59647).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var byte: UInt8 = 1
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.3) { release.signal() }
        receiver.stop()
        XCTAssertEqual(completed.wait(timeout: .now()), .success, "Stop returned before its callback finished")
    }
}
