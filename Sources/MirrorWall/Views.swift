import AppKit
import AVFoundation
import MirrorCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: SlotStore
    @State private var focusedSlotID: Int?

    var body: some View {
        Group {
            if store.uxplayURL == nil {
                SetupView()
            } else {
                grid
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem {
                Button {
                    store.addSlot()
                } label: {
                    Label("Add Slot", systemImage: "plus")
                }
                .disabled(!store.canAddSlot || store.uxplayURL == nil)
                .help("Add a slot another iPhone can mirror to")
            }
            ToolbarItem {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Choose which phones can mirror, and alerts")
            }
        }
    }

    /// The focused slot, if it still exists.
    private var focusedSlot: Slot? {
        focusedSlotID.flatMap { id in store.slots.first { $0.id == id } }
    }

    /// One grid for both modes: focusing filters it down to one slot, so that slot's tile stays the
    /// same view instead of being rebuilt.
    private var grid: some View {
        GeometryReader { geometry in
            let focused = focusedSlot
            ScrollView {
                LazyVGrid(
                    columns: focused == nil
                        ? [GridItem(.adaptive(minimum: 220), spacing: 16)]
                        : [GridItem(.flexible())],
                    spacing: 16
                ) {
                    ForEach(focused.map { [$0] } ?? store.slots) { slot in
                        SlotTile(
                            slot: slot,
                            isFocused: focused != nil,
                            maxVideoHeight: focused != nil ? max(200, geometry.size.height - 90) : nil
                        ) {
                            focusedSlotID = focused == nil ? slot.id : nil
                        }
                    }
                }
                .padding()
                // Fills the window, so right-clicking anywhere between or below the tiles offers a
                // new slot. Tiles keep their own menus.
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Add Slot") { store.addSlot() }
                        .disabled(!store.canAddSlot)
                }
            }
        }
    }
}

/// Shown when uxplay can't be found.
struct SetupView: View {
    @EnvironmentObject private var store: SlotStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Mirror Wall needs uxplay")
                .font(.title2.bold())
            Text("It looks in /opt/homebrew/bin, /usr/local/bin and the casting app folder. Point it at the uxplay you built.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Choose uxplay…") { store.chooseUxPlay() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SlotTile: View {
    @EnvironmentObject private var store: SlotStore
    @ObservedObject var slot: Slot
    let isFocused: Bool
    /// In single-slot view, keeps the picture within the window.
    var maxVideoHeight: CGFloat? = nil
    let toggleFocus: () -> Void

    @State private var showingLog = false
    @AppStorage(StatsSetting.key) private var showStats = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 8) {
            framedPicture
                .onTapGesture(count: 2, perform: toggleFocus)
                .frame(maxHeight: maxVideoHeight ?? .infinity)

            footer
        }
        .contextMenu { menuItems }
        .sheet(isPresented: $showingLog) { LogView(slot: slot, log: slot.log) }
        .alert("Rename slot", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { store.rename(slot, to: newName) }
            Button("Use the Mac's Name") { store.resetName(slot) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is the name the iPhone shows in Screen Mirroring, up to \(SlotConfig.maxNameLength) characters. The slot restarts, so a phone mirroring to it will need to reconnect.")
        }
    }

    /// The picture and what goes over it, in a phone frame when the slot has one.
    @ViewBuilder
    private var framedPicture: some View {
        let picture = ZStack {
            if !showsPicture, case .image(let fileName) = store.standby(for: slot) {
                // Shown as the slot's own window shows it; the footer still gives the status.
                StandbyImage(fileName: fileName)
            }
            VideoLayerView(renderer: slot.renderer, isShowing: showsPicture)
            if !showsPicture {
                if !hasStandbyImage { placeholder }
            } else if slot.state == .paused {
                pausedBanner
            }
            if showStats {
                StatsOverlay(slot: slot, stats: slot.stats)
            }
        }
        .overlay(alignment: .topTrailing) { popOutButton }
        if slot.showsBezel {
            PhoneBezel(geometry: slot.bezel(for: pictureShape), picture: pictureShape) {
                picture.background(Color.black)
            }
        } else {
            picture
                .aspectRatio(pictureShape.width / pictureShape.height, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
        }
    }

    private var pictureShape: CGSize {
        if let size = slot.videoSize, size.width > 0, size.height > 0 { return size }
        return CGSize(width: 9, height: 19.5) // a portrait iPhone until the first picture arrives
    }

    /// The last picture stays up while live or paused; a disconnected phone's stale frame is hidden.
    private var showsPicture: Bool {
        slot.showsPicture
    }

    private var hasStandbyImage: Bool {
        if case .image = store.standby(for: slot) { return true }
        return false
    }

    /// Opens the slot's own window, or closes it if open. Sits in the picture's top right corner,
    /// clear of Stats for Nerds in the top left.
    private var popOutButton: some View {
        let isOpen = store.poppedOutIDs.contains(slot.id)
        return Button {
            if isOpen { store.closeOwnWindow(slot) } else { store.openOwnWindow(slot) }
        } label: {
            Image(systemName: isOpen ? "arrow.down.left" : "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .help(isOpen ? "Close this slot's own window" : "Open this slot in its own window, for OBS")
    }

    private var pausedBanner: some View {
        VStack {
            Spacer()
            Label("Screen off. Turn it on within about a minute or the iPhone stops mirroring.", systemImage: "moon.fill")
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.7))
                .foregroundStyle(.white)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: placeholderIcon)
                .font(.system(size: 28))
            Text(placeholderText)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding()
    }

    private var placeholderIcon: String {
        switch slot.state {
        case .failed: return "exclamationmark.triangle"
        case .stopped: return "pause.circle"
        case .disconnected: return "iphone.slash"
        default: return "iphone"
        }
    }

    private var placeholderText: String {
        switch slot.state {
        case .waiting, .live, .paused: return "On your iPhone, open Control Center › Screen Mirroring and pick “\(slot.name)”."
        case .connecting: return "Connecting to \(slot.phoneName ?? "iPhone")…"
        case .disconnected:
            return "\(slot.phoneName ?? "The iPhone") stopped mirroring. To reconnect, pick “\(slot.name)” in Screen Mirroring on the phone."
        case .stopped: return "Stopped"
        case .failed(let message): return message
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(slot.name)
                    .font(.headline)
                    .lineLimit(1)
                if let feedName = slot.obsFeedName {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                        .help("Sending to OBS: add a Syphon Client source and pick \"[Mirror Wall] \(feedName)\"")
                }
                Spacer(minLength: 4)
                Button {
                    if slot.recordingSince == nil { slot.startRecording() } else { slot.stopRecording() }
                } label: {
                    Image(systemName: slot.recordingSince == nil ? "record.circle" : "stop.circle.fill")
                        .foregroundStyle(slot.recordingSince == nil ? Color.secondary : Color.red)
                }
                .buttonStyle(.borderless)
                .help(slot.recordingSince == nil
                    ? (showsPicture ? "Start recording to \(SaveFolders.recordings.lastPathComponent)" : "Record to \(SaveFolders.recordings.lastPathComponent) when a phone connects")
                    : "Stop recording")
                Button {
                    slot.takeScreenshot()
                } label: {
                    Image(systemName: "camera")
                }
                .buttonStyle(.borderless)
                .disabled(!showsPicture)
                .help("Save a screenshot to \(SaveFolders.screenshots.lastPathComponent)")
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            HStack(spacing: 6) {
                // The phone's name gives way when space is short; the status never does.
                Text(slot.state == .disconnected ? "" : slot.phoneName ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        if let saved = slot.screenshotSavedAt, context.date.timeIntervalSince(saved) < 2 {
                            Text("Screenshot saved")
                        }
                        if let since = slot.recordingSince {
                            Text("● REC \(Self.format(context.date.timeIntervalSince(since)))")
                                .foregroundStyle(.red)
                                .help(slot.recordingError ?? "Recording to \(SaveFolders.recordings.path)")
                        }
                        Text(statusText(now: context.date))
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
        }
    }

    /// The slot's own menu, in groups: viewing, capturing, what the picture looks like and
    /// where it goes, the slot itself. App-wide items (the recordings and screenshots folders,
    /// Stats for Nerds) live in the menu bar's File and View menus.
    @ViewBuilder
    private var menuItems: some View {
        Button(isFocused ? "Back to All Slots" : "Show Only This Slot", action: toggleFocus)
        if store.poppedOutIDs.contains(slot.id) {
            Button("Close Own Window") { store.closeOwnWindow(slot) }
        } else {
            Button("Open in Own Window") { store.openOwnWindow(slot) }
        }
        Toggle("Show on Stage", isOn: Binding(
            get: { slot.showsOnStage },
            set: { store.setShowsOnStage(slot, on: $0) }
        ))
        Divider()
        Button("Take Screenshot") { slot.takeScreenshot() }
            .disabled(!showsPicture)
        if slot.recordingSince == nil {
            // With no phone yet, recording starts when one connects.
            Button(showsPicture ? "Start Recording" : "Record When a Phone Connects") { slot.startRecording() }
        } else {
            Button("Stop Recording") { slot.stopRecording() }
        }
        Divider()
        if SyphonFeed.isAvailable {
            Toggle("Send to OBS (Syphon)", isOn: Binding(
                get: { slot.sendsToOBS },
                set: { store.setOBSFeed(slot, on: $0) }
            ))
        }
        Menu("Phone Bezel") {
            Toggle("On the Wall and Own Window", isOn: Binding(
                get: { slot.showsBezel },
                set: { store.setBezel(slot, on: $0) }
            ))
            if SyphonFeed.isAvailable {
                Toggle("In the OBS Feed", isOn: Binding(
                    get: { slot.framesOBSFeed },
                    set: { store.setFramesOBSFeed(slot, on: $0) }
                ))
                .disabled(!slot.sendsToOBS)
            }
        }
        Menu("Standby Picture") {
            let current = StandbyChoice(slot.config.standby)
            standbyItem("Same as All Slots (Settings)", .allSlots, current: current) { store.setStandby(slot, nil) }
            standbyItem("Waiting Message", .message, current: current) { store.setStandby(slot, .message) }
            standbyItem("Blank", .blank, current: current) { store.setStandby(slot, .blank) }
            // Always offered, so a slot with an image can switch to another one.
            standbyItem("Image…", .image, current: current) {
                // Once the menu has closed: a file chooser opened from inside it is unreliable.
                DispatchQueue.main.async { store.chooseStandbyImage(for: slot) }
            }
        }
        Divider()
        Button("Rename…") {
            newName = slot.name
            renaming = true
        }
        Menu("Troubleshooting") {
            Button("Show Log") { showingLog = true }
            Button("Restart Receiver") { store.restart(slot) }
        }
        Divider()
        Button("Remove Slot", role: .destructive) { store.remove(slot) }
    }

    /// A menu item with a tick when it's the current choice. Choosing it again runs it again
    /// (so Image… can pick a different image).
    private func standbyItem(_ title: String, _ choice: StandbyChoice, current: StandbyChoice, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { choice == current }, set: { _ in action() }))
    }

    private var statusColor: Color {
        switch slot.state {
        case .live: return .green
        case .waiting, .connecting, .paused: return .yellow
        case .disconnected: return .orange
        case .stopped: return .gray
        case .failed: return .red
        }
    }

    private func statusText(now: Date) -> String {
        switch slot.state {
        case .stopped: return "Stopped"
        case .failed: return "Error"
        case .waiting: return "Waiting"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        case .paused: return "Screen off \(Self.format(now.timeIntervalSince(slot.stateSince)))"
        case .live:
            guard let since = slot.connectedSince else { return "Live" }
            return "Live \(Self.format(now.timeIntervalSince(since)))"
        }
    }

    /// "0:42", "12:05" or "1:03:20".
    private static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        let mmss = String(format: "%d:%02d", minutes, seconds)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : mmss
    }
}

struct LogView: View {
    let slot: Slot
    @ObservedObject var log: SlotLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(slot.name) log")
                .font(.headline)
            ScrollView {
                Text(log.lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 560, minHeight: 320)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.lines.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}

/// Shows a slot's picture through a display layer of its own, so the same slot can be on screen
/// in several places (its tile and its own window).
struct VideoLayerView: NSViewRepresentable {
    let renderer: H264Renderer
    var isShowing = true

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView(renderer: renderer)
        view.isShowing = isShowing
        return view
    }

    func updateNSView(_ view: LayerHostView, context: Context) {
        view.isShowing = isShowing
    }

    static func dismantleNSView(_ view: LayerHostView, coordinator: ()) {
        view.detach()
    }

    final class LayerHostView: NSView {
        private let renderer: H264Renderer
        private let videoLayer: AVSampleBufferDisplayLayer

        init(renderer: H264Renderer) {
            self.renderer = renderer
            videoLayer = renderer.makeLayer()
            super.init(frame: .zero)
            let host = CALayer()
            host.addSublayer(videoLayer)
            layer = host
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// Hidden while there's no current picture. When shown again (a phone reconnecting), the
        /// layer is re-laid out and given the latest picture, so it doesn't sit on a stale one.
        var isShowing = true {
            didSet {
                guard isShowing != oldValue else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                videoLayer.isHidden = !isShowing
                videoLayer.frame = bounds
                CATransaction.commit()
                if isShowing { renderer.refresh(videoLayer) }
            }
        }

        func detach() {
            renderer.removeLayer(videoLayer)
        }

        // Let SwiftUI handle clicks (double-click to focus, context menu).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// The choices in a Standby Picture menu. `allSlots` only applies to a single slot.
enum StandbyChoice: Hashable {
    case allSlots, message, blank, image

    init(_ standby: StandbyPicture?) {
        switch standby {
        case nil: self = .allSlots
        case .message?: self = .message
        case .blank?: self = .blank
        case .image?: self = .image
        }
    }
}
