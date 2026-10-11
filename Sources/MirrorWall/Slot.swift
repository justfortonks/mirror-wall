import CoreMedia
import Foundation
import MirrorCore

/// A running mirroring slot: its uxplay process, the RTP stream it forwards, and the renderer.
///
/// Published properties change on the main queue only.
final class Slot: ObservableObject, Identifiable {
    enum State: Equatable {
        case stopped
        case waiting
        case live
        case failed(String)
    }

    private(set) var config: SlotConfig
    var id: Int { config.id }

    @Published private(set) var state: State = .stopped
    /// When the last picture arrived; nil until the first one.
    @Published private(set) var lastFrameAt: Date?
    /// Picture size in pixels, used for the tile's aspect ratio.
    @Published private(set) var videoSize: CGSize?
    @Published private(set) var log: [String] = []

    let renderer = H264Renderer()

    private var process: ReceiverProcess?
    private var receiver: UDPReceiver?
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
            if self.state != .live { self.state = .live }
        }
    }

    // MARK: - Main queue

    private func append(_ line: String) {
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private func processExited(_ status: Int32) {
        append("uxplay exited with status \(status)")
        process = nil
        receiver?.stop()
        receiver = nil
        state = .failed("The receiver stopped (exit status \(status)). Use Restart, or check the log.")
    }
}
