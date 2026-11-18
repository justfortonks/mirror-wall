import AppKit
import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import IOSurface
import MirrorCore
import ScreenCaptureKit
import SwiftUI

/// The pictures the Stage shows besides phones: a Mac window (captured with ScreenCaptureKit, the
/// same way File › Send a Window to OBS does, but drawn on the Stage instead of sent to OBS) and
/// a camera (an AVCaptureSession). A phone's picture comes from its slot (Slot.swift).

/// Seconds on a steady clock.
private func uptimeSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}

// MARK: - A window's pictures, to layers

/// Hands the newest picture of a captured window to the layers showing it, on the main thread, a
/// picture at a time: if the screen is slower than the capture, older pictures are skipped.
final class StagePictureRelay {
    private let lock = NSLock()
    // Guarded by `lock`.
    private var observers: [UUID: (IOSurface) -> Void] = [:]
    private var newest: IOSurface?
    private var delivering = false

    /// The newest picture, if any has arrived.
    var latest: IOSurface? {
        lock.lock()
        defer { lock.unlock() }
        return newest
    }

    /// Calls `observer`, on the main thread, with each new picture. Returns what to give `remove`.
    func add(_ observer: @escaping (IOSurface) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        observers[token] = observer
        lock.unlock()
        return token
    }

    func remove(_ token: UUID) {
        lock.lock()
        observers[token] = nil
        lock.unlock()
    }

    /// Forgets the picture, so a window that's started again doesn't show its old one.
    func clear() {
        lock.lock()
        newest = nil
        lock.unlock()
    }

    /// Called on the capture queue with each new picture.
    func publish(_ surface: IOSurface) {
        lock.lock()
        newest = surface
        let needsDelivery = !delivering
        delivering = true
        lock.unlock()
        if needsDelivery {
            DispatchQueue.main.async { [self] in deliver() }
        }
    }

    private func deliver() {
        lock.lock()
        delivering = false
        let surface = newest
        let all = Array(observers.values)
        lock.unlock()
        guard let surface else { return }
        for observer in all { observer(surface) }
    }
}

/// Shows a captured window's pictures, straight from the capture's memory, with no copying.
struct StageSurfaceView: NSViewRepresentable {
    let relay: StagePictureRelay

    func makeNSView(context: Context) -> SurfaceHostView {
        SurfaceHostView(relay: relay)
    }

    func updateNSView(_ view: SurfaceHostView, context: Context) {}

    static func dismantleNSView(_ view: SurfaceHostView, coordinator: ()) {
        view.detach()
    }

    final class SurfaceHostView: NSView {
        private let relay: StagePictureRelay
        private var token: UUID?

        init(relay: StagePictureRelay) {
            self.relay = relay
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.contentsGravity = .resizeAspect
            token = relay.add { [weak self] surface in self?.show(surface) }
            if let surface = relay.latest { show(surface) }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        private func show(_ surface: IOSurface) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = surface
            CATransaction.commit()
        }

        func detach() {
            if let token { relay.remove(token) }
            token = nil
        }

        // Let SwiftUI handle clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Receiving a window's pictures

/// Receives one window's pictures from ScreenCaptureKit on its own queue and passes each to the
/// relay, keeping tallies for the source's status.
private final class StageFrameSink: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Tally {
        var frames = 0
        /// The size of the last picture, in pixels.
        var width = 0
        var height = 0
        /// Set when the capture ended: why.
        var stopped: String?
    }

    let queue = DispatchQueue(label: "Mirror Wall stage window capture", qos: .userInteractive)
    let relay: StagePictureRelay
    private let lock = NSLock()
    // Guarded by `lock`.
    private var tally = Tally()

    init(relay: StagePictureRelay) {
        self.relay = relay
    }

    /// What arrived since the last call, and the counts start again.
    func takeTally() -> Tally {
        lock.lock()
        defer { lock.unlock() }
        let taken = tally
        tally.frames = 0
        return taken
    }

    func reset() {
        lock.lock()
        tally = Tally()
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let rawStatus = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surfaceRef = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else { return }
        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)
        lock.lock()
        tally.frames += 1
        tally.width = CVPixelBufferGetWidth(image)
        tally.height = CVPixelBufferGetHeight(image)
        lock.unlock()
        relay.publish(surface)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let code = (error as NSError).code
        // -3817: the person chose Stop Sharing in the menu bar.
        let reason = code == -3817 ? "Stopped from the menu bar" : "macOS ended the capture (the window was probably closed)"
        lock.lock()
        tally.stopped = reason
        lock.unlock()
    }
}

// MARK: - A Mac window on the Stage

/// One Mac window being captured for the Stage. It runs while the Stage is open and is stopped
/// while it's closed (the window stays chosen, so opening the Stage brings it back).
@MainActor
final class StageWindowSource: ObservableObject {
    enum Status: Equatable {
        case starting
        case live
        /// The capture ended, with the reason.
        case stopped(String)
    }

    /// The name it goes by in layouts ("Safari – Docs").
    let key: String
    /// The app the window belongs to, if macOS said.
    let appName: String?
    let relay: StagePictureRelay
    @Published private(set) var status = Status.starting
    /// The picture's size in pixels, once one has arrived.
    @Published private(set) var pixelSize = CGSize.zero
    /// Whether macOS has the window on screen: not when it's minimized, hidden or on another
    /// desktop, when its picture stops moving. Nil when this macOS doesn't say which window it is.
    @Published private(set) var onScreen: Bool?

    private let filter: SCContentFilter
    private let windowID: CGWindowID?
    private let sink: StageFrameSink
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var timer: Timer?

    init(filter: SCContentFilter, key: String, appName: String?, windowID: CGWindowID?) {
        self.filter = filter
        self.key = key
        self.appName = appName
        self.windowID = windowID
        let relay = StagePictureRelay()
        self.relay = relay
        self.sink = StageFrameSink(relay: relay)
    }

    var isRunning: Bool { stream != nil }

    func start() {
        guard stream == nil else { return }
        let configuration = makeConfiguration()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        } catch {
            status = .stopped("Couldn't start: \(error.localizedDescription)")
            return
        }
        self.configuration = configuration
        self.stream = stream
        status = .starting
        sink.reset()
        WindowFeedLog.shared.write("stage: capturing \"\(key)\" (window \(windowID.map { String($0) } ?? "?")), \(configuration.width)×\(configuration.height)")
        Task {
            do {
                try await stream.startCapture()
            } catch {
                finish("Couldn't start: \(error.localizedDescription)")
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stops capturing, keeping the window chosen so `start` can bring it back.
    func stop() {
        guard stream != nil else { return }
        timer?.invalidate()
        timer = nil
        let stream = stream
        self.stream = nil
        configuration = nil
        Task { try? await stream?.stopCapture() }
        if status == .live { status = .starting }
        relay.clear()
    }

    /// The capture ended on its own, or couldn't start.
    private func finish(_ reason: String) {
        WindowFeedLog.shared.write("stage: \"\(key)\": \(reason)")
        stop()
        status = .stopped(reason)
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
        configuration.showsCursor = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    /// Follows the window as it's resized, so the picture keeps the window's own pixels.
    private func followWindowSize() {
        guard let stream, let configuration else { return }
        let size = windowPixelSize()
        guard size.width >= 16, size.height >= 16,
              abs(size.width - CGFloat(configuration.width)) >= 2 || abs(size.height - CGFloat(configuration.height)) >= 2 else { return }
        configuration.width = Int(size.width.rounded())
        configuration.height = Int(size.height.rounded())
        Task { try? await stream.updateConfiguration(configuration) }
    }

    // MARK: Once a second

    private func tick() {
        let tally = sink.takeTally()
        if let reason = tally.stopped {
            finish(reason)
            return
        }
        if tally.frames > 0, status != .live { status = .live }
        if tally.width > 0 {
            let size = CGSize(width: tally.width, height: tally.height)
            if size != pixelSize { pixelSize = size }
        }
        let onScreenNow = windowID.flatMap(Self.isOnScreen)
        if onScreenNow != onScreen { onScreen = onScreenNow }
        followWindowSize()
    }

    /// Whether macOS has the window on screen. Needs no permission: only the window's own
    /// listing, which leaves the key out for a window that isn't.
    private static func isOnScreen(_ windowID: CGWindowID) -> Bool? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let entry = list.first else { return nil }
        return (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }
}

// MARK: - A camera on the Stage

/// One camera, running while the Stage is open (so its light is off while it isn't). Asks macOS
/// for permission the first time.
@MainActor
final class StageCameraSource: ObservableObject {
    enum Status: Equatable {
        case starting
        case live
        /// Camera access is off for Mirror Wall in System Settings › Privacy & Security › Camera.
        case noPermission
        /// The camera isn't plugged in, or something else has taken it.
        case notFound
    }

    let deviceID: String
    @Published private(set) var name: String
    @Published private(set) var status = Status.starting
    /// The picture's size in pixels, once the camera is running.
    @Published private(set) var pixelSize = CGSize.zero
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "Mirror Wall camera")
    private var wantsRunning = false

    init(deviceID: String, name: String) {
        self.deviceID = deviceID
        self.name = name
    }

    /// The cameras on this Mac: built in, plugged in, a phone or a desk camera.
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    func start() {
        if wantsRunning, status == .live { return }
        wantsRunning = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted { self.run() } else { self.status = .noPermission }
                }
            }
        default:
            status = .noPermission
        }
    }

    func stop() {
        wantsRunning = false
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
        if status == .live { status = .starting }
    }

    /// Cameras were plugged in or out: starts this one again if it's back, or notes it's gone.
    func devicesChanged() {
        guard wantsRunning else { return }
        if AVCaptureDevice(uniqueID: deviceID) == nil {
            status = .notFound
        } else if status == .notFound {
            run()
        }
    }

    private func run() {
        guard wantsRunning else { return }
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            status = .notFound
            return
        }
        name = device.localizedName
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            for existing in session.inputs { session.removeInput(existing) }
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
        } catch {
            status = .notFound
            return
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        pixelSize = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
        status = .live
        let session = session
        queue.async { if !session.isRunning { session.startRunning() } }
    }
}

/// Shows a camera's picture.
struct StageCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraHostView {
        CameraHostView(session: session)
    }

    func updateNSView(_ view: CameraHostView, context: Context) {}

    final class CameraHostView: NSView {
        private let preview: AVCaptureVideoPreviewLayer

        init(session: AVCaptureSession) {
            preview = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)
            preview.videoGravity = .resizeAspect
            let host = CALayer()
            host.backgroundColor = NSColor.black.cgColor
            host.addSublayer(preview)
            layer = host
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        // Let SwiftUI handle clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
        }
    }
}
