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
    let metrics = Telemetry()
    private(set) var log: RunLog?
    var logURL: URL? { log?.url }
    private var pipeline: EncoderPipeline?
    private let captureQueue = DispatchQueue(label: "iosdirect.capture", qos: .userInitiated)
    private var capturedStream: SCStream? // captureQueue only
    private var stream: SCStream? // main only
    private var pickerPending = false
    private var request = 0
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        do {
            let log = try RunLog(); self.log = log
            let pipeline = EncoderPipeline(metrics: metrics, log: log); self.pipeline = pipeline
            pipeline.onFailure = { [weak self] error in
                DispatchQueue.main.async { self?.finish(state: "failed: \(error)") }
            }
            log.event("run.start", "G1 stub only; iOS=\(UIDevice.current.systemVersion); build=1; bitrate=6000000; fps=30")
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
        updateDeviceState()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "iosdirect.metrics", qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
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
        let snapshot = metrics.snapshot()
        log?.write(snapshot)
        let failure = log?.error()
        DispatchQueue.main.async {
            self.counters = snapshot
            if let failure, !self.state.hasPrefix("failed: log") { self.finish(state: "failed: log write: \(failure)") }
        }
    }
    private func setState(_ value: String) {
        state = value; metrics.update { $0.captureState = value }; log?.event("capture.state", value)
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
    func stop() { finish(state: "stopped by user") }
    func reset() {
        pipeline?.resetCounters()
        log?.event("counters.reset", "epoch=\(metrics.snapshot().resetEpoch)")
    }
    private func finish(state: String) { // main only; invalidate admission before SCStream stop
        request += 1; pickerPending = false; busy = false
        SCContentSharingPicker.shared.isActive = false
        let old = stream; stream = nil
        captureQueue.sync { capturedStream = nil; pipeline?.stop() }
        setState(state)
        old?.stopCapture { [weak self] error in
            self?.log?.event("stream.stopCompletion", error.map { String(describing: $0) } ?? "success")
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
            let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            let token = self.request
            do {
                try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
                self.stream = newStream
                self.captureQueue.sync { self.pipeline?.start(); self.capturedStream = newStream }
                self.log?.event("stream.startRequested", "full display; native capture dimensions; SDR; no audio output")
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
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        SCContentSharingPicker.shared.remove(self)
    }
}
