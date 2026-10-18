import SwiftUI
import AppKit
import AVFoundation
import IOSDirectShared

@MainActor
final class VideoWindowModel: ObservableObject {
    @Published var rotation = VideoRotationState()
    var setAutomatic: ((Bool) -> Void)?
    @Published var stats: VideoReceiveSnapshot
    init(session: UUID) { stats = VideoReceiveSnapshot(session: session) }
}

/// Key equivalents are handled by the key video window, including after a layer rebind.
private final class RotationWindow: NSWindow {
    var rotateAction: (() -> Void)?
    var resetAction: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r": rotateAction?(); return true
            case "0": resetAction?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class RotationToolbar: NSObject, NSToolbarDelegate {
    private let rotate: () -> Void
    init(window: NSWindow, rotate: @escaping () -> Void) {
        self.rotate = rotate; super.init()
        let toolbar = NSToolbar(identifier: "IOSDirectRotation")
        toolbar.delegate = self; toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
    }
    private let rotateID = NSToolbarItem.Identifier("IOSDirectRotate")
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [rotateID, .flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [rotateID, .flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == rotateID else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Rotate"; item.paletteLabel = "Rotate"; item.toolTip = "Rotate clockwise (⌘R); reset with ⌘0"
        item.image = NSImage(systemSymbolName: "rotate.right", accessibilityDescription: "Rotate")
        item.target = self; item.action = #selector(clicked)
        return item
    }
    @objc private func clicked() { rotate() }
}

private final class VideoLayerHost: NSView {
    var orientation: UInt8 = 1
    var rotationDegrees: UInt16 = 0
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
        let swapped = VideoWindowGeometry(width: 1, height: 1, orientation: orientation, rotationDegrees: rotationDegrees).swapsAxes
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
        let rotation = CGAffineTransform(rotationAngle: -CGFloat(rotationDegrees) * .pi / 180)
        display.setAffineTransform(transform.concatenating(rotation)); CATransaction.commit()
    }
}
private struct VideoLayerView: NSViewRepresentable {
    let renderer: VideoSessionRenderer
    let orientation: UInt8
    let rotationDegrees: UInt16
    func makeNSView(context: Context) -> NSView { VideoLayerHost(display: renderer.layer) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? VideoLayerHost)?.replaceDisplay(renderer.layer)
        (view as? VideoLayerHost)?.rotationDegrees = rotationDegrees
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
            VideoLayerView(renderer: renderer, orientation: model.stats.orientation, rotationDegrees: model.rotation.degrees)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(model.stats.state).font(.headline)
                    Button(showStats ? "Hide stats" : "Show stats") { showStats.toggle() }.controlSize(.small)
                }
                Toggle("Smooth (100 ms buffer)", isOn: Binding(
                    get: { model.stats.presentationMode == "smooth100ms" },
                    set: { renderer.setSmoothing($0) }
                )).toggleStyle(.checkbox)
                Toggle("Auto-rotate", isOn: Binding(get: { model.rotation.automatic }, set: { model.setAutomatic?($0) }))
                    .toggleStyle(.checkbox)
                if showStats {
                    Text("Rotation \(model.rotation.degrees)° · source \(model.rotation.sourceLabel)")
                    let s = model.stats
                    if let settings = s.streamSettings {
                        Text("\(settings.preset.rawValue) · \(s.width)×\(s.height) · \(settings.fps) fps · target \(settings.targetBitrate / 1_000_000) Mbit/s")
                    } else { Text("Stream quality metadata unavailable") }
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
        let window: RotationWindow, model: VideoWindowModel
        let toolbar: RotationToolbar
        var renderer: VideoSessionRenderer
        var geometry: VideoWindowGeometry?
    }
    private var entries: [UUID: Entry] = [:] // Verified deviceID, never label or installID.
    private var sessions = VideoWindowSessions()
    // standard uses this standalone receiver's bundle domain; never Mirror Wall's domain.
    private let defaults = UserDefaults.standard
    private func rotationKey(_ device: UUID) -> String { "video.manualRotation.\(device.uuidString)" }
    private func changeRotation(device: UUID, _ change: (inout VideoRotationState) -> Void) {
        guard let entry = entries[device] else { return }
        var next = entry.model.rotation; change(&next); entry.model.rotation = next
        defaults.set(Int(next.manualDegrees), forKey: rotationKey(device))
        updateGeometry(device: device)
    }
    func open(device: UUID, session: UUID, label: String, renderer: VideoSessionRenderer, model: VideoWindowModel) {
        sessions.bind(device: device, session: session)
        var waiting = VideoReceiveSnapshot(session: session); waiting.state = "Waiting for video"
        if var entry = entries[device] {
            // New decoder/layer per authenticated session; keep the same NSWindow,
            // position and geometry. Disconnected layers have already been blacked.
            entry.renderer = renderer; entry.model.stats = waiting
            entry.model.rotation.resetHints()
            entry.window.title = label
            entry.window.contentView = NSHostingView(rootView: VideoSessionView(model: entry.model, renderer: renderer))
            entries[device] = entry; entry.window.makeKeyAndOrderFront(nil); return
        }
        model.stats = waiting
        model.rotation = VideoRotationState(manualDegrees: UInt16(exactly: defaults.integer(forKey: rotationKey(device))) ?? 0)
        model.setAutomatic = { [weak self] enabled in self?.changeRotation(device: device) { $0.automatic = enabled } }
        let window = RotationWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = label
        window.isReleasedWhenClosed = false; window.backgroundColor = .black; window.delegate = self
        window.rotateAction = { [weak self] in self?.changeRotation(device: device) { $0.cycle() } }
        window.resetAction = { [weak self] in self?.changeRotation(device: device) { $0.reset() } }
        let toolbar = RotationToolbar(window: window) { [weak window] in window?.rotateAction?() }
        window.contentView = NSHostingView(rootView: VideoSessionView(model: model, renderer: renderer))
        entries[device] = Entry(window: window, model: model, toolbar: toolbar, renderer: renderer)
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    func update(_ sample: VideoReceiveSnapshot) {
        guard let device = sessions.device(for: sample.session), let entry = entries[device] else { return }
        var display = sample
        if sample.state == "disconnected" { display.state = "Disconnected" }
        entry.model.stats = display
        if let hint = sample.captureOrientationHint { entry.model.rotation.accept(hint) }
        if let hint = sample.deviceOrientationHint { entry.model.rotation.accept(hint) }
        updateGeometry(device: device)
    }
    private func updateGeometry(device: UUID) {
        guard var entry = entries[device] else { return }
        let sample = entry.model.stats
        guard sample.width > 0, sample.height > 0 else { return }
        let geometry = VideoWindowGeometry(width: sample.width, height: sample.height, orientation: sample.orientation, rotationDegrees: entry.model.rotation.degrees)
        guard geometry != entry.geometry else { return }
        let oldGeometry = entry.geometry
        entry.geometry = geometry; entries[device] = entry
        // 180° turns only change the layer, never bounce the window's frame.
        guard oldGeometry?.aspect != geometry.aspect else { return }
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
