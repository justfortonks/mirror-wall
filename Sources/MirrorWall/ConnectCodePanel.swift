import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MirrorCore
import SwiftUI

/// Connect with QR Code…: a small floating window with a code an Android phone scans to share to
/// a slot without finding it on the network. Guest Wi-Fi with client isolation, a VPN on every
/// device, or a network that drops multicast all stop Bonjour; the code carries the Mac's
/// addresses and the slot's port instead. The phone tries them in order.
@MainActor
enum ConnectCodePanel {
    private static var panel: NSPanel?

    static func show(store: SlotStore, slot: Slot? = nil) {
        if let panel {
            if let slot { ConnectCodeModel.shared.select(slot) }
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = ConnectCodeModel.shared
        model.store = store
        model.select(slot ?? store.slots.first(where: \.isFreeForAndroid) ?? store.slots.first)
        let view = ConnectCodeView(model: model, store: store)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "Connect with QR Code"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        self.panel = panel
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            Task { @MainActor in
                Self.panel = nil
                ConnectCodeModel.shared.stop()
            }
        }
        model.start()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Which slot the code is for, and the Mac's addresses, refreshed while the window is open (Wi-Fi
/// can change mid-meeting).
@MainActor
final class ConnectCodeModel: ObservableObject {
    static let shared = ConnectCodeModel()

    weak var store: SlotStore?
    @Published var slotID: Int?
    @Published private(set) var addresses: [LocalAddress] = []
    @Published private(set) var copied = false
    private var timer: Timer?

    func select(_ slot: Slot?) {
        slotID = slot?.config.id
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let now = LocalAddress.current()
        if now != addresses { addresses = now }
        let codes = store?.slots.map(\.relayCode) ?? []
        if codes != lastCodes { lastCodes = codes; objectWillChange.send() }
    }
    private var lastCodes: [String?] = []

    var slot: Slot? {
        guard let store else { return nil }
        return store.slots.first { $0.config.id == slotID } ?? store.slots.first
    }

    var link: ConnectLink? {
        guard let slot else { return nil }
        let relay = store?.relaySettings?.host
        let code = slot.relayCode
        guard !addresses.isEmpty || (relay != nil && code != nil) else { return nil }
        return ConnectLink(name: slot.name, port: slot.config.castPort, hosts: addresses.map(\.address), relay: code == nil ? nil : relay, code: code)
    }

    func copyLink() {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.text, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

struct ConnectCodeView: View {
    @ObservedObject var model: ConnectCodeModel
    @ObservedObject var store: SlotStore

    var body: some View {
        VStack(spacing: 14) {
            Picker("Slot", selection: Binding(
                get: { model.slotID ?? store.slots.first?.config.id ?? 1 },
                set: { model.slotID = $0 }
            )) {
                ForEach(store.slots) { slot in
                    Text(slot.isFreeForAndroid ? slot.name : "\(slot.name) (in use)").tag(slot.config.id)
                }
            }
            .pickerStyle(.menu)

            if let link = model.link, let image = QRCode.image(of: link.text, side: 260) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
                    .accessibilityLabel("QR code for \(link.name)")
                Text("In Mirror Wall Cast, tap Scan QR Code. The phone's camera app works too.")
                    .font(Brand.font(13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let code = link.code, let relay = link.relay {
                    VStack(spacing: 2) {
                        Text("Code \(code.prefix(3)) \(code.suffix(3))")
                            .font(Brand.mono(22, .semibold))
                            .foregroundStyle(Brand.lampText)
                            .textSelection(.enabled)
                        Text("through \(relay), for phones that can't reach this Mac")
                            .font(Brand.font(11)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.addresses) { address in
                        HStack {
                            Text(address.label).font(Brand.font(12)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(address.address):\(link.port)").font(Brand.mono(12)).foregroundStyle(Brand.signalText)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.surfaceSunken))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.signal.opacity(0.35)))
                Text("The phone tries each address, Wi-Fi first. A customer's guest Wi-Fi usually keeps devices apart; a VPN both share (Tailscale) still works.")
                    .font(Brand.font(11))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(model.copied ? "Copied" : "Copy Link") { model.copyLink() }
                    Button("Type It Instead…") { showTyped(link) }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("This Mac has no network address yet.").font(Brand.font(14, .semibold))
                    Text("Join a Wi-Fi network or turn on a VPN, and the code appears here.")
                        .font(Brand.font(12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(width: 260, height: 260)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { model.refresh() }
    }

    /// For a phone that can't scan: the address to type into "Or connect by address".
    private func showTyped(_ link: ConnectLink) {
        let alert = NSAlert()
        alert.messageText = "Connect by address"
        alert.informativeText = "In Mirror Wall Cast, under “Or connect by address”, type one of these and tap Share:\n\n"
            + link.hosts.map { "\($0):\(link.port)" }.joined(separator: "\n")
            + (link.hasRelay ? "\n\nOr the relay code: \(link.code ?? "")" : "")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension Slot {
    /// Nothing is mirroring to it, so an Android phone that scans the code gets in.
    var isFreeForAndroid: Bool { state == .waiting || state == .disconnected }
}

/// QR codes from Core Image, drawn crisp (no interpolation) at the size asked for.
enum QRCode {
    static func image(of text: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
