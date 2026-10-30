import AppKit
import Combine
import MirrorCore
import SwiftUI

/// One window showing every phone that's mirroring, side by side at their true relative sizes,
/// for sharing a single window in Teams, Zoom or OBS. Titled "MacMirror-Stage" so OBS finds it
/// again by name, like the slots' own windows.
@MainActor
final class StageWindow: NSObject, NSWindowDelegate {
    static let title = "MacMirror-Stage"

    let window: NSWindow
    var onClose: (() -> Void)?

    init(store: SlotStore) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            // Not minimizable, for the same reason as slots' own windows: a minimized window only
            // gives capture apps a frozen thumbnail.
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.title = Self.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.current.stageWindowColor
        window.minSize = NSSize(width: 320, height: 180)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: StageView(model: StageModel(store: store), store: store, onClose: { [weak self] in self?.close() }))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MacMirror stage")
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// Tells the stage to redraw when any slot changes (a phone connecting, turning sideways,
/// getting a frame), since which phones are on stage and their sizes come from every slot.
@MainActor
final class StageModel: ObservableObject {
    private var slotsWatcher: AnyCancellable?
    private var watchers: [AnyCancellable] = []

    init(store: SlotStore) {
        slotsWatcher = store.$slots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] slots in
                MainActor.assumeIsolated { self?.watch(slots) }
            }
    }

    private func watch(_ slots: [Slot]) {
        // Deferred to the next turn of the main queue, because @Published sends before the
        // property changes.
        watchers = slots.map { slot in
            slot.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.objectWillChange.send() }
                }
        }
        objectWillChange.send()
    }
}

struct StageView: View {
    @ObservedObject var model: StageModel
    @ObservedObject var store: SlotStore
    let onClose: () -> Void
    @CurrentTheme private var theme
    /// The "Live demo" strip along the bottom.
    @StageCaptionSetting private var showsCaption
    /// Stage-first: the controls fade in while the mouse moves over the Stage and fade out again
    /// a couple of seconds after it stops, so the shared picture stays clean.
    @State private var controlsVisible = false
    @State private var overControls = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let phones = store.slots.filter { $0.showsPicture && $0.showsOnStage }
        GeometryReader { proxy in
            let captionHeight = showsCaption ? min(64, max(34, proxy.size.height * 0.085)) : 0
            let frames = stageFrames(
                sizes: phones.map(Self.size(of:)),
                layout: store.stageLayout,
                areaWidth: proxy.size.width,
                areaHeight: proxy.size.height - captionHeight
            )
            ZStack(alignment: .topLeading) {
                theme.stageBackground
                    .frame(width: proxy.size.width, height: proxy.size.height)
                if phones.isEmpty {
                    StageEmptyState(slots: store.slots)
                        .frame(width: proxy.size.width, height: proxy.size.height - captionHeight)
                }
                ForEach(zip(phones, frames).map(Placed.init)) { placed in
                    StagePhone(slot: placed.slot)
                        .frame(width: placed.frame.width, height: placed.frame.height)
                        .offset(x: placed.frame.x, y: placed.frame.y)
                }
                if showsCaption {
                    StageCaption(phones: phones, height: captionHeight)
                        .frame(width: proxy.size.width, height: captionHeight)
                        .offset(y: proxy.size.height - captionHeight)
                }
                if !phones.isEmpty {
                    WaitingPills(slots: store.slots.filter { !$0.showsPicture })
                        .frame(width: proxy.size.width)
                        .offset(y: proxy.size.height - captionHeight - 42)
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(false)
                }
                StageControls(store: store, connected: store.slots.filter(\.showsPicture), recording: store.isAnyRecording)
                    .onHover { inside in
                        overControls = inside
                        if inside { showControls() } else { scheduleHide() }
                    }
                    .frame(width: proxy.size.width)
                    .offset(y: 36)
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
            }
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            switch phase {
            case .active: showControls()
            case .ended: scheduleHide()
            }
        }
        .contextMenu {
            StageLayoutItems(store: store)
            Toggle("Show Caption Bar", isOn: $showsCaption)
            Divider()
            Menu("Phones on Stage") {
                StageSlotItems(store: store)
            }
            Divider()
            Button("Show Wall") { MainWindow.show() }
            Button("Close Stage", action: onClose)
        }
    }

    private func showControls() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled, !overControls else { return }
            withAnimation(.easeIn(duration: 0.4)) { controlsVisible = false }
        }
    }

    private struct Placed: Identifiable {
        let slot: Slot
        let frame: StageRect
        var id: Int { slot.id }
    }

    private static func picture(of slot: Slot) -> CGSize {
        slot.videoSize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? CGSize(width: 9, height: 19.5)
    }

    private static func size(of slot: Slot) -> (width: Double, height: Double) {
        let picture = picture(of: slot)
        return stagePhoneSize(modelCode: slot.config.lastPhoneModel, pictureWidth: picture.width, pictureHeight: picture.height, bezel: slot.showsBezel)
    }
}

private func stageStatus(_ state: Slot.State) -> String {
    switch state {
    case .live: return "live"
    case .connecting: return "connecting"
    case .paused: return "screen off"
    case .waiting: return "waiting"
    case .disconnected: return "disconnected"
    case .stopped: return "stopped"
    case .failed: return "error"
    }
}

/// The Stage's control bar: a chip per connected phone (its menu has the slot's options), then
/// add slot, layout, bezels, record and more. Fades with the mouse; see StageView.
private struct StageControls: View {
    @ObservedObject var store: SlotStore
    /// Passed in by the Stage, which redraws whenever any slot changes.
    let connected: [Slot]
    let recording: Bool
    @CurrentTheme private var theme
    @StageCaptionSetting private var showsCaption
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 4) {
            ForEach(connected) { slot in
                StageSlotChip(slot: slot, store: store)
            }
            if !connected.isEmpty {
                Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 18).padding(.horizontal, 2)
            }
            Button { store.addSlot() } label: {
                HUDLabel(title: "Slot", systemImage: "plus")
            }
            .disabled(!store.canAddSlot)
            .help("Add a slot another phone can mirror to")
            Menu { StageLayoutItems(store: store) } label: {
                HUDLabel(title: "Layout", systemImage: "rectangle.split.3x1")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            Button { store.setBezelsForAllSlots(!store.bezelsForAllSlots) } label: {
                HUDLabel(title: "Bezels", systemImage: "iphone", isOn: store.bezelsForAllSlots)
            }
            .help("Phone frames around every phone")
            Button { recording ? store.stopAllRecordings() : store.startAllRecordings() } label: {
                HUDLabel(title: recording ? "Stop" : "Record", systemImage: recording ? "stop.fill" : "record.circle", fill: theme.red)
            }
            .help(recording ? "Stop all recordings" : "Record every phone")
            Menu {
                Toggle("Caption Bar", isOn: $showsCaption)
                Button("Screenshot All Phones") { store.screenshotAll() }
                Divider()
                Button("Show Wall") { MainWindow.show() }
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            } label: {
                HUDLabel(title: nil, systemImage: "gearshape")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .padding(5)
        .background(theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .fixedSize()
    }
}

/// One item in the control bar.
private struct HUDLabel: View {
    let title: String?
    let systemImage: String
    var isOn = false
    var fill: Color? = nil
    @CurrentTheme private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            if let title { Text(title) }
        }
        .font(theme.font(12, .semibold))
        .foregroundStyle(fill != nil || isOn ? Color.white : theme.controlText)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill ?? (isOn ? Color.white.opacity(0.14) : Color.clear))
        )
        .contentShape(Rectangle())
    }
}

/// A connected phone in the control bar; its menu has what the wall tile's ⋯ menu had.
private struct StageSlotChip: View {
    @CurrentTheme private var theme
    @ObservedObject var slot: Slot
    let store: SlotStore

    var body: some View {
        Menu {
            Toggle("On Stage", isOn: Binding(
                get: { slot.showsOnStage },
                set: { store.setShowsOnStage(slot, on: $0) }
            ))
            Toggle("Phone Bezel", isOn: Binding(
                get: { slot.showsBezel },
                set: { store.setBezel(slot, on: $0) }
            ))
            Divider()
            Button("Take Screenshot") { slot.takeScreenshot() }
            if slot.recordingSince == nil {
                Button("Start Recording") { slot.startRecording() }
            } else {
                Button("Stop Recording") { slot.stopRecording() }
            }
            Divider()
            if store.poppedOutIDs.contains(slot.id) {
                Button("Close Own Window") { store.closeOwnWindow(slot) }
            } else {
                Button("Open in Own Window") { store.openOwnWindow(slot) }
            }
            Button("More in the Wall…") { MainWindow.show() }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(theme.statusColor(slot.state)).frame(width: 8, height: 8)
                Text(slot.phoneName ?? slot.name).lineLimit(1)
                if slot.recordingSince != nil {
                    Text("REC").foregroundStyle(theme.red)
                }
            }
            .font(theme.font(12, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.1)))
            .opacity(slot.showsOnStage ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(slot.showsOnStage ? "On the Stage. Click for this phone's options." : "Off the Stage. Click to put it back.")
    }
}

/// Slots without a phone, along the bottom while the controls show.
private struct WaitingPills: View {
    @CurrentTheme private var theme
    let slots: [Slot]

    var body: some View {
        HStack(spacing: 8) {
            // Labelled, so a pill sitting under a phone isn't read as that phone's status.
            if !slots.isEmpty {
                Text("Other slots")
                    .font(theme.font(11, .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.6), radius: 2)
            }
            ForEach(slots) { slot in
                HStack(spacing: 7) {
                    Circle().fill(theme.statusColor(slot.state)).frame(width: 7, height: 7)
                    Text(slot.name).font(theme.font(12, .semibold))
                    Text(stageStatus(slot.state)).font(theme.font(11)).opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(theme.panel.opacity(0.75)))
            }
        }
    }
}

/// The Stage before any phone is mirroring: how to connect, slot by slot. The meeting may see
/// this, so it reads as a friendly "about to start" screen.
private struct StageEmptyState: View {
    @CurrentTheme private var theme
    let slots: [Slot]

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Ready for phones")
                    .font(theme.font(28, .bold))
                Text("Each phone appears here as it connects.")
                    .font(theme.font(15))
                    .opacity(0.7)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(slots) { slot in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(theme.statusColor(slot.state)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(slot.name).font(theme.font(14, .semibold))
                            Text("iPhone: Control Center › Screen Mirroring › “\(slot.name)”   ·   Android: Mirror Wall Cast")
                                .font(theme.font(12))
                                .opacity(0.65)
                        }
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.panel.opacity(0.45)))
        }
        .foregroundStyle(.white)
        .padding()
    }
}

/// The strip along the stage's bottom: "Live demo · Tom's iPhone & Zebra TC58".
private struct StageCaption: View {
    @CurrentTheme private var theme
    let phones: [Slot]
    let height: CGFloat

    var body: some View {
        HStack(spacing: height * 0.3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.red)
                .frame(width: 4, height: height * 0.5)
            Text("Live demo")
                .font(theme.font(height * 0.36, .bold))
            if !names.isEmpty {
                Text("· \(names)")
                    .font(theme.font(height * 0.36))
                    .opacity(0.75)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: height)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, height * 0.5)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.18))
    }

    private var names: String {
        phones.map { $0.phoneName ?? $0.name }.formatted(.list(type: .and))
    }
}

/// One phone on the stage: its picture, in its phone frame when the slot has one on.
private struct StagePhone: View {
    @ObservedObject var slot: Slot

    var body: some View {
        let shape = slot.videoSize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? CGSize(width: 9, height: 19.5)
        if slot.drawsBezel {
            PhoneBezel(geometry: slot.bezel(for: shape), picture: shape) { picture }
        } else {
            GeometryReader { proxy in
                picture.clipShape(RoundedRectangle(cornerRadius: min(proxy.size.width, proxy.size.height) * 0.04, style: .continuous))
            }
        }
    }

    private var picture: some View {
        ZStack {
            Color.black
            VideoLayerView(renderer: slot.renderer, isShowing: slot.showsPicture)
        }
    }
}

/// Ticked layout choices, for the View menu and the stage's own menu.
struct StageLayoutItems: View {
    @ObservedObject var store: SlotStore

    var body: some View {
        ForEach(StageLayout.allCases) { layout in
            Toggle(layout.title, isOn: Binding(
                get: { store.stageLayout == layout },
                set: { _ in store.setStageLayout(layout) }
            ))
        }
    }
}

/// A tick for each slot, to choose which phones appear on the stage.
struct StageSlotItems: View {
    @ObservedObject var store: SlotStore

    var body: some View {
        ForEach(store.slots) { slot in
            StageSlotToggle(slot: slot, store: store)
        }
    }
}

private struct StageSlotToggle: View {
    @ObservedObject var slot: Slot
    let store: SlotStore

    var body: some View {
        Toggle(slot.phoneName.map { "\(slot.name) (\($0))" } ?? slot.name, isOn: Binding(
            get: { slot.showsOnStage },
            set: { store.setShowsOnStage(slot, on: $0) }
        ))
    }
}

/// View › Show Stage, View › Stage Layout and View › Phones on Stage.
struct StageCommands: Commands {
    @ObservedObject var store: SlotStore

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Show Stage") { store.showStage() }
                .keyboardShortcut("1")
            Menu("Stage Layout") {
                StageLayoutItems(store: store)
            }
            Menu("Phones on Stage") {
                StageSlotItems(store: store)
            }
        }
    }
}
