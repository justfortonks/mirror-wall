import AppKit
import MirrorCore

/// Mirror Wall › Check for Update…: compares this copy with the newest release on GitHub (or, on
/// the Beta channel, lets you choose a test build or the newest release) and, when asked,
/// downloads its DMG, puts the new Mirror Wall in place of this one and reopens it.
///
/// Nothing needs signing for this: macOS only asks "Open Anyway" about apps that arrive marked
/// as downloaded from the internet, and that mark comes from browsers, not from a download the
/// app makes itself. The copy is ad-hoc signed like every build, and checked before it's used.
@MainActor
enum Updater {
    private static var busy = false
    /// Settings › General › Updates: Stable or Beta.
    static let channelKey = "updateChannel"

    static var channel: UpdateChannel {
        UserDefaults.standard.string(forKey: channelKey).flatMap(UpdateChannel.init) ?? .stable
    }

    static func check() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let channel = Self.channel
                var request = URLRequest(url: LatestRelease.url(for: channel))
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Mirror Wall", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)
                switch channel {
                case .stable:
                    guard let release = LatestRelease(json: data, asset: "MirrorWall.dmg") else {
                        throw UpdateError("GitHub didn't list a release Mirror Wall could read.")
                    }
                    await offer(release)
                case .beta:
                    let choices = LatestRelease.choices(json: data, asset: "MirrorWall.dmg")
                    guard !choices.isEmpty else {
                        throw UpdateError("GitHub didn't list a release or test build Mirror Wall could read.")
                    }
                    if let chosen = choose(from: choices) { await install(chosen) }
                }
            } catch {
                showProblem("Mirror Wall couldn't check for an update.", error)
            }
        }
    }

    /// This copy's number, from its Info.plist (scripts/build-app.sh); nil when run from the
    /// source folder.
    static var current: BuildNumber? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard Bundle.main.bundleURL.pathExtension == "app",
              let build = (info["CFBundleVersion"] as? String).flatMap(Int.init) else { return nil }
        return BuildNumber(build: build, beta: (info["MirrorWallBeta"] as? String).flatMap(Int.init))
    }

    private static func offer(_ release: LatestRelease) async {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let installable = current != nil && release.downloadURL != nil
        let newest = "the newest release"
        if let current = Self.current, current >= release.number {
            alert.messageText = "Mirror Wall is up to date"
            alert.informativeText = current == release.number
                ? "You have \(release.version), \(newest)."
                : "You have \(current.version), newer than \(newest) (\(release.version))."
            alert.addButton(withTitle: "OK")
            // Only when this copy is newer, e.g. a beta: goes back to the release.
            let canGoBack = installable && current > release.number
            if canGoBack { alert.addButton(withTitle: "Go Back to \(release.version)") }
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        } else {
            alert.messageText = "Mirror Wall \(release.version) is available"
            let have = current.map { "You have \($0.version)." } ?? "This copy runs from the source folder, so it can't replace itself."
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

    /// The Beta channel: a list of every test build on offer and the newest release, to install
    /// any one of them. Nil when nothing was chosen.
    private static func choose(from choices: [LatestRelease]) -> LatestRelease? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Choose a Mirror Wall build"
        let have = current.map { "You have \($0.version)." } ?? "This copy runs from the source folder, so it can't replace itself."
        alert.informativeText = have + " Test builds are listed most recent first, then the newest release."
            + (current != nil ? " Mirror Wall will close, update and open again. Phones reconnect by themselves." : "")
        let picker = BuildPicker(choices: choices, current: current)
        alert.accessoryView = picker.view
        alert.addButton(withTitle: current != nil ? "Install and Reopen" : "Open Download Page")
        alert.addButton(withTitle: "Cancel")
        picker.installButton = alert.buttons[0]
        picker.showSelection()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard current != nil else {
            NSWorkspace.shared.open(LatestRelease.pageURL)
            return nil
        }
        return picker.selected
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

/// The list in the Beta channel's alert: a pop-up of builds and, below it, what the chosen one is.
@MainActor
private final class BuildPicker: NSObject {
    let view: NSView
    var installButton: NSButton?
    private let choices: [LatestRelease]
    private let current: BuildNumber?
    private let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 166, width: 440, height: 26), pullsDown: false)
    private let details: NSTextView

    var selected: LatestRelease? { choices.indices.contains(popUp.indexOfSelectedItem) ? choices[popUp.indexOfSelectedItem] : nil }

    init(choices: [LatestRelease], current: BuildNumber?) {
        self.choices = choices
        self.current = current
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 192))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 158))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        details = NSTextView(frame: scroll.bounds)
        details.isEditable = false
        details.textContainerInset = NSSize(width: 4, height: 4)
        details.autoresizingMask = [.width]
        scroll.documentView = details
        super.init()
        for release in choices {
            let item = NSMenuItem(title: label(for: release), action: nil, keyEquivalent: "")
            popUp.menu?.addItem(item)
        }
        // The first one that isn't this copy.
        popUp.selectItem(at: choices.firstIndex { $0.number != current } ?? 0)
        popUp.target = self
        popUp.action = #selector(changed)
        view.addSubview(popUp)
        view.addSubview(scroll)
    }

    private func label(for release: LatestRelease) -> String {
        var parts = [release.version]
        if release.number.beta == nil {
            parts.append("newest release")
        } else if !release.title.isEmpty {
            parts.append(release.title)
        }
        return parts.joined(separator: " · ") + (release.number == current ? " (installed)" : "")
    }

    @objc private func changed() { showSelection() }

    func showSelection() {
        guard let release = selected else { return }
        var lines = [release.number.beta == nil ? "Release \(release.version)" : "Test build \(release.version)"]
        if !release.title.isEmpty { lines[0] += ": \(release.title)" }
        if let published = release.published {
            lines.append("Published \(published.formatted(date: .abbreviated, time: .shortened))")
        }
        if release.number == current { lines.append("This is the copy you have.") }
        if !release.notes.isEmpty { lines.append("\n" + release.notes) }
        details.string = lines.joined(separator: "\n")
        details.textColor = .labelColor
        details.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        installButton?.isEnabled = release.number != current
    }
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
