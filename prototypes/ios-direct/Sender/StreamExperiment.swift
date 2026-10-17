import SwiftUI
import UIKit
import IOSDirectShared

@MainActor
final class StreamExperiment: ObservableObject {
    let discovery = RadioExperiment() // Reuse G2 Bonjour recovery; no synthetic sender is started here.
    let sink: VideoNetworkSink
    let capture: CaptureExperiment
    @Published private(set) var state = "idle"
    @Published private(set) var connected = false
    @Published private(set) var running = false
    @Published private(set) var logFailure: String?
    private let radioLog: RadioLog?
    var radioLogURL: URL? { radioLog?.url }
    init() {
        let sink = VideoNetworkSink(); self.sink = sink
        let capture = CaptureExperiment(videoSink: sink); self.capture = capture
        do { radioLog = try RadioLog(receiver: false) }
        catch { radioLog = nil; logFailure = error.localizedDescription }
        let metrics = capture.metrics, log = capture.log
        sink.onEvent = { name, details in log?.event(name, "\(details) appState=\(metrics.snapshot().appState)") }
        sink.onState = { [weak self] state, ready in
            DispatchQueue.main.async { self?.state = state; self?.connected = ready }
        }
        let radioLog = self.radioLog
        sink.onRadioSample = { [weak self] sample in
            DispatchQueue.main.async { self?.logFailure = radioLog?.error() }
            log?.event("video.transport", "session=\(sample.id) state=\(sample.state) path=\(sample.path?.availableInterfaces.joined(separator: ",") ?? "unknown") appState=\(metrics.snapshot().appState)")
        }
    }
    func connect() {
        guard !running, let endpoint = discovery.receivers.first(where: { $0.id == discovery.selected })?.endpoint else { return }
        do {
            let code = try RadioCode(discovery.code)
            guard radioLog != nil, radioLog?.error() == nil, capture.log != nil, capture.log?.error() == nil else {
                state = "log unavailable"; return
            }
            let key = "iosdirect.radio.installUUID"
            let install = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
            UserDefaults.standard.set(install.uuidString, forKey: key)
            running = true
            sink.start(endpoint: endpoint, code: code, install: install, label: UIDevice.current.name, log: radioLog)
        } catch { state = String(describing: error) }
    }
    func disconnect() {
        sink.stop(); if capture.busy { capture.stop() }; running = false; connected = false; state = "disconnected"
    }
    deinit { sink.stop() }
}

struct StreamExperimentView: View {
    @ObservedObject var experiment: StreamExperiment
    @ObservedObject var capture: CaptureExperiment
    let otherCaptureBusy: Bool
    @State private var clock = false
    var body: some View {
        NavigationStack {
            Form {
                StreamConnectionControls(experiment: experiment, discovery: experiment.discovery)
                Section("Full-display consent") {
                    Text("Session: \(experiment.state)")
                    Text("Capture: \(capture.state) · encoder: \(capture.counters.encoderState)")
                    Button("Share full display") { capture.shareDisplay() }
                        .disabled(!experiment.connected || capture.busy || otherCaptureBusy)
                    Button("Stop capture") { capture.stop() }.disabled(!capture.busy)
                    Button("Disconnect") { experiment.disconnect() }.disabled(!experiment.running)
                    Button("Latency clock screen") { clock = true }
                    if let failure = capture.logFailure ?? experiment.logFailure { Text("Log failed: \(failure)").foregroundStyle(.red) }
                    if let url = capture.logURL { ShareLink("Export stream stage log", item: url) }
                    if let url = experiment.radioLogURL { ShareLink("Export TLS/path log", item: url) }
                }
                Section("Once per second · stages in current app state") {
                    let m = capture.counters
                    Text("App: \(m.appState)")
                    Text(String(format: "Capture %.1f · paced %.1f · encoded %.1f fps", m.capturedFPS, m.pacedFPS, m.encodedFPS))
                    Text(String(format: "Sent %.1f · ACKed %.1f fps · %.2f Mbit/s", m.sentFPS, m.ackedFPS, m.sentMbit))
                    if let v = m.video {
                        Text(String(format: "Queue %d B / %.1f ms · outstanding %d B", v.queueBytes, v.queueAgeMS, v.outstandingBytes))
                        Text("Sent / ACKed / decoded ACKs: \(v.sent) / \(v.acked) / \(v.decodedAcks)")
                        Text("Reconnects \(v.reconnects) · attempts \(v.reconnectAttempts) · IDR requests \(v.keyframeRequests)")
                        Text("Drops: \(v.drops.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
                        Text("RTT p50 / p95: \(number(v.rttP50MS)) / \(number(v.rttP95MS)) ms")
                    }
                    Text("Keyframes \(m.keyframes) · thermal \(m.thermalState) · memory \(number(m.residentMemoryMB)) MB")
                    Text("Pixels \(m.sourceDimensions.map { "\($0.width)×\($0.height)" } ?? "—") · orientation \(m.frameOrientation.map(String.init) ?? "—")")
                }
            }.navigationTitle("Stream experiment")
                .onAppear { experiment.discovery.browse() }
                .fullScreenCover(isPresented: $clock) { LatencyClockView() }
        }
    }
    private func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
}
private struct StreamConnectionControls: View {
    @ObservedObject var experiment: StreamExperiment
    @ObservedObject var discovery: RadioExperiment
    var body: some View {
        Section("Authenticate, then share") {
            Text("Browser: \(discovery.browserState)")
            Picker("Receiver", selection: $discovery.selected) {
                Text("Select receiver").tag("")
                ForEach(discovery.receivers) { result in Text(result.label).tag(result.id) }
            }.disabled(experiment.running)
            TextField("Mac code", text: $discovery.code).textInputAutocapitalization(.characters)
                .autocorrectionDisabled().font(.system(.body, design: .monospaced)).disabled(experiment.running)
            Button("Connect") { experiment.connect() }.disabled(experiment.running || discovery.selected.isEmpty)
            Button("Restart discovery") { discovery.restartBrowser(reason: "stream user retry") }
        }
    }
}

/// Optical reference: milliseconds from the same monotonic clock used by transport.
/// The clock is foreground UI only; background capture tests use other changing content.
private final class ClockDigits: UILabel {
    private var link: CADisplayLink?
    private final class Target: NSObject {
        weak var label: ClockDigits?
        @objc func tick(_ link: CADisplayLink) { label?.text = String(radioNow() / 1_000_000) }
    }
    private let target = Target()
    override init(frame: CGRect) {
        super.init(frame: frame); target.label = self
        backgroundColor = .black; textColor = .white; textAlignment = .center
        font = .monospacedDigitSystemFont(ofSize: 100, weight: .bold)
        adjustsFontSizeToFitWidth = true; minimumScaleFactor = 0.1
        let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func stop() { link?.invalidate(); link = nil }
    deinit { stop() }
}
private struct ClockDisplay: UIViewRepresentable {
    func makeUIView(context: Context) -> ClockDigits { ClockDigits(frame: .zero) }
    func updateUIView(_ view: ClockDigits, context: Context) {}
    static func dismantleUIView(_ view: ClockDigits, coordinator: ()) { view.stop() }
}
private struct LatencyClockView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea(); ClockDisplay().padding(20)
            Button("Close") { dismiss() }.foregroundStyle(.white).padding()
        }.statusBarHidden()
    }
}
