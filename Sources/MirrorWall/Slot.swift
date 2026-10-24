import CoreMedia
import Foundation
import MirrorCore
import VideoToolbox

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
            castServer?.setAdvertised(!carriesPhoneFrames && state != .connecting)
        }
    }
    /// Do not publish a previous decoder's final frame while a replacement is connecting.
    private var carriesPhoneFrames: Bool {
        state == .live || state == .paused
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
    /// True while a mirroring phone has gone quiet for a few seconds (no check-in or video) but
    /// hasn't been given up on yet, so the Stage can say "Reconnecting…" without ending anything.
    @Published private(set) var isQuiet = false
    /// The last picture and its size from before the phone dropped, kept through the receiver's
    /// restart so the Stage can hold the phone in place, dimmed, while it may reconnect.
    @Published private(set) var heldImage: CGImage?
    @Published private(set) var heldVideoSize: CGSize?
    /// Stage-only freeze. Recordings, screenshots and independent feeds remain live.
    @Published private(set) var frozenImage: CGImage?
    var isFrozen: Bool { frozenImage != nil }
    private var frozenDeviceID: String?
    private var currentDeviceID: String?
    /// The picture's size, or the held one while reconnecting.
    var displaySize: CGSize? { videoSize ?? heldVideoSize }
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
    @Published private(set) var recordingHasFrames = false
    @Published private(set) var isSavingRecording = false
    private var recordingID = UUID()
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
    /// The 4-digit code iPhones must enter, or nil for none. Takes effect when the receiver starts.
    var airplayPIN: String?
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
    private var relayClient: RelayClient?
    /// Settings for the Mirror Wall Relay; nil when it's off. Set by the store before start.
    var relay: RelayClient.Settings?
    /// This slot's six-digit code on the relay, while it's reachable there.
    @Published private(set) var relayCode: String?
    /// The Android phone that has the slot, if any. While one does, the slot's uxplay is stopped
    /// so iPhones don't list it.
    private var castPhone: CastConnection?
    private var logFile: FileHandle?
    /// When the phone last checked in or sent video. A phone on a charger, its screen off, can go
    /// quiet without ending the session, and uxplay never notices; the watchdog does.
    private var lastSignOfLifeAt: Date?
    /// The uxplay this slot runs, kept for giving each new connection a fresh receiver.
    private var uxplayURL: URL?
    private var watchdog: Timer?
    /// Quiet this long (the phone checks in every 2 seconds) and the Stage shows "Reconnecting…".
    static let quietLimit: TimeInterval = 4.5
    /// Bumped on every start and stop, so callbacks from an old uxplay process are ignored.
    private var generation = 0
    private var lifetime = StreamLifetime()
    private var teardown: Task<Void, Never>?
    private var castDeviceID: String?
    private var castShareID: String?
    private var admission = CastAdmission()
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
    }

    var name: String { config.name }
    var displayName: String { config.displayAlias ?? phoneName ?? config.lastPhoneName ?? name }
    var bezelPreset: BezelPreset? { BezelPreset.resolve(selection: config.bezelModel, model: config.lastPhoneModel) }
    func setDisplayAlias(_ alias: String) {
        objectWillChange.send()
        let tidy = String(alias.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        config.displayAlias = tidy.isEmpty ? nil : tidy
        onConfigChanged?()
    }
    func setBezelModel(_ id: String?) {
        objectWillChange.send()
        config.bezelModel = id == BezelPreset.automatic ? nil : id
        updateFeedBezel()
        if showsPicture, let image = renderer.currentImage { syphonFeed?.publishFrame(image) }
        onConfigChanged?()
    }

    /// - Parameter freshLog: false when restarting after a disconnect, to keep what led up to it.
    func start(uxplay: URL, freshLog: Bool = true) {
        guard process == nil, receiver == nil, castServer == nil else { return }
        generation += 1
        let currentGeneration = generation
        if let teardown {
            Task { @MainActor [weak self] in
                await teardown.value
                guard let self, self.generation == currentGeneration else { return }
                self.teardown = nil
                self.start(uxplay: uxplay, freshLog: freshLog)
            }
            return
        }
        lifetime = StreamLifetime()
        let lifetime = lifetime
        uxplayURL = uxplay
        if freshLog {
            log.lines = []
            openLogFile()
        }
        depacketizer.reset()
        meter.reset()

        let stamp = lifetime.stamp
        installRecordingCallback(lifetime: lifetime, stamp: stamp)
        let receiver = UDPReceiver(port: config.rtpPort) { [weak self] datagram in
            self?.handle(datagram, lifetime: lifetime, stamp: stamp)
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
            arguments: config.uxplayArguments(maxFrameRate: maxFrameRate, allowedDevices: allowedDevices, sharpPicture: sharpPicture, pin: airplayPIN),
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
            self.receiver = nil
            lifetime.invalidate()
            teardown = Task.detached { receiver.stop() }
            state = .failed("couldn't start uxplay: \(error.localizedDescription)")
            return
        }
        self.process = process
        processStartedAt = Date()
        startCastServer(lifetime: lifetime)
        startWatchdog()
        append("Started: uxplay \(config.uxplayArguments(maxFrameRate: maxFrameRate, allowedDevices: allowedDevices, sharpPicture: sharpPicture, pin: airplayPIN).joined(separator: " "))")
        state = .waiting
    }

    func stop(endingSharing: Bool = false) {
        generation += 1
        lifetime.invalidate()
        if endingSharing, let castDeviceID { admission.stop(deviceID: castDeviceID, shareID: castShareID) }
        let previous = teardown
        let oldProcess = process
        let oldServer = castServer
        let oldReceiver = receiver
        process = nil
        castServer = nil
        relayClient?.stop()
        relayClient = nil
        relayCode = nil
        castPhone = nil
        castDeviceID = nil
        castShareID = nil
        receiver = nil
        watchdog?.invalidate()
        watchdog = nil
        lastSignOfLifeAt = nil
        if endingSharing { resume() }
        currentDeviceID = nil
        stats.clearStream()
        lastFrameAt = nil
        hasPicture = false
        videoSize = nil
        phoneName = nil
        connectedSince = nil
        isQuiet = false
        state = .stopped
        // No child-process wait, transport drain or decoder reset blocks the main thread.
        teardown = Task.detached { [self] in
            await previous?.value
            oldServer?.stop(endingSharing: endingSharing)
            oldReceiver?.stop()
            oldProcess?.stop()
            streamLock.withLock {
                renderer.reset()
                depacketizer.reset()
                meter.reset()
                lostPacketsCounted = 0
                lastNotified = 0
                lastDimensions = nil
            }
            recorderLock.withLock { recorder?.endFile() }
        }
    }

    func finishStopping() async { await teardown?.value }

    func restart(uxplay: URL, endingSharing: Bool = false) {
        stop(endingSharing: endingSharing)
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
        BezelGeometry(style: bezelPreset?.style ?? BezelStyle(modelCode: config.lastPhoneModel),
                      pictureWidth: picture.width, pictureHeight: picture.height,
                      portraitAspect: bezelPreset?.portraitAspect, turns: phoneTurns)
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
        syphonFeed?.setBezel(style: framesOBSFeed ? (bezelPreset?.style ?? BezelStyle(modelCode: config.lastPhoneModel)) : nil,
                              portraitAspect: bezelPreset?.portraitAspect)
        syphonFeed?.bezelTurns = phoneTurns
    }

    /// Whether the phone appears in the Stage window while it's mirroring.
    var showsOnStage: Bool { config.onStage ?? true }

    func setShowsOnStage(_ on: Bool) {
        objectWillChange.send()
        config.onStage = on ? nil : false
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
        recordingID = UUID()
        let id = recordingID
        recordingHasFrames = false
        recorder.onStarted = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.recordingID == id, self.recordingSince != nil else { return }
                self.recordingHasFrames = true
            }
        }
        recorder.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.recordingID == id else { return }
                self.stopRecording()
                self.recordingError = message
                self.append("Recording: \(message)")
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
        isSavingRecording = false
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
        recordingHasFrames = false
        isSavingRecording = true
        let id = recordingID
        Task { @MainActor [weak self] in
            await SlotRecorder.finishPendingFiles()
            guard let self, self.recordingID == id else { return }
            self.isSavingRecording = false
        }
        append("Recording stopped")
    }

    /// Installed only after the previous decoder has drained.
    private func installRecordingCallback(lifetime: StreamLifetime, stamp: Int) {
        renderer.onPicture = { [weak self] image, timestamp in
            guard lifetime.isCurrent(stamp) else { return }
            self?.record(image: image, rtpTimestamp: timestamp)
        }
    }

    /// Decoder thread: hands a picture to the recorder, if recording.
    private func record(image: CVImageBuffer, rtpTimestamp: UInt32) {
        recorderLock.withLock {
            recorder?.append(image: image, rtpTimestamp: rtpTimestamp, arrival: Self.uptime())
        }
    }

    // MARK: - UDP thread

    private func handle(_ datagram: [UInt8], lifetime: StreamLifetime, stamp: Int) {
        guard let packet = RTPPacket(datagram) else { return }
        streamLock.withLock {
            guard lifetime.isCurrent(stamp) else { return }
            let frames = depacketizer.push(packet)
            let arrivedAt = Self.uptime()
            meter.packet(bytes: packet.payload.count, lost: depacketizer.lostPackets - lostPacketsCounted, at: arrivedAt)
            lostPacketsCounted = depacketizer.lostPackets
            deliver(frames, arrivedAt: arrivedAt, lifetime: lifetime, stamp: stamp)
        }
    }

    /// Cast queue: one picture from the Android phone.
    private func handleCastVideo(captureMicros: Int64, accessUnit: [UInt8], lifetime: StreamLifetime) {
        let stamp = lifetime.stamp
        let nalUnits = annexBNALUnits(accessUnit)
        streamLock.withLock {
            guard lifetime.isCurrent(stamp) else { return }
            if let codec = castCodec(of: nalUnits) { castStreamCodec = codec }
            let frame = H264Frame(nalUnits: nalUnits, timestamp: castRTPTimestamp(captureMicros: captureMicros), codec: castStreamCodec)
            let arrivedAt = Self.uptime()
            meter.packet(bytes: accessUnit.count, lost: 0, at: arrivedAt)
            deliver([frame], arrivedAt: arrivedAt, lifetime: lifetime, stamp: stamp)
            // Arrival minus capture time, on clocks with an unknown offset: only its rise above
            // the best so far means anything, which is what Lag vs best shows.
            if arrivedAt - lastLatencyReport >= 1 {
                lastLatencyReport = arrivedAt
                let latency = arrivedAt - Double(captureMicros) / 1e6
                DispatchQueue.main.async { [weak self] in
                    guard lifetime.isCurrent(stamp) else { return }
                    self?.stats.recordLatency(latency)
                }
            }
        }
    }

    /// Under `streamLock`: decodes frames from either kind of phone and keeps the tile up to date.
    private func deliver(_ frames: [H264Frame], arrivedAt: Double, lifetime: StreamLifetime, stamp: Int) {
        var rendered = false
        for frame in frames {
            let shown = renderer.render(frame, arrival: arrivedAt)
            meter.frame(at: arrivedAt, isKeyframe: frame.isKeyframe, macTime: shown ? Self.uptime() - arrivedAt : nil)
            rendered = rendered || shown
        }
        if let snapshot = meter.snapshotIfDue(at: arrivedAt) {
            let codec = renderer.codecDescription
            DispatchQueue.main.async { [weak self] in
                guard let self, lifetime.isCurrent(stamp) else { return }
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
            guard let self, lifetime.isCurrent(stamp) else { return }
            self.receivedFrame(dimensions: dimensions)
        }
    }

    /// A locked device can send lock-screen frames without resuming its video session.
    /// Only the transport's explicit resume event ends screen-off grace.
    func receivedFrame(dimensions: CMVideoDimensions?, now: Date = Date()) {
        lastFrameAt = now
        if !hasPicture {
            hasPicture = true
            clearHeldPicture()
        }
        if let dimensions {
            let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
            if videoSize != size { videoSize = size }
            lastPictureSize = size
        }
        lastSignOfLifeAt = now
        if state == .connecting || state == .waiting { state = .live }
    }

    // MARK: - Android phones (Mirror Wall Cast)

    private func startCastServer(lifetime: StreamLifetime) {
        let server = CastServer(port: config.castPort, name: config.name) { [weak self] phone in
            self?.castPhoneConnected(phone, lifetime: lifetime)
        }
        do {
            server.setAdvertised(!carriesPhoneFrames)
            try server.start()
            castServer = server
        } catch {
            append("Android phones can't connect to this slot: couldn't listen on port \(config.castPort) (\(error))")
        }
        append("Cast: listening on port \(config.castPort); relay \(relay?.isUsable == true ? "on (\(relay!.host))" : "off")")
        if let relay, relay.isUsable {
            let client = RelayClient(settings: relay, slot: config.name, deviceID: config.deviceID, queue: server.queue, onCode: { [weak self] code in
                DispatchQueue.main.async {
                    guard let self, lifetime.isActive else { return }
                    if self.relayCode != code { self.relayCode = code }
                    if let code { self.append("Reachable through the relay with code \(code)") }
                }
            }, onConnection: { [weak self] phone in
                self?.castPhoneConnected(phone, lifetime: lifetime)
            })
            client.log = { [weak self] line in DispatchQueue.main.async { guard lifetime.isActive else { return }; self?.append(line) } }
            client.start()
            relayClient = client
        }
    }

    /// Cast queue: wires up a new connection. Nothing is decided until the phone says hello.
    private func castPhoneConnected(_ phone: CastConnection, lifetime: StreamLifetime) {
        phone.onMessage = { [weak self, weak phone] message in
            guard let self, let phone, lifetime.isActive else { return }
            switch message {
            case .video(let captureMicros, let accessUnit):
                if phone.isAccepted { self.handleCastVideo(captureMicros: captureMicros, accessUnit: accessUnit, lifetime: lifetime) }
            default:
                DispatchQueue.main.async {
                    guard lifetime.isActive else { return }
                    self.castMessage(message, from: phone)
                }
            }
        }
        phone.onClose = { [weak self, weak phone] in
            DispatchQueue.main.async {
                guard let self, let phone, lifetime.isActive else { return }
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
        guard admission.permits(hello.deviceID, shareID: hello.shareID) else {
            phone.refuse("Sharing was stopped on the Mac. Wait a minute, then tap Share again.")
            return
        }
        if let allowedDevices, !allowedDevices.contains(hello.deviceID) {
            onPhoneSeen?(KnownPhone(deviceID: hello.deviceID, name: hello.name, model: hello.model, lastSeen: Date()))
            append("Turned away \(hello.name) (\(hello.model)): not on the allow-list")
            phone.refuse("This phone isn't allowed on \(name). It can be allowed in Mirror Wall's Settings.")
            return
        }
        lifetime.advance() // queued AirPlay frames cannot update this Android session
        castPhone = phone
        castDeviceID = hello.deviceID
        castShareID = hello.shareID
        phoneTurns = nil
        append("Android phone connecting: \(hello.name) (\(hello.model)) from \(phone.remoteDescription)")
        generation += 1
        let currentGeneration = generation
        let oldProcess = process
        let oldReceiver = receiver
        process = nil
        receiver = nil
        apply(.clientConnecting(name: hello.name, model: hello.model, deviceID: hello.deviceID))
        lastSignOfLifeAt = Date()
        let lifetime = lifetime
        let handoff = Task.detached { [self] in
            oldReceiver?.stop()
            oldProcess?.stop()
            streamLock.withLock {
                renderer.reset()
                depacketizer.reset()
                castStreamCodec = .h264
            }
        }
        teardown = handoff
        Task { @MainActor [weak self] in
            await handoff.value
            guard let self, lifetime.isActive, self.generation == currentGeneration,
                  self.castPhone === phone else { return }
            self.teardown = nil
            self.installRecordingCallback(lifetime: lifetime, stamp: lifetime.stamp)
            phone.accept(CastWelcome(slot: self.name, maxFrameRate: self.maxFrameRate, sharpPicture: self.sharpPicture))
        }
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

    func apply(_ event: UxPlayEvent) {
        switch event {
        case .clientConnecting(let name, let model, let deviceID):
            // The decoder needs no reset here: a new stream starts with new parameter sets, which
            // rebuild it. (This line can also arrive after the new stream's first frames.)
            if deviceID.isEmpty || frozenDeviceID != deviceID { resume() }
            currentDeviceID = deviceID.isEmpty ? nil : deviceID
            lastSignOfLifeAt = Date()
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
            lastSignOfLifeAt = Date()
            if state == .connecting || state == .paused || state == .disconnected { state = .live }
        case .streamPaused:
            lastSignOfLifeAt = Date()
            if state == .live || state == .connecting { state = .paused }
        case .openConnections(0), .lostConnection:
            connectedSince = nil
            if state != .waiting && state != .disconnected {
                phoneDropped()
            }
        case .heartbeat:
            lastSignOfLifeAt = Date()
            if isQuiet { isQuiet = false }
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
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkForSilence()
        }
    }

    /// The picture on screen now, as an image that outlives the receiver.
    private func snapshot() -> CGImage? {
        guard let buffer = renderer.currentImage else { return nil }
        var image: CGImage?
        _ = VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        return image
    }

    /// Keeps the picture on screen now, before the receiver restart clears it.
    private func holdLastPicture() {
        heldVideoSize = videoSize ?? heldVideoSize
        if let image = frozenImage ?? snapshot() { heldImage = image }
    }

    /// Freezes the Stage on this phone's current picture; the phone keeps mirroring.
    func pause() {
        guard frozenImage == nil, let image = snapshot() else { return }
        freeze(image)
    }

    /// Associates the presentation snapshot with a device, not the reusable receiver slot.
    func freeze(_ image: CGImage) {
        frozenImage = image
        frozenDeviceID = currentDeviceID
    }

    func resume() {
        if frozenImage != nil { frozenImage = nil }
        frozenDeviceID = nil
    }

    /// Lets go of the held picture: the phone is back, or no longer waited for.
    func clearHeldPicture() {
        if heldImage != nil { heldImage = nil }
        if heldVideoSize != nil { heldVideoSize = nil }
    }

    func checkForSilence(now: Date = Date()) {
        let silentFor = lastSignOfLifeAt.map { now.timeIntervalSince($0) } ?? 0
        let quiet = state == .live && silentFor > Self.quietLimit
        if quiet != isQuiet { isQuiet = quiet }
        let limit = SessionLiveness.silenceLimit(screenOff: state == .paused, android: castPhone != nil)
        guard lastSignOfLifeAt != nil, state == .live || state == .paused || state == .connecting,
              silentFor > limit else { return }
        append("No check-in or video from the phone for \(Int(limit)) seconds; treating it as disconnected")
        connectedSince = nil
        phoneDropped()
    }

    private func phoneDropped() {
        let wasMirroring = state == .live || state == .paused || state == .connecting
        if wasMirroring { holdLastPicture() }
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
        // A receiver that ran a while and quit by itself, most often crashing as a phone
        // disconnects (in H.265 mode especially), gets replaced like after any disconnect. One
        // that quits within seconds of starting is shown as failed rather than restarted over
        // and over.
        let ranAWhile = processStartedAt.map { Date().timeIntervalSince($0) > 5 } ?? false
        guard ranAWhile, let uxplay = uxplayURL else {
            stop()
            state = .failed("The receiver stopped (exit status \(status)). Use Restart, or check the log.")
            return
        }
        let wasMirroring = state == .live || state == .paused || state == .connecting
        let phone = phoneName
        if wasMirroring { holdLastPicture() }
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
