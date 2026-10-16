import AppKit
import Combine
import Foundation
import MirrorCore
import SwiftUI

/// The list of slots, their own windows, the uxplay location, and persistence of all three.
@MainActor
final class SlotStore: ObservableObject {
    @Published private(set) var slots: [Slot] = []
    @Published private(set) var uxplayURL: URL?
    /// Slots currently shown in a window of their own.
    @Published private(set) var poppedOutIDs: Set<Int> = []
    /// The most frames a second phones are asked to send (30 or 60).
    @Published private(set) var maxFrameRate: Int
    /// Shows frames at the pace the phone captured them, a moment later, instead of as they arrive.
    @Published private(set) var smoothMotion: Bool
    /// Offers phones H.265, for portrait pictures twice as tall and wide. Off by default.
    @Published private(set) var sharpPicture: Bool
    /// The size of slots' own windows.
    @Published private(set) var popOutSize: PopOutSize
    /// With a Custom size, whether windows' sizes are locked against dragging. On by default.
    @Published private(set) var popOutSizeLocked: Bool
    /// Phones that have mirrored to this Mac, newest first.
    @Published private(set) var knownPhones: [KnownPhone]
    /// When on, only phones in `allowedDeviceIDs` can mirror. Off by default: any phone can.
    @Published private(set) var allowListEnabled: Bool
    @Published private(set) var allowedDeviceIDs: Set<String>
    /// What slots show while no phone is mirroring, unless a slot has its own.
    @Published private(set) var defaultStandby: StandbyPicture
    /// Every slot sends its picture to OBS unless turned off in its own menu. Off by default.
    @Published private(set) var obsFeedForAllSlots: Bool
    /// Reopens the slots' own windows that were open when Mirror Wall last quit. Off by default.
    @Published private(set) var reopensOwnWindows: Bool
    /// Every slot shows a phone frame around its picture unless turned off in its own menu. Off by default.
    @Published private(set) var bezelsForAllSlots: Bool
    /// Keeps the Mac and its screen from going to sleep while a phone is mirroring or a slot is
    /// recording. On by default.
    @Published private(set) var keepsMacAwake: Bool
    /// How the Stage window arranges the phones.
    @Published private(set) var stageLayout: StageLayout

    private let defaults = UserDefaults.standard
    private let slotsKey = "slots"
    private let uxplayPathKey = "uxplayPath"
    private let poppedOutKey = "poppedOutSlots"
    private let maxFrameRateKey = "maxFrameRate"
    private let smoothMotionKey = "smoothMotion"
    private let sharpPictureKey = "sharpPicture"
    private let popOutSizeKey = "popOutSize"
    private let popOutSizeLockedKey = "popOutSizeLocked"
    private let knownPhonesKey = "knownPhones"
    private let allowListEnabledKey = "allowListEnabled"
    private let allowedDevicesKey = "allowedDevices"
    private let defaultStandbyKey = "defaultStandby"
    private let obsFeedForAllSlotsKey = "obsFeedForAllSlots"
    private let reopensOwnWindowsKey = "reopenOwnWindows"
    private let bezelsForAllSlotsKey = "bezelsForAllSlots"
    private let keepsMacAwakeKey = "keepMacAwake"
    private let stageLayoutKey = "stageLayout"
    static let bounceKey = "bounceOnDisconnect"
    /// Shows Mirror Wall's icon in the menu bar, and keeps the app running (and mirroring) when
    /// the wall's window is closed. On by default.
    static let menuBarIconKey = "showMenuBarIcon"

    private var popOutWindows: [Int: PopOutWindow] = [:]
    private var stageWindow: StageWindow?
    /// Watches each slot's state, to send its standby picture to OBS when the phone leaves.
    private var standbyWatchers: [Int: AnyCancellable] = [:]
    /// Watches each slot's state and recording, to keep the Mac awake while any is in use.
    private var awakeWatchers: [Int: AnyCancellable] = [:]
    /// Puts a phone on the Stage as it connects (see watchForStage).
    private var stageWatchers: [Int: AnyCancellable] = [:]
    /// Slots with a phone connected, so a phone only goes on the Stage when it first connects and
    /// taking it off mid-demo sticks until it reconnects.
    private var connectedSlotIDs: Set<Int> = []
    /// True while a phone is connecting, mirroring or has its screen off, or a slot is recording.
    @Published private(set) var anySlotInUse = false
    /// Held while the Mac is being kept awake.
    private var awakeActivity: NSObjectProtocol?
    /// Set while quitting, so windows closing then are still reopened next launch.
    private var terminating = false

    static let maxSlots = 8

    init() {
        defaults.register(defaults: [Self.bounceKey: true, popOutSizeLockedKey: true, keepsMacAwakeKey: true, Self.menuBarIconKey: true])
        let saved = defaults.data(forKey: slotsKey).flatMap { try? JSONDecoder().decode([SlotConfig].self, from: $0) }
        var configs = saved ?? (1...2).map { SlotConfig(id: $0, name: SlotConfig.defaultName(for: $0, computerName: Self.computerName)) }
        // Slots still on a name earlier versions gave them take the current default, so two Macs'
        // slots can be told apart on the phone.
        for index in configs.indices where SlotConfig.isOldDefaultName(configs[index].name, id: configs[index].id, computerName: Self.computerName) {
            configs[index].name = SlotConfig.defaultName(for: configs[index].id, computerName: Self.computerName)
        }
        let savedRate = defaults.integer(forKey: maxFrameRateKey)
        maxFrameRate = SlotConfig.frameRates.contains(savedRate) ? savedRate : 30
        smoothMotion = defaults.bool(forKey: smoothMotionKey)
        sharpPicture = defaults.bool(forKey: sharpPictureKey)
        popOutSize = defaults.string(forKey: popOutSizeKey).flatMap(PopOutSize.init(rawValue:)) ?? .medium
        popOutSizeLocked = defaults.bool(forKey: popOutSizeLockedKey)
        knownPhones = defaults.data(forKey: knownPhonesKey).flatMap { try? JSONDecoder().decode([KnownPhone].self, from: $0) } ?? []
        allowListEnabled = defaults.bool(forKey: allowListEnabledKey)
        allowedDeviceIDs = Set(defaults.stringArray(forKey: allowedDevicesKey) ?? [])
        defaultStandby = defaults.data(forKey: defaultStandbyKey).flatMap { try? JSONDecoder().decode(StandbyPicture.self, from: $0) } ?? .message
        obsFeedForAllSlots = defaults.bool(forKey: obsFeedForAllSlotsKey)
        reopensOwnWindows = defaults.bool(forKey: reopensOwnWindowsKey)
        bezelsForAllSlots = defaults.bool(forKey: bezelsForAllSlotsKey)
        keepsMacAwake = defaults.bool(forKey: keepsMacAwakeKey)
        stageLayout = defaults.string(forKey: stageLayoutKey).flatMap(StageLayout.init(rawValue:)) ?? .sideBySide
        slots = configs.map { Slot(config: $0) }
        uxplayURL = Self.locateUxPlay(savedPath: defaults.string(forKey: uxplayPathKey))
        slots.forEach(watch)
        if saved != nil { save() }
        updateWindowTitles() // also starts the OBS feeds that were on
    }

    /// The Mac's name, as set in System Settings › General › Sharing.
    nonisolated static var computerName: String? {
        Host.current().localizedName
    }

    /// Saves a slot's config when it learns a new phone's name, and retitles windows to match.
    private func watch(_ slot: Slot) {
        slot.maxFrameRate = maxFrameRate
        slot.renderer.smoothMotion = smoothMotion
        slot.sharpPicture = sharpPicture
        slot.allowedDevices = allowedDevices
        slot.showsBezel = slot.config.bezel ?? bezelsForAllSlots
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
        // Deferred to the next turn of the main queue, because @Published sends before the
        // property changes.
        standbyWatchers[slot.id] = slot.$state.combineLatest(slot.$hasPicture)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak slot] _ in
                MainActor.assumeIsolated {
                    if let self, let slot { self.sendStandbyToOBS(slot) }
                }
            }
        awakeWatchers[slot.id] = slot.$state.combineLatest(slot.$recordingSince)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateKeepAwake() }
            }
        watchForStage(slot)
    }

    /// Stage-first: a phone that connects always goes on the Stage. It can still be taken off from
    /// the Stage's control bar; that holds until the phone disconnects and connects again.
    private func watchForStage(_ slot: Slot) {
        stageWatchers[slot.id] = slot.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak slot] _ in
                MainActor.assumeIsolated {
                    guard let self, let slot else { return }
                    let connected = slot.state == .connecting || slot.state == .live || slot.state == .paused
                    if connected, !self.connectedSlotIDs.contains(slot.id) {
                        self.connectedSlotIDs.insert(slot.id)
                        if !slot.showsOnStage { self.setShowsOnStage(slot, on: true) }
                    } else if !connected {
                        self.connectedSlotIDs.remove(slot.id)
                    }
                }
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
        SaveFolders.showInFinder(.recordings)
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
        slot.setOBSFeed(false, name: "")
        slot.stopRecording()
        slot.stop()
        StandbyPictures.discard(slot.config.standby)
        standbyWatchers[slot.id] = nil
        awakeWatchers[slot.id] = nil
        stageWatchers[slot.id] = nil
        connectedSlotIDs.remove(slot.id)
        slots.removeAll { $0 === slot }
        save()
        updateWindowTitles()
        updateKeepAwake()
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

    /// Turns Smoother Motion on or off for every slot. Takes effect at once; nothing restarts.
    func setSmoothMotion(_ on: Bool) {
        guard on != smoothMotion else { return }
        smoothMotion = on
        defaults.set(on, forKey: smoothMotionKey)
        for slot in slots { slot.renderer.smoothMotion = on }
    }

    /// Turns the sharper picture on or off. Each receiver restarts to apply it, so phones
    /// mirroring now have to reconnect.
    func setSharpPicture(_ on: Bool) {
        guard on != sharpPicture else { return }
        sharpPicture = on
        defaults.set(on, forKey: sharpPictureKey)
        for slot in slots {
            slot.sharpPicture = on
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
        sendStandbyToOBS(slot)
    }

    func chooseStandbyImage(for slot: Slot) {
        guard let picture = StandbyPictures.choose(label: "slot-\(slot.id)") else { return }
        setStandby(slot, picture)
    }

    /// What `slot` shows while no phone is mirroring: its own choice, or the one for all slots.
    func standby(for slot: Slot) -> StandbyPicture {
        slot.config.standby ?? defaultStandby
    }

    func setDefaultStandby(_ standby: StandbyPicture) {
        let old = defaultStandby
        guard standby != old else { return }
        defaultStandby = standby
        if let data = try? JSONEncoder().encode(standby) { defaults.set(data, forKey: defaultStandbyKey) }
        StandbyPictures.discard(old)
        slots.forEach(sendStandbyToOBS)
    }

    func chooseDefaultStandbyImage() {
        guard let picture = StandbyPictures.choose(label: "all-slots") else { return }
        setDefaultStandby(picture)
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

    func setPopOutSizeLocked(_ locked: Bool) {
        guard locked != popOutSizeLocked else { return }
        popOutSizeLocked = locked
        defaults.set(locked, forKey: popOutSizeLockedKey)
        popOutWindows.values.forEach { $0.locked = locked }
    }

    func openOwnWindow(_ slot: Slot) {
        if let existing = popOutWindows[slot.id] {
            existing.show()
            return
        }
        let window = PopOutWindow(slot: slot, store: self, title: windowTitles[slot.id] ?? "MacMirror-\(slot.name)", size: popOutSize, locked: popOutSizeLocked)
        let id = slot.id
        window.onClose = { [weak self] in self?.ownWindowClosed(id) }
        popOutWindows[id] = window
        poppedOutIDs.insert(id)
        window.show()
        savePoppedOut()
    }

    // MARK: - Stage

    func showStage() {
        if stageWindow == nil {
            let window = StageWindow(store: self)
            window.onClose = { [weak self] in self?.stageWindow = nil }
            stageWindow = window
        }
        stageWindow?.show()
    }

    func setShowsOnStage(_ slot: Slot, on: Bool) {
        slot.setShowsOnStage(on)
        save()
    }

    func setStageLayout(_ layout: StageLayout) {
        guard layout != stageLayout else { return }
        stageLayout = layout
        defaults.set(layout.rawValue, forKey: stageLayoutKey)
    }

    func closeOwnWindow(_ slot: Slot) {
        popOutWindows[slot.id]?.close()
    }

    /// Reopens the windows that were open when the app last quit, if that's turned on.
    func restoreOwnWindows() {
        guard reopensOwnWindows else { return }
        let ids = Set(defaults.array(forKey: poppedOutKey) as? [Int] ?? [])
        slots.filter { ids.contains($0.id) }.forEach(openOwnWindow)
    }

    func prepareForTermination() {
        terminating = true
    }

    private var windowTitles: [Int: String] {
        SlotConfig.windowTitles(for: slots.map(\.config))
    }

    /// Keeps the slots' own windows and OBS feeds named after their phones. A feed goes by the
    /// same name as the window, so an OBS scene can switch between the two without renaming.
    private func updateWindowTitles() {
        let titles = windowTitles
        for (id, window) in popOutWindows {
            if let title = titles[id], window.window.title != title { window.window.title = title }
        }
        for slot in slots where wantsOBSFeed(slot) {
            if let title = titles[slot.id], slot.obsFeedName != title { slot.setOBSFeed(true, name: title) }
        }
    }

    /// Whether a slot should send to OBS: its own choice, or the setting for all slots.
    private func wantsOBSFeed(_ slot: Slot) -> Bool {
        slot.config.obsFeed ?? obsFeedForAllSlots
    }

    /// Turns a slot's OBS feed (Syphon) on or off. Remembered per slot.
    func setOBSFeed(_ slot: Slot, on: Bool) {
        let started = slot.setOBSFeed(on, name: windowTitles[slot.id] ?? "MacMirror-\(slot.name)")
        slot.rememberOBSFeed(started ? (on == obsFeedForAllSlots ? nil : on) : nil)
        save()
        sendStandbyToOBS(slot)
    }

    /// Turns every slot's OBS feed on or off, including slots added later. A slot's own menu can
    /// still change it afterwards.
    func setOBSFeedForAllSlots(_ on: Bool) {
        guard on != obsFeedForAllSlots else { return }
        obsFeedForAllSlots = on
        defaults.set(on, forKey: obsFeedForAllSlotsKey)
        for slot in slots {
            slot.rememberOBSFeed(nil)
            slot.setOBSFeed(on, name: windowTitles[slot.id] ?? "MacMirror-\(slot.name)")
            sendStandbyToOBS(slot)
        }
        save()
    }

    func setReopensOwnWindows(_ on: Bool) {
        reopensOwnWindows = on
        defaults.set(on, forKey: reopensOwnWindowsKey)
    }

    // MARK: - Phone bezels

    /// Turns a slot's phone frame on or off. Remembered per slot, unless it matches the setting
    /// for all slots.
    func setBezel(_ slot: Slot, on: Bool) {
        slot.rememberBezel(on == bezelsForAllSlots ? nil : on)
        slot.showsBezel = on
        save()
    }

    /// Turns every slot's phone frame on or off, including slots added later. A slot's own menu
    /// can still change it afterwards.
    func setBezelsForAllSlots(_ on: Bool) {
        guard on != bezelsForAllSlots else { return }
        bezelsForAllSlots = on
        defaults.set(on, forKey: bezelsForAllSlotsKey)
        for slot in slots {
            slot.rememberBezel(nil)
            slot.showsBezel = on
        }
        save()
    }

    /// Puts the phone frame around a slot's OBS feed, or takes it off. Remembered per slot.
    func setFramesOBSFeed(_ slot: Slot, on: Bool) {
        slot.setFramesOBSFeed(on)
        save()
        sendStandbyToOBS(slot)
    }

    // MARK: - Keeping the Mac awake

    func setKeepsMacAwake(_ on: Bool) {
        guard on != keepsMacAwake else { return }
        keepsMacAwake = on
        defaults.set(on, forKey: keepsMacAwakeKey)
        updateKeepAwake()
    }

    /// True while a phone is connecting, mirroring or has its screen off, or a slot is recording.
    var isAnySlotInUse: Bool {
        slots.contains { slot in
            slot.recordingSince != nil || slot.state == .connecting || slot.state == .live || slot.state == .paused
        }
    }

    /// Stops the Mac (and its screen) going to sleep on its own while a slot is in use, and lets
    /// it again once none is. Closing the lid or choosing Sleep still works.
    private func updateKeepAwake() {
        let inUse = isAnySlotInUse
        if inUse != anySlotInUse { anySlotInUse = inUse }
        let wanted = keepsMacAwake && inUse
        if wanted, awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: "A phone is mirroring to Mirror Wall"
            )
        } else if !wanted, let activity = awakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            awakeActivity = nil
        }
    }

    /// While no phone is mirroring, sends the slot's standby picture down its OBS feed, drawn as
    /// its own window draws it and at the size of the phone's last picture (an iPhone-shaped
    /// 1179×2556 before any phone has connected). Live pictures replace it when a phone returns.
    func sendStandbyToOBS(_ slot: Slot) {
        guard slot.sendsToOBS, !slot.showsPicture else { return }
        let size = slot.lastPictureSize ?? CGSize(width: 1179, height: 2556)
        // Drawn at a third of the size and scaled up 3×, so the waiting message is about as big
        // relative to the picture as in the slot's own window.
        let scale: CGFloat = 3
        let content = ZStack {
            Color.black
            StandbyContent(standby: standby(for: slot), slot: slot)
        }
        .frame(width: size.width / scale, height: size.height / scale)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.cgImage, let buffer = makePixelBuffer(from: image) else { return }
        slot.sendToOBS(buffer)
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
