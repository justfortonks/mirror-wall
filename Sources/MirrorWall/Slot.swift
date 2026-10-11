import CoreMedia
import Foundation
import MirrorCore

/// A running mirroring slot: its uxplay process, the RTP stream it forwards, and the renderer.
///
/// Published properties change on the main queue only.
final class Slot: ObservableObject, Identifiable {
    enum State: Equatable {
        case stopped
        /// Receiver running, no phone attached.
        case waiting
        /// A phone is connecting; no picture yet.
        case connecting
        case live
        /// The phone paused its stream, usually because its screen locked.
        case paused
        /// The phone stopped mirroring; it has to reconnect from Screen Mirroring.
        case disconnected
        case failed(String)
    }

    private(set) var config: SlotConfig
    var id: Int { config.id }

    @Published private(set) var state: State = .stopped {
        didSet { if state != oldValue { stateSince = Date() } }
    }
    /// When the current state began, e.g. how long the screen has been off.
    @Published private(set) var stateSince = Date()
    /// When the current phone connected; nil when none is.
    @Published private(set) var connectedSince: Date?
    /// When the last picture arrived; nil until the first one.
    @Published private(set) var lastFrameAt: Date?
    /// Picture size in pixels, used for the tile's aspect ratio.
    @Published private(set) var videoSize: CGSize?
    @Published private(set) var log: [String] = []
    /// The connected phone's name, as it introduced itself to uxplay.
    @Published private(set) var phoneName: String?

    let renderer = H264Renderer()
    /// Called when the config changes on its own (a new phone's name), so it can be saved.
    var onConfigChanged: (() -> Void)?

    private var process: ReceiverProcess?
    private var receiver: UDPReceiver?
    /// When the phone last paused its stream. A locked phone can still send a frame or two (its lock
    /// screen), so frames only count as a resume once they keep coming after this.
    private var pausedAt: Date?
    private var logFile: FileHandle?
    /// Bumped on every start and stop, so callbacks from an old uxplay process are ignored.
    private var generation = 0

    // Touched only on the UDP thread.
    private let depacketizer = H264Depacketizer()
    private var lastNotified: CFAbsoluteTime = 0
    private var lastDimensions: CMVideoDimensions?

    init(config: SlotConfig) {
        self.config = config
    }

    var name: String { config.name }

    func start(uxplay: URL) {
        guard process == nil else { return }
        generation += 1
        let currentGeneration = generation
        log = []
        openLogFile()
        depacketizer.reset()

        let receiver = UDPReceiver(port: config.rtpPort) { [weak self] datagram in
            self?.handle(datagram)
        }
        do {
            try receiver.start()
        } catch {
            state = .failed("\(error)")
            return
        }
        self.receiver = receiver

        let process = ReceiverProcess(
            executable: uxplay,
            arguments: config.uxplayArguments,
            onLine: { [weak self] line in
                guard let self, self.generation == currentGeneration else { return }
                self.append(line)
            },
            onExit: { [weak self] status in
                guard let self, self.generation == currentGeneration else { return }
                self.processExited(status)
            }
        )
        do {
            try process.start()
        } catch {
            receiver.stop()
            self.receiver = nil
            state = .failed("couldn't start uxplay: \(error.localizedDescription)")
            return
        }
        self.process = process
        append("Started: uxplay \(config.uxplayArguments.joined(separator: " "))")
        state = .waiting
    }

    func stop() {
        generation += 1
        process?.stop()
        process = nil
        receiver?.stop()
        receiver = nil
        renderer.reset()
        lastFrameAt = nil
        videoSize = nil
        phoneName = nil
        connectedSince = nil
        state = .stopped
    }

    func restart(uxplay: URL) {
        stop()
        start(uxplay: uxplay)
    }

    func rename(to name: String, uxplay: URL?) {
        objectWillChange.send()
        config.name = name
        if let uxplay, process != nil {
            restart(uxplay: uxplay)
        }
    }

    // MARK: - UDP thread

    private func handle(_ datagram: [UInt8]) {
        guard let packet = RTPPacket(datagram) else { return }
        var rendered = false
        for frame in depacketizer.push(packet) where renderer.render(frame) {
            rendered = true
        }
        guard rendered else { return }

        // Tell the UI at most a few times a second; the layer shows every frame by itself.
        let now = CFAbsoluteTimeGetCurrent()
        let dimensions = renderer.dimensions
        let sizeChanged = dimensions?.width != lastDimensions?.width || dimensions?.height != lastDimensions?.height
        guard sizeChanged || now - lastNotified > 0.5 else { return }
        lastNotified = now
        lastDimensions = dimensions

        DispatchQueue.main.async { [weak self] in
            guard let self, self.process != nil else { return }
            self.lastFrameAt = Date()
            if let dimensions {
                let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
                if self.videoSize != size { self.videoSize = size }
            }
            let pauseSettled = self.pausedAt.map { Date().timeIntervalSince($0) > 3 } ?? true
            if self.state != .live && self.state != .disconnected && (self.state != .paused || pauseSettled) {
                self.state = .live
            }
        }
    }

    // MARK: - Main queue

    private func append(_ line: String) {
        logFile?.write(Data((line + "\n").utf8))
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) }
        if let event = UxPlayEvent(line: line) {
            apply(event)
        }
    }

    private func apply(_ event: UxPlayEvent) {
        switch event {
        case .clientConnecting(let name, _):
            phoneName = name
            connectedSince = Date()
            if config.lastPhoneName != name {
                objectWillChange.send()
                config.lastPhoneName = name
                onConfigChanged?()
            }
            state = .connecting
        case .streamStarted:
            if state == .connecting || state == .paused || state == .disconnected { state = .live }
        case .streamPaused:
            pausedAt = Date()
            if state == .live || state == .connecting { state = .paused }
        case .openConnections(0), .lostConnection:
            connectedSince = nil
            if state != .waiting { state = .disconnected }
        case .openConnections:
            break
        }
    }

    /// Mirrors the log to ~/Library/Logs/MirrorWall/slot-N.log (replaced on each start) for troubleshooting.
    private func openLogFile() {
        try? logFile?.close()
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MirrorWall")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("slot-\(config.id).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logFile = try? FileHandle(forWritingTo: url)
    }

    private func processExited(_ status: Int32) {
        append("uxplay exited with status \(status)")
        process = nil
        receiver?.stop()
        receiver = nil
        state = .failed("The receiver stopped (exit status \(status)). Use Restart, or check the log.")
    }
}
