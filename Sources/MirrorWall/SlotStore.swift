import AppKit
import Foundation
import MirrorCore

/// The list of slots, their own windows, the uxplay location, and persistence of all three.
@MainActor
final class SlotStore: ObservableObject {
    @Published private(set) var slots: [Slot] = []
    @Published private(set) var uxplayURL: URL?
    /// Slots currently shown in a window of their own.
    @Published private(set) var poppedOutIDs: Set<Int> = []
    /// The most frames a second phones are asked to send (30 or 60).
    @Published private(set) var maxFrameRate: Int
    /// The size of slots' own windows.
    @Published private(set) var popOutSize: PopOutSize
    /// Phones that have mirrored to this Mac, newest first.
    @Published private(set) var knownPhones: [KnownPhone]
    /// When on, only phones in `allowedDeviceIDs` can mirror. Off by default: any phone can.
    @Published private(set) var allowListEnabled: Bool
    @Published private(set) var allowedDeviceIDs: Set<String>

    private let defaults = UserDefaults.standard
    private let slotsKey = "slots"
    private let uxplayPathKey = "uxplayPath"
    private let poppedOutKey = "poppedOutSlots"
    private let maxFrameRateKey = "maxFrameRate"
    private let popOutSizeKey = "popOutSize"
    private let knownPhonesKey = "knownPhones"
    private let allowListEnabledKey = "allowListEnabled"
    private let allowedDevicesKey = "allowedDevices"
    static let bounceKey = "bounceOnDisconnect"

    private var popOutWindows: [Int: PopOutWindow] = [:]
    /// Set while quitting, so windows closing then are still reopened next launch.
    private var terminating = false

    static let maxSlots = 8

    init() {
        defaults.register(defaults: [Self.bounceKey: true])
        let saved = defaults.data(forKey: slotsKey).flatMap { try? JSONDecoder().decode([SlotConfig].self, from: $0) }
        var configs = saved ?? (1...2).map { SlotConfig(id: $0, name: SlotConfig.defaultName(for: $0, computerName: Self.computerName)) }
        // Slots still on the old "Mirror Wall N" name take the Mac's name, so two Macs' slots
        // can be told apart on the phone.
        for index in configs.indices where SlotConfig.isOldDefaultName(configs[index].name, id: configs[index].id) {
            configs[index].name = SlotConfig.defaultName(for: configs[index].id, computerName: Self.computerName)
        }
        let savedRate = defaults.integer(forKey: maxFrameRateKey)
        maxFrameRate = SlotConfig.frameRates.contains(savedRate) ? savedRate : 30
        popOutSize = defaults.string(forKey: popOutSizeKey).flatMap(PopOutSize.init(rawValue:)) ?? .medium
        knownPhones = defaults.data(forKey: knownPhonesKey).flatMap { try? JSONDecoder().decode([KnownPhone].self, from: $0) } ?? []
        allowListEnabled = defaults.bool(forKey: allowListEnabledKey)
        allowedDeviceIDs = Set(defaults.stringArray(forKey: allowedDevicesKey) ?? [])
        slots = configs.map { Slot(config: $0) }
        uxplayURL = Self.locateUxPlay(savedPath: defaults.string(forKey: uxplayPathKey))
        slots.forEach(watch)
        if saved != nil { save() }
    }

    /// The Mac's name, as set in System Settings › General › Sharing.
    nonisolated static var computerName: String? {
        Host.current().localizedName
    }

    /// Saves a slot's config when it learns a new phone's name, and retitles windows to match.
    private func watch(_ slot: Slot) {
        slot.maxFrameRate = maxFrameRate
        slot.allowedDevices = allowedDevices
        slot.onConfigChanged = { [weak self] in
            MainActor.assumeIsolated {
                self?.save()
                self?.updateWindowTitles()
            }
        }
        slot.onPhoneSeen = { [weak self] phone in
            MainActor.assumeIsolated { self?.remember(phone) }
        }
        slot.onPhoneDropped = { [weak self] in
            MainActor.assumeIsolated { self?.alertPhoneDropped() }
        }
    }

    // MARK: - Allow-list and alerts

    /// The device IDs receivers are restricted to, or nil when any phone may connect.
    private var allowedDevices: [String]? {
        allowListEnabled ? allowedDeviceIDs.sorted() : nil
    }

    private func remember(_ phone: KnownPhone) {
        knownPhones.removeAll { $0.deviceID == phone.deviceID }
        knownPhones.insert(phone, at: 0)
        if let data = try? JSONEncoder().encode(knownPhones) { defaults.set(data, forKey: knownPhonesKey) }
    }

    func forget(_ phone: KnownPhone) {
        knownPhones.removeAll { $0.deviceID == phone.deviceID }
        if let data = try? JSONEncoder().encode(knownPhones) { defaults.set(data, forKey: knownPhonesKey) }
        setAllowed(phone, false)
    }

    /// Turning the allow-list on starts with every known phone ticked, so nobody is locked out
    /// by surprise.
    func setAllowListEnabled(_ enabled: Bool) {
        guard enabled != allowListEnabled else { return }
        if enabled && allowedDeviceIDs.isEmpty {
            allowedDeviceIDs = Set(knownPhones.map(\.deviceID))
            defaults.set(allowedDeviceIDs.sorted(), forKey: allowedDevicesKey)
        }
        allowListEnabled = enabled
        defaults.set(enabled, forKey: allowListEnabledKey)
        applyAllowList()
    }

    func setAllowed(_ phone: KnownPhone, _ allowed: Bool) {
        let before = allowedDeviceIDs
        if allowed { allowedDeviceIDs.insert(phone.deviceID) } else { allowedDeviceIDs.remove(phone.deviceID) }
        guard allowedDeviceIDs != before else { return }
        defaults.set(allowedDeviceIDs.sorted(), forKey: allowedDevicesKey)
        if allowListEnabled { applyAllowList() }
    }

    /// Receivers read the allow-list when they start, so each one restarts.
    private func applyAllowList() {
        for slot in slots {
            slot.allowedDevices = allowedDevices
            restart(slot)
        }
    }

    /// Bounces the Dock icon until Mirror Wall is clicked (macOS doesn't while it's in front).
    private func alertPhoneDropped() {
        guard defaults.bool(forKey: Self.bounceKey) else { return }
        NSApp.requestUserAttention(.criticalRequest)
    }

    // MARK: - uxplay

    /// Where to look for uxplay: the one packaged inside MirrorWall.app first (it brings its own
    /// GStreamer, so it works on any Mac), then any path the user picked, then the usual places.
    static func candidatePaths(savedPath: String?) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Where the milestone 1 test built UxPlay.
        let testFolders = ["casting app", "Apple Casting App"].map { home + "/Documents/Claude Code/\($0)/UxPlay" }
        let packaged = Bundle.main.resourceURL?.appendingPathComponent(PackagedReceiver.executablePathInResources).path
        return [packaged, savedPath].compactMap { $0 } + [
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

    var isAnyRecording: Bool { slots.contains { $0.recordingSince != nil } }

    func startAllRecordings() {
        slots.forEach { $0.startRecording() }
        objectWillChange.send()
    }

    /// - Parameter wait: true when quitting, so every file is complete before the app exits.
    func stopAllRecordings(wait: Bool = false) {
        slots.forEach { $0.stopRecording(wait: wait) }
        objectWillChange.send()
    }

    func showRecordings() {
        let folder = SlotRecorder.defaultFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    var canAddSlot: Bool { slots.count < Self.maxSlots }

    func addSlot() {
        guard canAddSlot else { return }
        let used = Set(slots.map(\.id))
        guard let id = (1...Self.maxSlots).first(where: { !used.contains($0) }) else { return }
        let slot = Slot(config: SlotConfig(id: id, name: SlotConfig.defaultName(for: id, computerName: Self.computerName)))
        watch(slot)
        slots.append(slot)
        slots.sort { $0.id < $1.id }
        if let uxplayURL { slot.start(uxplay: uxplayURL) }
        save()
        updateWindowTitles()
    }

    func remove(_ slot: Slot) {
        closeOwnWindow(slot)
        slot.stopRecording()
        slot.stop()
        StandbyPictures.discard(slot.config.standby)
        slots.removeAll { $0 === slot }
        save()
        updateWindowTitles()
    }

    /// Changes the frame rate phones are asked for. Each receiver restarts to apply it, so phones
    /// mirroring now have to reconnect.
    func setMaxFrameRate(_ rate: Int) {
        guard rate != maxFrameRate, SlotConfig.frameRates.contains(rate) else { return }
        maxFrameRate = rate
        defaults.set(rate, forKey: maxFrameRateKey)
        for slot in slots {
            slot.maxFrameRate = rate
            restart(slot)
        }
    }

    func restart(_ slot: Slot) {
        guard let uxplayURL else { return }
        slot.restart(uxplay: uxplayURL)
    }

    func rename(_ slot: Slot, to name: String) {
        let tidy = SlotConfig.tidyName(name)
        guard !tidy.isEmpty, tidy != slot.name else { return }
        slot.rename(to: tidy, uxplay: uxplayURL)
        save()
        updateWindowTitles()
        objectWillChange.send()
    }

    func resetName(_ slot: Slot) {
        rename(slot, to: SlotConfig.defaultName(for: slot.id, computerName: Self.computerName))
    }

    // MARK: - Standby pictures and screenshots

    func setStandby(_ slot: Slot, _ standby: StandbyPicture?) {
        let old = slot.config.standby
        guard standby != old else { return }
        slot.setStandby(standby)
        StandbyPictures.discard(old)
        save()
    }

    func chooseStandbyImage(for slot: Slot) {
        guard let picture = StandbyPictures.choose(for: slot.id) else { return }
        setStandby(slot, picture)
    }

    func screenshotAll() {
        slots.forEach { $0.takeScreenshot() }
    }

    // MARK: - Own windows

    func setPopOutSize(_ size: PopOutSize) {
        guard size != popOutSize else { return }
        popOutSize = size
        defaults.set(size.rawValue, forKey: popOutSizeKey)
        popOutWindows.values.forEach { $0.size = size }
    }

    func openOwnWindow(_ slot: Slot) {
        if let existing = popOutWindows[slot.id] {
            existing.show()
            return
        }
        let window = PopOutWindow(slot: slot, title: windowTitles[slot.id] ?? "MacMirror-\(slot.name)", size: popOutSize)
        let id = slot.id
        window.onClose = { [weak self] in self?.ownWindowClosed(id) }
        popOutWindows[id] = window
        poppedOutIDs.insert(id)
        window.show()
        savePoppedOut()
    }

    func closeOwnWindow(_ slot: Slot) {
        popOutWindows[slot.id]?.close()
    }

    /// Reopens the windows that were open when the app last quit.
    func restoreOwnWindows() {
        let ids = Set(defaults.array(forKey: poppedOutKey) as? [Int] ?? [])
        slots.filter { ids.contains($0.id) }.forEach(openOwnWindow)
    }

    func prepareForTermination() {
        terminating = true
    }

    private var windowTitles: [Int: String] {
        SlotConfig.windowTitles(for: slots.map(\.config))
    }

    private func updateWindowTitles() {
        let titles = windowTitles
        for (id, window) in popOutWindows {
            if let title = titles[id], window.window.title != title { window.window.title = title }
        }
    }

    private func ownWindowClosed(_ id: Int) {
        popOutWindows[id] = nil
        poppedOutIDs.remove(id)
        if !terminating { savePoppedOut() }
    }

    private func savePoppedOut() {
        defaults.set(poppedOutIDs.sorted(), forKey: poppedOutKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(slots.map(\.config)) {
            defaults.set(data, forKey: slotsKey)
        }
    }
}
