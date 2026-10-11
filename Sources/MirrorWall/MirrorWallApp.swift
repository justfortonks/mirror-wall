import AppKit
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
            CommandGroup(after: .newItem) {
                Button("Add Slot") { appDelegate.store.addSlot() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Choose uxplay…") { appDelegate.store.chooseUxPlay() }
            }
            CommandGroup(before: .windowList) {
                ShowMainWindowButton()
                Divider()
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
