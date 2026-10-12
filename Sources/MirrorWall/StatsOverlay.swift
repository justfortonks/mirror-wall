import MirrorCore
import SwiftUI

/// What the Stats for Nerds overlay shows for one slot. Changes on the main queue only.
final class SlotStats: ObservableObject {
    /// The last second of video, measured as it arrives.
    @Published var stream: StreamSnapshot?
    @Published var codec: String?
    /// Network round trip to the phone, in seconds.
    @Published var roundTrip: Double?
    /// How far the latest frame's arrival is behind its timestamp, compared with the smallest
    /// such gap this connection, in seconds. The phone's timestamps run ahead of the Mac's clock
    /// by a fixed amount that differs per phone, so only this change is meaningful: it rises
    /// when the stream falls behind.
    @Published private(set) var lag: Double?
    private var bestLatency: Double?

    /// A latency report from uxplay: the frame's arrival time minus its timestamp.
    func recordLatency(_ seconds: Double) {
        let best = min(bestLatency ?? seconds, seconds)
        bestLatency = best
        lag = seconds - best
    }
    /// The phone's model, e.g. "iPhone 15 Pro Max".
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
        lag = nil
        bestLatency = nil
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
                            // Shrinks to fit a narrow tile rather than cutting off.
                            .minimumScaleFactor(0.6)
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
        rows.append(Row(label: "Phone", value: stats.phoneModel ?? "–"))
        if let codec = stats.codec {
            rows.append(Row(label: "Codec", value: codec))
        }
        if let size = slot.videoSize {
            rows.append(Row(label: "Picture", value: "\(Int(size.width))×\(Int(size.height))"))
        }
        if let stream {
            rows.append(Row(label: "Frames", value: String(format: "%.0f/s", stream.framesPerSecond)))
            rows.append(Row(label: "Bitrate", value: Self.bitrate(stream.bitsPerSecond)))
        }
        rows.append(Row(label: "Lag vs best", value: stats.lag.map { "+" + Self.milliseconds($0) } ?? "not reported"))
        rows.append(Row(label: "Decode", value: stream?.macTime.map(Self.milliseconds) ?? "–"))
        rows.append(Row(label: "Round trip", value: stats.roundTrip.map(Self.milliseconds) ?? "–"))
        if let stream {
            rows.append(Row(label: "Jitter", value: Self.milliseconds(stream.frameJitter)))
            let keyframeEvery = stream.keyframeInterval.map { String(format: ", every %.1f s", $0) } ?? ""
            rows.append(Row(label: "Keyframes", value: "\(stream.totalKeyframes)\(keyframeEvery)"))
            rows.append(Row(label: "Lost", value: "\(stream.totalPacketsLost) packets, \(stream.totalFramesSkipped) frames"))
        }
        if let lastFrameAt = slot.lastFrameAt {
            rows.append(Row(label: "Last frame", value: Self.ago(now.timeIntervalSince(lastFrameAt))))
        }
        if let last = stats.lastHeartbeatAt {
            let every = stats.heartbeatInterval.map { String(format: "every %.1f s, ", $0) } ?? ""
            rows.append(Row(label: "Check-ins", value: every + Self.ago(now.timeIntervalSince(last))))
        }
        rows.append(Row(label: "Connections", value: "\(stats.connections)"))
        return rows
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
