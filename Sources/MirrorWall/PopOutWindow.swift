import AppKit
import Combine
import MirrorCore
import SwiftUI

/// The size of slots' own windows, so a scene laid out in OBS never shifts because a window
/// was resized: a fixed size for all of them (the length of their longer side in points), or
/// Custom, where each window keeps a size of its own that can be locked.
enum PopOutSize: String, CaseIterable, Identifiable {
    case small, medium, large, custom

    var id: String { rawValue }

    /// Nil for Custom, where each window has its own.
    var presetLongSide: CGFloat? {
        switch self {
        case .small: return 600
        case .medium: return 800
        case .large: return 1000
        case .custom: return nil
        }
    }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .custom: return "Custom"
        }
    }
}

/// A slot in a window of its own, showing only the phone's picture so OBS (or anything else)
/// can capture it cleanly. OBS finds the window again by its title, so the store keeps that
/// title stable.
@MainActor
final class PopOutWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onClose: (() -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var videoSize: CGSize?
    private let customSizeKey: String

    /// Changing it resizes the window, keeping its top-left corner where it is.
    var size: PopOutSize {
        didSet {
            guard size != oldValue else { return }
            updateResizable()
            fit()
        }
    }

    /// With a Custom size, whether the window can be resized by dragging its edges.
    var locked: Bool {
        didSet { if locked != oldValue { updateResizable() } }
    }

    init(slot: Slot, store: SlotStore, title: String, size: PopOutSize, locked: Bool) {
        self.size = size
        self.locked = locked
        customSizeKey = "popOutCustomLongSide.\(slot.id)"
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 780),
            // Not minimizable: macOS only gives capture apps a frozen thumbnail of a minimized
            // window, so OBS would show a tiny still picture. Covered windows capture fine.
            // Resizable only with an unlocked Custom size (`updateResizable`).
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.title = title
        // The title bar is see-through and its title hidden, so the window is all picture; the
        // title still names the window for OBS. The window buttons appear only under the pointer.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: PopOutView(
            slot: slot,
            store: store,
            onClose: { [weak self] in self?.close() },
            onHover: { [weak self] hovering in self?.showWindowButtons(hovering) }
        ))
        window.delegate = self
        window.center()
        // Restores the place the window had last time, if any; `fit` then sets its size.
        window.setFrameAutosaveName("MacMirror slot \(slot.id)")
        showWindowButtons(false)
        videoSize = slot.videoSize
        updateResizable()
        fit()

        slot.$videoSize
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] size in
                self?.videoSize = size
                self?.fit()
            }
            .store(in: &cancellables)
    }

    func show() {
        window.orderFront(nil)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    /// Remembers a Custom size, per slot, once the user has finished resizing.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard size == .custom else { return }
        UserDefaults.standard.set(Double(max(window.frame.width, window.frame.height)), forKey: customSizeKey)
    }

    private func updateResizable() {
        if size == .custom && !locked {
            window.styleMask.insert(.resizable)
        } else {
            window.styleMask.remove(.resizable)
        }
    }

    /// The window's longer side: the preset's, or this slot's remembered Custom size.
    private var longSide: CGFloat {
        if let preset = size.presetLongSide { return preset }
        let saved = UserDefaults.standard.double(forKey: customSizeKey)
        return saved >= 200 ? CGFloat(saved) : 800
    }

    private func showWindowButtons(_ visible: Bool) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = !visible
        }
    }

    /// Gives the window the picture's shape (portrait or landscape, a portrait iPhone until the
    /// first picture arrives) at the chosen size, keeping its top-left corner where it is. The
    /// picture fills the whole frame (the title bar is see-through), so the frame itself takes
    /// the picture's shape.
    private func fit() {
        let picture = videoSize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? CGSize(width: 9, height: 19.5)
        // Resizing by dragging keeps the picture's shape.
        window.aspectRatio = picture
        let scale = longSide / max(picture.width, picture.height)
        let newSize = NSSize(width: (picture.width * scale).rounded(), height: (picture.height * scale).rounded())
        var frame = window.frame
        guard frame.size != newSize else { return }
        frame.origin.y += frame.height - newSize.height
        frame.size = newSize
        window.setFrame(frame, display: true)
    }
}

/// The pop-out window's content: the picture and nothing else once a phone is mirroring.
struct PopOutView: View {
    @ObservedObject var slot: Slot
    @ObservedObject var store: SlotStore
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        ZStack {
            Color.black
            VideoLayerView(renderer: slot.renderer, isShowing: slot.showsPicture)
            if !slot.showsPicture {
                switch store.standby(for: slot) {
                case .message:
                    Text(waitingText)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding()
                case .blank:
                    EmptyView()
                case .image(let fileName):
                    StandbyImage(fileName: fileName)
                }
            }
        }
        .ignoresSafeArea()
        .onHover(perform: onHover)
        .contextMenu {
            Button("Show Mirror Wall Window") { MainWindow.show() }
            Menu("Window Size") {
                PopOutSizeItems(store: store)
            }
            Button("Close This Window", action: onClose)
        }
    }

    private var waitingText: String {
        let phone = slot.config.lastPhoneName ?? "an iPhone"
        return "Waiting for \(phone) to mirror to “\(slot.name)”"
    }
}

/// A standby image, scaled to fit the space without distortion (black bars if its shape differs).
struct StandbyImage: View {
    let fileName: String

    var body: some View {
        if let image = StandbyPictures.image(named: fileName) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        }
    }
}

/// Ticked size choices plus the Custom lock, for the View menu and pop-out windows' own menu.
struct PopOutSizeItems: View {
    @ObservedObject var store: SlotStore

    var body: some View {
        ForEach(PopOutSize.allCases) { size in
            Toggle(size.title, isOn: Binding(
                get: { store.popOutSize == size },
                set: { _ in store.setPopOutSize(size) }
            ))
        }
        Divider()
        Toggle("Lock Custom Size", isOn: Binding(
            get: { store.popOutSizeLocked },
            set: { store.setPopOutSizeLocked($0) }
        ))
        .disabled(store.popOutSize != .custom)
    }
}
