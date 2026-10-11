import MirrorCore
import SwiftUI

/// What the Stats for Nerds overlay shows for one slot. Changes on the main queue only.
final class SlotStats: ObservableObject {
    /// The last second of video, measured as it arrives.
    @Published var stream: StreamSnapshot?
    @Published var codec: String?
    /// Network round trip to the phone, in seconds.
    @Published var roundTrip: Double?
    /// How long ago the phone captured the frame uxplay just received, in seconds.
    @Published var latency: Double?
    /// The phone's model identifier, e.g. "iPhone16,2".
    @Published var phoneModel: String?
    /// Phones that have connected since the app started.
    @Published var connections = 0
    @Published private(set) var lastHeartbeatAt: Date?
    /// Seconds between the phone's last two check-ins.
    @Published private(set) var heartbeatInterval: Double?

    func heartbeat() {
        let now = Date()
        if let lastHeartbeatAt { heartbeatInterval = now.timeIntervalSince(lastHeartbeatAt) }
        lastHeartbeatAt = now
    }

    /// Forgets the current stream's numbers when its receiver stops.
    func clearStream() {
        stream = nil
        codec = nil
        roundTrip = nil
        latency = nil
        lastHeartbeatAt = nil
        heartbeatInterval = nil
    }
}

/// Stats for Nerds: a panel over a slot's tile with the stream's numbers.
struct StatsOverlay: View {
    @ObservedObject var slot: Slot
    @ObservedObject var stats: SlotStats

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 1) {
                ForEach(rows(now: context.date), id: \.label) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.white.opacity(0.6))
                        Text(row.value)
                    }
                }
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(6)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private struct Row {
        let label: String
        let value: String
    }

    private func rows(now: Date) -> [Row] {
        let stream = stats.stream
        var rows: [Row] = []
        rows.append(Row(label: "Phone", value: [stats.phoneModel, stats.codec].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "–"))
        if let size = slot.videoSize {
            rows.append(Row(label: "Picture", value: "\(Int(size.width))×\(Int(size.height))"))
        }
        if let stream {
            rows.append(Row(label: "Frames", value: String(format: "%.0f/s", stream.framesPerSecond)))
            rows.append(Row(label: "Bitrate", value: Self.bitrate(stream.bitsPerSecond)))
        }
        rows.append(Row(label: "Latency", value: latencyText(macTime: stream?.macTime)))
        rows.append(Row(label: "Round trip", value: stats.roundTrip.map(Self.milliseconds) ?? "–"))
        if let stream {
            rows.append(Row(label: "Jitter", value: Self.milliseconds(stream.frameJitter)))
            let keyframeEvery = stream.keyframeInterval.map { String(format: ", every %.1f s", $0) } ?? ""
            rows.append(Row(label: "Keyframes", value: "\(stream.totalKeyframes)\(keyframeEvery)"))
            rows.append(Row(label: "Lost", value: "\(stream.totalPacketsLost) packets, \(stream.totalFramesSkipped) frames skipped"))
        }
        if let lastFrameAt = slot.lastFrameAt {
            rows.append(Row(label: "Last frame", value: Self.ago(now.timeIntervalSince(lastFrameAt))))
        }
        if let last = stats.lastHeartbeatAt {
            let every = stats.heartbeatInterval.map { String(format: "every %.1f s, ", $0) } ?? ""
            rows.append(Row(label: "Check-ins", value: every + "last " + Self.ago(now.timeIntervalSince(last))))
        }
        rows.append(Row(label: "Connections", value: "\(stats.connections)"))
        return rows
    }

    /// Phone to Mac (from the phone's capture time) plus the Mac's decode, e.g. "48 ms (45 + 3)".
    private func latencyText(macTime: Double?) -> String {
        switch (stats.latency, macTime) {
        case let (network?, mac?):
            return "\(Self.milliseconds(network + mac)) (\(Self.number(network)) + \(Self.number(mac)))"
        case let (network?, nil):
            return Self.milliseconds(network) + " to the Mac"
        case let (nil, mac?):
            return Self.milliseconds(mac) + " on the Mac only"
        case (nil, nil):
            return "–"
        }
    }

    private static func number(_ seconds: Double) -> String {
        String(format: "%.0f", seconds * 1000)
    }

    private static func milliseconds(_ seconds: Double) -> String {
        seconds < 0.01 && seconds > -0.01 ? String(format: "%.1f ms", seconds * 1000) : number(seconds) + " ms"
    }

    private static func bitrate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
            : String(format: "%.0f kbps", bitsPerSecond / 1000)
    }

    private static func ago(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "just now" : "\(Int(seconds)) s ago"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// View › Stats for Nerds, shared by every tile.
struct StatsCommands: Commands {
    @AppStorage(StatsSetting.key) private var showStats = false

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Stats for Nerds", isOn: $showStats)
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

enum StatsSetting {
    static let key = "showStatsForNerds"
}
