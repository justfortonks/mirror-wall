import AppKit
import Foundation
import MirrorCore

/// The list of slots, the uxplay location, and persistence of both.
@MainActor
final class SlotStore: ObservableObject {
    @Published private(set) var slots: [Slot] = []
    @Published private(set) var uxplayURL: URL?

    private let defaults = UserDefaults.standard
    private let slotsKey = "slots"
    private let uxplayPathKey = "uxplayPath"

    static let maxSlots = 8

    init() {
        let saved = defaults.data(forKey: slotsKey).flatMap { try? JSONDecoder().decode([SlotConfig].self, from: $0) }
        let configs = saved ?? (1...2).map { SlotConfig(id: $0, name: SlotConfig.defaultName(for: $0)) }
        slots = configs.map { Slot(config: $0) }
        uxplayURL = Self.locateUxPlay(savedPath: defaults.string(forKey: uxplayPathKey))
    }

    // MARK: - uxplay

    /// Places uxplay is commonly found, after any path the user picked.
    static func candidatePaths(savedPath: String?) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Where the milestone 1 test built UxPlay.
        let testFolders = ["casting app", "Apple Casting App"].map { home + "/Documents/Claude Code/\($0)/UxPlay" }
        return [savedPath].compactMap { $0 } + [
            "/opt/homebrew/bin/uxplay",
            "/usr/local/bin/uxplay",
        ] + testFolders.flatMap { [$0 + "/build/uxplay", $0 + "/uxplay"] }
    }

    static func locateUxPlay(savedPath: String?) -> URL? {
        candidatePaths(savedPath: savedPath)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func chooseUxPlay() {
        let panel = NSOpenPanel()
        panel.title = "Choose the uxplay program"
        panel.message = "Pick the uxplay binary you built (for example UxPlay/build/uxplay)."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            NSSound.beep()
            return
        }
        defaults.set(url.path, forKey: uxplayPathKey)
        uxplayURL = url
        stopAll()
        startAll()
    }

    /// Stops uxplay processes left behind by an earlier run that crashed or was killed.
    /// They are recognised by the device IDs only Mirror Wall slots use.
    nonisolated static func stopLeftoverReceivers() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "uxplay .*-m 02:00:00:00:00:[0-9A-F]{2}"]
        guard (try? pkill.run()) != nil else { return }
        pkill.waitUntilExit()
        if pkill.terminationStatus == 0 {
            Thread.sleep(forTimeInterval: 0.5) // let them release their ports
        }
    }

    // MARK: - Slots

    func startAll() {
        guard let uxplayURL else { return }
        slots.forEach { $0.start(uxplay: uxplayURL) }
    }

    func stopAll() {
        slots.forEach { $0.stop() }
    }

    var canAddSlot: Bool { slots.count < Self.maxSlots }

    func addSlot() {
        guard canAddSlot else { return }
        let used = Set(slots.map(\.id))
        guard let id = (1...Self.maxSlots).first(where: { !used.contains($0) }) else { return }
        let slot = Slot(config: SlotConfig(id: id, name: SlotConfig.defaultName(for: id)))
        slots.append(slot)
        slots.sort { $0.id < $1.id }
        if let uxplayURL { slot.start(uxplay: uxplayURL) }
        save()
    }

    func remove(_ slot: Slot) {
        slot.stop()
        slots.removeAll { $0 === slot }
        save()
    }

    func restart(_ slot: Slot) {
        guard let uxplayURL else { return }
        slot.restart(uxplay: uxplayURL)
    }

    func rename(_ slot: Slot, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != slot.name else { return }
        slot.rename(to: trimmed, uxplay: uxplayURL)
        save()
        objectWillChange.send()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(slots.map(\.config)) {
            defaults.set(data, forKey: slotsKey)
        }
    }
}
