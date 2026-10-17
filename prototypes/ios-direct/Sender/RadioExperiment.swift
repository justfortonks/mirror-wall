import SwiftUI
import UIKit
import Network
import IOSDirectShared

struct RadioDiscovery: Identifiable {
    let endpoint: NWEndpoint
    var id: String { String(describing: endpoint) }
    var label: String {
        if case .service(let name, _, _, _) = endpoint { return name }
        return id
    }
}

@MainActor
final class RadioExperiment: ObservableObject {
    @Published var receivers: [RadioDiscovery] = []
    @Published var selected: String = ""
    @Published var code = ""
    @Published var rate = 12
    @Published var window: RadioWindowMode = .latency
    @Published private(set) var browserState = "stopped"
    @Published private(set) var state = "idle"
    @Published private(set) var running = false
    @Published private(set) var snapshot = RadioSnapshot()
    @Published private(set) var receiverSnapshot: RadioSnapshot?
    @Published private(set) var logFailure: String?
    private let queue = DispatchQueue(label: "iosdirect.radio.browser")
    private var browser: NWBrowser?
    private var browserGeneration = UUID()
    private var browserRestart: DispatchWorkItem?
    private var browserRetryDelay = 0.5
    private var sender: RadioSender?
    private var log: RadioLog?
    private var timer: Timer?
    private var generation = UUID()
    var logURL: URL? { log?.url }
    init() {
        do { log = try RadioLog(receiver: false); log?.event("radio.run", "synthetic only") }
        catch { logFailure = error.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log?.event("browser.sample", "state=\(self.browserState) discovered=\(self.receivers.count) sender=\(self.state) thermal=\(radioThermalState()) memoryMB=\(radioMemoryMB().map { String($0) } ?? "unavailable")")
                self.logFailure = self.log?.error() ?? self.logFailure
            }
        }
    }
    func browse() {
        guard browser == nil, browserRestart == nil else { return }
        browserGeneration = UUID(); let attempt = browserGeneration
        let browser = NWBrowser(for: .bonjour(type: RadioTLS.service, domain: nil), using: RadioTLS.browserParameters())
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.browserGeneration == attempt else { return }
                self.browserState = String(describing: state)
                self.log?.event("browser.state", self.browserState)
                if case .ready = state { self.browserRetryDelay = 0.5 }
                if case .failed = state {
                    let delay = self.browserRetryDelay
                    self.browserRetryDelay = min(4, delay * 2)
                    self.restartBrowser(reason: self.browserState, delay: delay)
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            DispatchQueue.main.async {
                guard let self, self.browserGeneration == attempt else { return }
                for change in changes { self.log?.event("browser.change", String(describing: change)) }
                self.receivers = results.map { RadioDiscovery(endpoint: $0.endpoint) }.sorted { $0.id < $1.id }
                if !self.receivers.contains(where: { $0.id == self.selected }) { self.selected = self.receivers.first?.id ?? "" }
            }
        }
        browser.start(queue: queue)
    }
    func restartBrowser(reason: String, delay: Double = 0) {
        browserGeneration = UUID()
        browserRestart?.cancel(); browserRestart = nil
        browser?.cancel(); browser = nil
        receivers.removeAll(); selected = ""
        browserState = "restarting in \(delay) s"
        log?.event("browser.restart", "delay=\(delay)s reason=\(reason)")
        let attempt = browserGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.browserGeneration == attempt else { return }
            self.browserRestart = nil; self.browse()
        }
        browserRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func start() {
        guard !running, let endpoint = receivers.first(where: { $0.id == selected })?.endpoint else { return }
        do {
            let credential = try RadioCode(code)
            guard log != nil, log?.error() == nil else { state = "log unavailable"; return }
            let key = "iosdirect.radio.installUUID"
            let install = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
            UserDefaults.standard.set(install.uuidString, forKey: key)
            generation = UUID(); let run = generation
            let sender = RadioSender(endpoint: endpoint, code: credential, rate: rate, window: window, install: install,
                label: UIDevice.current.name, log: log)
            sender.onState = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.generation == run else { return }
                    self.state = state
                    if state != "TLS ready; awaiting welcome" && state != "sending synthetic payload" { self.running = false; self.sender = nil }
                }
            }
            sender.onSample = { [weak self] sample in
                DispatchQueue.main.async { guard let self, self.generation == run else { return }; self.snapshot = sample }
            }
            sender.onReceiverStats = { [weak self] sample in
                DispatchQueue.main.async { guard let self, self.generation == run else { return }; self.receiverSnapshot = sample }
            }
            self.sender = sender; snapshot = RadioSnapshot(); receiverSnapshot = nil
            state = "connecting with TLS-PSK"; running = true; sender.start()
        } catch { state = String(describing: error) }
    }
    func stop() { sender?.stop() }
    deinit { timer?.invalidate(); browserRestart?.cancel(); browser?.cancel(); sender?.stop() }
}

struct RadioExperimentView: View {
    @StateObject private var experiment = RadioExperiment()
    var body: some View {
        NavigationStack {
            Form {
                Section("Synthetic radio experiment") {
                    Text("Deterministic test bytes only. Enter the code displayed by your Mac.")
                    Text("Browser: \(experiment.browserState)")
                    Picker("Receiver", selection: $experiment.selected) {
                        Text("Select receiver").tag("")
                        ForEach(experiment.receivers) { result in Text(result.label).tag(result.id) }
                    }.disabled(experiment.running)
                    TextField("7K2M-9QXD-4HTA-W3PR", text: $experiment.code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled().font(.system(.body, design: .monospaced))
                        .disabled(experiment.running)
                    Picker("Mbit/s", selection: $experiment.rate) {
                        ForEach(experiment.window == .capacityProbe ? RadioPacer.rates : [2, 6, 12, 24], id: \.self) { Text("\($0)").tag($0) }
                    }.disabled(experiment.running)
                    Picker("Window", selection: $experiment.window) {
                        ForEach(RadioWindowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.disabled(experiment.running).onChange(of: experiment.window) { _, window in
                        if window == .latency, experiment.rate > 24 { experiment.rate = 24 }
                    }
                    Button("Start") { experiment.start() }.disabled(experiment.running || experiment.selected.isEmpty)
                    Button("Stop") { experiment.stop() }.disabled(!experiment.running)
                    Text(experiment.state).accessibilityIdentifier("radioState")
                    if let failure = experiment.logFailure { Text("Log write failed: \(failure)").foregroundStyle(.red) }
                    if let url = experiment.logURL { ShareLink("Export radio log", item: url) }
                }
                Section("Once per second") {
                    let m = experiment.snapshot
                    LabeledContent("Session", value: String(m.id.uuidString.prefix(8)))
                    LabeledContent("Sent / delivered Mbit/s", value: String(format: "%.2f / %.2f", m.sentMbit, m.deliveredMbit))
                    LabeledContent("RTT p50 / p95 ms", value: "\(number(m.rttMedianMS)) / \(number(m.rttP95MS))")
                    LabeledContent("Outstanding bytes", value: "\(m.outstandingBytes)")
                    LabeledContent("Active window", value: m.windowMode.map { "\($0.label) · \(m.windowBytes ?? 0) bytes" } ?? "unavailable")
                    LabeledContent("Send blocked ms / s", value: number(m.sendBlockedMSPerSecond))
                    LabeledContent("Receiver gaps / CRC errors", value: experiment.receiverSnapshot.map { "\($0.seqGaps) / \($0.crcFailures)" } ?? "unavailable")
                    LabeledContent("Path", value: m.path?.availableInterfaces.joined(separator: ", ") ?? "unavailable")
                    LabeledContent("Thermal / memory MB", value: "\(m.thermal) / \(number(m.residentMemoryMB))")
                }
            }.navigationTitle("Radio experiment").onAppear { experiment.browse() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    experiment.restartBrowser(reason: "willEnterForeground")
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    experiment.restartBrowser(reason: "didBecomeActive")
                }
        }
    }
    private func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "unavailable" }
}
