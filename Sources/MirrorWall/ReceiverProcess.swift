import Darwin
import Foundation
import MirrorCore

/// Runs one uxplay process and streams its output lines.
///
/// uxplay's output goes to a pseudo-terminal rather than a pipe: into a pipe, it arrives in
/// blocks of about 16 KB, which left the app up to ~18 seconds behind on connects, screen-offs
/// and disconnects. On a terminal it arrives line by line.
final class ReceiverProcess {
    private let process = Process()
    private var masterFD: Int32 = -1
    private var reader: DispatchSourceRead?
    private var partialLine = ""
    private let onLine: (String) -> Void

    /// Both callbacks arrive on the main queue.
    init(executable: URL, arguments: [String], onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        self.onLine = onLine
        process.executableURL = executable
        process.arguments = arguments
        if let environment = Self.packagedEnvironment(for: executable) {
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { process in
            let status = process.terminationStatus
            DispatchQueue.main.async { onExit(status) }
        }
    }

    /// The environment for a uxplay that ships with its own GStreamer (the one inside
    /// MirrorWall.app); nil for any other, which inherits the app's.
    private static func packagedEnvironment(for executable: URL) -> [String: String]? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = caches.appendingPathComponent("MirrorWall")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return PackagedReceiver.environment(
            forExecutableAt: executable.path,
            inheriting: ProcessInfo.processInfo.environment,
            registryPath: folder.appendingPathComponent("gstreamer-registry.bin").path,
            fileExists: FileManager.default.fileExists(atPath:)
        )
    }

    func start() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        process.standardOutput = terminal
        process.standardError = terminal
        do {
            try process.run()
        } catch {
            close(master)
            throw error
        }
        // The child has its own copy now; ours would keep the terminal open after it exits.
        try? terminal.close()
        masterFD = master
        startReading()
    }

    var isRunning: Bool { process.isRunning }

    /// Asks uxplay to shut down cleanly (SIGINT), then forces it if it hasn't exited.
    func stop(waitingUpTo timeout: TimeInterval = 1.5) {
        defer { reader?.cancel() }
        guard process.isRunning else { return }
        process.interrupt()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.isRunning else { return }
        process.terminate()
        let killDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func startReading() {
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            // 0 or an error (EIO once uxplay has exited and the terminal is gone) ends the output.
            guard count > 0 else {
                source?.cancel()
                return
            }
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            DispatchQueue.main.async { self?.received(text) }
        }
        source.setCancelHandler { close(fd) }
        reader = source
        source.resume()
    }

    private func received(_ text: String) {
        // A terminal ends lines with "\r\n".
        partialLine += text.replacingOccurrences(of: "\r", with: "")
        var lines = partialLine.components(separatedBy: "\n")
        partialLine = lines.removeLast()
        lines.filter { !$0.isEmpty }.forEach(onLine)
    }
}
