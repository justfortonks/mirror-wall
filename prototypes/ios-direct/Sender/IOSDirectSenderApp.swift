import SwiftUI
import IOSDirectShared

@main
struct IOSDirectSenderApp: App {
    @StateObject private var experiment = CaptureExperiment()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section {
                        Text(experiment.state).accessibilityIdentifier("captureState")
                        Text("Encoder: \(experiment.counters.encoderState)").accessibilityIdentifier("encoderState")
                        if let failure = experiment.logFailure { Text("Log write failed: \(failure)") }
                        Button("Share full display") { experiment.shareDisplay() }.disabled(experiment.busy)
                        Button("Stop") { experiment.stop() }.disabled(!experiment.busy)
                        Button("Reset counters") { experiment.reset() }
                        if let url = experiment.logURL { ShareLink("Export log", item: url) }
                    }
                    Section("Output") {
                        let m = experiment.counters
                        row("Dimensions", m.dimensions.map { "\($0.width) × \($0.height)" } ?? "unavailable")
                        row("Bitrate requested", "\(m.bitrate) bit/s")
                        row("Hardware encoder", m.hardwareEncoder)
                        row("Source dimensions", m.sourceDimensions.map { "\($0.width) × \($0.height)" } ?? "unavailable")
                        row("Frame orientation", m.frameOrientation.map { String($0) } ?? "unavailable")
                        row("Profile", m.negotiatedProfile ?? "unavailable")
                        row("Generation", "\(m.generation)")
                    }
                    Section("Counters (once per second)") {
                        let m = experiment.counters
                        row("App", m.appState)
                        row("Capture / valid / paced", "\(m.captureCallbacks) / \(m.validFrames) / \(m.pacedFrames)")
                        row("Pacing / source drops", "\(m.pacingDrops) / \(m.sourceDrops)")
                        row("Latest PTS", m.latestPTS.map { String(format: "%.3f", $0) } ?? "unavailable")
                        row("Encode submitted / completed", "\(m.encodeSubmitted) / \(m.encodeCompleted)")
                        row("Encode errors / bytes / IDRs", "\(m.encodeErrors) / \(m.encodeBytes) / \(m.keyframes)")
                        row("Recreate attempts / successes", "\(m.encoderRecreateAttempts) / \(m.encoderRecreateSuccesses)")
                        row("No session drops", "\(m.encoderNoSessionDrops)")
                        row("Last failing OSStatus", m.encoderLastFailingOSStatus.map { String($0) } ?? "none")
                        row("Sink enqueued / drained", "\(m.sinkEnqueued) / \(m.sinkDrained)")
                        row("Sink bytes / drops", "\(m.sinkBytes) / \(m.sinkDrops)")
                        row("Queue bytes / age ms", "\(m.sinkQueueBytes) / \(Int(m.sinkQueueAgeMS))")
                        row("Rolling hash", m.sinkHash)
                        row("Thermal / low power", "\(m.thermalState) / \(m.lowPower)")
                        row("Resident MB", m.residentMemoryMB.map { String(format: "%.1f", $0) } ?? "unavailable")
                    }
                }
                .navigationTitle("Capture experiment")
            }
        }
    }
    private func row(_ name: String, _ value: String) -> some View {
        LabeledContent(name) { Text(value).monospacedDigit().textSelection(.enabled) }
    }
}
