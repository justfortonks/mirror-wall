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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SlotStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` rather than from an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        store.startAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
