import AppKit
import MirrorCore
import SwiftUI

@main
struct MirrorWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(SlotStore.menuBarIconKey) private var showsMenuBarIcon = true

    var body: some Scene {
        Window("Mirror Wall", id: "main") {
            ContentView()
                .environmentObject(appDelegate.store)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Mirror Wall") { AboutPanel.show() }
                Button("Check for Update…") { Updater.check() }
            }
            CommandGroup(after: .newItem) {
                Button("Add Slot") { appDelegate.store.addSlot() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Connect with QR Code…") { ConnectCodePanel.show(store: appDelegate.store) }
                    .keyboardShortcut("k")
                Button("Choose uxplay…") { appDelegate.store.chooseUxPlay() }
                Divider()
                Button("Record All Slots") { appDelegate.store.startAllRecordings() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Stop All Recordings") { appDelegate.store.stopAllRecordings() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Show Recordings in Finder") { appDelegate.store.showRecordings() }
                Divider()
                Button("Screenshot All Slots") { appDelegate.store.screenshotAll() }
                Button("Show Screenshots in Finder") { Screenshots.showInFinder() }
            }
            CommandGroup(before: .windowList) {
                ShowMainWindowButton()
                Divider()
            }
            StatsCommands()
            FrameRateCommands(store: appDelegate.store)
            SmoothMotionCommands(store: appDelegate.store)
            PopOutSizeCommands(store: appDelegate.store)
            StageCommands(store: appDelegate.store)
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.store)
        }

        MenuBarExtra(isInserted: $showsMenuBarIcon) {
            MenuBarMenu(store: appDelegate.store)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
    }
}

/// The menu bar icon: filled while a phone is mirroring or a slot is recording.
struct MenuBarLabel: View {
    @ObservedObject var store: SlotStore

    var body: some View {
        if let glyph = Brand.menuBarImage(inUse: store.anySlotInUse) {
            Image(nsImage: glyph).accessibilityLabel("Mirror Wall")
        } else {
            Image(systemName: store.anySlotInUse ? "circle.fill" : "circle").accessibilityLabel("Mirror Wall")
        }
    }
}

/// The menu bar icon's menu: every slot and how it's doing, and ways back to the wall. With the
/// icon there, closing the wall's window leaves Mirror Wall running, so phones keep mirroring
/// to their own windows and OBS.
struct MenuBarMenu: View {
    @ObservedObject var store: SlotStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ForEach(store.slots) { slot in
            MenuBarSlotItem(slot: slot, store: store)
        }
        Divider()
        Button("Connect with QR Code…") { ConnectCodePanel.show(store: store) }
        Button("Show Stage") { store.showStage() }
        Button("Show Wall") {
            MainWindow.open = openWindow
            MainWindow.show()
        }
        if store.isAnyRecording {
            Button("Stop All Recordings") { store.stopAllRecordings() }
        } else {
            Button("Record All Slots") { store.startAllRecordings() }
        }
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        Button("Check for Update…") { Updater.check() }
        Divider()
        Button("Quit Mirror Wall") { NSApp.terminate(nil) }
    }
}

/// One slot in the menu bar icon's menu, e.g. "● Mirror Wall 1: Live, Tom's iPhone". Choosing it
/// opens the slot's own window, or brings it forward.
struct MenuBarSlotItem: View {
    @ObservedObject var slot: Slot
    let store: SlotStore

    var body: some View {
        Button("\(dot) \(slot.name): \(status)") { store.openOwnWindow(slot) }
    }

    private var dot: String {
        switch slot.state {
        case .live: return "🟢"
        case .waiting, .connecting, .paused: return "🟡"
        case .disconnected: return "🟠"
        case .stopped: return "⚪️"
        case .failed: return "🔴"
        }
    }

    private var status: String {
        let phone = slot.phoneName.map { ", \($0)" } ?? ""
        let recording = slot.recordingSince == nil ? "" : ", recording"
        switch slot.state {
        case .stopped: return "Stopped"
        case .failed: return "Error"
        case .waiting: return "Waiting"
        case .connecting: return "Connecting" + phone
        case .disconnected: return "Disconnected"
        case .paused: return "Screen off" + phone + recording
        case .live: return "Live" + phone + recording
        }
    }
}

/// View › Pop-out Window Size: the size of slots' own windows, and the Custom lock.
struct PopOutSizeCommands: Commands {
    @ObservedObject var store: SlotStore

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Menu("Pop-out Window Size") {
                PopOutSizeItems(store: store)
            }
        }
    }
}

/// View › Smoother Motion: shows frames at the phone's pace, a moment late, instead of in
/// Wi-Fi's bursts. View › Sharper Picture: asks phones for H.265 at twice the size.
struct SmoothMotionCommands: Commands {
    @ObservedObject var store: SlotStore

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Smoother Motion", isOn: Binding(
                get: { store.smoothMotion },
                set: { store.setSmoothMotion($0) }
            ))
            Toggle("Sharper Picture (H.265)", isOn: Binding(
                get: { store.sharpPicture },
                set: { store.setSharpPicture($0) }
            ))
        }
    }
}

/// View › Frame Rate Limit: the most frames a second phones are asked to send.
struct FrameRateCommands: Commands {
    @ObservedObject var store: SlotStore

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Picker("Frame Rate Limit", selection: Binding(
                get: { store.maxFrameRate },
                set: { store.setMaxFrameRate($0) }
            )) {
                ForEach(SlotConfig.frameRates, id: \.self) { Text("\($0) frames a second").tag($0) }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SlotStore()
    /// Stage-first: the wall closes itself the first time it appears (see ContentView).
    static var hideWallAtLaunch = true

    private var signalSources: [DispatchSourceSignal] = []
    /// Keeps macOS from napping the app while its windows are hidden, e.g. behind a full-screen
    /// OBS projector: the pictures it draws are still being captured.
    private var noNap: NSObjectProtocol?
    private let instanceLock = InstanceLock()
    private var terminating = false
    private var ownsReceivers = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check older builds too: they do not yet acquire the advisory lock.
        if let other = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            ($0.bundleIdentifier == "com.justfortonks.mirrorwall" || $0.executableURL?.lastPathComponent == "MirrorWall")
        }) {
            other.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        let lockFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MirrorWall")
        try? FileManager.default.createDirectory(at: lockFolder, withIntermediateDirectories: true)
        guard instanceLock.acquire(at: lockFolder.appendingPathComponent("instance.lock")) else {
            let alert = NSAlert()
            alert.messageText = "Mirror Wall is already running"
            alert.informativeText = "Use the open copy. If it is not visible, quit that copy before opening another build."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        ownsReceivers = true
        // Needed when launched with `swift run` rather than from an app bundle.
        NSApp.setActivationPolicy(.regular)
        showAppIcon()
        NSApp.activate(ignoringOtherApps: true)
        noNap = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Showing live iPhone screens that other apps may be capturing"
        )
        stopReceiversOnSignals()
        SlotStore.stopLeftoverReceivers()
        store.startAll()
        store.restoreOwnWindows()
        // Stage-first: open straight to the Stage. The wall closes itself as it appears
        // (ContentView, hideWallAtLaunch); it's still in Window › Show Wall.
        store.showStage()
    }

    /// MirrorWall.app gets its icon from the bundle; run with `swift run`, the app sets it itself
    /// so the Dock and app switcher still show it.
    private func showAppIcon() {
        guard Bundle.main.bundleURL.pathExtension != "app",
              let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = icon
    }

    /// Ctrl-C or kill would otherwise end the app without stopping its uxplay processes,
    /// leaving them holding the slots' ports and names.
    private func stopReceiversOnSignals() {
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                guard self != nil else { return }
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ownsReceivers else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        store.prepareForTermination()
        store.stopAll(endingSharing: true)
        Task { @MainActor in
            for slot in store.slots { await slot.finishStopping() }
            store.stopAllRecordings()
            await SlotRecorder.finishPendingFiles()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Clicking the Dock icon brings back the Stage, the window being shared, not the wall.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        store.showStage()
        return false
    }

    /// Closing the last window (now usually the Stage) quits Mirror Wall, unless its menu bar
    /// icon is there to bring it back. Closing the Stage with ⌘W only hides it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: SlotStore.menuBarIconKey)
    }
}

/// Mirror Wall › About Mirror Wall: the standard panel, plus which code the build came from
/// (linked), so two Macs' copies can be told apart, and what changed in it (CHANGELOG.md's
/// newest entry, which scripts/build-app.sh copies into the app).
@MainActor
enum AboutPanel {
    /// This fork, so About and updates point at its builds, not upstream's.
    static let repository = "https://github.com/yurtbeer/mirror-wall"

    static func show() {
        let info = Bundle.main.infoDictionary ?? [:]
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let plain: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: NSColor.secondaryLabelColor]
        let credits = NSMutableAttributedString()
        func add(_ text: String, link: String? = nil, bold: Bool = false) {
            var attributes = plain
            if let link, let url = URL(string: link) { attributes[.link] = url }
            if bold { attributes[.font] = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize) }
            credits.append(NSAttributedString(string: text, attributes: attributes))
        }

        if let commit = info["MirrorWallCommit"] as? String, let built = info["MirrorWallBuilt"] as? String {
            add("Built \(built) from commit ")
            let full = info["MirrorWallCommitFull"] as? String
            add(commit, link: full.map { "\(repository)/commit/\($0)" })
            add(".")
        } else {
            add("Development build, run from the source folder.")
        }

        if let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
           let markdown = try? String(contentsOf: url, encoding: .utf8),
           let entry = ChangeLogEntry.latest(in: markdown) {
            add("\n\nWhat's new: \(entry.heading)\n", bold: true)
            for item in entry.items {
                add("• \(item)\n")
            }
            add("\n")
        } else {
            add("\n\n")
        }
        add("Full change log", link: "\(repository)/blob/main/CHANGELOG.md")

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Brings back the main window from anywhere: the Window menu, the Dock icon, or a slot's own window.
@MainActor
enum MainWindow {
    /// SwiftUI's action for reopening the main window if it was closed; set by the menu item.
    static var open: OpenWindowAction?

    static func show() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let open {
            open(id: "main")
        } else if let menu = showWallMenuItem?.menu, let item = showWallMenuItem {
            // The wall never appeared this run, so SwiftUI's open action isn't known yet; the
            // Window menu's Show Wall item has it.
            menu.performActionForItem(at: menu.index(of: item))
            return
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var showWallMenuItem: NSMenuItem? {
        for top in NSApp.mainMenu?.items ?? [] {
            if let item = top.submenu?.items.first(where: { $0.title == "Show Wall" }) { return item }
        }
        return nil
    }
}

struct ShowMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Wall") {
            MainWindow.open = openWindow
            MainWindow.show()
        }
        .keyboardShortcut("0")
        .onAppear { MainWindow.open = openWindow }
    }
}
