import MirrorCore
import SwiftUI

/// The one screen: where to share (a slot on this network, the QR code, or an address), then
/// Start sharing. The broadcast itself runs in the extension; this shows how it's going.
struct ContentView: View {
    @StateObject private var browser = SlotBrowser()
    @State private var target = Shared.target
    @State private var status = Shared.status
    @State private var phoneName = Shared.phoneName
    @State private var address = ""
    @State private var scanning = false
    @State private var message: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let target { readyCard(target) }
                    slotsSection
                    scanSection
                    addressSection
                    nameSection
                    troubleshooting
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Brand.surface)
        }
        .background(Brand.surface.ignoresSafeArea())
        .onAppear {
            browser.start()
            listenForStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { status = Shared.status; browser.start() }
            if phase == .background { browser.stop() }
        }
        .onOpenURL { url in use(link: url.absoluteString) }
        .sheet(isPresented: $scanning) { scannerSheet }
    }

    // MARK: Header

    private var sharing: Bool { status?.sharing == true }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                BrandMark(size: 22)
                Text("Mirror Wall Cast").font(Brand.display(16)).foregroundStyle(Brand.lamp)
            }
            Text(sharing ? "Sharing this screen" : (target == nil ? "Pick a slot" : "Ready to share"))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Brand.onNight)
            Text(message ?? status?.text ?? "Mirror Wall slots on this Wi-Fi appear below.")
                .font(.system(size: 15))
                .foregroundStyle(Brand.onNightMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(Brand.night.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Brand.signal.frame(height: 1) }
    }

    // MARK: Ready

    private func readyCard(_ target: Shared.Target) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(sharing ? Brand.gel : Brand.lamp).frame(width: 10, height: 10)
                    .shadow(color: (sharing ? Brand.gel : Brand.lamp).opacity(0.8), radius: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Brand.ink)
                    Text(routeText(target)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Brand.signalText)
                        .lineLimit(2)
                }
            }
            ZStack {
                Text(sharing ? "Stop sharing" : "Start sharing")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Brand.onLamp)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(Brand.lamp))
                BroadcastPicker()
            }
            .frame(height: 50)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            Text("iOS asks to confirm: tap Start Broadcast. To stop, tap the red pill at the top of the screen, or come back here.")
                .font(.system(size: 13)).foregroundStyle(Brand.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.line))
        .padding(.top, 16)
    }

    private func routeText(_ target: Shared.Target) -> String {
        var parts = target.hosts.map { "\($0):\(target.port)" }
        if target.hasRelay, let code = target.code { parts.append("relay \(code.prefix(3)) \(code.suffix(3))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Slots

    private var slotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Brand.label("Slots on this network").padding(.top, 18)
            if let problem = browser.problem {
                Text(problem).font(.system(size: 14)).foregroundStyle(Brand.inkMuted)
            } else if browser.slots.isEmpty {
                Text("Looking… Mirror Wall must be open on a Mac on the same Wi-Fi.")
                    .font(.system(size: 14)).foregroundStyle(Brand.inkMuted)
            }
            ForEach(browser.slots) { slot in
                Button { pick(slot) } label: {
                    HStack(spacing: 14) {
                        Circle().fill(Brand.lamp).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(slot.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.ink)
                            Text("Tap to share this screen").font(.system(size: 13)).foregroundStyle(Brand.inkMuted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Brand.signalText)
                    }
                    .padding(16)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.line))
                }
                .buttonStyle(.plain)
                .disabled(sharing)
            }
        }
    }

    private func pick(_ slot: SlotBrowser.Slot) {
        message = "Finding \(slot.name)…"
        Task {
            guard let (host, port) = await SlotBrowser.resolve(slot) else {
                message = "Couldn't reach \(slot.name). Try the QR code instead."
                return
            }
            setTarget(Shared.Target(name: slot.name, port: port, hosts: [host]))
        }
    }

    // MARK: QR code

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Brand.label("Or scan the code in Mirror Wall").padding(.top, 18)
            Button {
                guard CodeScanner.isSupported else {
                    message = "This iPhone can't scan in the app. Point the Camera app at the code instead."
                    return
                }
                Task {
                    if await CodeScanner.requestCamera() {
                        scanning = true
                    } else {
                        message = "Scanning needs the camera. Allow it in Settings › Mirror Wall Cast, or point the Camera app at the code."
                    }
                }
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.onLamp)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 48)
                    .background(Capsule().fill(Brand.lamp))
            }
            .disabled(sharing)
            Text("Mirror Wall › Connect with QR Code… (⌘K) shows it. Works where the list stays empty: guest Wi-Fi, a VPN both share, or anywhere through the relay.")
                .font(.system(size: 13)).foregroundStyle(Brand.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scannerSheet: some View {
        NavigationStack {
            CodeScanner { text in
                scanning = false
                use(link: text)
            }
            .ignoresSafeArea()
            .navigationTitle("Scan the code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
        }
    }

    /// A mirrorwall://connect link, from the scanner or the Camera app. Every address and the
    /// relay go to the extension, which tries them in order.
    private func use(link text: String) {
        guard let link = ConnectLink(text: text) else {
            message = "That isn't a Mirror Wall code."
            return
        }
        setTarget(Shared.Target(name: link.name, port: link.port, hosts: link.hosts, relay: link.relay, code: link.code))
    }

    // MARK: Address

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Brand.label("Or connect by address").padding(.top, 18)
            HStack(spacing: 8) {
                TextField("192.168.1.20:7450", text: $address)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 16, design: .monospaced))
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.line))
                    .onSubmit(useAddress)
                Button("Use", action: useAddress)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.onLamp)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 48)
                    .background(Capsule().fill(Brand.lamp))
                    .disabled(sharing)
            }
        }
    }

    private func useAddress() {
        let text = address.filter { $0 != "," && !$0.isWhitespace }
        guard !text.isEmpty else { return }
        let host = String(text.split(separator: ":").first ?? "")
        let port = text.split(separator: ":").dropFirst().first.flatMap { UInt16($0) } ?? 7350
        setTarget(Shared.Target(name: "\(host):\(port)", port: port, hosts: [host]))
    }

    // MARK: Name and log

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Brand.label("This phone's name on Mirror Wall").padding(.top, 18)
            TextField("iPhone", text: $phoneName)
                .font(.system(size: 16))
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.line))
                .onChange(of: phoneName) { _, name in Shared.phoneName = name }
        }
    }

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Brand.label("Troubleshooting").padding(.top, 18)
            ShareLink(item: Shared.logText.isEmpty ? "Nothing logged yet." : Shared.logText, subject: Text("Mirror Wall Cast log from \(Shared.phoneName)")) {
                Text("Share Log").font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.ink)
                    .padding(.horizontal, 16).frame(minHeight: 40)
                    .overlay(Capsule().strokeBorder(Brand.line, lineWidth: 1.5))
            }
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                .font(.system(size: 12)).foregroundStyle(Brand.inkMuted).padding(.top, 8)
        }
    }

    // MARK: State

    /// A slot was picked (from the list, a scan or a link): remember it and go straight to iOS's
    /// Start Broadcast sheet, so picking a slot is the same one step as on Android.
    private func setTarget(_ new: Shared.Target) {
        Shared.target = new
        target = new
        message = nil
        Shared.log("Picked \(new.name): \(routeText(new))", from: "app")
        guard !sharing else { return }
        BroadcastPicker.open()
    }

    private func listenForStatus() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            NotificationCenter.default.post(name: .castStatusChanged, object: nil)
        }, Shared.statusChanged, nil, .deliverImmediately)
        NotificationCenter.default.addObserver(forName: .castStatusChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in status = Shared.status; message = nil }
        }
    }
}

extension Notification.Name {
    static let castStatusChanged = Notification.Name("castStatusChanged")
}
