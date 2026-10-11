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
    /// When recording started; nil when not recording.
    @Published private(set) var recordingSince: Date?
    /// The last recording error, shown in the tile until recording restarts.
    @Published private(set) var recordingError: String?

    let renderer = H264Renderer()
    /// The most frames a second phones are asked to send; takes effect when the receiver starts.
    var maxFrameRate = 30
    /// Numbers for the Stats for Nerds overlay, kept apart so they don't redraw everything else.
    let stats = SlotStats()
    /// Called when the config changes on its own (a new phone's name), so it can be saved.
    var onConfigChanged: (() -> Void)?

    private var process: ReceiverProcess?
    /// Used on the UDP thread and the main queue, so guarded by `recorderLock`.
    private var recorder: SlotRecorder?
    private let recorderLock = NSLock()
    private var receiver: UDPReceiver?
    /// When the phone last paused its stream. A locked phone can still send a frame or two (its lock
    /// screen), so frames only count as a resume once they keep coming after this.
    private var pausedAt: Date?
    private var logFile: FileHandle?
    /// When the phone last checked in or sent video. A phone on a charger, its screen off, can go
    /// quiet without ending the session, and uxplay never notices; the watchdog does.
    private var lastSignOfLifeAt: Date?
    /// The uxplay this slot runs, kept for giving each new connection a fresh receiver.
    private var uxplayURL: URL?
    private var watchdog: Timer?
    static let silenceLimit: TimeInterval = 10
    /// Bumped on every start and stop, so callbacks from an old uxplay process are ignored.
    private var generation = 0

    // Touched only on the UDP thread.
    private let depacketizer = H264Depacketizer()
    private let meter = StreamMeter()
    private var lostPacketsCounted = 0
    private var lastNotified: CFAbsoluteTime = 0
    private var lastDimensions: CMVideoDimensions?

    init(config: SlotConfig) {
        self.config = config
        renderer.onCompressedFrame = { [weak self] avcc, format, isKeyframe, rtpTimestamp in
            self?.record(avcc: avcc, format: format, isKeyframe: isKeyframe, rtpTimestamp: rtpTimestamp)
        }
    }

    var name: String { config.name }

    /// - Parameter freshLog: false when restarting after a disconnect, to keep what led up to it.
    func start(uxplay: URL, freshLog: Bool = true) {
        guard process == nil else { return }
        generation += 1
        let currentGeneration = generation
        uxplayURL = uxplay
        if freshLog {
            log = []
            openLogFile()
        }
        depacketizer.reset()
        meter.reset()

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
            arguments: config.uxplayArguments(maxFrameRate: maxFrameRate),
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
        startWatchdog()
        append("Started: uxplay \(config.uxplayArguments(maxFrameRate: maxFrameRate).joined(separator: " "))")
        state = .waiting
    }

    func stop() {
        // A recording carries on into the next connection, in a new file.
        recorderLock.withLock { recorder?.endFile() }
        generation += 1
        watchdog?.invalidate()
        watchdog = nil
        lastSignOfLifeAt = nil
        process?.stop()
        process = nil
        receiver?.stop()
        receiver = nil
        renderer.reset()
        stats.clearStream()
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

    // MARK: - Recording

    func startRecording() {
        guard recordingSince == nil else { return }
        let recorder = SlotRecorder(folder: SlotRecorder.defaultFolder, baseName: phoneName ?? config.lastPhoneName ?? name)
        recorder.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.recordingError = message
                self?.append("Recording: \(message)")
            }
        }
        recorderLock.withLock { self.recorder = recorder }
        recordingError = nil
        recordingSince = Date()
        append("Recording to \(SlotRecorder.defaultFolder.path)")
    }

    /// - Parameter wait: true when quitting, so the file is complete before the app exits.
    func stopRecording(wait: Bool = false) {
        guard recordingSince != nil else { return }
        recorderLock.withLock {
            recorder?.endFile(wait: wait)
            recorder = nil
        }
        recordingSince = nil
        append("Recording stopped")
    }

    /// UDP thread: hands a compressed frame to the recorder, if recording.
    private func record(avcc: [UInt8], format: CMVideoFormatDescription, isKeyframe: Bool, rtpTimestamp: UInt32) {
        recorderLock.withLock {
            recorder?.append(avcc: avcc, format: format, isKeyframe: isKeyframe, rtpTimestamp: rtpTimestamp, arrival: Self.uptime())
        }
    }

    // MARK: - UDP thread

    private func handle(_ datagram: [UInt8]) {
        guard let packet = RTPPacket(datagram) else { return }
        let frames = depacketizer.push(packet)
        let arrivedAt = Self.uptime()
        meter.packet(bytes: packet.payload.count, lost: depacketizer.lostPackets - lostPacketsCounted, at: arrivedAt)
        lostPacketsCounted = depacketizer.lostPackets
        var rendered = false
        for frame in frames {
            let shown = renderer.render(frame)
            meter.frame(at: arrivedAt, isKeyframe: frame.isKeyframe, macTime: shown ? Self.uptime() - arrivedAt : nil)
            rendered = rendered || shown
        }
        if let snapshot = meter.snapshotIfDue(at: arrivedAt) {
            let codec = renderer.codecDescription
            DispatchQueue.main.async { [weak self] in
                guard let self, self.process != nil else { return }
                self.stats.stream = snapshot
                self.stats.codec = codec
            }
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
            self.lastSignOfLifeAt = Date()
            let pauseSettled = self.pausedAt.map { Date().timeIntervalSince($0) > 3 } ?? true
            if self.state != .live && self.state != .disconnected && (self.state != .paused || pauseSettled) {
                self.state = .live
            }
        }
    }

    // MARK: - Main queue

    private func append(_ line: String) {
        let event = UxPlayEvent(line: line)
        // Latency reports come every second; they feed the stats overlay, not the log.
        if case .videoLatency? = event {} else {
            logFile?.write(Data((line + "\n").utf8))
            log.append(line)
            if log.count > 300 { log.removeFirst(log.count - 300) }
        }
        if let event {
            apply(event)
        }
    }

    private func apply(_ event: UxPlayEvent) {
        switch event {
        case .clientConnecting(let name, let model):
            // The decoder needs no reset here: a new stream starts with new parameter sets, which
            // rebuild it. (This line can also arrive after the new stream's first frames.)
            lastSignOfLifeAt = nil
            phoneName = name
            connectedSince = Date()
            recorderLock.withLock { recorder?.baseName = name }
            stats.phoneModel = model.isEmpty ? nil : model
            stats.connections += 1
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
            if state != .waiting && state != .disconnected {
                state = .disconnected
                restartReceiverSoon()
            }
        case .heartbeat:
            lastSignOfLifeAt = Date()
            stats.heartbeat()
        case .networkRoundTrip(let seconds):
            stats.roundTrip = seconds
        case .videoLatency(let seconds):
            stats.recordLatency(seconds)
        case .openConnections:
            break
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkForSilence()
        }
    }

    private func checkForSilence() {
        guard let lastSignOfLifeAt, state == .live || state == .paused || state == .connecting,
              Date().timeIntervalSince(lastSignOfLifeAt) > Self.silenceLimit else { return }
        append("No check-in or video from the phone for \(Int(Self.silenceLimit)) seconds; treating it as disconnected")
        connectedSince = nil
        state = .disconnected
        restartReceiverSoon()
    }

    /// After a phone disconnects, uxplay sometimes fails to rebuild its video output, and the next
    /// connection then gets no video at all. So each disconnect gets a fresh uxplay. The tile
    /// keeps saying Disconnected, and the slot's name comes back on the phone within a second or
    /// two. This also clears the last picture, so a new connection never shows a stale frame.
    private func restartReceiverSoon() {
        let currentGeneration = generation
        // A moment for uxplay to finish logging the disconnect.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.generation == currentGeneration, self.state == .disconnected,
                  let uxplay = self.uxplayURL else { return }
            let phone = self.phoneName
            self.append("Restarting the receiver so the next connection starts fresh")
            self.stop()
            self.start(uxplay: uxplay, freshLog: false)
            if self.state == .waiting {
                self.phoneName = phone
                self.state = .disconnected
            }
        }
    }

    /// Seconds on a steady clock, for timing frames.
    private static func uptime() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
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
