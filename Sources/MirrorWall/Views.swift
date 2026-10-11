import AppKit
import MirrorCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: SlotStore
    @State private var focusedSlotID: Int?

    var body: some View {
        Group {
            if store.uxplayURL == nil {
                SetupView()
            } else if let id = focusedSlotID, let slot = store.slots.first(where: { $0.id == id }) {
                SlotTile(slot: slot, isFocused: true) { focusedSlotID = nil }
                    .padding()
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
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                ForEach(store.slots) { slot in
                    SlotTile(slot: slot, isFocused: false) { focusedSlotID = slot.id }
                }
            }
            .padding()
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
            Text("It looks in /opt/homebrew/bin, /usr/local/bin and the Apple Casting App folder. Point it at the uxplay you built.")
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
    let toggleFocus: () -> Void

    @State private var showingLog = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                VideoLayerView(videoLayer: slot.renderer.layer)
                    .opacity(slot.lastFrameAt == nil ? 0 : 1)
                if slot.lastFrameAt == nil {
                    placeholder
                }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
            .onTapGesture(count: 2, perform: toggleFocus)

            footer
        }
        .contextMenu { menuItems }
        .sheet(isPresented: $showingLog) { LogView(slot: slot) }
        .alert("Rename slot", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { store.rename(slot, to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is the name the iPhone shows in Screen Mirroring. The slot restarts, so a phone mirroring to it will need to reconnect.")
        }
    }

    private var aspectRatio: CGFloat {
        if let size = slot.videoSize, size.height > 0 { return size.width / size.height }
        return 9.0 / 19.5 // a portrait iPhone until the first picture arrives
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
        default: return "iphone"
        }
    }

    private var placeholderText: String {
        switch slot.state {
        case .waiting, .live: return "On your iPhone, open Control Center › Screen Mirroring and pick “\(slot.name)”."
        case .stopped: return "Stopped"
        case .failed(let message): return message
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(slot.name)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(statusText(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(isFocused ? "Back to All Slots" : "Show Only This Slot", action: toggleFocus)
        Button("Rename…") {
            newName = slot.name
            renaming = true
        }
        Button("Restart") { store.restart(slot) }
        Button("Show Log") { showingLog = true }
        Divider()
        Button("Remove Slot", role: .destructive) { store.remove(slot) }
    }

    private var statusColor: Color {
        switch slot.state {
        case .live: return .green
        case .waiting: return .yellow
        case .stopped: return .gray
        case .failed: return .red
        }
    }

    private func statusText(now: Date) -> String {
        switch slot.state {
        case .stopped: return "Stopped"
        case .failed: return "Error"
        case .waiting: return "Waiting"
        case .live:
            guard let last = slot.lastFrameAt else { return "Live" }
            let idle = Int(now.timeIntervalSince(last))
            // iPhones send nothing while the screen is unchanged or locked, so this is only a hint.
            return idle < 5 ? "Live" : "No change for \(Self.format(seconds: idle))"
        }
    }

    private static func format(seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
    }
}

struct LogView: View {
    @ObservedObject var slot: Slot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(slot.name) log")
                .font(.headline)
            ScrollView {
                Text(slot.log.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 560, minHeight: 320)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(slot.log.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}

/// Hosts the slot's AVSampleBufferDisplayLayer. Only one view shows a given layer at a time.
struct VideoLayerView: NSViewRepresentable {
    let videoLayer: CALayer

    func makeNSView(context: Context) -> LayerHostView {
        LayerHostView(hostedLayer: videoLayer)
    }

    func updateNSView(_ view: LayerHostView, context: Context) {
        view.attach()
    }

    final class LayerHostView: NSView {
        private let hostedLayer: CALayer

        init(hostedLayer: CALayer) {
            self.hostedLayer = hostedLayer
            super.init(frame: .zero)
            wantsLayer = true
            attach()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        // Let SwiftUI handle clicks (double-click to focus, context menu).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func attach() {
            if hostedLayer.superlayer !== layer {
                layer?.addSublayer(hostedLayer)
            }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
