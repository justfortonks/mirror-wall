import SwiftUI
import IOSDirectShared

@MainActor
final class ReceiverExperiment: ObservableObject {
    @Published private(set) var state = "starting"
    @Published private(set) var code = ""
    @Published private(set) var sessions: [UUID: RadioSnapshot] = [:]
    @Published private(set) var events: [String] = []
    @Published private(set) var logFailure: String?
    private var receiver: RadioReceiver?
    private var log: RadioLog?
    private var timer: Timer?
    var logURL: URL? { log?.url }
    init() {
        do {
            log = try RadioLog(receiver: true)
            let receiver = RadioReceiver(label: Host.current().localizedName ?? "iOS Direct Receiver", log: log)
            self.receiver = receiver
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
            newCode()
        } catch { state = "failed: \(error)"; logFailure = String(describing: error) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.logFailure = self?.log?.error() }
        }
    }
    func newCode() {
        do {
            let credential = try RadioCode.generate(); code = credential.formatted
            sessions.removeAll(); receiver?.start(code: credential)
            log?.event("receiver.newRun", "new test credential; all sessions disconnected")
        } catch { state = "random code generation failed: \(error)"; receiver?.stop(); code = "" }
    }
    deinit { timer?.invalidate(); receiver?.stop() }
}

@main
struct IOSDirectReceiverApp: App {
    @StateObject private var experiment = ReceiverExperiment()
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("iOS Direct — G2 receiver").font(.title)
                Text("Listener: \(experiment.state)").textSelection(.enabled)
                HStack {
                    Text(experiment.code).font(.system(size: 32, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Button("New code") { experiment.newCode() }
                }
                Text("G2 test credential. New code disconnects all phones. Synthetic bytes only; max two sessions.")
                    .foregroundStyle(.secondary)
                if let failure = experiment.logFailure { Text("Log write failed: \(failure)").foregroundStyle(.red) }
                if let url = experiment.logURL { ShareLink("Export receiver log", item: url) }
                List {
                    ForEach(experiment.sessions.values.sorted { $0.id.uuidString < $1.id.uuidString }) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(m.label) · \(m.id.uuidString.prefix(8)) · \(m.state)").font(.headline)
                            Text(String(format: "Delivered %.2f Mbit/s · RTT p50 %@ / p95 %@ ms · gaps %llu · CRC %llu",
                                m.deliveredMbit, number(m.rttMedianMS), number(m.rttP95MS), m.seqGaps, m.crcFailures))
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
        }
    }
    private func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
}
