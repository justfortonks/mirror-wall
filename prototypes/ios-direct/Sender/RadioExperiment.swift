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
    @Published private var presence = PairingCredentialPresence()
    var pairedReceivers: Set<UUID> { presence.receivers }
    func refresh(_ rid: UUID, store: PairingKeyStore) { try? presence.refresh(rid, store: store) }
    private let key = "iosdirect.pairingStatus.v3"
    private init() {
        status = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ReceiverPairingStatus.self, from: $0) } ?? ReceiverPairingStatus()
        let migration = "iosdirect.reachabilityPolicy.v1"
        if !UserDefaults.standard.bool(forKey: migration) {
            status.clearLegacyReachabilityRejections(); persist()
            UserDefaults.standard.set(true, forKey: migration)
        }
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
    var onRecoveryAvailabilityChanged: ((Bool) -> Void)?
    private var activityObservers: [NSObjectProtocol] = []
    private var applicationActive = true
    private var backgroundCaptureActive = false
    private var recoveryAllowed: Bool { applicationActive || backgroundCaptureActive }
    private var freshResults = FreshReceiverResults<NWEndpoint>()
    private var endpointWaiters: [UUID: (rid: UUID, completion: (NWEndpoint?) -> Void)] = [:]
    @Published private(set) var unreachable = false
    private var radioPolicy = ClientSessionPolicy()
    private var radioBackoff = ReconnectBackoff()
    private var radioRetry: DispatchWorkItem?
    private var radioNeedsRetry = false
    private var radioResolution = UUID()
    private var radioResolving = false
    private var radioAttempt = UUID()
    let scanner = PairingScanPresentation()
    private var pairingAttempt = PairingAttempt()
    private var pairingTeardown = false
    private var findDeadline: Date?
    func pairingFailure(_ rid: UUID) -> PairingRejection? { PhonePairingState.shared.status[rid] }
    func pairingLabel(_ result: RadioDiscovery) -> String {
        guard let rid = result.rid else { return "Not paired" }
        return PhonePairingState.shared.status.label(rid: rid, hasCredential: isPaired(result))
    }
    func canConnect() -> Bool {
        guard applicationActive, let rid = selectedReceiver?.rid, freshResults.endpoint(for: rid) != nil,
              pairingFailure(rid) == nil else { return false }
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
        return PhonePairingState.shared.pairedReceivers.contains(rid)
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
        guard !pairingAttempt.busy else {
            _ = pairingAttempt.begin(); syncPairingState(); return
        }
        do {
            // Validate before stopping an existing session or using TLS.
            let invitation = try PairingInvitation(payload: payload, expectedReceiverID: expectedRID)
            guard let run = pairingAttempt.begin() else { syncPairingState(); return }
            pendingInvitation = invitation; findDeadline = Date().addingTimeInterval(5)
            syncPairingState()
            // Invalidate callbacks immediately; cancellation and provisional-key
            // cleanup finish before the next client can touch this receiver's key.
            stop()
            NotificationCenter.default.post(name: .pairingWillBegin, object: invitation.rid)
            teardownPairer { [weak self] in
                guard let self, self.pairingAttempt.id == run else { return }; self.attemptPairing()
            }
        } catch { pairingState = String(describing: error) }
    }
    private func syncPairingState() { pairingBusy = pairingAttempt.busy; pairingState = pairingAttempt.message }
    private func teardownPairer(_ completion: @escaping @MainActor () -> Void) {
        guard let old = pairer else {
            if !pairingTeardown { completion() }; return
        }
        pairer = nil; pairingTeardown = true
        old.cancel { [weak self, old] in
            _ = old // Keep alive through onClosed and credential cleanup.
            DispatchQueue.main.async {
                guard let self else { return }; self.pairingTeardown = false
                completion(); self.attemptPairing()
            }
        }
    }
    private func attemptPairing() {
        guard !pairingTeardown, pairer == nil, let token = pendingInvitation, let run = pairingAttempt.id else { return }
        guard token.expires.addingTimeInterval(30) >= Date() else {
            pendingInvitation = nil; _ = pairingAttempt.update(.failed(PairingInvitationError.expired.description), attempt: run); syncPairingState(); return
        }
        guard let target = receivers.first(where: { $0.rid == token.rid }) else {
            if let findDeadline, Date() >= findDeadline {
                pendingInvitation = nil
                _ = pairingAttempt.update(.failed("Pairing failed: this Mac was not discovered within 5 seconds; check that its pairing code is still open and scan again"), attempt: run)
                syncPairingState()
            }
            return
        }
        selected = target.id
        var info = utsname(); uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let client = PairingClient(endpoint: target.endpoint, invitation: token, install: installID,
            label: UIDevice.current.name, model: model, store: pairingStore, log: log)
        pairer = client; pendingInvitation = nil; findDeadline = nil
        client.onProgress = { [weak self] progress in DispatchQueue.main.async {
            guard let self, self.pairingAttempt.update(progress, attempt: run) else { return }
            if progress.terminal {
                PhonePairingState.shared.refresh(token.rid, store: self.pairingStore)
                self.pairer = nil; self.pairingRevision += 1
            }
            self.syncPairingState()
        } }
        client.onPaired = { [weak self] credential in DispatchQueue.main.async {
            guard let self, self.pairingAttempt.id == run else { return }
            // Read the committed store now; the labels in BOTH tabs update without
            // a discovery event or relaunch. This cache never authorizes a session.
            PhonePairingState.shared.refresh(credential.rid, store: self.pairingStore)
            PhonePairingState.shared.clear(credential.rid); self.pairingRevision += 1
        } }
        client.start()
    }
    func cancelPairing() {
        pairingAttempt.cancel(); pendingInvitation = nil; findDeadline = nil; syncPairingState()
        teardownPairer { }
    }
    func forget(rid requestedRID: UUID? = nil) {
        guard let rid = requestedRID ?? connectionRID ?? selectedReceiver?.rid else { return }
        do {
            try pairingStore.delete(account: rid.uuidString); PhonePairingState.shared.clear(rid)
            PhonePairingState.shared.refresh(rid, store: pairingStore); stop(); cancelPairing()
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
        applicationActive = UIApplication.shared.applicationState != .background
        activityObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        })
        activityObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        })
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
                if self.connectionRID == notification.object as? UUID { self.stop() }
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
        guard recoveryAllowed, browser == nil, browserRestart == nil else { return }
        browserGeneration = freshResults.restart(); let attempt = browserGeneration
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
                var endpoints: [UUID: NWEndpoint] = [:]
                for result in self.receivers { if let rid = result.rid { endpoints[rid] = result.endpoint } }
                _ = self.freshResults.update(endpoints, generation: attempt)
                self.fulfillEndpointWaiters()
                if !self.receivers.contains(where: { $0.id == self.selected }), self.connectionRID == nil, self.pinnedRID == nil { self.selected = self.receivers.first?.id ?? "" }
                for rid in self.receivers.compactMap(\.rid) { PhonePairingState.shared.refresh(rid, store: self.pairingStore) }
                self.attemptPairing()
                self.sender?.setReceiverDiscovered(self.receivers.contains { $0.rid == self.connectionRID })
                self.onReceiversChanged?()
            }
        }
        browser.start(queue: queue)
    }
    func restartBrowser(reason: String, delay: Double = 0) {
        browserGeneration = freshResults.restart()
        browserRestart?.cancel(); browserRestart = nil
        browser?.cancel(); browser = nil
        receivers.removeAll(); if connectionRID == nil, pinnedRID == nil { selected = "" }
        sender?.setReceiverDiscovered(false); onReceiversChanged?()
        browserState = "restarting in \(delay) s"
        log?.event("browser.restart", "delay=\(delay)s reason=\(reason)")
        guard recoveryAllowed else { return }
        let attempt = browserGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.browserGeneration == attempt else { return }
            self.browserRestart = nil; self.browse()
        }
        browserRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// Every recovery requests a new browser epoch. There is no cached endpoint
    /// fallback, including when a defunct browser restarts during foregrounding.
    func refreshReceiver(_ rid: UUID, completion: @escaping (NWEndpoint?) -> Void) {
        guard recoveryAllowed else { completion(nil); return }
        let id = UUID(); endpointWaiters[id] = (rid, completion)
        restartBrowser(reason: "fresh reconnect discovery")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let waiter = self?.endpointWaiters.removeValue(forKey: id) else { return }; waiter.completion(nil)
        }
    }
    private func fulfillEndpointWaiters() {
        guard recoveryAllowed else { return }
        let ready = endpointWaiters.compactMap { id, waiter -> (UUID, NWEndpoint)? in
            freshResults.endpoint(for: waiter.rid).map { (id, $0) }
        }
        for (id, endpoint) in ready { endpointWaiters.removeValue(forKey: id)?.completion(endpoint) }
    }
    func setBackgroundCaptureActive(_ active: Bool) {
        guard backgroundCaptureActive != active else { return }
        backgroundCaptureActive = active
        guard !applicationActive else { return }
        if active {
            restartBrowser(reason: "background capture started; fresh discovery")
            onRecoveryAvailabilityChanged?(true)
        } else { pauseRecoveryForSuspension() }
    }
    private func enteredBackground() {
        applicationActive = false
        if recoveryAllowed {
            // SCK still grants execution: keep background link recovery, but
            // invalidate any endpoint learned before this lifecycle transition.
            restartBrowser(reason: "background capture fresh discovery")
        } else { pauseRecoveryForSuspension() }
    }
    private func pauseRecoveryForSuspension() {
        onRecoveryAvailabilityChanged?(false)
        radioRetry?.cancel(); radioRetry = nil; radioResolution = UUID(); radioResolving = false
        sender?.pauseAdmission()
        restartBrowser(reason: "background invalidates cached discovery")
        let waiting = endpointWaiters.values; endpointWaiters.removeAll()
        for waiter in waiting { waiter.completion(nil) }
    }
    private func becameActive() {
        applicationActive = true
        // Run synchronously on main before releasing either mode's retry gate.
        restartBrowser(reason: "didBecomeActive fresh discovery")
        onRecoveryAvailabilityChanged?(true)
        if radioNeedsRetry, let rid = connectionRID, let credential = try? pairingStore.credential(rid: rid) {
            scheduleRadioRetry(credential, run: generation)
        }
    }
    func start() {
        guard !running, canConnect(), let rid = selectedReceiver?.rid, let endpoint = freshResults.endpoint(for: rid) else { return }
        do {
            let credential = try credential()
            guard log != nil, log?.error() == nil else { state = "log unavailable"; return }
            generation = UUID(); radioPolicy = ClientSessionPolicy(); radioBackoff = ReconnectBackoff(); unreachable = false
            connectionRID = rid; running = true
            connectRadio(endpoint, credential: credential, run: generation)
        } catch { state = String(describing: error) }
    }
    private func connectRadio(_ endpoint: NWEndpoint, credential: DeviceCredential, run: UUID) {
        radioPolicy.beginAttempt(); radioAttempt = UUID(); let attempt = radioAttempt
        let sender = RadioSender(endpoint: endpoint, credential: credential, rate: rate, window: window, install: installID,
            label: UIDevice.current.name, log: log, receiverDiscovered: true, pairingStore: pairingStore)
        sender.onState = { [weak self] state in DispatchQueue.main.async {
            guard let self, self.generation == run, self.radioAttempt == attempt else { return }; self.state = state
        } }
        sender.onWelcome = { [weak self] in DispatchQueue.main.async {
            guard let self, self.generation == run, self.radioAttempt == attempt else { return }
            self.radioPolicy.welcomed(); self.radioBackoff = ReconnectBackoff()
        } }
        sender.onClosed = { [weak self] cause in DispatchQueue.main.async {
            guard let self, self.generation == run, self.radioAttempt == attempt else { return }
            self.sender = nil
            switch self.radioPolicy.action(for: cause, receiverDiscovered: self.freshResults.endpoint(for: credential.rid) != nil) {
            case .retry: self.scheduleRadioRetry(credential, run: run)
            case .unreachable:
                self.running = false; self.unreachable = true; self.state = ClientSessionPolicy.unreachableMessage
            case .pairingRejected: self.running = false
            case .stop:
                self.running = false; self.connectionRID = nil
                if cause == .linkLoss { self.state = "Disconnected — tap Connect" }
            }
        } }
        sender.onPairingRejected = { [weak self] rejection in DispatchQueue.main.async {
            guard let self, self.generation == run, self.radioAttempt == attempt else { return }
            PhonePairingState.shared.refresh(credential.rid, store: self.pairingStore)
            PhonePairingState.shared.reject(credential.rid, reason: rejection); self.pairingState = rejection.message
        } }
        sender.onSample = { [weak self] sample in DispatchQueue.main.async {
            guard let self, self.generation == run, self.radioAttempt == attempt else { return }; self.snapshot = sample
        } }
        sender.onReceiverStats = { [weak self] sample in DispatchQueue.main.async {
            guard let self, self.generation == run, self.radioAttempt == attempt else { return }; self.receiverSnapshot = sample
        } }
        self.sender = sender; snapshot = RadioSnapshot(); receiverSnapshot = nil
        state = radioNeedsRetry ? "Reconnecting…" : "connecting with TLS-PSK"; radioNeedsRetry = false; sender.start()
    }
    private func scheduleRadioRetry(_ credential: DeviceCredential, run: UUID) {
        radioNeedsRetry = true; state = "Reconnecting…"
        guard recoveryAllowed, radioRetry == nil, !radioResolving else { return }
        let delay = radioBackoff.next()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == run, self.radioNeedsRetry else { return }; self.radioRetry = nil
            self.radioResolution = UUID(); let request = self.radioResolution; self.radioResolving = true
            self.refreshReceiver(credential.rid) { [weak self] endpoint in
                guard let self, self.generation == run, self.radioResolution == request else { return }
                self.radioResolution = UUID(); self.radioResolving = false
                guard let endpoint else {
                    self.radioPolicy.receiverUnavailable(); self.scheduleRadioRetry(credential, run: run); return
                }
                self.connectRadio(endpoint, credential: credential, run: run)
            }
        }
        radioRetry = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func tryAgain() {
        guard let rid = connectionRID ?? selectedRID, let credential = try? pairingStore.credential(rid: rid) else { return }
        stop(); connectionRID = rid; running = true; unreachable = false
        radioPolicy = ClientSessionPolicy(); radioBackoff = ReconnectBackoff()
        scheduleRadioRetry(credential, run: generation)
    }
    func stop() {
        generation = UUID(); radioResolution = UUID(); radioResolving = false; radioRetry?.cancel(); radioRetry = nil; radioNeedsRetry = false
        sender?.stop(); sender = nil; running = false; unreachable = false; connectionRID = nil; state = "Disconnected — tap Connect"
    }
    deinit {
        for observer in activityObservers { NotificationCenter.default.removeObserver(observer) }
        if let rePairObserver { NotificationCenter.default.removeObserver(rePairObserver) }
        if let forgottenObserver { NotificationCenter.default.removeObserver(forgottenObserver) }
        timer?.invalidate(); radioRetry?.cancel(); browserRestart?.cancel(); browser?.cancel(); sender?.stop()
    }

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
                    if experiment.unreachable {
                        Button("Try again") { experiment.tryAgain() }
                        Button("Pair again") { experiment.scanner.present(rid: experiment.selectedRID) }
                    }
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
        }.modifier(PairingScannerPresenter(presentation: experiment.scanner, scanned: { experiment.scan($0, expectedRID: $1) }))
    }
    private func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "unavailable" }
}

struct PairingControls: View {
    @ObservedObject var discovery: RadioExperiment
    let forget: () -> Void
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
        }
    }
    private func showScanner() {
        discovery.scanner.present(rid: discovery.selectedRID)
    }
}

extension Notification.Name {
    static let pairingForgotten = Notification.Name("iosdirect.pairingForgotten")
    static let pairingWillBegin = Notification.Name("iosdirect.pairingWillBegin")
}
