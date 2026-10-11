import AppKit
import Combine
import SwiftUI

/// A slot in a window of its own, showing only the phone's picture so OBS (or anything else)
/// can capture it cleanly. OBS finds the window again by its title, so the store keeps that
/// title stable.
@MainActor
final class PopOutWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onClose: (() -> Void)?

    private var cancellables: Set<AnyCancellable> = []

    init(slot: Slot, title: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 780),
            // Not minimizable: macOS only gives capture apps a frozen thumbnail of a minimized
            // window, so OBS would show a tiny still picture. Covered windows capture fine.
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
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
        // On every desktop, including the one a full-screen app (an OBS projector) makes for
        // itself. Otherwise going full screen moves the window off screen, and capture stalls
        // for seconds each time. Behind the projector it's only covered, which captures fine.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: PopOutView(
            slot: slot,
            onClose: { [weak self] in self?.close() },
            onHover: { [weak self] hovering in self?.showWindowButtons(hovering) }
        ))
        window.delegate = self
        window.center()
        // Restores the size and place the window had last time, if any.
        window.setFrameAutosaveName("MacMirror slot \(slot.id)")
        showWindowButtons(false)

        slot.$videoSize
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] size in self?.fit(to: size) }
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

    private func showWindowButtons(_ visible: Bool) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = !visible
        }
    }

    /// Gives the window the picture's shape (portrait or landscape), keeping its longer side and
    /// its top-left corner where they are. The picture fills the whole frame (the title bar is
    /// see-through), so the frame itself takes the picture's shape.
    private func fit(to videoSize: CGSize) {
        guard videoSize.width > 0, videoSize.height > 0 else { return }
        window.aspectRatio = videoSize
        var frame = window.frame
        guard frame.height > 0, abs(frame.width / frame.height - videoSize.width / videoSize.height) > 0.01 else {
            return
        }
        let scale = max(frame.width, frame.height) / max(videoSize.width, videoSize.height)
        let size = NSSize(width: (videoSize.width * scale).rounded(), height: (videoSize.height * scale).rounded())
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
    }
}

/// The pop-out window's content: the picture and nothing else once a phone is mirroring.
struct PopOutView: View {
    @ObservedObject var slot: Slot
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        ZStack {
            Color.black
            VideoLayerView(renderer: slot.renderer, isShowing: showsPicture)
            if !showsPicture {
                Text(waitingText)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding()
            }
        }
        .ignoresSafeArea()
        .onHover(perform: onHover)
        .contextMenu {
            Button("Show Mirror Wall Window") { MainWindow.show() }
            Button("Close This Window", action: onClose)
        }
    }

    private var showsPicture: Bool {
        slot.lastFrameAt != nil && (slot.state == .live || slot.state == .paused)
    }

    private var waitingText: String {
        let phone = slot.config.lastPhoneName ?? "an iPhone"
        return "Waiting for \(phone) to mirror to “\(slot.name)”"
    }
}
