import Foundation

/// Runs one uxplay process and streams its output lines.
final class ReceiverProcess {
    private let process = Process()
    private let output = Pipe()
    private var partialLine = ""

    /// Both callbacks arrive on the main queue.
    init(executable: URL, arguments: [String], onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.partialLine += text
                var lines = self.partialLine.components(separatedBy: "\n")
                self.partialLine = lines.removeLast()
                lines.filter { !$0.isEmpty }.forEach(onLine)
            }
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            DispatchQueue.main.async { onExit(status) }
        }
    }

    func start() throws {
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    /// Asks uxplay to shut down cleanly (SIGINT), then forces it if it hasn't exited.
    func stop(waitingUpTo timeout: TimeInterval = 1.5) {
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
}
