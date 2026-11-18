import AppKit
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import MirrorCore
import ScreenCaptureKit
import SwiftUI

/// File › Send a Window to OBS (Syphon): any Mac window, such as Screen Sharing, a browser or a
/// game, goes to OBS as a Syphon feed ("[Mirror Wall] <window name>" in a Syphon Client source),
/// by capturing just that window with ScreenCaptureKit. It needs no Screen Recording permission:
/// the window is picked in macOS's own window picker, and that choice is the permission.
///
/// macOS doesn't draw a minimized window at all, so a window has to stay open for its feed to
/// move: behind other windows, behind OBS's full-screen projector or on another screen all work
/// in principle. Each feed says whether pictures are arriving, and why not, in the list.

// MARK: - Status

/// How one window's feed is doing, as "Windows Sent to OBS" shows it.
enum WindowFeedStatus: Equatable {
    case starting
    /// New pictures are arriving, this many a second.
    case live(framesPerSecond: Int)
    /// macOS says the window hasn't changed, so there's nothing new to send; OBS keeps the last picture.
    case still
    /// macOS has sent nothing for this many seconds.
    case noPictures(seconds: Int)
    /// macOS sends pictures but says they're blank or suspended.
    case blank
    /// The capture ended, with the reason.
    case stopped(String)

    var text: String {
        switch self {
        case .starting: return "Starting…"
        case .live(let fps): return "Live · \(fps) frames a second"
        case .still: return "Live · the window isn't changing"
        case .noPictures(let seconds): return "No new picture for \(seconds) s"
        case .blank: return "macOS is sending blank pictures"
        case .stopped(let reason): return reason
        }
    }

    var color: Color {
        switch self {
        case .starting: return .yellow
        case .live, .still: return .green
        case .noPictures, .blank: return .orange
        case .stopped: return .gray
        }
    }

    var isStopped: Bool {
        if case .stopped = self { return true }
        return false
    }
}

// MARK: - Log

/// ~/Library/Logs/MirrorWall/window-feeds.log: what each feed's pictures did, so a window that
/// freezes can be explained afterwards. The log before the last launch is window-feeds.previous.log.
final class WindowFeedLog {
    static let shared = WindowFeedLog()

    private let queue = DispatchQueue(label: "Mirror Wall window feed log")
    private var file: FileHandle?
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    func write(_ message: String) {
        queue.async { [self] in
            if file == nil { openFile() }
            file?.write(Data("\(formatter.string(from: Date())) \(message)\n".utf8))
        }
    }

    private func openFile() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MirrorWall")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("window-feeds.log")
        let previous = folder.appendingPathComponent("window-feeds.previous.log")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
    }
}

/// Seconds on a steady clock.
private func uptimeSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}

// MARK: - Receiving pictures

/// Receives one window's pictures from ScreenCaptureKit on its own queue, hands each to the
/// Syphon feed at once, and keeps tallies for the feed's status.
private final class WindowFrameSink: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Tally {
        var complete = 0
        var idle = 0
        var blank = 0
        var suspended = 0
        /// The size of the last picture, in pixels.
        var width = 0
        var height = 0
        /// When macOS last called, whatever it sent.
        var lastCallback: Double?
        /// Set when the capture ended: why.
        var stopped: String?
    }

    let queue = DispatchQueue(label: "Mirror Wall window capture", qos: .userInteractive)
    private let syphon: SyphonFeed
    private let lock = NSLock()
    // Guarded by `lock`.
    private var tally = Tally()
    private var publishing = true
    private var previewWanted = false
    private var previewAt = 0.0
    private var preview: CGImage?
    // Used on `queue` only.
    private lazy var ciContext = CIContext()

    init(syphon: SyphonFeed) {
        self.syphon = syphon
    }

    /// What arrived since the last call, and the counts start again.
    func takeTally() -> Tally {
        lock.lock()
        defer { lock.unlock() }
        let taken = tally
        tally.complete = 0
        tally.idle = 0
        tally.blank = 0
        tally.suspended = 0
        return taken
    }

    func setPreviewWanted(_ wanted: Bool) {
        lock.lock()
        previewWanted = wanted
        lock.unlock()
    }

    func takePreview() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        let taken = preview
        preview = nil
        return taken
    }

    /// Stops handing pictures to Syphon, ahead of the feed being closed.
    func stopPublishing() {
        lock.lock()
        publishing = false
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let rawStatus = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        let now = uptimeSeconds()

        lock.lock()
        tally.lastCallback = now
        switch status {
        case .complete: tally.complete += 1
        case .idle: tally.idle += 1
        case .blank: tally.blank += 1
        case .suspended: tally.suspended += 1
        default: break
        }
        let publish = publishing
        let makePreview = previewWanted && now - previewAt >= 0.5
        if makePreview { previewAt = now }
        lock.unlock()

        guard status == .complete, publish, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        tally.width = CVPixelBufferGetWidth(image)
        tally.height = CVPixelBufferGetHeight(image)
        lock.unlock()
        // Already BGRA in an IOSurface, so Syphon takes it as it is.
        syphon.publish(image, framed: false)
        if makePreview, let thumbnail = thumbnail(of: image) {
            lock.lock()
            preview = thumbnail
            lock.unlock()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let code = (error as NSError).code
        // -3817: the person chose Stop Sharing in the menu bar.
        let reason = code == -3817 ? "Stopped from the menu bar" : "macOS ended the capture (the window was probably closed)"
        WindowFeedLog.shared.write("capture ended: \(error.localizedDescription) (code \(code))")
        lock.lock()
        tally.stopped = reason
        lock.unlock()
    }

    private func thumbnail(of image: CVImageBuffer) -> CGImage? {
        let picture = CIImage(cvPixelBuffer: image)
        guard picture.extent.width > 0 else { return nil }
        let scale = min(1, 480 / picture.extent.width)
        let scaled = picture.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }
}

// MARK: - One window's feed

@MainActor
final class WindowFeed: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var name: String
    @Published private(set) var status = WindowFeedStatus.starting
    /// The picture's size, in pixels.
    @Published private(set) var pixelSize = CGSize.zero
    @Published private(set) var preview: NSImage?
    /// Whether macOS has the window on screen: not when it's minimized, hidden or on another
    /// desktop. Nil when this macOS doesn't say which window it is.
    @Published private(set) var windowOnScreen: Bool?
    /// What macOS sent in the last second, by kind, for working out why a picture isn't moving.
    @Published private(set) var counts = ""
    @Published var showsPointer = true {
        didSet { if showsPointer != oldValue { applyConfiguration() } }
    }

    /// The app the window belongs to, if macOS said.
    let appName: String?

    private let filter: SCContentFilter
    private let windowID: CGWindowID?
    private let syphon: SyphonFeed
    private let sink: WindowFrameSink
    private let wantsPreview: () -> Bool
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var timer: Timer?
    private var lastTickAt = uptimeSeconds()
    private var lastActivityAt = uptimeSeconds()
    private var closed = false

    /// Nil if the Syphon feed can't start (the app was built without Syphon).
    init?(filter: SCContentFilter, name: String, appName: String?, windowID: CGWindowID?, wantsPreview: @escaping () -> Bool) {
        guard let syphon = SyphonFeed(name: name) else { return nil }
        self.filter = filter
        self.name = name
        self.appName = appName
        self.windowID = windowID
        self.syphon = syphon
        self.sink = WindowFrameSink(syphon: syphon)
        self.wantsPreview = wantsPreview
    }

    func start() {
        let configuration = makeConfiguration()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        } catch {
            finish("Couldn't start: \(error.localizedDescription)")
            return
        }
        self.configuration = configuration
        self.stream = stream
        log("sending \"\(name)\" (\(appName ?? "unknown app"), window \(windowID.map { String($0) } ?? "?")), \(configuration.width)×\(configuration.height)")
        Task {
            do {
                try await stream.startCapture()
            } catch {
                finish("Couldn't start: \(error.localizedDescription)")
            }
        }
        lastTickAt = uptimeSeconds()
        lastActivityAt = lastTickAt
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stops the feed: OBS's source loses it.
    func stop() {
        guard !closed else { return }
        log("stopped sending \"\(name)\"")
        shutDown()
    }

    /// Ends the capture and the Syphon feed, once.
    private func shutDown() {
        guard !closed else { return }
        closed = true
        timer?.invalidate()
        timer = nil
        sink.stopPublishing()
        let stream = stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        syphon.stop()
    }

    /// Renames the feed in OBS's list. A source in OBS set to the old name loses it.
    func rename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { return }
        log("renamed \"\(name)\" to \"\(trimmed)\"")
        name = trimmed
        syphon.name = trimmed
    }

    // MARK: Configuration

    /// The window's size in pixels, from macOS. Zero if it can't say.
    private func windowPixelSize() -> CGSize {
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        return CGSize(width: info.contentRect.width * scale, height: info.contentRect.height * scale)
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let size = windowPixelSize()
        configuration.width = size.width >= 16 ? Int(size.width.rounded()) : 1280
        configuration.height = size.height >= 16 ? Int(size.height.rounded()) : 720
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 4
        configuration.showsCursor = showsPointer
        configuration.ignoreShadowsSingleWindow = true
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    private func applyConfiguration() {
        guard let stream, let configuration else { return }
        configuration.showsCursor = showsPointer
        Task { try? await stream.updateConfiguration(configuration) }
    }

    /// Follows the window as it's resized, so the picture keeps the window's own pixels.
    private func followWindowSize() {
        guard let stream, let configuration else { return }
        let size = windowPixelSize()
        guard size.width >= 16, size.height >= 16,
              abs(size.width - CGFloat(configuration.width)) >= 2 || abs(size.height - CGFloat(configuration.height)) >= 2 else { return }
        configuration.width = Int(size.width.rounded())
        configuration.height = Int(size.height.rounded())
        log("window is now \(configuration.width)×\(configuration.height)")
        Task { try? await stream.updateConfiguration(configuration) }
    }

    // MARK: Once a second

    private func tick() {
        let now = uptimeSeconds()
        let elapsed = max(0.1, now - lastTickAt)
        lastTickAt = now
        let tally = sink.takeTally()
        if let last = tally.lastCallback { lastActivityAt = max(lastActivityAt, last) }

        let onScreen = windowID.flatMap(Self.isOnScreen)
        if onScreen != windowOnScreen {
            windowOnScreen = onScreen
            if onScreen != nil { log("\"\(name)\": window is \(Self.onScreenText(onScreen))") }
        }

        let newStatus: WindowFeedStatus
        if let reason = tally.stopped {
            newStatus = .stopped(reason)
        } else if tally.complete > 0 {
            newStatus = .live(framesPerSecond: Int((Double(tally.complete) / elapsed).rounded()))
        } else if tally.blank + tally.suspended > 0 {
            newStatus = .blank
        } else if tally.idle > 0 {
            newStatus = .still
        } else {
            let quiet = now - lastActivityAt
            newStatus = quiet >= 2 ? .noPictures(seconds: Int(quiet)) : status
        }
        // A rising count of seconds isn't a change worth a log line.
        if !Self.sameKind(newStatus, status) {
            log("\"\(name)\": \(newStatus.text) (complete \(tally.complete), idle \(tally.idle), blank \(tally.blank), suspended \(tally.suspended); window \(Self.onScreenText(onScreen)))")
        }
        if newStatus != status { status = newStatus }
        counts = "Last second: \(tally.complete) new, \(tally.idle) unchanged, \(tally.blank) blank, \(tally.suspended) suspended"
        if tally.width > 0 {
            let size = CGSize(width: tally.width, height: tally.height)
            if size != pixelSize { pixelSize = size }
        }

        if newStatus.isStopped {
            shutDown()
            return
        }

        followWindowSize()
        let wanted = wantsPreview()
        sink.setPreviewWanted(wanted)
        if wanted, let image = sink.takePreview() {
            preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    /// The capture ended on its own, or couldn't start.
    private func finish(_ reason: String) {
        log("\"\(name)\": \(reason)")
        shutDown()
        status = .stopped(reason)
    }

    private func log(_ message: String) {
        WindowFeedLog.shared.write(message)
    }

    private static func sameKind(_ a: WindowFeedStatus, _ b: WindowFeedStatus) -> Bool {
        switch (a, b) {
        case (.starting, .starting), (.live, .live), (.still, .still), (.noPictures, .noPictures), (.blank, .blank): return true
        case (.stopped(let x), .stopped(let y)): return x == y
        default: return false
        }
    }

    /// Whether macOS has the window on screen. Needs no permission: only the window's own
    /// listing, which leaves the key out for a window that isn't.
    private static func isOnScreen(_ windowID: CGWindowID) -> Bool? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let entry = list.first else { return nil }
        return (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    static func onScreenText(_ onScreen: Bool?) -> String {
        switch onScreen {
        case true?: return "on screen"
        case false?: return "not on screen (minimized, hidden or on another desktop)"
        case nil: return "state unknown"
        }
    }
}

// MARK: - The list of feeds

/// Every window being sent to OBS, and the picker that adds more. A window can't be remembered
/// from one launch to the next, because the picker only hands over a window for the moment, so
/// feeds end when Mirror Wall quits.
@MainActor
final class WindowFeedStore: ObservableObject {
    static let shared = WindowFeedStore()

    @Published private(set) var feeds: [WindowFeed] = []
    private var observer: PickerObserver?
    /// A feed whose window went away, being replaced by a new pick under the same name.
    private var replacing: WindowFeed?
    private var listWindow: WindowFeedsWindow?

    static var isAvailable: Bool { SyphonFeed.isAvailable }

    /// Opens macOS's window picker. The chosen window starts going to OBS.
    func pickWindow(replacing old: WindowFeed? = nil) {
        guard Self.isAvailable else { return }
        replacing = old
        let picker = SCContentSharingPicker.shared
        if observer == nil {
            let observer = PickerObserver()
            observer.onPick = { [weak self] filter in
                Task { @MainActor in self?.picked(filter) }
            }
            observer.onCancel = { [weak self] in
                Task { @MainActor in self?.pickEnded() }
            }
            observer.onFail = { error in
                WindowFeedLog.shared.write("window picker failed: \(error.localizedDescription)")
                Task { @MainActor in self.pickEnded() }
            }
            picker.add(observer)
            self.observer = observer
        }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        // Not Mirror Wall's own windows: a feed of its own list would only show itself.
        if let bundleID = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [bundleID] }
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picker.present(using: .window)
    }

    private func pickEnded() {
        replacing = nil
        SCContentSharingPicker.shared.isActive = false
    }

    private func picked(_ filter: SCContentFilter) {
        let old = replacing
        pickEnded()

        var app: String?
        var title: String?
        var windowID: CGWindowID?
        if #available(macOS 15.2, *), let window = filter.includedWindows.first {
            app = window.owningApplication?.applicationName
            title = window.title
            windowID = window.windowID
        }
        if let old { remove(old) }
        let name = WindowFeedName.unique(old?.name ?? WindowFeedName.make(app: app, title: title), among: feeds.map(\.name))
        guard let feed = WindowFeed(filter: filter, name: name, appName: app, windowID: windowID, wantsPreview: { [weak self] in self?.listIsVisible ?? false }) else {
            let alert = NSAlert()
            alert.messageText = "This copy of Mirror Wall can't send windows to OBS"
            alert.informativeText = "It was built without Syphon, which OBS needs to receive them. The Mirror Wall from the download page has it."
            alert.runModal()
            return
        }
        feeds.append(feed)
        feed.start()
        showList()
    }

    /// Stops sending a window and takes it off the list.
    func remove(_ feed: WindowFeed) {
        feed.stop()
        feeds.removeAll { $0 === feed }
    }

    func stopAll() {
        feeds.forEach { $0.stop() }
        feeds.removeAll()
    }

    // MARK: The list's window

    private var listIsVisible: Bool { listWindow?.window.isVisible ?? false }

    func showList() {
        if listWindow == nil { listWindow = WindowFeedsWindow(store: self) }
        listWindow?.show()
    }
}

/// Hears from macOS's window picker. Its calls come on any thread.
private final class PickerObserver: NSObject, SCContentSharingPickerObserver {
    var onPick: ((SCContentFilter) -> Void)?
    var onCancel: (() -> Void)?
    var onFail: ((Error) -> Void)?

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        onPick?(filter)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        onCancel?()
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        onFail?(error)
    }
}

// MARK: - Window and menu items

/// The "Windows Sent to OBS" window.
@MainActor
final class WindowFeedsWindow: NSObject {
    let window: NSWindow

    init(store: WindowFeedStore) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.title = "Windows Sent to OBS"
        window.minSize = NSSize(width: 480, height: 280)
        window.contentView = NSHostingView(rootView: WindowFeedsView(store: store))
        window.center()
        window.setFrameAutosaveName("Windows sent to OBS")
    }

    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct WindowFeedsView: View {
    @ObservedObject var store: WindowFeedStore

    var body: some View {
        VStack(spacing: 0) {
            if store.feeds.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("No windows are going to OBS")
                        .font(.headline)
                    Text("Pick any window, such as Screen Sharing, a browser or a game. In OBS, add a Syphon Client source and choose “[Mirror Wall]” and the window's name.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.feeds) { feed in
                            WindowFeedRow(feed: feed, store: store)
                            Divider()
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("Keep a window open to keep its picture moving: macOS stops drawing it once it's minimized.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Send a Window…") { store.pickWindow() }
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 280)
    }
}

struct WindowFeedRow: View {
    @ObservedObject var feed: WindowFeed
    let store: WindowFeedStore
    @State private var draftName = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let preview = feed.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 96)
            .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text("[Mirror Wall]")
                        .foregroundStyle(.secondary)
                    TextField("Name in OBS", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            feed.rename(to: draftName)
                            draftName = feed.name
                        }
                }
                HStack(spacing: 6) {
                    Circle().fill(feed.status.color).frame(width: 9, height: 9)
                    Text(feed.status.text)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(feed.counts)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Toggle("Show mouse pointer", isOn: $feed.showsPointer)
                    .toggleStyle(.checkbox)
                    .disabled(feed.status.isStopped)
                HStack {
                    if feed.status.isStopped {
                        Button("Pick the Window Again…") { store.pickWindow(replacing: feed) }
                    }
                    Button(feed.status.isStopped ? "Remove" : "Stop Sending") { store.remove(feed) }
                }
            }
        }
        .padding(12)
        .onAppear { draftName = feed.name }
    }

    private var detail: String {
        var parts: [String] = []
        if let app = feed.appName { parts.append(app) }
        if feed.pixelSize.width > 0 { parts.append("\(Int(feed.pixelSize.width))×\(Int(feed.pixelSize.height))") }
        if feed.windowOnScreen != nil { parts.append("window " + WindowFeed.onScreenText(feed.windowOnScreen)) }
        return parts.joined(separator: " · ")
    }
}

/// The two menu items, for File, the menu bar icon and the wall's right-click menu.
struct WindowFeedItems: View {
    @ObservedObject var feeds: WindowFeedStore

    var body: some View {
        if WindowFeedStore.isAvailable {
            Button("Send a Window to OBS (Syphon)…") { feeds.pickWindow() }
            Button(feeds.feeds.isEmpty ? "Windows Sent to OBS" : "Windows Sent to OBS (\(feeds.feeds.count))") { feeds.showList() }
        }
    }
}
