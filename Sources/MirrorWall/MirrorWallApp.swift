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
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SlotStore()

    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` rather than from an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        stopReceiversOnSignals()
        SlotStore.stopLeftoverReceivers()
        store.startAll()
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
        store.stopAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
