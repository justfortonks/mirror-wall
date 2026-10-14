import AppKit
import MirrorCore

/// Mirror Wall › Check for Update…: compares this copy with the newest release on GitHub and, when
/// asked, downloads its DMG, puts the new Mirror Wall in place of this one and reopens it.
///
/// Nothing needs signing for this: macOS only asks "Open Anyway" about apps that arrive marked
/// as downloaded from the internet, and that mark comes from browsers, not from a download the
/// app makes itself. The copy is ad-hoc signed like every build, and checked before it's used.
@MainActor
enum Updater {
    private static var busy = false

    static func check() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                var request = URLRequest(url: LatestRelease.apiURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Mirror Wall", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let release = LatestRelease(json: data, asset: "MirrorWall.dmg") else {
                    throw UpdateError("GitHub didn't list a release Mirror Wall could read.")
                }
                await offer(release)
            } catch {
                showProblem("Mirror Wall couldn't check for an update.", error)
            }
        }
    }

    private static var currentBuild: Int? {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init)
    }

    private static func offer(_ release: LatestRelease) async {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let installable = currentBuild != nil && release.downloadURL != nil
        if let current = currentBuild, current >= release.build {
            alert.messageText = "Mirror Wall is up to date"
            alert.informativeText = current == release.build
                ? "You have \(release.version), the newest release."
                : "You have 0.\(current), newer than the newest release (\(release.version))."
            alert.addButton(withTitle: "OK")
            // Puts a fresh copy of the release back, e.g. after trying a test build.
            if installable { alert.addButton(withTitle: "Install \(release.version) Anyway") }
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        } else {
            alert.messageText = "Mirror Wall \(release.version) is available"
            let have = currentBuild.map { "You have 0.\($0)." } ?? "This copy runs from the source folder, so it can't replace itself."
            let notes = release.notes.isEmpty ? "" : "\n\n\(release.notes)"
            alert.informativeText = have + notes + (installable ? "\n\nMirror Wall will close, update and open again. Phones reconnect by themselves." : "")
            alert.addButton(withTitle: installable ? "Install and Reopen" : "Open Download Page")
            alert.addButton(withTitle: "Later")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard installable else {
                NSWorkspace.shared.open(LatestRelease.pageURL)
                return
            }
        }
        await install(release)
    }

    private static func install(_ release: LatestRelease) async {
        guard let url = release.downloadURL else { return }
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            showProblem("Mirror Wall can't replace itself in \(folder.path).",
                        UpdateError("Download the new version from its page and drag it to Applications instead."),
                        offerPage: true)
            return
        }

        let progress = ProgressPanel(title: "Downloading Mirror Wall \(release.version)…")
        defer { progress.close() }
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorWallUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let (download, _) = try await URLSession.shared.download(from: url)
            let dmg = work.appendingPathComponent("MirrorWall.dmg")
            try FileManager.default.moveItem(at: download, to: dmg)

            progress.title = "Installing Mirror Wall \(release.version)…"
            // Beside the app, so the swap is a rename on the same disk.
            let staged = folder.appendingPathComponent(".Mirror Wall \(release.version).app")
            try await Task.detached { try Updater.copyApp(outOf: dmg, to: staged, mountingIn: work) }.value
            try relaunch(replacing: app, with: staged)
        } catch {
            showProblem("Mirror Wall couldn't install \(release.version).", error, offerPage: true)
        }
    }

    /// Opens the DMG out of sight, copies the app out of it and checks it's an intact Mirror Wall.
    nonisolated private static func copyApp(outOf dmg: URL, to staged: URL, mountingIn work: URL) throws {
        let mount = work.appendingPathComponent("mount")
        try run("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path)
        defer { try? run("/usr/bin/hdiutil", "detach", mount.path, "-force") }

        let contents = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
        guard let source = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError("The download had no app in it.")
        }
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", source.path, staged.path)
        guard Bundle(url: staged)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError("The download wasn't Mirror Wall.")
        }
        // In case anything marked it as downloaded, so macOS doesn't ask about it again.
        try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", staged.path)
        do {
            try run("/usr/bin/codesign", "--verify", "--deep", "--strict", staged.path)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError("The downloaded app was damaged.")
        }
    }

    /// Hands over to a small script that waits for Mirror Wall to quit (stopping its receivers and
    /// recordings as usual), swaps the new app into place and opens it. If the swap fails, the
    /// old app goes back and opens instead.
    private static func relaunch(replacing app: URL, with staged: URL) throws {
        let script = #"""
        pid=$1 app=$2 new=$3 old=$4
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        if mv "$app" "$old"; then
            if mv "$new" "$app"; then rm -rf "$old"; else mv "$old" "$app"; rm -rf "$new"; fi
        fi
        open "$app"
        """#
        let old = app.deletingLastPathComponent().appendingPathComponent(".Mirror Wall replaced.app")
        try? FileManager.default.removeItem(at: old)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "mirror-wall-update",
                            String(ProcessInfo.processInfo.processIdentifier), app.path, staged.path, old.path]
        try helper.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    private static func showProblem(_ message: String, _ error: Error, offerPage: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = (error as? UpdateError)?.message ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        if offerPage { alert.addButton(withTitle: "Open Download Page") }
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(LatestRelease.pageURL)
        }
    }
}

private struct UpdateError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A small window with a spinner while the update downloads and installs.
@MainActor
private final class ProgressPanel {
    private let panel: NSPanel
    private let label: NSTextField

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init(title: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Check for Update"
        label = NSTextField(labelWithString: title)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let row = NSStackView(views: [spinner, label])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = row
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { panel.close() }
}
