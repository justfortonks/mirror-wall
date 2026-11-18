import AppKit
import AVFoundation
import Combine
import MirrorCore
import SwiftUI

/// One window showing every phone that's mirroring, and any Mac windows and cameras added to it,
/// arranged by one of the automatic layouts or freely, for sharing a single window in Teams, Zoom
/// or OBS, or for filling a second screen. Titled "MacMirror-Stage" so OBS finds it again by name,
/// like the slots' own windows. What's on it is StageController's.
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
        window.contentView = NSHostingView(rootView: StageView(stage: store.stage, store: store, onClose: { [weak self] in self?.close() }))
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

struct StageView: View {
    @ObservedObject var stage: StageController
    @ObservedObject var store: SlotStore
    let onClose: () -> Void
    @CurrentTheme private var theme
    /// The "Live demo" strip along the bottom.
    @StageCaptionSetting private var showsCaption
    /// Stage-first: the controls fade in while the mouse moves over the Stage and fade out again
    /// a couple of seconds after it stops, so the shared picture stays clean. While editing the
    /// layout they stay.
    @State private var controlsVisible = false
    @State private var overControls = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let captionHeight = showsCaption ? min(64, max(34, proxy.size.height * 0.085)) : 0
            let area = CGSize(width: proxy.size.width, height: max(0, proxy.size.height - captionHeight))
            let placed = stage.placedItems(area: area)
            let showsControls = controlsVisible || stage.isEditing
            ZStack(alignment: .topLeading) {
                theme.stageBackground
                    .frame(width: proxy.size.width, height: proxy.size.height)
                if placed.isEmpty {
                    StageEmptyState(slots: store.slots)
                        .frame(width: area.width, height: area.height)
                }
                ForEach(placed) { entry in
                    StageItemContent(stage: stage, entry: entry)
                        .frame(width: entry.rect.width, height: entry.rect.height)
                        .offset(x: entry.rect.x, y: entry.rect.y)
                }
                if stage.isEditing {
                    StageEditLayer(stage: stage, placed: placed, area: area)
                    StageEditHint()
                        .frame(width: area.width)
                        .offset(y: max(0, area.height - 46))
                }
                if showsCaption {
                    StageCaption(phones: placed.compactMap { stage.slot(for: $0.item) }, height: captionHeight)
                        .frame(width: proxy.size.width, height: captionHeight)
                        .offset(y: proxy.size.height - captionHeight)
                }
                StageControls(stage: stage, store: store, connected: store.slots.filter(\.showsPicture), recording: store.isAnyRecording)
                    .onHover { inside in
                        overControls = inside
                        if inside { showControls() } else { scheduleHide() }
                    }
                    .frame(width: proxy.size.width)
                    .offset(y: 36)
                    .opacity(showsControls ? 1 : 0)
                    .allowsHitTesting(showsControls)
            }
            .onAppear { stage.areaSize = area }
            .onChange(of: area) { _, newArea in stage.areaSize = newArea }
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            switch phase {
            case .active: showControls()
            case .ended: scheduleHide()
            }
        }
        .contextMenu {
            Menu("Add to Stage") {
                StageAddItems(stage: stage, store: store)
            }
            Menu("Layout") {
                StageLayoutItems(stage: stage)
            }
            Button(stage.isEditing ? "Done Editing" : "Edit Layout") { stage.toggleEditing() }
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
}

// MARK: - The control bar

/// The Stage's control bar: a chip per connected phone, window and camera (its menu has that
/// picture's options), then add slot, add to the Stage, layout, edit, bezels, record and more.
/// Fades with the mouse; see StageView.
private struct StageControls: View {
    @ObservedObject var stage: StageController
    @ObservedObject var store: SlotStore
    /// Passed in by the Stage, which redraws whenever any slot changes.
    let connected: [Slot]
    let recording: Bool
    @CurrentTheme private var theme
    @StageCaptionSetting private var showsCaption
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let sources = stage.arrangement.items.filter { $0.kind != .phone }
        HStack(spacing: 4) {
            ForEach(connected) { slot in
                StageSlotChip(slot: slot, store: store)
            }
            ForEach(sources) { item in
                StageSourceChip(stage: stage, item: item)
            }
            if !connected.isEmpty || !sources.isEmpty {
                Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 18).padding(.horizontal, 2)
            }
            Button { store.addSlot() } label: {
                HUDLabel(title: "Slot", systemImage: "plus")
            }
            .disabled(!store.canAddSlot)
            .help("Add a slot another phone can mirror to")
            Menu { StageAddItems(stage: stage, store: store) } label: {
                HUDLabel(title: "Add", systemImage: "plus.rectangle.on.rectangle")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Put a Mac window, a camera or a phone on the Stage")
            Menu { StageLayoutItems(stage: stage) } label: {
                HUDLabel(title: "Layout", systemImage: "rectangle.split.3x1")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("How the pictures are arranged, and your saved layouts")
            Button { stage.toggleEditing() } label: {
                HUDLabel(title: stage.isEditing ? "Done" : "Edit", systemImage: stage.isEditing ? "checkmark" : "arrow.up.left.and.arrow.down.right", isOn: stage.isEditing)
            }
            .help(stage.isEditing ? "Finish arranging" : "Drag pictures to move them and their corners to resize them")
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

/// A Mac window or camera on the Stage, in the control bar; its menu moves, changes or removes it.
private struct StageSourceChip: View {
    @CurrentTheme private var theme
    @ObservedObject var stage: StageController
    let item: StageItem

    var body: some View {
        Menu {
            StageItemMenuItems(stage: stage, item: item)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.kind == .camera ? "video.fill" : "macwindow")
                Text(item.label).lineLimit(1)
                if hidden {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(theme.font(12, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(hidden ? "macOS isn't drawing this window (it's minimized, hidden or on another desktop), so its picture is frozen. Bring it back to move it again." : "Click for this picture's options.")
    }

    /// A window macOS isn't drawing, so its picture is stuck.
    private var hidden: Bool {
        item.kind == .window && stage.windowSource(for: item)?.onScreen == false
    }
}

/// The options for one picture on the Stage, for its chip and its right-click menu.
struct StageItemMenuItems: View {
    @ObservedObject var stage: StageController
    let item: StageItem

    var body: some View {
        switch item.kind {
        case .window:
            Button("Choose Another Window…") { stage.chooseWindow(for: item) }
            Divider()
        case .camera:
            Menu("Choose Another Camera") {
                ForEach(stage.cameraDevices, id: \.uniqueID) { device in
                    Button(device.localizedName) { stage.chooseCamera(device, for: item) }
                }
            }
            Divider()
        case .phone:
            EmptyView()
        }
        Button(stage.arrangement.isFree ? "Send Backward" : "Move Left") { stage.moveItem(item.id, by: -1) }
            .disabled(!stage.canMoveItem(item.id, by: -1))
        Button(stage.arrangement.isFree ? "Bring Forward" : "Move Right") { stage.moveItem(item.id, by: 1) }
            .disabled(!stage.canMoveItem(item.id, by: 1))
        Divider()
        Button("Remove from Stage") { stage.remove(item) }
    }
}

/// What can be added to the Stage: a Mac window, a camera, or a phone's slot.
struct StageAddItems: View {
    @ObservedObject var stage: StageController
    @ObservedObject var store: SlotStore

    var body: some View {
        Button("Mac Window…") { stage.addWindow() }
        Menu("Camera") {
            let devices = stage.cameraDevices
            if devices.isEmpty {
                Button("No cameras found") {}
                    .disabled(true)
            }
            ForEach(devices, id: \.uniqueID) { device in
                Button(device.localizedName) { stage.addCamera(device) }
            }
        }
        let offStage = store.slots.filter { !$0.showsOnStage }
        if !offStage.isEmpty {
            Menu("Phone Slot") {
                ForEach(offStage) { slot in
                    Button(slot.name) { stage.addPhone(slot) }
                }
            }
        }
    }
}

// MARK: - Pictures on the Stage

/// What one item shows: a phone, a window or a camera, or a placeholder saying what's missing.
private struct StageItemContent: View {
    @ObservedObject var stage: StageController
    let entry: StageController.PlacedItem

    var body: some View {
        let item = entry.item
        switch item.kind {
        case .phone:
            if entry.hasPicture, let slot = stage.slot(for: item) {
                StagePhone(slot: slot)
            } else {
                StagePlaceholder(systemImage: "iphone", title: item.label, detail: "Waiting for a phone to mirror to it")
            }
        case .window:
            if let source = stage.windowSource(for: item) {
                StageWindowTile(source: source, stage: stage, item: item)
            } else {
                StagePlaceholder(systemImage: "macwindow", title: item.label, detail: "A window can't be remembered from one launch to the next, so choose it again.", buttonTitle: "Choose Window…") {
                    stage.chooseWindow(for: item)
                }
            }
        case .camera:
            if let source = stage.cameraSource(for: item) {
                StageCameraTile(source: source)
            } else {
                StagePlaceholder(systemImage: "video", title: item.label, detail: "Starting…")
            }
        }
    }
}

/// A Mac window's picture, or why there isn't one.
private struct StageWindowTile: View {
    @ObservedObject var source: StageWindowSource
    let stage: StageController
    let item: StageItem

    var body: some View {
        if case .stopped(let reason) = source.status {
            StagePlaceholder(systemImage: "macwindow", title: item.label, detail: reason, buttonTitle: "Choose Another Window…") {
                stage.chooseWindow(for: item)
            }
        } else {
            StageSurfaceView(relay: source.relay)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// A camera's picture, or why there isn't one.
private struct StageCameraTile: View {
    @ObservedObject var source: StageCameraSource

    var body: some View {
        switch source.status {
        case .live:
            StageCameraPreview(session: source.session)
                .background(Color.black)
        case .starting:
            StagePlaceholder(systemImage: "video", title: source.name, detail: "Starting the camera…")
        case .noPermission:
            StagePlaceholder(systemImage: "video.slash", title: source.name, detail: "Camera access is off for Mirror Wall. Turn it on in System Settings › Privacy & Security › Camera.", buttonTitle: "Open Camera Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .notFound:
            StagePlaceholder(systemImage: "video.slash", title: source.name, detail: "This camera isn't plugged in, or another app has it.")
        }
    }
}

/// A dashed box standing where a picture will be, saying why it isn't there yet.
private struct StagePlaceholder: View {
    @CurrentTheme private var theme
    let systemImage: String
    let title: String
    let detail: String
    var buttonTitle: String?
    var action: (() -> Void)?

    init(systemImage: String, title: String, detail: String, buttonTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.buttonTitle = buttonTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 26))
            Text(title)
                .font(theme.font(15, .semibold))
                .lineLimit(2)
            Text(detail)
                .font(theme.font(12))
                .opacity(0.7)
                .multilineTextAlignment(.center)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .minimumScaleFactor(0.5)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.panel.opacity(0.55)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
        )
    }
}

// MARK: - Editing the layout

/// The coordinate space of the Stage's picture area, which dragging is measured in (a picture
/// being dragged moves, so its own coordinates wouldn't hold still).
private let stageEditSpace = "stageEditArea"

/// Over the pictures while editing: an outline on each, to drag it, and handles to resize the one
/// that's selected.
private struct StageEditLayer: View {
    @ObservedObject var stage: StageController
    let placed: [StageController.PlacedItem]
    let area: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { stage.select(nil) }
            ForEach(placed) { entry in
                StageEditItem(stage: stage, entry: entry, area: area, others: placed.filter { $0.id != entry.id }.map(\.rect))
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .coordinateSpace(.named(stageEditSpace))
    }
}

private struct StageEditItem: View {
    @ObservedObject var stage: StageController
    let entry: StageController.PlacedItem
    let area: CGSize
    /// Where the other pictures are, for lining this one up with them.
    let others: [StageRect]
    @State private var moveStart: StageRect?
    @State private var resizeStart: StageRect?

    private let handleSize: CGFloat = 16

    var body: some View {
        let selected = stage.selectedID == entry.id
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: entry.rect.width, height: entry.rect.height)
            .overlay(
                Rectangle().strokeBorder(
                    selected ? Color.accentColor : Color.white.opacity(0.6),
                    style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [6, 4])
                )
            )
            .overlay(alignment: .topLeading) {
                Text(entry.item.label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.65), in: Capsule())
                    .padding(6)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) { if selected { handle(.topLeft) } }
            .overlay(alignment: .topTrailing) { if selected { handle(.topRight) } }
            .overlay(alignment: .bottomLeading) { if selected { handle(.bottomLeft) } }
            .overlay(alignment: .bottomTrailing) { if selected { handle(.bottomRight) } }
            .contentShape(Rectangle())
            .onTapGesture { stage.select(entry.id) }
            .gesture(moveGesture)
            .contextMenu { StageItemMenuItems(stage: stage, item: entry.item) }
            .offset(x: entry.rect.x, y: entry.rect.y)
    }

    private var bounds: StageRect {
        StageRect(x: 0, y: 0, width: area.width, height: area.height)
    }

    private func handle(_ corner: StageCorner) -> some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
            .frame(width: handleSize, height: handleSize)
            .offset(x: corner.isLeft ? -handleSize / 2 : handleSize / 2, y: corner.isTop ? -handleSize / 2 : handleSize / 2)
            .gesture(resizeGesture(corner))
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(stageEditSpace))
            .onChanged { value in
                if moveStart == nil {
                    stage.select(entry.id)
                    stage.beginFreeArrangement(area: area)
                    moveStart = entry.rect
                }
                guard let start = moveStart else { return }
                var moved = start.offsetBy(dx: value.translation.width, dy: value.translation.height).clamped(inside: bounds)
                // Edges and middles line up with the Stage's and the other pictures', when close.
                var xTargets: [Double] = [0, bounds.midX, bounds.maxX]
                var yTargets: [Double] = [0, bounds.midY, bounds.maxY]
                for other in others {
                    xTargets += [other.x, other.midX, other.maxX]
                    yTargets += [other.y, other.midY, other.maxY]
                }
                let snap = stageSnapOffset(for: moved, xTargets: xTargets, yTargets: yTargets, threshold: 8)
                moved = moved.offsetBy(dx: snap.dx, dy: snap.dy).clamped(inside: bounds)
                stage.setPicture(entry.id, rect: moved, area: area)
            }
            .onEnded { _ in
                moveStart = nil
                stage.commitChange()
            }
    }

    private func resizeGesture(_ corner: StageCorner) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(stageEditSpace))
            .onChanged { value in
                if resizeStart == nil {
                    stage.select(entry.id)
                    stage.beginFreeArrangement(area: area)
                    resizeStart = entry.rect
                }
                guard let start = resizeStart else { return }
                let resized = start.resizing(corner: corner, dx: value.translation.width, dy: value.translation.height, minWidth: 60, bounds: bounds)
                stage.setPicture(entry.id, rect: resized, area: area)
            }
            .onEnded { _ in
                resizeStart = nil
                stage.commitChange()
            }
    }
}

/// What to do while editing, along the bottom.
private struct StageEditHint: View {
    var body: some View {
        Text("Drag a picture to move it, or a corner to resize it. Right-click a picture for more.")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.6), in: Capsule())
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
    }
}

// MARK: - Empty state and caption

/// The Stage before anything is on it: how to connect a phone, slot by slot, and what else can go
/// on it. The meeting may see this, so it reads as a friendly "about to start" screen.
private struct StageEmptyState: View {
    @CurrentTheme private var theme
    let slots: [Slot]

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Ready for phones")
                    .font(theme.font(28, .bold))
                Text("Each phone appears here as it connects. Move the mouse and use Add to put a Mac window or a camera next to them.")
                    .font(theme.font(15))
                    .opacity(0.7)
                    .multilineTextAlignment(.center)
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

// MARK: - Menus

/// The Stage's layouts: the automatic ones, free placement, your saved layouts and how to save
/// them, ticked for the one in use. For the View menu, the Layout button and the Stage's own menu.
struct StageLayoutItems: View {
    @ObservedObject var stage: StageController

    var body: some View {
        ForEach(StageLayout.allCases) { layout in
            Toggle(layout.title, isOn: Binding(
                get: { stage.arrangement.automatic == layout },
                set: { _ in stage.setAutomatic(layout) }
            ))
        }
        Toggle("Free (Drag to Arrange)", isOn: Binding(
            get: { stage.arrangement.isFree },
            set: { _ in stage.makeFree() }
        ))
        if !stage.savedLayouts.isEmpty {
            Divider()
            ForEach(stage.savedLayouts) { saved in
                Toggle(saved.name, isOn: Binding(
                    get: { stage.currentLayoutID == saved.id && !stage.isModified },
                    set: { _ in stage.apply(saved) }
                ))
            }
        }
        Divider()
        Button("Save Layout As…") { stage.promptSaveAs() }
        if let current = stage.currentLayout {
            Button("Update “\(current.name)”") { stage.updateCurrentLayout() }
                .disabled(!stage.isModified)
            Button("Rename “\(current.name)”…") { stage.promptRename() }
            Button("Delete “\(current.name)”…") { stage.promptDelete() }
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

/// View › Show Stage, View › Stage Layout, View › Add to Stage and View › Phones on Stage.
struct StageCommands: Commands {
    @ObservedObject var store: SlotStore

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Show Stage") { store.showStage() }
                .keyboardShortcut("1")
            Menu("Stage Layout") {
                StageLayoutItems(stage: store.stage)
            }
            Menu("Add to Stage") {
                StageAddItems(stage: store.stage, store: store)
            }
            Menu("Phones on Stage") {
                StageSlotItems(store: store)
            }
        }
    }
}
