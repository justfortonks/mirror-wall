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
        window.backgroundColor = .black
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

    var body: some View {
        let phones = store.slots.filter(\.showsPicture)
        GeometryReader { proxy in
            let frames = stageFrames(
                sizes: phones.map(Self.size(of:)),
                layout: store.stageLayout,
                areaWidth: proxy.size.width,
                areaHeight: proxy.size.height
            )
            ZStack(alignment: .topLeading) {
                Color.black
                if phones.isEmpty {
                    Text("Phones show up here while they're mirroring.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                ForEach(zip(phones, frames).map(Placed.init)) { placed in
                    StagePhone(slot: placed.slot)
                        .frame(width: placed.frame.width, height: placed.frame.height)
                        .offset(x: placed.frame.x, y: placed.frame.y)
                }
            }
        }
        .ignoresSafeArea()
        .contextMenu {
            StageLayoutItems(store: store)
            Divider()
            Button("Show Mirror Wall Window") { MainWindow.show() }
            Button("Close Stage", action: onClose)
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

/// One phone on the stage: its picture, in its phone frame when the slot has one on.
private struct StagePhone: View {
    @ObservedObject var slot: Slot

    var body: some View {
        let shape = slot.videoSize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? CGSize(width: 9, height: 19.5)
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

/// View › Show Stage and View › Stage Layout.
struct StageCommands: Commands {
    @ObservedObject var store: SlotStore

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Show Stage") { store.showStage() }
            Menu("Stage Layout") {
                StageLayoutItems(store: store)
            }
        }
    }
}
