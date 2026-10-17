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
    private let store: SlotStore

    init(store: SlotStore) {
        self.store = store
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
        window.backgroundColor = Brand.nsBlue
        window.minSize = NSSize(width: 320, height: 180)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: StageView(model: StageModel(store: store), store: store, onClose: { [weak self] in self?.close() }))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MacMirror stage")
        StageControlsPresence.shared.start()
        StageControlsPresence.shared.onPauseKey = { [weak store] in store?.togglePauseAll() }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.close()
    }

    /// ⌘W hides the Stage instead of closing it, so a Teams or Zoom window share keeps its
    /// window. The Dock icon or ⌘1 brings it back. (Close Stage in its menu really closes it.)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    /// Narrows (or widens) the window around the phones on it, keeping its height, with the same
    /// margin at the sides as above and below. A phone-shaped shared window means Teams and Zoom
    /// show the phones much bigger.
    func fitToPhones() {
        guard let content = window.contentView else { return }
        let phones = StageView.phonesOnStage(store)
        guard !phones.isEmpty else { return }
        let height = content.bounds.height
        let caption = StageView.captionEnabled ? StageView.captionHeight(forStageHeight: height) : 0
        let area = height - caption
        // A very wide area, so the phones are as big as the height allows.
        let frames = stageFrames(sizes: phones.map(StageView.size(of:)), layout: store.stageLayout, areaWidth: 100_000, areaHeight: area)
        guard let minX = frames.map(\.x).min(),
              let maxX = frames.map({ $0.x + $0.width }).max(),
              let minY = frames.map(\.y).min(),
              let maxY = frames.map({ $0.y + $0.height }).max() else { return }
        let verticalMargin = area - (maxY - minY)
        let contentWidth = max(window.minSize.width, (maxX - minX) + verticalMargin)
        var frame = window.frame
        let newWidth = contentWidth + (frame.width - content.bounds.width)
        frame.origin.x += (frame.width - newWidth) / 2
        frame.size.width = newWidth
        window.setFrame(frame, display: true, animate: true)
    }
}

/// Whether the Stage's controls are showing. They show only while ⌥ Option (Alt on a PC
/// keyboard) or Control is held, while the pointer is on them, or while pinned (tap C on the
/// Stage, or View › Show Stage Controls), so the meeting watching the Stage doesn't see them
/// every time the presenter moves the mouse.
@MainActor
final class StageControlsPresence: ObservableObject {
    static let shared = StageControlsPresence()

    @Published private(set) var visible = false
    /// View › Stage Controls: keeps them up, for setting up before sharing.
    @Published var pinned = false { didSet { update() } }
    var overControls = false { didSet { update() } }
    private var optionHeld = false
    /// A moment after ⌥ is let go, so the pointer can reach the bar.
    private var lingering = false
    private var lingerTask: Task<Void, Never>?
    private var monitor: Any?

    private var keyMonitor: Any?
    /// P on the Stage: pause or resume every phone.
    var onPauseKey: (() -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = !event.modifierFlags.intersection([.option, .control]).isEmpty
            MainActor.assumeIsolated { self?.setOptionHeld(held) }
            return event
        }
        // On the Stage itself: C pins or unpins the controls, Esc hides pinned ones. Plain keys,
        // so they work on any keyboard.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window?.title == StageWindow.title,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            let handled: Bool = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.charactersIgnoringModifiers?.lowercased() == "c" {
                    self.pinned.toggle()
                    return true
                }
                if event.charactersIgnoringModifiers?.lowercased() == "p" {
                    self.onPauseKey?()
                    return true
                }
                if event.keyCode == 53, self.pinned { // Esc
                    self.pinned = false
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
    }

    private func setOptionHeld(_ held: Bool) {
        guard held != optionHeld else { return }
        optionHeld = held
        lingerTask?.cancel()
        if !held {
            lingering = true
            lingerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { return }
                self.lingering = false
                self.update()
            }
        }
        update()
    }

    private func update() {
        let show = optionHeld || pinned || overControls || lingering
        if show != visible { visible = show }
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
    /// The "Live demo" strip along the bottom, with the logo when it's installed.
    @AppStorage("stageCaptionBar") private var showsCaption = true
    @ObservedObject private var presence = StageControlsPresence.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let showsCaptionKey = "stageCaptionBar"
    static var captionEnabled: Bool {
        UserDefaults.standard.object(forKey: showsCaptionKey) as? Bool ?? true
    }

    static func captionHeight(forStageHeight height: CGFloat) -> CGFloat {
        min(64, max(40, height * 0.085))
    }

    /// Phones shown on the Stage: those mirroring, and those that just dropped and may come back.
    static func phonesOnStage(_ store: SlotStore) -> [Slot] {
        store.slots.filter { $0.showsOnStage && ($0.showsPicture || store.isReconnecting($0)) }
    }

    var body: some View {
        let phones = Self.phonesOnStage(store)
        let controlsVisible = presence.visible
        GeometryReader { proxy in
            let captionHeight = showsCaption ? Self.captionHeight(forStageHeight: proxy.size.height) : 0
            let frames = stageFrames(
                sizes: phones.map(Self.size(of:)),
                layout: store.stageLayout,
                areaWidth: proxy.size.width,
                areaHeight: proxy.size.height - captionHeight
            )
            // The control bar sits over the caption strip, never over the phones.
            let barHeight: CGFloat = 38
            let barY = showsCaption
                ? proxy.size.height - captionHeight + (captionHeight - barHeight) / 2
                : proxy.size.height - barHeight - 10
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topTrailing) {
                    Brand.stageGradient
                    HexPattern(
                        colors: [.white, Brand.sky, Brand.teal],
                        radius: max(16, proxy.size.height * 0.04),
                        columns: 6,
                        rows: 7,
                        density: 0.75,
                        seed: 21,
                        opacity: 0.16
                    )
                    .frame(width: proxy.size.width * 0.42, height: proxy.size.height * 0.7)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                if phones.isEmpty {
                    StageEmptyState(slots: store.slots, showsSteps: controlsVisible, pin: store.airplayPIN)
                        .frame(width: proxy.size.width, height: proxy.size.height - captionHeight)
                }
                ForEach(zip(phones, frames).map(Placed.init)) { placed in
                    StagePhone(slot: placed.slot, reconnecting: !placed.slot.showsPicture)
                        .frame(width: placed.frame.width, height: placed.frame.height)
                        .offset(x: placed.frame.x, y: placed.frame.y)
                }
                if showsCaption {
                    StageCaption(phones: phones, height: captionHeight)
                        .frame(width: proxy.size.width, height: captionHeight)
                        .offset(y: proxy.size.height - captionHeight)
                }
                if !phones.isEmpty {
                    WaitingPills(slots: store.slots.filter { !$0.showsPicture && !store.isReconnecting($0) }, pin: store.airplayPIN)
                        .frame(width: proxy.size.width)
                        .offset(y: barY - 34)
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(controlsVisible)
                }
                StageControls(
                    store: store,
                    phones: store.slots.filter { $0.showsPicture || store.isReconnecting($0) },
                    recording: store.isAnyRecording
                )
                .onHover { presence.overControls = $0 }
                .frame(width: proxy.size.width)
                .offset(y: barY)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controlsVisible)
        }
        .ignoresSafeArea()
        .contextMenu {
            let sharing = store.sharingSlots
            if !sharing.isEmpty {
                Button(store.isAnyPaused ? "Unfreeze Stage" : "Freeze Stage") { store.togglePauseAll() }
                if sharing.count == 1, let only = sharing.first {
                    Button("Stop Sharing") { store.stopSharing(only) }
                } else {
                    Menu("Stop Sharing") {
                        ForEach(sharing) { slot in
                            Button(slot.phoneName ?? slot.name) { store.stopSharing(slot) }
                        }
                        Divider()
                        Button("All Phones") { sharing.forEach(store.stopSharing) }
                    }
                }
                Divider()
            }
            StageLayoutItems(store: store)
            Button("Fit Window to Phones") { store.fitStageToPhones() }
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

    private struct Placed: Identifiable {
        let slot: Slot
        let frame: StageRect
        var id: Int { slot.id }
    }

    private static func picture(of slot: Slot) -> CGSize {
        slot.displaySize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? CGSize(width: 9, height: 19.5)
    }

    static func size(of slot: Slot) -> (width: Double, height: Double) {
        let picture = picture(of: slot)
        return stagePhoneSize(modelCode: slot.config.lastPhoneModel, pictureWidth: picture.width, pictureHeight: picture.height, bezel: slot.showsBezel)
    }
}

/// A slot's status dot on the Stage: teal live, blues in between, red for trouble.
private func stageDotColor(_ state: Slot.State) -> Color {
    switch state {
    case .live: return Brand.teal
    case .connecting, .paused: return Brand.sky
    case .waiting: return Brand.blueMuted
    case .disconnected, .failed: return Brand.red
    case .stopped: return .gray
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

/// The Stage's control bar: a chip per phone (its menu has the slot's options), then add slot,
/// layout, bezels, record and more. Shows while ⌥ is held; see StageControlsPresence.
struct StageControls: View {
    @ObservedObject var store: SlotStore
    /// Passed in by the Stage, which redraws whenever any slot changes.
    let phones: [Slot]
    let recording: Bool
    @AppStorage("stageCaptionBar") private var showsCaption = true
    @AppStorage(StageCaption.logoKey) private var showsLogo = true
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                ForEach(phones) { slot in
                    StageSlotChip(slot: slot, store: store, reconnecting: store.isReconnecting(slot))
                }
                freezeButton
                recordButton
                moreMenu
            }.fixedSize()
            HStack(spacing: 4) {
                Menu {
                    ForEach(phones) { slot in
                        Menu(slot.displayName) { StageSlotActions(slot: slot, store: store) }
                    }
                    if phones.isEmpty { Text("No connected devices") }
                    Divider()
                    Button("Add Device Space") { store.addSlot() }.disabled(!store.canAddSlot)
                } label: { HUDLabel(title: "Devices", systemImage: "iphone") }
                freezeButton
                moreMenu
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .padding(5)
        .background(Color(hex: 0x141E2D).opacity(0.96), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var freezeButton: some View {
        if !phones.isEmpty {
            let frozen = phones.contains(where: \.isFrozen)
            Button { store.togglePauseAll() } label: {
                HUDLabel(title: frozen ? "Unfreeze Stage" : "Freeze Stage", systemImage: frozen ? "play.fill" : "pause.fill", isOn: frozen)
            }
            .help("Stage only (P). Recordings, screenshots and independent OBS feeds stay live.")
        }
    }

    private var recordButton: some View {
        Button { recording ? store.stopAllRecordings() : store.startAllRecordings() } label: {
            HUDLabel(title: recording ? "Stop Recording" : "Record", systemImage: recording ? "stop.fill" : "record.circle", fill: recording ? Brand.red : nil)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Add Device Space") { store.addSlot() }.disabled(!store.canAddSlot)
            Menu("Layout") {
                StageLayoutItems(store: store)
                Button("Fit Window to Devices") { store.fitStageToPhones() }
            }
            Toggle("Device Bezels", isOn: Binding(get: { store.bezelsForAllSlots }, set: { store.setBezelsForAllSlots($0) }))
            Button(recording ? "Stop All Recordings" : "Record All Devices") {
                recording ? store.stopAllRecordings() : store.startAllRecordings()
            }
            Button("Screenshot All Devices") { store.screenshotAll() }
            Divider()
            Toggle("Caption Bar", isOn: $showsCaption)
            Toggle("Logo in Caption", isOn: $showsLogo)
            Button("Show Wall") { MainWindow.show() }
            Button("Settings…") { openSettings() }
        } label: { HUDLabel(title: nil, systemImage: "ellipsis") }
        .accessibilityLabel("More presentation controls")
    }

}

/// One item in the control bar.
private struct HUDLabel: View {
    let title: String?
    let systemImage: String
    var isOn = false
    var fill: Color? = nil
    var outline: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            if let title { Text(title) }
        }
        .font(Brand.font(12, .semibold))
        .foregroundStyle(fill != nil || isOn ? Color.white : Brand.ice)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill ?? (isOn ? Color.white.opacity(0.14) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(outline ?? .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }
}

/// A phone in the control bar; its menu has what the wall tile's ⋯ menu had.
private struct StageSlotChip: View {
    @ObservedObject var slot: Slot
    let store: SlotStore
    let reconnecting: Bool

    var body: some View {
        Menu {
            StageSlotActions(slot: slot, store: store)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(stageDotColor(slot.state)).frame(width: 8, height: 8)
                Text(slot.displayName).lineLimit(1).frame(maxWidth: 170)
                if reconnecting {
                    Text("reconnecting").font(Brand.font(11)).opacity(0.75)
                } else if slot.isFrozen {
                    Text("Stage frozen").font(Brand.font(11)).opacity(0.85)
                } else if slot.state == .paused {
                    Text("Screen off").font(Brand.font(11)).opacity(0.85)
                }
                if slot.recordingError != nil {
                    Label("Recording failed", systemImage: "exclamationmark.triangle.fill").font(Brand.font(10))
                } else if slot.recordingSince != nil {
                    Text(slot.recordingHasFrames ? "REC" : "ARMED")
                        .font(Brand.font(10, .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Brand.red))
                }
            }
            .font(Brand.font(12, .semibold))
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

private struct StageSlotActions: View {
    @ObservedObject var slot: Slot
    let store: SlotStore
    var body: some View {
            if slot.showsPicture {
                Button(slot.isFrozen ? "Unfreeze Stage" : "Freeze Stage") { store.setPaused(slot, !slot.isFrozen) }
            }
            Button("Stop Sharing") { store.stopSharing(slot) }
            Divider()
            Toggle("On Stage", isOn: Binding(
                get: { slot.showsOnStage },
                set: { store.setShowsOnStage(slot, on: $0) }
            ))
            Toggle("Phone Bezel", isOn: Binding(
                get: { slot.showsBezel },
                set: { store.setBezel(slot, on: $0) }
            ))
            BezelModelPicker(slot: slot)
            Button("Demo Label…") { DemoLabelEditor.show(for: slot) }
            Divider()
            Button("Take Screenshot") { slot.takeScreenshot() }
                .disabled(!slot.showsPicture)
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
    }
}

/// Slots without a phone, above the control bar while it shows.
private struct WaitingPills: View {
    let slots: [Slot]
    let pin: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(slots) { slot in
                    HStack(spacing: 7) {
                        Circle().fill(stageDotColor(slot.state)).frame(width: 7, height: 7)
                        Text(slot.name).font(Brand.font(12, .semibold))
                        Text(stageStatus(slot.state)).font(Brand.font(11)).opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(Color(hex: 0x141E2D).opacity(0.85)))
                }
                if let pin, !slots.isEmpty {
                    Text("PIN \(pin)")
                        .font(Brand.font(12, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(Capsule().fill(Color(hex: 0x141E2D).opacity(0.85)))
                }
            }
        }
    }
}

/// The Stage before any phone is mirroring. The meeting may be watching, so it shows a clean
/// "starting shortly" screen; the how-to-connect steps appear only while ⌥ is held.
private struct StageEmptyState: View {
    let slots: [Slot]
    let showsSteps: Bool
    let pin: String?

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Demo starting shortly")
                    .font(Brand.font(30, .bold))
                Text(showsSteps ? "Connect a phone and it appears here." : "Press C or hold Control for controls")
                    .font(Brand.font(14))
                    .opacity(showsSteps ? 0.7 : 0.35)
            }
            if showsSteps {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(slots) { slot in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(stageDotColor(slot.state)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slot.name).font(Brand.font(14, .semibold))
                                Text("iPhone: Control Center › Screen Mirroring › “\(slot.name)”   ·   Android: Mirror Wall Cast")
                                    .font(Brand.font(12))
                                    .opacity(0.65)
                            }
                        }
                    }
                    if let pin {
                        Text("PIN for iPhones: \(pin)")
                            .font(Brand.font(14, .semibold))
                            .padding(.top, 4)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x141E2D).opacity(0.55)))
            }
        }
        .foregroundStyle(.white)
        .padding()
    }
}

/// The strip along the stage's bottom: "Live demo · Tom's iPhone & Zebra TC58", and the
/// official logo on its own at the right (the brand guide wants clear space around it).
private struct StageCaption: View {
    static let logoKey = "stageCaptionLogo"
    let phones: [Slot]
    let height: CGFloat
    @AppStorage(StageCaption.logoKey) private var showsLogo = true

    var body: some View {
        HStack(spacing: height * 0.3) {
            // Only once something is live, so the waiting screen doesn't claim to be live.
            if !phones.isEmpty {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Brand.teal)
                    .frame(width: 4, height: height * 0.5)
                Text(phones.contains(where: { $0.isFrozen || $0.state != .live || $0.isQuiet }) ? "Demo" : "Live demo")
                    .font(Brand.font(height * 0.36, .bold))
                Text("· \(names)")
                    .font(Brand.font(height * 0.36))
                    .opacity(0.75)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: height)
            if showsLogo, let logo = Brand.whiteLogo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: height * 0.6)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, height * 0.5)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.18))
    }

    private var names: String {
        phones.map { $0.displayName }.formatted(.list(type: .and))
    }
}

/// One phone on the stage: its picture, in its phone frame when the slot has one on. A phone
/// that dropped keeps its place, dimmed on its last picture, while it may reconnect.
private struct StagePhone: View {
    @ObservedObject var slot: Slot
    let reconnecting: Bool

    var body: some View {
        let shape = slot.displaySize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? CGSize(width: 9, height: 19.5)
        if slot.showsBezel {
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
            if reconnecting, let held = slot.heldImage {
                // The receiver restarts after a drop, which clears the live picture.
                Image(decorative: held, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            } else if let frozen = slot.frozenImage {
                Image(decorative: frozen, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            } else {
                VideoLayerView(renderer: slot.renderer, isShowing: slot.showsPicture || reconnecting)
            }
            if reconnecting || slot.isQuiet {
                Color(hex: 0x141E2D).opacity(0.6)
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Reconnecting…")
                        .font(Brand.font(14, .semibold))
                        .foregroundStyle(.white)
                }
            } else if slot.isFrozen {
                VStack {
                    VStack(spacing: 2) {
                        Label("Stage frozen", systemImage: "pause.fill")
                        Text("Other outputs stay live").font(Brand.font(10))
                    }
                        .font(Brand.font(12, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(hex: 0x141E2D).opacity(0.8)))
                        .padding(.top, 10)
                    Spacer()
                }
            }
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
            StageControlsToggle()
            Menu("Stage Layout") {
                StageLayoutItems(store: store)
            }
            Button("Fit Stage to Phones") { store.fitStageToPhones() }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Menu("Phones on Stage") {
                StageSlotItems(store: store)
            }
        }
    }
}

/// View › Show Stage Controls: keeps the Stage's controls up without holding ⌥, for setting up
/// before you share.
private struct StageControlsToggle: View {
    @ObservedObject private var presence = StageControlsPresence.shared

    var body: some View {
        Toggle("Show Stage Controls", isOn: $presence.pinned)
            .keyboardShortcut("k")
    }
}
