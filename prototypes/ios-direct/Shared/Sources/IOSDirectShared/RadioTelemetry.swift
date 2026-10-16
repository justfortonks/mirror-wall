import Foundation
import Network
import Darwin

public struct RadioPath: Codable {
    public var status: String
    public var availableInterfaces: [String]
    public var wifi: Bool
    public var wired: Bool
    public var other: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var localEndpoint: String?
    public var remoteEndpoint: String?
    public init(_ path: NWPath) {
        status = String(describing: path.status)
        availableInterfaces = path.availableInterfaces.map { "\($0.name):\($0.type):\($0.index)" }
        wifi = path.usesInterfaceType(.wifi); wired = path.usesInterfaceType(.wiredEthernet); other = path.usesInterfaceType(.other)
        isExpensive = path.isExpensive; isConstrained = path.isConstrained
        localEndpoint = path.localEndpoint.map { String(describing: $0) }
        remoteEndpoint = path.remoteEndpoint.map { String(describing: $0) }
    }
}
public struct RadioSnapshot: Codable, Identifiable {
    public var kind = "radio.metrics"
    public var id = UUID() // Connection/session routing ID, never a display name.
    public var installID: UUID?
    public var label = "pending"
    public var monotonicNs: UInt64 = 0
    public var wallTime = ""
    public var state = "setup"
    public var error: String?
    public var path: RadioPath?
    public var endpoint = ""
    public var tlsVersion: UInt16?
    public var cipherSuite: UInt16?
    public var sentBytes: UInt64 = 0 // Successful NW contentProcessed payload bytes.
    public var deliveredBytes: UInt64 = 0 // ACKed on sender; validated/ACK-submitted on receiver.
    public var receivedWireBytes: UInt64 = 0
    public var sentWireBytes: UInt64 = 0
    public var sentMbit: Double = 0
    public var deliveredMbit: Double = 0
    public var rttMedianMS: Double?
    public var rttP95MS: Double?
    public var seqGaps: UInt64 = 0
    public var crcFailures: UInt64 = 0
    public var outstandingBytes = 0
    public var sendBlockedMS: Double = 0
    public var pendingNetworkBytes = 0
    public var thermal = "unknown"
    public var residentMemoryMB: Double?
    public init() {}
}

public func radioThermalState() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

public func radioMemoryMB() -> Double? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : nil
}

/// Dedicated disk queue keeps fsync off the pacing queue. Bounded metadata backlog;
/// any overflow/write failure is visible and persists as a failure instead of silent loss.
public final class RadioLog {
    public let url: URL
    private let queue = DispatchQueue(label: "iosdirect.radio.log", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var failure: String?
    private let handle: FileHandle
    public init(receiver: Bool) throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(receiver ? "IOSDirectPOC-Receiver/logs" : "IOSDirectPOC/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        url = directory.appendingPathComponent("radio-\(stamp)-\(UUID().uuidString.prefix(8)).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }
    public func error() -> String? { lock.lock(); defer { lock.unlock() }; return failure }
    public func write<T: Encodable>(_ item: T) {
        lock.lock()
        guard pending < 128, failure == nil else {
            if failure == nil { failure = "radio log backlog exceeded 128 records" }; lock.unlock(); return
        }
        pending += 1; lock.unlock()
        do {
            let line = try JSONLine.encode(item)
            queue.async {
                do { try self.handle.write(contentsOf: line); try self.handle.synchronize() }
                catch { self.lock.lock(); self.failure = error.localizedDescription; self.lock.unlock() }
                self.lock.lock(); self.pending -= 1; self.lock.unlock()
            }
        } catch { lock.lock(); pending -= 1; failure = error.localizedDescription; lock.unlock() }
    }
    public func event(_ name: String, _ details: String = "") {
        write(Event(monotonicTime: Double(radioNow()) / 1e9,
            wallTime: ISO8601DateFormatter().string(from: Date()), name: name, details: details))
    }
    deinit { try? handle.close() }
}
