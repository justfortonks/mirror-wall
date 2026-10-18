import Foundation
import UIKit
import IOSDirectShared
import Darwin

func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
func wallTime() -> String { ISO8601DateFormatter().string(from: Date()) }

/// Lock protects small metadata only. No capture or encoder calls while holding it.
final class Telemetry {
    private let lock = NSLock()
    private var value = MetricsSnapshot()
    func update(_ body: (inout MetricsSnapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }; body(&value)
    }
    func snapshot() -> MetricsSnapshot {
        lock.lock(); defer { lock.unlock() }; return value
    }
    func reset() {
        update { old in
            var fresh = MetricsSnapshot()
            fresh.resetEpoch = old.resetEpoch + 1
            fresh.appState = old.appState; fresh.captureState = old.captureState
            fresh.encoderState = old.encoderState; fresh.encoderLastFailingOSStatus = old.encoderLastFailingOSStatus
            fresh.encoderRetryAfter = old.encoderRetryAfter
            fresh.dimensions = old.dimensions; fresh.generation = old.generation
            fresh.streamPreset = old.streamPreset; fresh.maxFPS = old.maxFPS; fresh.bitrate = old.bitrate
            fresh.sourceDimensions = old.sourceDimensions; fresh.frameOrientation = old.frameOrientation
            fresh.frameScreenRect = old.frameScreenRect; fresh.frameContentRect = old.frameContentRect
            fresh.frameScaleFactor = old.frameScaleFactor; fresh.frameContentScale = old.frameContentScale
            fresh.sourcePixelFormat = old.sourcePixelFormat
            fresh.hardwareEncoder = old.hardwareEncoder; fresh.negotiatedProfile = old.negotiatedProfile
            fresh.batteryLevel = old.batteryLevel; fresh.batteryState = old.batteryState
            old = fresh
        }
    }
}

/// Serializes JSON lines and fsyncs every line. Metadata only, never media payload.
final class RunLog {
    let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private(set) var failure: String?
    init() throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IOSDirectPOC/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Capture is explicitly consented; metadata must remain writable after device lock.
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: directory.path)
        let stamp = wallTime().replacingOccurrences(of: ":", with: "-")
        url = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8)).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.none]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }
    func write<T: Encodable>(_ item: T) {
        lock.lock(); defer { lock.unlock() }
        do { try handle.write(contentsOf: JSONLine.encode(item)); try handle.synchronize() }
        catch { failure = error.localizedDescription }
    }
    func error() -> String? { lock.lock(); defer { lock.unlock() }; return failure }
    func event(_ name: String, _ details: String = "") {
        write(Event(monotonicTime: uptime(), wallTime: wallTime(), name: name, details: details))
    }
    deinit { try? handle.close() }
}

func residentMemoryMB() -> Double? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : nil
}
