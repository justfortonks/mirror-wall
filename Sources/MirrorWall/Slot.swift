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
        didSet {
            if state != oldValue { stateSince = Date() }
            syphonFeed?.passesFrames = carriesPhoneFrames
            // A slot in use drops out of the Android app's list until it's free again.
            castServer?.setAdvertised(!carriesPhoneFrames)
        }
    }
    /// True while a phone is (or is about to be) mirroring, so its frames belong in the OBS feed.
    private var carriesPhoneFrames: Bool {
        state == .connecting || state == .live || state == .paused
    }
    /// When the current state began, e.g. how long the screen has been off.
    @Published private(set) var stateSince = Date()
    /// When the current phone connected; nil when none is.
    @Published private(set) var connectedSince: Date?
    /// When the last picture arrived; nil until the first one.
    /// Updated with every picture, so not published: a change here would redraw the whole tile
    /// several times a second, closing any menu open on it. Views that show it re-read it on a
    /// timer; `hasPicture` tells them when it starts and stops.
    private(set) var lastFrameAt: Date?
    /// True once a picture has arrived, until the slot stops.
    @Published private(set) var hasPicture = false
    /// Picture size in pixels, used for the tile's aspect ratio.
    @Published private(set) var videoSize: CGSize?
    /// The last picture size seen, kept after the phone leaves, for sizing the OBS feed's standby
    /// picture like the phone's.
    private(set) var lastPictureSize: CGSize?
    /// The receiver's output, kept apart so a new line only redraws the log window.
    let log = SlotLog()
    /// The connected phone's name, as it introduced itself to uxplay.
    @Published private(set) var phoneName: String?
    /// When recording started; nil when not recording.
    @Published private(set) var recordingSince: Date?
    /// The last recording error, shown in the tile until recording restarts.
    @Published private(set) var recordingError: String?
    /// When the last screenshot was saved, for a moment's confirmation in the tile.
    @Published private(set) var screenshotSavedAt: Date?

    let renderer = H264Renderer()
    /// The slot's OBS feed, while it's on.
    private var syphonFeed: SyphonFeed?
    /// The most frames a second phones are asked to send; takes effect when the receiver starts.
    var maxFrameRate = 30
    /// Offers phones H.265 for a sharper picture; takes effect when the receiver starts.
    var sharpPicture = false
    /// Numbers for the Stats for Nerds overlay, kept apart so they don't redraw everything else.
    let stats = SlotStats()
    /// Called when the config changes on its own (a new phone's name), so it can be saved.
    var onConfigChanged: (() -> Void)?
    /// Only phones with these device IDs may connect, or any phone if nil. Takes effect when the
    /// receiver starts.
    var allowedDevices: [String]?
    /// Called when a phone asks to connect, so the store can remember it for the allow-list.
    var onPhoneSeen: ((KnownPhone) -> Void)?
    /// Called when a mirroring phone drops unexpectedly (not when the slot is stopped).
    var onPhoneDropped: (() -> Void)?

    private var process: ReceiverProcess?
    /// Used on the UDP thread and the main queue, so guarded by `recorderLock`.
    private var recorder: SlotRecorder?
    private let recorderLock = NSLock()
    private var receiver: UDPReceiver?
    /// Listens for Android phones (Mirror Wall Cast) while the slot runs.
    private var castServer: CastServer?
    /// The Android phone that has the slot, if any. While one does, the slot's uxplay is stopped
    /// so iPhones don't list it.
    private var castPhone: CastConnection?
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
    /// When the receiver last started, to tell a crash after running a while (start a fresh one)
    /// from one that can't run at all (show the error).
    private var processStartedAt: Date?

    // Touched only on the UDP thread or the cast queue, under `streamLock`. (Only one of them
    // carries video at a time: uxplay is stopped while an Android phone has the slot.)
    private let streamLock = NSLock()
    private let depacketizer = H264Depacketizer()
    private let meter = StreamMeter()
    private var lostPacketsCounted = 0
    private var lastNotified: CFAbsoluteTime = 0
    private var lastDimensions: CMVideoDimensions?
    /// The Android phone's codec, read from its keyframes.
    private var castStreamCodec: VideoCodec = .h264
    private var lastLatencyReport: Double = 0

    init(config: SlotConfig) {
        self.config = config
        renderer.onPicture = { [weak self] image, rtpTimestamp in
            self?.record(image: image, rtpTimestamp: rtpTimestamp)
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
            log.lines = []
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
            arguments: config.uxplayArguments(maxFrameRate: maxFrameRate, allowedDevices: allowedDevices, sharpPicture: sharpPicture),
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
        processStartedAt = Date()
        startCastServer()
        startWatchdog()
        append("Started: uxplay \(config.uxplayArguments(maxFrameRate: maxFrameRate, allowedDevices: allowedDevices, sharpPicture: sharpPicture).joined(separator: " "))")
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
        castServer?.stop()
        castServer = nil
        castPhone = nil
        receiver?.stop()
        receiver = nil
        renderer.reset()
        stats.clearStream()
        lastFrameAt = nil
        hasPicture = false
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

    /// Sends the slot's picture to OBS through Syphon, under `name`, or stops. Returns false if
    /// the feed couldn't start (no Syphon in this build).
    @discardableResult
    func setOBSFeed(_ on: Bool, name: String) -> Bool {
        objectWillChange.send()
        if on {
            if let feed = syphonFeed {
                feed.name = name
            } else if let feed = SyphonFeed(name: name) {
                syphonFeed = feed
                feed.passesFrames = carriesPhoneFrames
                updateFeedBezel()
                renderer.onShow = { [weak feed] image in feed?.publishFrame(image) }
                if let image = renderer.currentImage { feed.publishFrame(image) }
            } else {
                return false
            }
        } else {
            renderer.onShow = nil
            syphonFeed?.stop()
            syphonFeed = nil
        }
        return true
    }

    /// Remembers this slot's own OBS feed choice; nil follows the setting for all slots.
    func rememberOBSFeed(_ choice: Bool?) {
        config.obsFeed = choice
    }

    /// Whether the picture has a phone frame around it, on the wall and in its own window. Set by
    /// the store from the slot's own choice or the setting for all slots.
    @Published var showsBezel = false

    func rememberBezel(_ choice: Bool?) {
        config.bezel = choice
    }

    /// The frame for a picture of this size (the phone's shape), styled after the last phone and
    /// turned the way an Android phone says it's held.
    func bezel(for picture: CGSize) -> BezelGeometry {
        BezelGeometry(modelCode: config.lastPhoneModel, pictureWidth: picture.width, pictureHeight: picture.height, turns: phoneTurns)
    }

    /// Which way up the Android phone says it's held (see `CastMessage.orientation`); nil for an
    /// iPhone or an older Android app, which don't say.
    @Published private(set) var phoneTurns: Int? {
        didSet { syphonFeed?.bezelTurns = phoneTurns }
    }

    /// Whether the OBS feed has the phone frame around the picture, with see-through corners.
    var framesOBSFeed: Bool { config.feedBezel ?? false }

    /// Puts the phone frame around the OBS feed's picture, or takes it off. The store re-sends
    /// the standby picture.
    func setFramesOBSFeed(_ on: Bool) {
        objectWillChange.send()
        config.feedBezel = on ? true : nil
        updateFeedBezel()
        if showsPicture, let image = renderer.currentImage { syphonFeed?.publishFrame(image) }
    }

    /// The feed's frame follows the last phone's model.
    private func updateFeedBezel() {
        syphonFeed?.bezelStyle = framesOBSFeed ? BezelStyle(modelCode: config.lastPhoneModel) : nil
        syphonFeed?.bezelTurns = phoneTurns
    }

    /// Whether the phone appears in the Stage window while it's mirroring. Off until it's put on
    /// the Stage (see SlotStore.StagePhones).
    var showsOnStage: Bool { config.onStage ?? false }

    func setShowsOnStage(_ on: Bool) {
        objectWillChange.send()
        config.onStage = on ? true : nil
    }

    /// True while the slot is sending its picture to OBS through Syphon.
    var sendsToOBS: Bool { syphonFeed != nil }
    /// The name OBS lists the slot's feed under, while it's on.
    var obsFeedName: String? { syphonFeed?.name }

    /// Sends a still picture (the standby picture) down the OBS feed, if it's on.
    func sendToOBS(_ image: CVImageBuffer) {
        syphonFeed?.publish(image)
    }

    func setStandby(_ standby: StandbyPicture?) {
        objectWillChange.send()
        config.standby = standby
    }

    /// True while there's a current picture: live, or paused on its last frame.
    var showsPicture: Bool {
        hasPicture && (state == .live || state == .paused)
    }

    // MARK: - Screenshots

    /// Saves the picture on screen now, at the stream's full size, to the screenshots folder.
    func takeScreenshot() {
        guard showsPicture, let image = renderer.currentImage else { return }
        let base = phoneName ?? config.lastPhoneName ?? name
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let url = try Screenshots.save(image, baseName: base)
                DispatchQueue.main.async {
                    self?.screenshotSavedAt = Date()
                    self?.append("Saved screenshot \(url.lastPathComponent)")
                }
            } catch {
                DispatchQueue.main.async { self?.append("Screenshot failed: \(error.localizedDescription)") }
            }
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
        recorderLock.withLock {
            self.recorder = recorder
            // Start with the picture on screen now: a still screen sends nothing until it changes.
            if let image = renderer.currentImage {
                recorder.append(image: image, rtpTimestamp: nil, arrival: Self.uptime())
            }
        }
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

    /// Decoder thread: hands a picture to the recorder, if recording.
    private func record(image: CVImageBuffer, rtpTimestamp: UInt32) {
        recorderLock.withLock {
            recorder?.append(image: image, rtpTimestamp: rtpTimestamp, arrival: Self.uptime())
        }
    }

    // MARK: - UDP thread

    private func handle(_ datagram: [UInt8]) {
        guard let packet = RTPPacket(datagram) else { return }
        streamLock.withLock {
            let frames = depacketizer.push(packet)
            let arrivedAt = Self.uptime()
            meter.packet(bytes: packet.payload.count, lost: depacketizer.lostPackets - lostPacketsCounted, at: arrivedAt)
            lostPacketsCounted = depacketizer.lostPackets
            deliver(frames, arrivedAt: arrivedAt)
        }
    }

    /// Cast queue: one picture from the Android phone.
    private func handleCastVideo(captureMicros: Int64, accessUnit: [UInt8]) {
        let nalUnits = annexBNALUnits(accessUnit)
        streamLock.withLock {
            if let codec = castCodec(of: nalUnits) { castStreamCodec = codec }
            let frame = H264Frame(nalUnits: nalUnits, timestamp: castRTPTimestamp(captureMicros: captureMicros), codec: castStreamCodec)
            let arrivedAt = Self.uptime()
            meter.packet(bytes: accessUnit.count, lost: 0, at: arrivedAt)
            deliver([frame], arrivedAt: arrivedAt)
            // Arrival minus capture time, on clocks with an unknown offset: only its rise above
            // the best so far means anything, which is what Lag vs best shows.
            if arrivedAt - lastLatencyReport >= 1 {
                lastLatencyReport = arrivedAt
                let latency = arrivedAt - Double(captureMicros) / 1e6
                DispatchQueue.main.async { [weak self] in self?.stats.recordLatency(latency) }
            }
        }
    }

    /// Under `streamLock`: decodes frames from either kind of phone and keeps the tile up to date.
    private func deliver(_ frames: [H264Frame], arrivedAt: Double) {
        var rendered = false
        for frame in frames {
            let shown = renderer.render(frame, arrival: arrivedAt)
            meter.frame(at: arrivedAt, isKeyframe: frame.isKeyframe, macTime: shown ? Self.uptime() - arrivedAt : nil)
            rendered = rendered || shown
        }
        if let snapshot = meter.snapshotIfDue(at: arrivedAt) {
            let codec = renderer.codecDescription
            DispatchQueue.main.async { [weak self] in
                guard let self, self.receiver != nil else { return }
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
            guard let self, self.receiver != nil else { return }
            self.lastFrameAt = Date()
            if !self.hasPicture { self.hasPicture = true }
            if let dimensions {
                let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
                if self.videoSize != size { self.videoSize = size }
                self.lastPictureSize = size
            }
            self.lastSignOfLifeAt = Date()
            let pauseSettled = self.pausedAt.map { Date().timeIntervalSince($0) > 3 } ?? true
            if self.state != .live && self.state != .disconnected && (self.state != .paused || pauseSettled) {
                self.state = .live
            }
        }
    }

    // MARK: - Android phones (Mirror Wall Cast)

    private func startCastServer() {
        let server = CastServer(port: config.castPort, name: config.name) { [weak self] phone in
            self?.castPhoneConnected(phone)
        }
        do {
            server.setAdvertised(!carriesPhoneFrames)
            try server.start()
            castServer = server
        } catch {
            append("Android phones can't connect to this slot: couldn't listen on port \(config.castPort) (\(error))")
        }
    }

    /// Cast queue: wires up a new connection. Nothing is decided until the phone says hello.
    private func castPhoneConnected(_ phone: CastConnection) {
        phone.onMessage = { [weak self, weak phone] message in
            guard let self, let phone else { return }
            switch message {
            case .video(let captureMicros, let accessUnit):
                if phone.isAccepted { self.handleCastVideo(captureMicros: captureMicros, accessUnit: accessUnit) }
            default:
                DispatchQueue.main.async { self.castMessage(message, from: phone) }
            }
        }
        phone.onClose = { [weak self, weak phone] in
            DispatchQueue.main.async {
                guard let self, let phone else { return }
                self.castPhoneLeft(phone)
            }
        }
    }

    private func castMessage(_ message: CastMessage, from phone: CastConnection) {
        if case .hello(let hello) = message {
            castHello(hello, from: phone)
            return
        }
        guard phone === castPhone else { return }
        switch message {
        case .paused: apply(.streamPaused)
        case .resumed: apply(.streamStarted)
        case .heartbeat:
            apply(.heartbeat)
            // A still screen sends no pictures; don't leave the last second's numbers up.
            if let lastFrameAt, Date().timeIntervalSince(lastFrameAt) > 1.5, stats.stream?.framesPerSecond != 0 {
                stats.stream?.framesPerSecond = 0
                stats.stream?.bitsPerSecond = 0
            }
            phone.send(.ping(DispatchTime.now().uptimeNanoseconds))
        case .pong(let sentAt):
            let now = DispatchTime.now().uptimeNanoseconds
            if now > sentAt { stats.roundTrip = Double(now - sentAt) / 1e9 }
        case .bye: append("\(phoneName ?? "The Android phone") stopped sharing")
        case .orientation(let turns): if phoneTurns != turns { phoneTurns = turns }
        default: break
        }
    }

    private func castHello(_ hello: CastHello, from phone: CastConnection) {
        guard castServer != nil, castPhone == nil else {
            phone.refuse("\(name) is showing another phone.")
            return
        }
        if state == .connecting || state == .live || state == .paused {
            phone.refuse("\(name) is showing \(phoneName ?? "another phone").")
            return
        }
        if let allowedDevices, !allowedDevices.contains(hello.deviceID) {
            onPhoneSeen?(KnownPhone(deviceID: hello.deviceID, name: hello.name, model: hello.model, lastSeen: Date()))
            append("Turned away \(hello.name) (\(hello.model)): not on the allow-list")
            phone.refuse("This phone isn't allowed on \(name). It can be allowed in Mirror Wall's Settings.")
            return
        }
        castPhone = phone
        phoneTurns = nil
        append("Android phone connecting: \(hello.name) (\(hello.model)) from \(phone.remoteDescription)")
        // Take the slot off iPhones' Screen Mirroring list while the Android phone has it. The
        // generation bump keeps the stopping uxplay's exit, and any pending restart, from
        // touching the slot.
        generation += 1
        process?.stop()
        process = nil
        streamLock.withLock {
            depacketizer.reset()
            castStreamCodec = .h264
        }
        apply(.clientConnecting(name: hello.name, model: hello.model, deviceID: hello.deviceID))
        lastSignOfLifeAt = Date()
        phone.accept(CastWelcome(slot: name, maxFrameRate: maxFrameRate, sharpPicture: sharpPicture))
    }

    /// The Android phone hung up, or the connection broke. Ends like an iPhone disconnecting:
    /// Disconnected, then a fresh uxplay so iPhones can see the slot again.
    private func castPhoneLeft(_ phone: CastConnection) {
        guard phone === castPhone else { return }
        castPhone = nil
        phoneTurns = nil
        append("\(phoneName ?? "The Android phone") disconnected")
        connectedSince = nil
        if state != .waiting && state != .disconnected {
            phoneDropped()
        } else {
            restartReceiverSoon()
        }
    }

    // MARK: - Main queue

    private func append(_ line: String) {
        let event = UxPlayEvent(line: line)
        // Latency reports come every second; they feed the stats overlay, not the log.
        if case .videoLatency? = event {} else {
            logFile?.write(Data((line + "\n").utf8))
            log.lines.append(line)
            if log.lines.count > 300 { log.lines.removeFirst(log.lines.count - 300) }
        }
        if let event {
            apply(event)
        }
    }

    private func apply(_ event: UxPlayEvent) {
        switch event {
        case .clientConnecting(let name, let model, let deviceID):
            // The decoder needs no reset here: a new stream starts with new parameter sets, which
            // rebuild it. (This line can also arrive after the new stream's first frames.)
            lastSignOfLifeAt = nil
            phoneName = name
            connectedSince = Date()
            recorderLock.withLock { recorder?.baseName = name }
            stats.phoneModel = model.isEmpty ? nil : phoneModelName(model)
            stats.connections += 1
            if !deviceID.isEmpty {
                onPhoneSeen?(KnownPhone(deviceID: deviceID, name: name, model: model, lastSeen: Date()))
            }
            if config.lastPhoneName != name || (!model.isEmpty && config.lastPhoneModel != model) {
                objectWillChange.send()
                config.lastPhoneName = name
                if !model.isEmpty { config.lastPhoneModel = model }
                updateFeedBezel()
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
                phoneDropped()
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
        phoneDropped()
    }

    private func phoneDropped() {
        let wasMirroring = state == .live || state == .paused || state == .connecting
        state = .disconnected
        restartReceiverSoon()
        if wasMirroring { onPhoneDropped?() }
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
        // A receiver that ran a while and quit by itself, most often crashing as a phone
        // disconnects (in H.265 mode especially), gets replaced like after any disconnect. One
        // that quits within seconds of starting is shown as failed rather than restarted over
        // and over.
        let ranAWhile = processStartedAt.map { Date().timeIntervalSince($0) > 5 } ?? false
        guard ranAWhile, let uxplay = uxplayURL else {
            state = .failed("The receiver stopped (exit status \(status)). Use Restart, or check the log.")
            return
        }
        let wasMirroring = state == .live || state == .paused || state == .connecting
        let phone = phoneName
        append("Starting a fresh receiver")
        stop()
        start(uxplay: uxplay, freshLog: false)
        if wasMirroring || phone != nil, state == .waiting {
            phoneName = phone
            state = .disconnected
        }
        if wasMirroring { onPhoneDropped?() }
    }
}

/// A slot's recent receiver output, for the log window.
final class SlotLog: ObservableObject {
    @Published var lines: [String] = []
}
