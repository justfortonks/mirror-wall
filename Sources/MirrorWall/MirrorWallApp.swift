import AppKit
import MirrorCore
import SwiftUI

@main
struct MirrorWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Mirror Wall", id: "main") {
            ContentView()
                .environmentObject(appDelegate.store)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Mirror Wall") { AboutPanel.show() }
            }
            CommandGroup(after: .newItem) {
                Button("Add Slot") { appDelegate.store.addSlot() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
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
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.store)
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

    private var signalSources: [DispatchSourceSignal] = []
    /// Keeps macOS from napping the app while its windows are hidden, e.g. behind a full-screen
    /// OBS projector: the pictures it draws are still being captured.
    private var noNap: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                self?.store.stopAll()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.prepareForTermination()
        store.stopAllRecordings(wait: true)
        store.stopAll()
    }

    /// Clicking the Dock icon brings back the main window, even when it's minimized and slots'
    /// own windows are open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Mirror Wall › About Mirror Wall: the standard panel, plus which code the build came from
/// (linked), so two Macs' copies can be told apart, and what changed in it (CHANGELOG.md's
/// newest entry, which scripts/build-app.sh copies into the app).
@MainActor
enum AboutPanel {
    static let repository = "https://github.com/justfortonks/mirror-wall"

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
        } else {
            open?(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ShowMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Mirror Wall Window") {
            MainWindow.open = openWindow
            MainWindow.show()
        }
        .keyboardShortcut("0")
        .onAppear { MainWindow.open = openWindow }
    }
}
