import SwiftUI
import UIKit
import Network
import Combine
import IOSDirectShared

@MainActor
final class StreamExperiment: ObservableObject {
    let discovery = RadioExperiment() // Reuse G2 Bonjour recovery; no synthetic sender is started here.
    let sink: VideoNetworkSink
    let capture: CaptureExperiment
    @Published private(set) var state = "idle"
    @Published private(set) var connected = false
    @Published private(set) var running = false
    @Published private(set) var unreachable = false
    private var connectionRun = UUID()
    private var captureActivity: AnyCancellable?
    @Published private(set) var logFailure: String?
    private let radioLog: RadioLog?
    private var rePairObserver: NSObjectProtocol?
    private var forgottenObserver: NSObjectProtocol?
    private var connectionRID: UUID?
    var radioLogURL: URL? { radioLog?.url }
    init() {
        let sink = VideoNetworkSink(); self.sink = sink
        let capture = CaptureExperiment(videoSink: sink); self.capture = capture
        do { radioLog = try RadioLog(receiver: false) }
        catch { radioLog = nil; logFailure = error.localizedDescription }
        forgottenObserver = NotificationCenter.default.addObserver(forName: .pairingForgotten, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.connectionRID == notification.object as? UUID { self.disconnect() }
            }
        }
        rePairObserver = NotificationCenter.default.addObserver(forName: .pairingWillBegin, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.connectionRID == notification.object as? UUID { self.disconnect() }
            }
        }
        discovery.onReceiversChanged = { [weak self] in
            guard let self else { return }
            self.sink.setReceiverDiscovered(self.discovery.receivers.contains { $0.rid == self.connectionRID })
        }
        discovery.onRecoveryAvailabilityChanged = { [weak sink] allowed in sink?.setRecoveryAllowed(allowed) }
        captureActivity = capture.$busy.sink { [weak discovery] busy in discovery?.setBackgroundCaptureActive(busy) }
        sink.onUnreachable = { [weak self] in DispatchQueue.main.async {
            self?.unreachable = true
        } }
        let metrics = capture.metrics, log = capture.log
        sink.onEvent = { name, details in log?.event(name, "\(details) appState=\(metrics.snapshot().appState)") }
        sink.onState = { [weak self] state, ready in
            DispatchQueue.main.async {
                guard let self else { return }; self.state = state; self.connected = ready
            }
        }
        sink.onStopped = { [weak self] in DispatchQueue.main.async {
            guard let self else { return }; self.running = false; self.connected = false
            if self.capture.busy { self.capture.stop() }
        } }
        sink.onPairingRejected = { [weak self] rid, rejection in DispatchQueue.main.async {
            guard let self, self.connectionRID == rid else { return }
            PhonePairingState.shared.refresh(rid, store: self.discovery.pairingStore)
            PhonePairingState.shared.reject(rid, reason: rejection)
            self.discovery.pairingState = rejection.message
            self.running = false; self.connected = false
            // Sharing may have been authorized earlier, but recovery requires a new
            // pairing and explicit capture consent. Do not leave capture busy.
            if self.capture.busy { self.capture.stop() }
        } }
        let radioLog = self.radioLog
        sink.onRadioSample = { [weak self] sample in
            DispatchQueue.main.async { self?.logFailure = radioLog?.error() }
            log?.event("video.transport", "session=\(sample.id) state=\(sample.state) path=\(sample.path?.availableInterfaces.joined(separator: ",") ?? "unknown") appState=\(metrics.snapshot().appState)")
        }
    }
    func connect() {
        guard !running, discovery.canConnect(), let endpoint = discovery.receivers.first(where: { $0.id == discovery.selected })?.endpoint else { return }
        do {
            let credential = try discovery.credential()
            guard radioLog != nil, radioLog?.error() == nil, capture.log != nil, capture.log?.error() == nil else {
                state = "log unavailable"; return
            }
            let install = discovery.installID
            connectionRun = UUID(); unreachable = false
            running = true; connectionRID = credential.rid; discovery.pinSelection(credential.rid)
            startSink(endpoint: endpoint, credential: credential, install: install)
        } catch { state = String(describing: error) }
    }
    private func startSink(endpoint: NWEndpoint, credential: DeviceCredential, install: UUID) {
        let discovery = self.discovery
        sink.start(endpoint: endpoint, credential: credential, install: install, label: UIDevice.current.name,
            log: radioLog, receiverDiscovered: true, pairingStore: discovery.pairingStore,
            refreshReceiver: { [weak discovery] completion in DispatchQueue.main.async {
                guard let discovery else { completion(nil); return }
                discovery.refreshReceiver(credential.rid, completion: completion)
            } })
    }
    func tryAgain() {
        guard let rid = connectionRID ?? discovery.selectedRID else { return }
        do {
            guard let credential = try discovery.pairingStore.credential(rid: rid) else { return }
            connectionRun = UUID(); let run = connectionRun
            running = true; connected = false; unreachable = false; state = "Reconnecting…"
            connectionRID = rid; discovery.pinSelection(rid)
            discovery.refreshReceiver(rid) { [weak self] endpoint in
                guard let self, self.connectionRun == run else { return }
                guard let endpoint else {
                    self.running = false; self.unreachable = true; self.state = ClientSessionPolicy.unreachableMessage; return
                }
                self.startSink(endpoint: endpoint, credential: credential, install: self.discovery.installID)
            }
        } catch { state = String(describing: error) }
    }
    func shareDisplay() {
        guard connected, !capture.busy else { return }; capture.shareDisplay()
    }
    func disconnect() {
        connectionRun = UUID(); sink.stop(); if capture.busy { capture.stop() }
        running = false; connected = false; unreachable = false; connectionRID = nil; discovery.pinSelection(nil); state = "Disconnected — tap Connect"
    }
    func forgetReceiver() {
        let rid = connectionRID ?? discovery.selectedReceiver?.rid
        disconnect(); discovery.forget(rid: rid)
    }
    deinit { if let rePairObserver { NotificationCenter.default.removeObserver(rePairObserver) }; if let forgottenObserver { NotificationCenter.default.removeObserver(forgottenObserver) }; sink.stop() }
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
                Section("Stream quality") {
                    Picker("Preset", selection: Binding(get: { capture.streamSettings.preset }, set: {
                        capture.setStreamSettings(StreamSettings(preset: $0, sixtyFPS: capture.streamSettings.sixtyFPS))
                    })) {
                        ForEach(StreamPreset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("60 fps", isOn: Binding(get: { capture.streamSettings.sixtyFPS }, set: {
                        capture.setStreamSettings(StreamSettings(preset: capture.streamSettings.preset, sixtyFPS: $0))
                    }))
                    Text("Target \(capture.streamSettings.targetBitrate / 1_000_000) Mbit/s · up to \(capture.streamSettings.fps) fps")
                    if capture.busy {
                        Text("Quality changes apply while sharing. To request a larger capture size, stop capture and Share again.")
                    }
                }
                Section("Full-display consent") {
                    Text("Session: \(experiment.state)")
                    Text("Capture: \(capture.state) · encoder: \(capture.counters.encoderState)")
                    Button("Share full display") { experiment.shareDisplay() }
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
                    Text(String(format: "Encoded %.2f Mbit/s · %@ · %d fps · target %.0f Mbit/s", m.encodedMbit, m.streamPreset, m.maxFPS, Double(m.bitrate) / 1e6))
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
        }.modifier(PairingScannerPresenter(presentation: experiment.discovery.scanner, scanned: { experiment.discovery.scan($0, expectedRID: $1) }))
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
                ForEach(discovery.receivers) { result in Text("\(result.label) · \(discovery.pairingLabel(result))").tag(result.id) }
            }.disabled(experiment.running)
            PairingControls(discovery: discovery, forget: { experiment.forgetReceiver() })
            Button("Connect") { experiment.connect() }.disabled(experiment.running || !discovery.canConnect() || discovery.pairingBusy)
            if experiment.unreachable {
                Button("Try again") { experiment.tryAgain() }.disabled(experiment.running)
                Button("Pair again") { discovery.scanner.present(rid: discovery.selectedRID) }
            }
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
    // Prevent the counter's large intrinsic width from expanding the SwiftUI cover
    // and pushing its exit button off screen. Geometry supplies the actual bounds.
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }
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
    @State private var showDone = true
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                ClockDisplay()
                    .frame(width: max(0, geometry.size.width - 40), height: max(0, geometry.size.height - 40))
                    .clipped().allowsHitTesting(false)
            }.contentShape(Rectangle()).onTapGesture { showDone = true }
        }
        .background(Color.black.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                if showDone {
                    Button("Done") { dismiss() }
                        .font(.headline).buttonStyle(.borderedProminent)
                        .tint(.white).foregroundStyle(.black)
                        .frame(minWidth: 72, minHeight: 44)
                        .accessibilityIdentifier("latencyClockDone")
                }
            }.padding(.horizontal, 20).padding(.vertical, 8).background(.black)
        }
        .statusBarHidden()
        // Done stays visible; screen taps also restore it. Dismiss only the cover,
        // leaving Stream's capture, encoder and authenticated transport running.
    }
}
