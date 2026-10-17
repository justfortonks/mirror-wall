import SwiftUI
import AppKit
import AVFoundation
import IOSDirectShared

@MainActor
final class VideoWindowModel: ObservableObject {
    @Published var stats: VideoReceiveSnapshot
    init(session: UUID) { stats = VideoReceiveSnapshot(session: session) }
}

private final class VideoLayerHost: NSView {
    var orientation: UInt8 = 1
    private(set) var display: AVSampleBufferDisplayLayer
    init(display: AVSampleBufferDisplayLayer) {
        self.display = display; super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(display)
    }
    func replaceDisplay(_ next: AVSampleBufferDisplayLayer) {
        guard display !== next else { return }
        display.removeFromSuperlayer(); display = next; layer?.addSublayer(next); needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Apply the documented CGImagePropertyOrientation to the delivered pixels.
        // Swap the viewport before quarter turns so resizeAspect still letterboxes correctly.
        let swapped = orientation >= 5
        display.bounds = CGRect(x: 0, y: 0, width: swapped ? bounds.height : bounds.width,
                                height: swapped ? bounds.width : bounds.height)
        display.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(scaleX: -1, y: 1)
        case 3: transform = CGAffineTransform(rotationAngle: .pi)
        case 4: transform = CGAffineTransform(scaleX: 1, y: -1)
        case 5: transform = CGAffineTransform(rotationAngle: -.pi / 2).scaledBy(x: -1, y: 1)
        case 6: transform = CGAffineTransform(rotationAngle: -.pi / 2)
        case 7: transform = CGAffineTransform(rotationAngle: .pi / 2).scaledBy(x: -1, y: 1)
        case 8: transform = CGAffineTransform(rotationAngle: .pi / 2)
        default: transform = .identity
        }
        display.setAffineTransform(transform); CATransaction.commit()
    }
}
private struct VideoLayerView: NSViewRepresentable {
    let renderer: VideoSessionRenderer
    let orientation: UInt8
    func makeNSView(context: Context) -> NSView { VideoLayerHost(display: renderer.layer) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? VideoLayerHost)?.replaceDisplay(renderer.layer)
        (view as? VideoLayerHost)?.orientation = orientation; view.needsLayout = true
    }
}
private struct VideoSessionView: View {
    @ObservedObject var model: VideoWindowModel
    let renderer: VideoSessionRenderer
    @State private var showStats = true
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            VideoLayerView(renderer: renderer, orientation: model.stats.orientation)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(model.stats.state).font(.headline)
                    Button(showStats ? "Hide stats" : "Show stats") { showStats.toggle() }.controlSize(.small)
                }
                Toggle("Smooth (100 ms buffer)", isOn: Binding(
                    get: { model.stats.presentationMode == "smooth100ms" },
                    set: { renderer.setSmoothing($0) }
                )).toggleStyle(.checkbox)
                if showStats {
                    let s = model.stats
                    Text(String(format: "Rx %.1f · decode %.1f · displayed %.1f fps", s.receivedFPS, s.decodedFPS, s.displayedFPS))
                    Text(String(format: "%.2f Mbit/s · frame %d B · errors %d · IDR requests %d", s.receivedMbit, s.frameBytes, s.decodeErrors, s.keyframeRequests))
                    Text(String(format: "Longest gap (session) %.0f ms", s.longestGapMS))
                    if let timing = s.timing {
                        Text("Last 1 s p50/p95 ms · arrival \(ms(timing.interArrival))")
                        Text("arrival→submit \(ms(timing.arrivalToSubmit)) · decode \(ms(timing.decode))")
                        Text("complete→enqueue \(ms(timing.completeToEnqueue))")
                    }
                    Text("Skipped \(s.displaySkipped) · queue peak \(s.decodeQueueDepth)/8 · \(s.presentationMode)")
                    Text("Recoveries: \(s.recoveries.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
                    Text("\(s.width)×\(s.height) · orientation \(s.orientation) · generation \(s.generation.map(String.init) ?? "—")")
                }
            }.font(.system(.caption, design: .monospaced)).foregroundStyle(.white)
                .padding(8).background(.black.opacity(0.7)).padding(8)
        }.frame(minWidth: 300, minHeight: 240)
    }
    private func ms(_ summary: VideoTimingSummary) -> String {
        guard let p50 = summary.p50MS, let p95 = summary.p95MS else { return "—" }
        return String(format: "%.1f/%.1f", p50, p95)
    }
}

@MainActor
final class VideoSessionWindows: NSObject, NSWindowDelegate {
    private struct Entry {
        let window: NSWindow, model: VideoWindowModel
        var renderer: VideoSessionRenderer
        var geometry: VideoWindowGeometry?
    }
    private var entries: [UUID: Entry] = [:] // Verified deviceID, never label or installID.
    private var sessions = VideoWindowSessions()
    func open(device: UUID, session: UUID, label: String, renderer: VideoSessionRenderer, model: VideoWindowModel) {
        sessions.bind(device: device, session: session)
        var waiting = VideoReceiveSnapshot(session: session); waiting.state = "Waiting for video"
        if var entry = entries[device] {
            // New decoder/layer per authenticated session; keep the same NSWindow,
            // position and geometry. Disconnected layers have already been blacked.
            entry.renderer = renderer; entry.model.stats = waiting
            entry.window.title = label
            entry.window.contentView = NSHostingView(rootView: VideoSessionView(model: entry.model, renderer: renderer))
            entries[device] = entry; entry.window.makeKeyAndOrderFront(nil); return
        }
        model.stats = waiting
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = label
        window.isReleasedWhenClosed = false; window.backgroundColor = .black; window.delegate = self
        window.contentView = NSHostingView(rootView: VideoSessionView(model: model, renderer: renderer))
        entries[device] = Entry(window: window, model: model, renderer: renderer)
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    func update(_ sample: VideoReceiveSnapshot) {
        guard let device = sessions.device(for: sample.session), var entry = entries[device] else { return }
        var display = sample
        if sample.state == "disconnected" { display.state = "Disconnected" }
        entry.model.stats = display
        guard sample.width > 0, sample.height > 0 else { return }
        let geometry = VideoWindowGeometry(width: sample.width, height: sample.height, orientation: sample.orientation)
        guard geometry != entry.geometry else { return }
        entry.geometry = geometry; entries[device] = entry
        let window = entry.window, oldFrame = window.frame
        let content = window.contentRect(forFrameRect: oldFrame).size
        let edge = max(content.width, content.height), aspect = CGFloat(geometry.aspect)
        let size = NSSize(width: edge * min(1, aspect), height: edge * min(1, 1 / aspect))
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        var newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        newFrame.origin = NSPoint(x: oldFrame.midX - newFrame.width / 2, y: oldFrame.midY - newFrame.height / 2)
        window.setFrame(newFrame, display: true, animate: false)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = entries.first(where: { $0.value.window === window })?.key else { return }
        // Closing a window releases its presentation resources when the session ends;
        // it does not stop another session or the listener.
        entries.removeValue(forKey: id); sessions.close(device: id)
    }

}
