import SwiftUI
import UIKit
import Network
import Combine
import IOSDirectShared

struct RadioDiscovery: Identifiable {
    let endpoint: NWEndpoint
    let rid: UUID?
    var id: String { String(describing: endpoint) }
    var label: String {
        if case .service(let name, _, _, _) = endpoint { return name }
        return id
    }
}

/// Shared across Radio/Stream and app relaunches; only non-secret rejection state.
@MainActor
final class PhonePairingState: ObservableObject {
    static let shared = PhonePairingState()
    @Published private(set) var status: ReceiverPairingStatus
    private let key = "iosdirect.pairingStatus.v3"
    private init() {
        status = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ReceiverPairingStatus.self, from: $0) } ?? ReceiverPairingStatus()
    }
    func reject(_ rid: UUID, reason: PairingRejection) { status.reject(rid, reason: reason); persist() }
    func clear(_ rid: UUID) { status.clear(rid); persist() }
    private func persist() { if let data = try? JSONEncoder().encode(status) { UserDefaults.standard.set(data, forKey: key) } }
}

@MainActor
final class RadioExperiment: ObservableObject {
    @Published var receivers: [RadioDiscovery] = []
    @Published var selected: String = ""
    @Published var pairingState = ""
    @Published var pairingBusy = false
    @Published var pairingRevision = 0
    let pairingStore: PairingKeyStore = KeychainPairingKeyStore()
    private var forgottenObserver: NSObjectProtocol?
    private var rePairObserver: NSObjectProtocol?
    private var pairingSubscription: AnyCancellable?
    var onReceiversChanged: (() -> Void)?
    private var pairingRun = UUID()
    func pairingFailure(_ rid: UUID) -> PairingRejection? { PhonePairingState.shared.status[rid] }
    func pairingLabel(_ result: RadioDiscovery) -> String {
        guard let rid = result.rid else { return "Not paired" }
        return PhonePairingState.shared.status.label(rid: rid, hasCredential: isPaired(result))
    }
    func canConnect() -> Bool {
        guard let rid = selectedReceiver?.rid, pairingFailure(rid) == nil else { return false }
        return (try? credential()) != nil
    }
    private var pairer: PairingClient?
    private var pendingInvitation: PairingInvitation?
    var selectedRID: UUID? { selectedReceiver?.rid ?? pinnedRID ?? connectionRID }
    private var pinnedRID: UUID?
    func pinSelection(_ rid: UUID?) { pinnedRID = rid }
    var selectedReceiver: RadioDiscovery? { receivers.first { $0.id == selected } }
    func isPaired(_ result: RadioDiscovery) -> Bool {
        guard let rid = result.rid else { return false }
        return (try? pairingStore.credential(rid: rid)) != nil
    }
    func credential() throws -> DeviceCredential {
        guard let rid = selectedReceiver?.rid, let credential = try pairingStore.credential(rid: rid) else {
            throw RadioError.protocolViolation("Not paired; scan the pairing code shown on your Mac")
        }
        return credential
    }
    var installID: UUID {
        let key = "iosdirect.radio.installUUID"
        let id = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key); return id
    }
    func scan(_ payload: String, expectedRID: UUID?) {
        do {
            // Validate completely before stopping an existing session or using TLS.
            let invitation = try PairingInvitation(payload: payload, expectedReceiverID: expectedRID)
            cancelPairing()
            NotificationCenter.default.post(name: .pairingWillBegin, object: invitation.rid)
            pendingInvitation = invitation
            pairingBusy = true; pairingState = "Finding the Mac from this code…"; attemptPairing()
        } catch { pairingState = String(describing: error) }
    }
    private func attemptPairing() {
        guard pairer == nil, let token = pendingInvitation else { return }
        guard token.expires.addingTimeInterval(30) > Date() else { cancelPairing(); pairingState = PairingInvitationError.expired.description; return }
        guard let target = receivers.first(where: { $0.rid == token.rid }) else { return }
        selected = target.id
        var info = utsname(); uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let client = PairingClient(endpoint: target.endpoint, invitation: token, install: installID,
            label: UIDevice.current.name, model: model, store: pairingStore, log: log)
        pairer = client; pendingInvitation = nil
        let run = pairingRun
        client.onState = { [weak self] state in DispatchQueue.main.async {
            guard let self, self.pairingRun == run else { return }
            self.pairingState = state
            if state != "Waiting for approval on Mac" { self.pairingBusy = false; self.pairer = nil; self.pairingRevision += 1 }
        } }
        client.onPaired = { [weak self] _ in DispatchQueue.main.async {
            guard let self, self.pairingRun == run else { return }
            PhonePairingState.shared.clear(token.rid); self.pairingRevision += 1
        } }
        client.start()
    }
    func cancelPairing() { pairingRun = UUID(); pairer?.cancel(); pairer = nil; pendingInvitation = nil; pairingBusy = false; pairingState = "Pairing cancelled" }
    func forget(rid requestedRID: UUID? = nil) {
        guard let rid = requestedRID ?? connectionRID ?? selectedReceiver?.rid else { return }
        do {
            try pairingStore.delete(account: rid.uuidString); PhonePairingState.shared.clear(rid); sender?.stop(); cancelPairing()
            NotificationCenter.default.post(name: .pairingForgotten, object: rid)
            pairingRevision += 1; pairingState = "Forgot this Mac; scan a new pairing code to reconnect"
        } catch { pairingState = String(describing: error) }
    }
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
    private(set) var connectionRID: UUID?
    private var log: RadioLog?
    private var timer: Timer?
    private var generation = UUID()
    var logURL: URL? { log?.url }
    init() {
        pairingSubscription = PhonePairingState.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        rePairObserver = NotificationCenter.default.addObserver(forName: .pairingWillBegin, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.connectionRID == notification.object as? UUID { self.stop() }
            }
        }
        forgottenObserver = NotificationCenter.default.addObserver(forName: .pairingForgotten, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }; self.pairingRevision += 1
                if self.connectionRID == notification.object as? UUID { self.sender?.stop() }
            }
        }
        do { log = try RadioLog(receiver: false); log?.event("radio.run", "synthetic only") }
        catch { logFailure = error.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.attemptPairing()
                self.log?.event("browser.sample", "state=\(self.browserState) discovered=\(self.receivers.count) sender=\(self.state) thermal=\(radioThermalState()) memoryMB=\(radioMemoryMB().map { String($0) } ?? "unavailable")")
                self.logFailure = self.log?.error() ?? self.logFailure
            }
        }
    }
    func browse() {
        guard browser == nil, browserRestart == nil else { return }
        browserGeneration = UUID(); let attempt = browserGeneration
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RadioTLS.service, domain: nil), using: RadioTLS.browserParameters())
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
                self.log?.event("browser.change", "changes=\(changes.count) receivers=\(results.count)")
                self.receivers = results.map { result in
                    var rid: UUID?
                    if case .bonjour(let txt) = result.metadata, txt["v"] == "3", let value = txt["rid"] { rid = UUID(uuidString: value) }
                    return RadioDiscovery(endpoint: result.endpoint, rid: rid)
                }.sorted { $0.id < $1.id }
                if !self.receivers.contains(where: { $0.id == self.selected }), self.connectionRID == nil, self.pinnedRID == nil { self.selected = self.receivers.first?.id ?? "" }
                self.sender?.setReceiverDiscovered(self.receivers.contains { $0.rid == self.connectionRID })
                self.onReceiversChanged?()
            }
        }
        browser.start(queue: queue)
    }
    func restartBrowser(reason: String, delay: Double = 0) {
        browserGeneration = UUID()
        browserRestart?.cancel(); browserRestart = nil
        browser?.cancel(); browser = nil
        receivers.removeAll(); if connectionRID == nil, pinnedRID == nil { selected = "" }
        sender?.setReceiverDiscovered(false); onReceiversChanged?()
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
        guard !running, canConnect(), let endpoint = receivers.first(where: { $0.id == selected })?.endpoint else { return }
        do {
            let credential = try credential()
            guard log != nil, log?.error() == nil else { state = "log unavailable"; return }
            let install = installID
            generation = UUID(); let run = generation
            let sender = RadioSender(endpoint: endpoint, credential: credential, rate: rate, window: window, install: install,
                label: UIDevice.current.name, log: log, receiverDiscovered: true, pairingStore: pairingStore)
            sender.onState = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.generation == run else { return }
                    self.state = state
                    if state != "TLS ready; awaiting welcome" && state != "sending synthetic payload" { self.running = false; self.sender = nil; self.connectionRID = nil }
                }
            }
            sender.onPairingRejected = { [weak self] rejection in DispatchQueue.main.async {
                guard let self, self.generation == run else { return }
                PhonePairingState.shared.reject(credential.rid, reason: rejection)
                self.pairingState = rejection.message
            } }
            sender.onSample = { [weak self] sample in
                DispatchQueue.main.async { guard let self, self.generation == run else { return }; self.snapshot = sample }
            }
            sender.onReceiverStats = { [weak self] sample in
                DispatchQueue.main.async { guard let self, self.generation == run else { return }; self.receiverSnapshot = sample }
            }
            self.sender = sender; connectionRID = credential.rid; snapshot = RadioSnapshot(); receiverSnapshot = nil
            state = "connecting with TLS-PSK"; running = true; sender.start()
        } catch { state = String(describing: error) }
    }
    func stop() { sender?.stop() }
    deinit { if let rePairObserver { NotificationCenter.default.removeObserver(rePairObserver) }; if let forgottenObserver { NotificationCenter.default.removeObserver(forgottenObserver) }; timer?.invalidate(); browserRestart?.cancel(); browser?.cancel(); sender?.stop() }
}

struct RadioExperimentView: View {
    @StateObject private var experiment = RadioExperiment()
    var body: some View {
        NavigationStack {
            Form {
                Section("Synthetic radio experiment") {
                    Text("Deterministic test bytes only. Pair with the Mac before connecting.")
                    Text("Browser: \(experiment.browserState)")
                    Picker("Receiver", selection: $experiment.selected) {
                        Text("Select receiver").tag("")
                        ForEach(experiment.receivers) { result in Text("\(result.label) · \(experiment.pairingLabel(result))").tag(result.id) }
                    }.disabled(experiment.running)
                    PairingControls(discovery: experiment, forget: { experiment.forget() })
                    Picker("Mbit/s", selection: $experiment.rate) {
                        ForEach(experiment.window == .capacityProbe ? RadioPacer.rates : [2, 6, 12, 24], id: \.self) { Text("\($0)").tag($0) }
                    }.disabled(experiment.running)
                    Picker("Window", selection: $experiment.window) {
                        ForEach(RadioWindowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.disabled(experiment.running).onChange(of: experiment.window) { _, window in
                        if window == .latency, experiment.rate > 24 { experiment.rate = 24 }
                    }
                    Button("Connect") { experiment.start() }.disabled(experiment.running || !experiment.canConnect() || experiment.pairingBusy)
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

struct PairingControls: View {
    @ObservedObject var discovery: RadioExperiment
    let forget: () -> Void
    @State private var scanning = false
    @State private var scanningRID: UUID?
    var body: some View {
        Group {
            if let rid = discovery.selectedRID, let failure = discovery.pairingFailure(rid) {
                Text(failure.message).foregroundStyle(.red)
                Button("Pair again") { showScanner() }
            }
            Button("Scan pairing code") { showScanner() }
            Button("Forget this Mac", role: .destructive, action: forget)
                .disabled(discovery.selectedRID == nil && discovery.connectionRID == nil)
            if discovery.pairingBusy { Button("Cancel pairing") { discovery.cancelPairing() } }
            if !discovery.pairingState.isEmpty { Text(discovery.pairingState) }
        }.sheet(isPresented: $scanning) {
            PairingScannerSheet(scanned: { discovery.scan($0, expectedRID: scanningRID) })
        }
    }
    private func showScanner() {
        scanningRID = discovery.selectedRID
        scanning = true
    }
}

extension Notification.Name {
    static let pairingForgotten = Notification.Name("iosdirect.pairingForgotten")
    static let pairingWillBegin = Notification.Name("iosdirect.pairingWillBegin")
}
