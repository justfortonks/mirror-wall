import SwiftUI
import IOSDirectShared
import CoreImage.CIFilterBuiltins
import AppKit

@MainActor
final class ReceiverExperiment: ObservableObject {
    @Published private(set) var state = "starting"
    @Published private(set) var invitation: PairingInvitation?
    @Published var approval: PairingApproval?
    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var live = Set<UUID>()
    @Published private(set) var seconds = 0
    var qrImage: NSImage? {
        guard let invitation else { return nil }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(invitation.payload.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 7, y: 7)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 280, height: 280))
    }
    @Published private(set) var sessions: [UUID: RadioSnapshot] = [:]
    @Published private(set) var events: [String] = []
    @Published private(set) var logFailure: String?
    private let videoWindows = VideoSessionWindows()
    private var receiver: RadioReceiver?
    private var log: RadioLog?
    private var timer: Timer?
    var logURL: URL? { log?.url }
    init() {
        do {
            log = try RadioLog(receiver: true)
            let directory = log!.url.deletingLastPathComponent()
            let identity = try ReceiverIdentity.load(at: directory.appendingPathComponent("receiver-identity.json"), name: Host.current().localizedName ?? "iOS Direct Receiver")
            let store = try ReceiverPairingStore(identity: identity, keys: KeychainPairingKeyStore(), metadataURL: directory.appendingPathComponent("paired-devices.json"))
            let receiver = RadioReceiver(store: store, log: log)
            self.receiver = receiver
            // Create the decoder synchronously on the session queue. Window/UI work is
            // posted to main; media never waits for main-thread delivery.
            let windows = videoWindows, videoLog = log
            receiver.makeVideoSession = { session, deviceID, label, request in
                let renderer = VideoSessionRenderer(session: session, log: videoLog, request: request)
                renderer.onSample = { sample in DispatchQueue.main.async { windows.update(sample) } }
                DispatchQueue.main.async {
                    windows.open(device: deviceID, session: session, label: label, renderer: renderer, model: VideoWindowModel(session: session))
                }
                return renderer
            }
            receiver.onState = { [weak self] state, port in
                DispatchQueue.main.async { self?.state = state + (port.map { " port \($0)" } ?? "") }
            }
            receiver.onSample = { [weak self] sample in
                DispatchQueue.main.async { self?.sessions[sample.id] = sample }
            }
            receiver.onRemoved = { [weak self] id in DispatchQueue.main.async { self?.sessions.removeValue(forKey: id) } }
            receiver.onEvent = { [weak self] event in
                DispatchQueue.main.async {
                    guard let self else { return }; self.events.append(event)
                    if self.events.count > 80 { self.events.removeFirst(self.events.count - 80) }
                }
            }
            receiver.onInvitation = { [weak self] token in DispatchQueue.main.async {
                self?.invitation = token; self?.seconds = max(0, Int(ceil(token?.expires.timeIntervalSinceNow ?? 0)))
            } }
            receiver.onApproval = { [weak self] request in DispatchQueue.main.async { self?.approval = request } }
            receiver.onDevices = { [weak self] devices, live in DispatchQueue.main.async { self?.devices = devices; self?.live = live } }
            receiver.start()
        } catch { state = "failed: \(error)"; logFailure = String(describing: error) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }; self.logFailure = self.log?.error()
                self.seconds = max(0, Int(ceil(self.invitation?.expires.timeIntervalSinceNow ?? 0)))
            }
        }
    }
    func pairNewDevice() { receiver?.pairNewDevice() }
    func cancelPairing() { receiver?.cancelPairing() }
    func approve(_ request: PairingApproval, allow: Bool) { receiver?.approve(request.id, allow: allow); approval = nil }
    func forget(_ id: UUID) { receiver?.forget(id) }
    deinit { timer?.invalidate(); receiver?.stop() }
}

@main
struct IOSDirectReceiverApp: App {
    @StateObject private var experiment = ReceiverExperiment()
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("iOS Direct — G3b receiver").font(.title)
                Text("Listener: \(experiment.state)").textSelection(.enabled)
                GroupBox("Devices") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(experiment.devices) { device in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(device.label) (\(device.model)) · \(device.id.uuidString.prefix(8))")
                                    Text("\(experiment.live.contains(device.id) ? "Live" : "Not live") · Last seen: \(device.lastSeen?.formatted() ?? "never")").font(.caption)
                                }
                                Spacer()
                                Button("Forget", role: .destructive) { experiment.forget(device.id) }
                            }
                        }
                        Button("Pair New Device") { experiment.pairNewDevice() }
                        if experiment.invitation != nil {
                            HStack {
                                if let image = experiment.qrImage { Image(nsImage: image).interpolation(.none).resizable().frame(width: 240, height: 240).padding(12).background(.white) }
                                VStack(alignment: .leading) {
                                    Text("Scan on your phone · \(experiment.seconds) s remaining")
                                    Button("Regenerate") { experiment.pairNewDevice() }
                                    Button("Cancel") { experiment.cancelPairing() }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let failure = experiment.logFailure { Text("Log write failed: \(failure)").foregroundStyle(.red) }
                if let url = experiment.logURL { ShareLink("Export receiver log", item: url) }
                List {
                    ForEach(experiment.sessions.values.filter { ($0.mode ?? .synthetic) == .synthetic }.sorted { $0.id.uuidString < $1.id.uuidString }) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(m.label) · \(m.id.uuidString.prefix(8)) · \(m.state)").font(.headline)
                            Text(String(format: "Delivered %.2f Mbit/s · RTT p50 %@ / p95 %@ ms · gaps %llu · CRC %llu",
                                m.deliveredMbit, number(m.rttMedianMS), number(m.rttP95MS), m.seqGaps, m.crcFailures))
                            Text("Window: \(m.windowMode?.label ?? "pending") · \(m.windowBytes ?? 0) bytes · sender blocked \(number(m.sendBlockedMSPerSecond)) ms / s")
                            Text(m.path?.availableInterfaces.joined(separator: ", ") ?? "path unavailable").font(.caption)
                        }.textSelection(.enabled)
                    }
                }.frame(minHeight: 120)
                Text("Event log").font(.headline)
                ScrollView {
                    Text(experiment.events.suffix(30).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(height: 170)
            }.padding(20).frame(minWidth: 800, minHeight: 560)
                .sheet(item: $experiment.approval) { request in
                    VStack(spacing: 18) {
                        Text("Allow \"\(request.label)\" (\(request.model)) to mirror to this Mac?").font(.headline)
                        Text("Only approve the phone you are pairing.")
                        HStack {
                            Button("Deny") { experiment.approve(request, allow: false) }
                            Button("Allow") { experiment.approve(request, allow: true) }.keyboardShortcut(.defaultAction)
                        }
                    }.padding(30).frame(width: 440).interactiveDismissDisabled()
                        .onDisappear { experiment.approve(request, allow: false) }
                }
        }
    }
    private func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
}
