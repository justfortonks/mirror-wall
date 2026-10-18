import Foundation
import Combine
import UIKit
import ScreenCaptureKit
import IOSDirectShared

/// UI, picker and stream lifecycle belong to main. Samples belong to captureQueue;
/// the encoder's two-frame mailbox is the only crossing for image buffers.
final class CaptureExperiment: NSObject, ObservableObject, SCContentSharingPickerObserver, SCStreamDelegate, SCStreamOutput {
    @Published private(set) var state = "idle"
    @Published private(set) var counters = MetricsSnapshot()
    @Published private(set) var busy = false
    @Published private(set) var logFailure: String?
    @Published private(set) var streamSettings = StreamSettings()
    let metrics = Telemetry()
    private(set) var log: RunLog?
    var logURL: URL? { log?.url }
    private let videoSink: VideoNetworkSink?
    private var previousSample: MetricsSnapshot?
    private var pipeline: EncoderPipeline?
    private let captureQueue = DispatchQueue(label: "iosdirect.capture", qos: .userInitiated)
    private var rotationProbe = RotationAttachmentProbe() // captureQueue only
    private var latestDeviceDegrees: UInt16? // main only
    private var orientationNotifications = 0, backgroundOrientationNotifications = 0 // main only
    private var capturedStream: SCStream? // captureQueue only
    private var stream: SCStream? // main only
    private var pickerPending = false
    private var request = 0
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    init(videoSink: VideoNetworkSink? = nil) {
        self.videoSink = videoSink
        super.init()
        do {
            let log = try RunLog(); self.log = log
            let pipeline = EncoderPipeline(metrics: metrics, log: log, network: videoSink); self.pipeline = pipeline
            log.event("run.start", "mode=\(videoSink == nil ? "capture-stub" : "stream-video"); iOS=\(UIDevice.current.systemVersion); build=1; bitrate=6000000; fps=30")
        } catch { setState("failed: log creation: \(error.localizedDescription)") }
        SCContentSharingPicker.shared.add(self)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification,
                     UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                self.updateDeviceState()
                switch note.name {
                case UIApplication.didBecomeActiveNotification: self.metrics.update { $0.appState = "active" }
                case UIApplication.willResignActiveNotification, UIApplication.willEnterForegroundNotification:
                    self.metrics.update { $0.appState = "inactive" }
                case UIApplication.didEnterBackgroundNotification: self.metrics.update { $0.appState = "background" }
                default: break
                }
                self.log?.event("lifecycle", "\(note.name.rawValue) appState=\(self.metrics.snapshot().appState)")
            })
        }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observers.append(center.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.observeOrientation(notification: true)
        })
        observeOrientation(notification: false)
        updateDeviceState()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "iosdirect.metrics", qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
    }
    private func observeOrientation(notification: Bool) { // main only
        let orientation = UIDevice.current.orientation
        let background = UIApplication.shared.applicationState == .background
        let capturing = stream != nil
        if notification {
            orientationNotifications += 1
            if background && capturing { backgroundOrientationNotifications += 1 }
        }
        // Face-up/down and unknown carry no planar rotation; retain the last usable hint.
        let degrees: UInt16?
        switch orientation {
        case .portrait: degrees = 0
        case .landscapeLeft: degrees = 90
        case .portraitUpsideDown: degrees = 180
        case .landscapeRight: degrees = 270
        default: degrees = nil
        }
        log?.event("capture.deviceOrientation", "notification=\(notification) raw=\(orientation.rawValue) degrees=\(degrees.map(String.init) ?? "unavailable") background=\(background) capturing=\(capturing) backgroundDuringCaptureNotifications=\(backgroundOrientationNotifications)")
        if let degrees { latestDeviceDegrees = degrees }
        if capturing, let latestDeviceDegrees {
            videoSink?.orientationHint(OrientationHint(degrees: latestDeviceDegrees, source: .device, monotonicNs: radioNow()))
        }
    }
    private func updateDeviceState() { // main only
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }
        let device = UIDevice.current
        let battery: String
        switch device.batteryState {
        case .unknown: battery = "unknown"
        case .unplugged: battery = "unplugged"
        case .charging: battery = "charging"
        case .full: battery = "full"
        @unknown default: battery = "unknown"
        }
        metrics.update { $0.appState = appState; $0.batteryLevel = Double(device.batteryLevel); $0.batteryState = battery }
    }
    private func tick() {
        pipeline?.sampleSink()
        let process = ProcessInfo.processInfo
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        metrics.update {
            $0.monotonicTime = uptime(); $0.wallTime = wallTime()
            $0.thermalState = thermal; $0.lowPower = process.isLowPowerModeEnabled
            $0.residentMemoryMB = residentMemoryMB()
        }
        let current = metrics.snapshot(), network = videoSink?.snapshot()
        if let previousSample, current.resetEpoch == previousSample.resetEpoch {
            let seconds = current.monotonicTime - previousSample.monotonicTime
            if seconds > 0 {
                metrics.update {
                    $0.capturedFPS = Double(current.validFrames - previousSample.validFrames) / seconds
                    $0.pacedFPS = Double(current.pacedFrames - previousSample.pacedFrames) / seconds
                    $0.encodedFPS = Double(current.encodeCompleted - previousSample.encodeCompleted) / seconds
                    $0.encodedMbit = Double(current.encodeBytes - previousSample.encodeBytes) * 8 / seconds / 1e6
                    if let network {
                        $0.sentFPS = Double(network.sent - (previousSample.video?.sent ?? 0)) / seconds
                        $0.ackedFPS = Double(network.acked - (previousSample.video?.acked ?? 0)) / seconds
                        $0.sentMbit = Double(network.sentBytes - (previousSample.video?.sentBytes ?? 0)) * 8 / seconds / 1e6
                    }
                }
            }
        }
        metrics.update { $0.video = network }
        let snapshot = metrics.snapshot(); previousSample = snapshot
        log?.write(snapshot)
        let failure = log?.error()
        DispatchQueue.main.async {
            self.counters = snapshot
            self.logFailure = failure // Logging failure is visible, but cannot tear down capture.
        }
    }
    private func setState(_ value: String) {
        state = value; metrics.update { $0.captureState = value }; log?.event("capture.state", value)
    }
    func setStreamSettings(_ next: StreamSettings) { // main only
        guard next != streamSettings else { return }
        streamSettings = next
        captureQueue.sync { pipeline?.setSettings(next) }
        if stream != nil {
            log?.event("stream.reconfigurationUnavailable", "live encoder settings applied; SCK dimensions remain as requested at Share; Stop/Share to request a larger capture size")
        }
    }
    func shareDisplay() {
        guard !busy, log != nil, log?.error() == nil else { return }
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { setState("failed: screen capture unavailable"); return }
        request += 1; pickerPending = true; busy = true
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.isActive = true
        setState("picker shown")
        picker.present()
    }
    func stop() { finish(state: "stopped by user", stopCapture: true) }
    func reset() {
        pipeline?.resetCounters()
        log?.event("counters.reset", "epoch=\(metrics.snapshot().resetEpoch)")
    }
    private func finish(state: String, stopCapture: Bool = false) { // main only
        // Capture consent ends independently of the authenticated transport. The
        // next Share starts a fresh encoder generation/config/IDR on that session.
        request += 1; pickerPending = false; busy = false
        SCContentSharingPicker.shared.isActive = false
        let old = stream; stream = nil
        log?.event("capture.orientationNotificationSummary", "notifications=\(orientationNotifications) backgroundDuringCapture=\(backgroundOrientationNotifications); zero does not prove OS suppression")
        captureQueue.sync { capturedStream = nil; pipeline?.stop() }
        setState(state)
        if stopCapture {
            old?.stopCapture { [weak self] error in
                self?.log?.event("stream.stopCompletion", error.map { String(describing: $0) } ?? "success")
            }
        }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async {
            guard self.pickerPending else { return }
            self.finish(state: "cancelled")
        }
    }
    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        DispatchQueue.main.async {
            guard self.pickerPending else { return }
            self.finish(state: "failed: \(error)")
        }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async {
            guard self.pickerPending else { self.log?.event("picker.ignored", "no explicit pending request"); return }
            self.pickerPending = false
            guard filter.style == .display else { self.finish(state: "failed: full display was not selected"); return }
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = false
            configuration.captureDynamicRange = .SDR
            let rect = filter.contentRect
            let scale = CGFloat(filter.pointPixelScale)
            if let size = self.streamSettings.preset.output(width: Int(rect.width * scale), height: Int(rect.height * scale)) {
                configuration.width = size.width; configuration.height = size.height
            }
            // iPhoneOS 27.1 SCStream.h exposes width/height on iOS, but explicitly
            // excludes minimumFrameInterval, pixelFormat, scalesToFit,
            // preservesAspectRatio and updateConfiguration. Keep the PTS pacer;
            // accept the delivered pixel format and observe frame metadata.
            let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            let token = self.request
            do {
                try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
                self.stream = newStream
                self.captureQueue.sync { self.pipeline?.start(); self.rotationProbe = RotationAttachmentProbe(); self.capturedStream = newStream }
                self.orientationNotifications = 0; self.backgroundOrientationNotifications = 0
                self.observeOrientation(notification: false)
                self.log?.event("stream.startRequested", "full display; filterRect=\(rect) pointPixelScale=\(scale); requested=\(configuration.width)x\(configuration.height); SDR; no audio output")
                self.log?.event("stream.configurationLimits", "iOS 27.1 SDK: minimumFrameInterval/pixelFormat/scalesToFit/preservesAspectRatio/updateConfiguration unavailable; explicit \(self.streamSettings.fps)fps pacer; preset=\(self.streamSettings.preset.rawValue) targetBitrate=\(self.streamSettings.targetBitrate); delivered pixel format recorded")
                newStream.startCapture { [weak self, weak newStream] error in
                    DispatchQueue.main.async {
                        guard let self, let newStream, token == self.request, self.stream === newStream else { return }
                        if let error { self.finish(state: "failed: \(error)") }
                        else { self.setState("capturing") }
                    }
                }
            } catch { self.finish(state: "failed: \(error)") }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, stream === capturedStream else { return }
        rotationProbe.inspect(sampleBuffer, log: log)
        pipeline?.offer(sampleBuffer)
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // Stop downstream immediately, independently of UI delivery.
        captureQueue.async {
            guard self.capturedStream === stream else { return }
            self.capturedStream = nil; self.pipeline?.stop()
            self.log?.event("stream.systemStop", String(describing: error))
            DispatchQueue.main.async {
                guard self.stream === stream else { return }
                self.finish(state: "stopped by system")
            }
        }
    }
    deinit {
        timer?.cancel()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        SCContentSharingPicker.shared.remove(self)
        pipeline?.stop()
        stream?.stopCapture { _ in }
    }
}
