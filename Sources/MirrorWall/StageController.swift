import AppKit
import AVFoundation
import Combine
import MirrorCore
import ScreenCaptureKit
import SwiftUI

/// What's on the Stage and where: phones, Mac windows and cameras, placed by one of the automatic
/// layouts or freely by dragging, and the layouts saved under names. The Stage window draws what
/// this says (StageWindow.swift); the sources behind the pictures are in StageSources.swift.
///
/// A phone is on the Stage when its slot says so (`Slot.showsOnStage`: the slot's menu, the
/// Stage's chips, View › Phones on Stage), and this keeps one item per such phone, so those
/// switches work in a free arrangement too.
@MainActor
final class StageController: ObservableObject {
    /// What's on the Stage now.
    @Published private(set) var arrangement: StageArrangement
    @Published private(set) var savedLayouts: [SavedStageLayout]
    /// The saved layout the Stage was last set to, which `isModified` compares against.
    @Published private(set) var currentLayoutID: UUID?
    /// Layout editing: pictures can be dragged and resized.
    @Published var isEditing = false
    @Published var selectedID: UUID?
    /// Counts cameras being plugged in and out, so menus that list them are drawn again.
    @Published private(set) var deviceRevision = 0

    /// The Stage's size in points, as its window last drew it, for placing new items.
    var areaSize = CGSize(width: 1600, height: 900)

    private weak var store: SlotStore?
    private var windowSources: [String: StageWindowSource] = [:]
    private var cameraSources: [String: StageCameraSource] = [:]
    private var slotsWatcher: AnyCancellable?
    private var slotWatchers: [AnyCancellable] = []
    private var sourceWatchers: [String: AnyCancellable] = [:]
    private var restoredPhones = false
    /// Whether the Stage window is open, which is when cameras and window captures run.
    private var isVisible = false

    private let defaults = UserDefaults.standard
    private static let arrangementKey = "stageArrangement"
    private static let savedLayoutsKey = "stageSavedLayouts"
    private static let currentLayoutKey = "stageCurrentLayout"
    /// Where Mirror Wall before layouts kept the automatic layout.
    private static let legacyLayoutKey = "stageLayout"

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.arrangementKey), let loaded = try? JSONDecoder().decode(StageArrangement.self, from: data) {
            arrangement = loaded
        } else {
            arrangement = StageArrangement(automatic: defaults.string(forKey: Self.legacyLayoutKey).flatMap(StageLayout.init(rawValue:)) ?? .sideBySide)
        }
        savedLayouts = defaults.data(forKey: Self.savedLayoutsKey).flatMap { try? JSONDecoder().decode([SavedStageLayout].self, from: $0) } ?? []
        currentLayoutID = defaults.string(forKey: Self.currentLayoutKey).flatMap(UUID.init(uuidString:))
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.camerasChanged() }
            }
        }
    }

    /// Starts following the slots, which decide which phones are on the Stage.
    func attach(_ store: SlotStore) {
        self.store = store
        // Deferred to the next turn of the main queue, because @Published sends before the
        // property changes.
        slotsWatcher = store.$slots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] slots in
                MainActor.assumeIsolated { self?.slotsChanged(slots) }
            }
    }

    // MARK: - Phones

    private func slotsChanged(_ slots: [Slot]) {
        slotWatchers = slots.map { slot in
            slot.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.slotChanged() }
                }
        }
        if !restoredPhones {
            restoredPhones = true
            restorePhones()
        }
        syncPhones()
        objectWillChange.send()
    }

    private func slotChanged() {
        syncPhones()
        objectWillChange.send()
    }

    /// At launch, a free arrangement brings its phones back onto the Stage, wherever they were
    /// placed. (An automatic one follows each slot's own setting, as before layouts.)
    private func restorePhones() {
        guard arrangement.isFree, let store else { return }
        let wanted = Set(arrangement.items.filter { $0.kind == .phone }.map(\.key))
        for slot in store.slots where wanted.contains(String(slot.id)) && !slot.showsOnStage {
            store.setShowsOnStage(slot, on: true)
        }
    }

    /// Makes the phone items match the slots that are on the Stage: one each, in the order they
    /// were put on, and none for a slot that's off the Stage or gone.
    func syncPhones() {
        guard let store else { return }
        var items = arrangement.items
        var changed = false
        let before = items.count
        items.removeAll { item in
            item.kind == .phone && !(store.slots.first { String($0.id) == item.key }?.showsOnStage ?? false)
        }
        if items.count != before { changed = true }
        for slot in store.slots where slot.showsOnStage {
            let key = String(slot.id)
            if let index = items.firstIndex(where: { $0.kind == .phone && $0.key == key }) {
                if items[index].label != slot.name {
                    items[index].label = slot.name
                    changed = true
                }
            } else {
                items.append(StageItem(kind: .phone, key: key, label: slot.name, frame: arrangement.isFree ? stageDefaultFrame(index: items.count) : nil))
                changed = true
            }
        }
        guard changed else { return }
        arrangement.items = items
        if let selectedID, !items.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        persist()
    }

    func slot(for item: StageItem) -> Slot? {
        store?.slots.first { String($0.id) == item.key }
    }

    // MARK: - What each item shows

    func windowSource(for item: StageItem) -> StageWindowSource? {
        windowSources[item.key]
    }

    func cameraSource(for item: StageItem) -> StageCameraSource? {
        cameraSources[item.key]
    }

    /// Whether there's a picture to draw for this item now.
    func hasPicture(_ item: StageItem) -> Bool {
        switch item.kind {
        case .phone:
            return slot(for: item)?.showsPicture ?? false
        case .window:
            guard let source = windowSources[item.key], source.pixelSize.width > 0 else { return false }
            if case .stopped = source.status { return false }
            return true
        case .camera:
            guard let source = cameraSources[item.key] else { return false }
            return source.status == .live && source.pixelSize.width > 0
        }
    }

    /// The shape of the item's picture (width over height) as the Stage draws it, a phone's with
    /// its frame if it has one; nil while there's no picture.
    func aspect(of item: StageItem) -> Double? {
        guard hasPicture(item) else { return nil }
        switch item.kind {
        case .phone:
            guard let phone = slot(for: item) else { return nil }
            let size = phoneSize(phone)
            return size.width / size.height
        case .window:
            guard let size = windowSources[item.key]?.pixelSize, size.height > 0 else { return nil }
            return Double(size.width / size.height)
        case .camera:
            guard let size = cameraSources[item.key]?.pixelSize, size.height > 0 else { return nil }
            return Double(size.width / size.height)
        }
    }

    /// A phone's size in the units of `stageFrames`: its true size relative to other phones.
    private func phoneSize(_ slot: Slot) -> (width: Double, height: Double) {
        let picture = slot.videoSize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? CGSize(width: 9, height: 19.5)
        return stagePhoneSize(modelCode: slot.config.lastPhoneModel, pictureWidth: picture.width, pictureHeight: picture.height, bezel: slot.showsBezel)
    }

    // MARK: - Placing items

    /// One item as the Stage draws it.
    struct PlacedItem: Identifiable {
        let item: StageItem
        /// The picture's place on the Stage, in points, y pointing down.
        let rect: StageRect
        let hasPicture: Bool

        var id: UUID { item.id }
    }

    /// The items to draw on a Stage of this size, back to front. A phone that isn't mirroring
    /// isn't drawn, except while editing a free arrangement, where it holds its place.
    func placedItems(area: CGSize) -> [PlacedItem] {
        guard area.width > 0, area.height > 0 else { return [] }
        let holdsPlaces = arrangement.isFree && isEditing
        var shown: [(item: StageItem, picture: Bool, aspect: Double?)] = []
        for item in arrangement.items {
            let picture = hasPicture(item)
            if item.kind == .phone, !picture, !holdsPlaces { continue }
            shown.append((item, picture, aspect(of: item)))
        }

        if let layout = arrangement.automatic {
            let sizes: [(width: Double, height: Double)] = shown.map { entry in
                if entry.item.kind == .phone, entry.picture, let phone = slot(for: entry.item) { return phoneSize(phone) }
                return stageSourceSize(aspect: entry.aspect ?? 16.0 / 9.0)
            }
            let frames = stageFrames(sizes: sizes, layout: layout, areaWidth: area.width, areaHeight: area.height)
            return zip(shown, frames).map { PlacedItem(item: $0.item, rect: $1, hasPicture: $0.picture) }
        }

        var placed: [PlacedItem] = []
        for (index, entry) in shown.enumerated() {
            let box = (entry.item.frame ?? stageDefaultFrame(index: index)).scaled(x: area.width, y: area.height)
            let rect = entry.aspect.map { stageFit(aspect: $0, in: box) } ?? box
            placed.append(PlacedItem(item: entry.item, rect: rect, hasPicture: entry.picture))
        }
        return placed
    }

    // MARK: - Choosing the arrangement

    func setAutomatic(_ layout: StageLayout) {
        guard arrangement.automatic != layout else { return }
        arrangement.automatic = layout
        persist()
    }

    /// Free placement: each picture stays where it is now, and can be dragged anywhere.
    func makeFree() {
        beginFreeArrangement(area: areaSize)
    }

    /// Switches to a free arrangement, keeping every picture where it is now.
    func beginFreeArrangement(area: CGSize) {
        guard arrangement.automatic != nil, area.width > 0, area.height > 0 else { return }
        var items = arrangement.items
        for entry in placedItems(area: area) {
            if let index = items.firstIndex(where: { $0.id == entry.item.id }) {
                items[index].frame = entry.rect.scaled(x: 1 / area.width, y: 1 / area.height)
            }
        }
        // What isn't on the Stage now (a phone that isn't mirroring) gets a box of its own.
        for index in items.indices where items[index].frame == nil {
            items[index].frame = stageDefaultFrame(index: index)
        }
        arrangement.items = items
        arrangement.automatic = nil
        persist()
    }

    func toggleEditing() {
        isEditing.toggle()
        if !isEditing { selectedID = nil }
    }

    func select(_ id: UUID?) {
        if selectedID != id { selectedID = id }
    }

    /// Puts a picture, as it's drawn, at this place on a Stage of this size. Call `commitChange`
    /// when the dragging is over.
    func setPicture(_ id: UUID, rect: StageRect, area: CGSize) {
        guard area.width > 0, area.height > 0, let index = arrangement.items.firstIndex(where: { $0.id == id }) else { return }
        arrangement.items[index].frame = rect.scaled(x: 1 / area.width, y: 1 / area.height)
    }

    func commitChange() {
        persist()
    }

    /// Moves an item one place earlier (-1) or later (+1) among those on view: left or right in
    /// an automatic layout, behind or in front in a free one.
    func moveItem(_ id: UUID, by step: Int) {
        guard step != 0, var index = arrangement.items.firstIndex(where: { $0.id == id }) else { return }
        var target = index + step
        while arrangement.items.indices.contains(target), !isOnView(arrangement.items[target]) { target += step }
        guard arrangement.items.indices.contains(target) else { return }
        var items = arrangement.items
        let moving = items.remove(at: index)
        index = target
        items.insert(moving, at: index)
        arrangement.items = items
        persist()
    }

    func canMoveItem(_ id: UUID, by step: Int) -> Bool {
        guard let index = arrangement.items.firstIndex(where: { $0.id == id }) else { return false }
        var target = index + step
        while arrangement.items.indices.contains(target), !isOnView(arrangement.items[target]) { target += step }
        return arrangement.items.indices.contains(target)
    }

    /// Phones that aren't mirroring have nothing to draw, so moving past them changes nothing.
    private func isOnView(_ item: StageItem) -> Bool {
        item.kind != .phone || hasPicture(item)
    }

    // MARK: - Adding and removing

    private func newFrame() -> StageRect? {
        arrangement.isFree ? stageDefaultFrame(index: arrangement.items.count) : nil
    }

    /// Puts a phone's slot on the Stage, where it waits for the phone.
    func addPhone(_ slot: Slot) {
        store?.setShowsOnStage(slot, on: true)
        syncPhones()
    }

    /// Opens macOS's window picker; the chosen window goes on the Stage.
    func addWindow() {
        WindowFeedStore.shared.pickWindowForStage { [weak self] filter, app, title, windowID in
            self?.windowPicked(filter, app: app, title: title, windowID: windowID, replacing: nil)
        }
    }

    /// Picks the window again for an item, such as one that was closed or restored from a saved
    /// layout (a window can't be remembered from one launch to the next).
    func chooseWindow(for item: StageItem) {
        WindowFeedStore.shared.pickWindowForStage { [weak self] filter, app, title, windowID in
            self?.windowPicked(filter, app: app, title: title, windowID: windowID, replacing: item.id)
        }
    }

    private func windowPicked(_ filter: SCContentFilter, app: String?, title: String?, windowID: CGWindowID?, replacing: UUID?) {
        let taken = arrangement.items.filter { $0.kind == .window && $0.id != replacing }.map(\.key)
        let key = WindowFeedName.unique(WindowFeedName.make(app: app, title: title), among: taken)
        let source = StageWindowSource(filter: filter, key: key, appName: app, windowID: windowID)
        var items = arrangement.items
        let id: UUID
        var oldKey: String?
        if let replacing, let index = items.firstIndex(where: { $0.id == replacing }) {
            id = replacing
            oldKey = items[index].key
            items[index].key = key
            items[index].label = key
        } else {
            let item = StageItem(kind: .window, key: key, label: key, frame: newFrame())
            id = item.id
            items.append(item)
        }
        windowSources[key]?.stop()
        windowSources[key] = source
        watch(source: source, as: "window " + key)
        if let oldKey, oldKey != key, !items.contains(where: { $0.kind == .window && $0.key == oldKey }) {
            // The window it replaces isn't kept.
            windowSources[oldKey]?.stop()
            windowSources[oldKey] = nil
            sourceWatchers["window " + oldKey] = nil
        }
        arrangement.items = items
        selectedID = id
        reconcileSources()
        persist()
    }

    /// Puts a camera on the Stage.
    func addCamera(_ device: AVCaptureDevice) {
        let item = StageItem(kind: .camera, key: device.uniqueID, label: device.localizedName, frame: newFrame())
        arrangement.items.append(item)
        selectedID = item.id
        reconcileSources()
        persist()
    }

    func chooseCamera(_ device: AVCaptureDevice, for item: StageItem) {
        guard let index = arrangement.items.firstIndex(where: { $0.id == item.id }) else { return }
        arrangement.items[index].key = device.uniqueID
        arrangement.items[index].label = device.localizedName
        reconcileSources()
        persist()
    }

    /// Takes an item off the Stage. A phone's slot stays; it's just off the Stage.
    func remove(_ item: StageItem) {
        if item.kind == .phone, let phone = slot(for: item) {
            store?.setShowsOnStage(phone, on: false)
        }
        arrangement.items.removeAll { $0.id == item.id }
        if selectedID == item.id { selectedID = nil }
        if item.kind == .window, !arrangement.items.contains(where: { $0.kind == .window && $0.key == item.key }) {
            // Taken off on purpose: the window isn't kept for a layout to bring back.
            windowSources[item.key]?.stop()
            windowSources[item.key] = nil
            sourceWatchers["window " + item.key] = nil
        }
        reconcileSources()
        persist()
        syncPhones()
    }

    // MARK: - Sources

    private func watch(source: StageWindowSource, as name: String) {
        sourceWatchers[name] = source.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
    }

    private func watch(source: StageCameraSource, as name: String) {
        sourceWatchers[name] = source.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
    }

    /// Makes the running sources match the items: a camera for each camera item, and while the
    /// Stage is open, every window and camera in use running, the rest stopped.
    private func reconcileSources() {
        let cameraKeys = Set(arrangement.items.filter { $0.kind == .camera }.map(\.key))
        for key in cameraKeys where cameraSources[key] == nil {
            let label = arrangement.items.first { $0.kind == .camera && $0.key == key }?.label ?? "Camera"
            let source = StageCameraSource(deviceID: key, name: label)
            cameraSources[key] = source
            watch(source: source, as: "camera " + key)
        }
        for key in Array(cameraSources.keys) where !cameraKeys.contains(key) {
            cameraSources[key]?.stop()
            cameraSources[key] = nil
            sourceWatchers["camera " + key] = nil
        }
        for source in cameraSources.values {
            if isVisible { source.start() } else { source.stop() }
        }

        let windowKeys = Set(arrangement.items.filter { $0.kind == .window }.map(\.key))
        for (key, source) in windowSources {
            if isVisible, windowKeys.contains(key) { source.start() } else { source.stop() }
        }
    }

    /// The Stage window opened: cameras and windows start.
    func resume() {
        isVisible = true
        reconcileSources()
    }

    /// The Stage window closed: cameras (and their lights) and window captures stop, and start
    /// again when it opens. A chosen window stays chosen.
    func suspend() {
        isVisible = false
        isEditing = false
        selectedID = nil
        reconcileSources()
    }

    private func camerasChanged() {
        deviceRevision += 1
        for source in cameraSources.values { source.devicesChanged() }
    }

    /// The cameras this Mac has, for the Add menu.
    var cameraDevices: [AVCaptureDevice] {
        _ = deviceRevision
        return StageCameraSource.devices()
    }

    // MARK: - Saved layouts

    var currentLayout: SavedStageLayout? {
        currentLayoutID.flatMap { id in savedLayouts.first { $0.id == id } }
    }

    /// Whether the Stage differs from the saved layout it was set to.
    var isModified: Bool {
        currentLayout.map { $0.arrangement != arrangement } ?? false
    }

    /// Sets the Stage to a saved layout: its items where it put them, and its phones on the
    /// Stage (others off).
    func apply(_ layout: SavedStageLayout) {
        arrangement = layout.arrangement
        currentLayoutID = layout.id
        selectedID = nil
        if let store {
            let wanted = Set(arrangement.items.filter { $0.kind == .phone }.map(\.key))
            for slot in store.slots {
                let shouldBeOn = wanted.contains(String(slot.id))
                if slot.showsOnStage != shouldBeOn { store.setShowsOnStage(slot, on: shouldBeOn) }
            }
        }
        reconcileSources()
        syncPhones()
        persist()
    }

    private func uniqueName(_ name: String, excluding id: UUID? = nil) -> String {
        WindowFeedName.unique(name, among: savedLayouts.filter { $0.id != id }.map(\.name))
    }

    func promptSaveAs() {
        let suggestion = uniqueName(arrangement.items.contains { $0.kind == .camera } ? "Camera Layout" : "My Layout")
        guard let name = StagePrompt.ask(title: "Save this layout", message: "Name it so you can bring it back from the Layout menu.", initial: suggestion, button: "Save") else { return }
        let layout = SavedStageLayout(name: uniqueName(name), arrangement: arrangement)
        savedLayouts.append(layout)
        currentLayoutID = layout.id
        persistSavedLayouts()
        persist()
    }

    /// Saves what's on the Stage over the layout it started from.
    func updateCurrentLayout() {
        guard let index = savedLayouts.firstIndex(where: { $0.id == currentLayoutID }) else { return }
        savedLayouts[index].arrangement = arrangement
        persistSavedLayouts()
        objectWillChange.send()
    }

    func promptRename() {
        guard let current = currentLayout, let index = savedLayouts.firstIndex(where: { $0.id == current.id }),
              let name = StagePrompt.ask(title: "Rename “\(current.name)”", message: "", initial: current.name, button: "Rename") else { return }
        savedLayouts[index].name = uniqueName(name, excluding: current.id)
        persistSavedLayouts()
    }

    func promptDelete() {
        guard let current = currentLayout,
              StagePrompt.confirm(title: "Delete “\(current.name)”?", message: "The Stage keeps what's on it now; only the saved layout goes.", button: "Delete") else { return }
        savedLayouts.removeAll { $0.id == current.id }
        currentLayoutID = nil
        persistSavedLayouts()
        persist()
    }

    // MARK: - Saving

    private func persist() {
        if let data = try? JSONEncoder().encode(arrangement) { defaults.set(data, forKey: Self.arrangementKey) }
        if let id = currentLayoutID { defaults.set(id.uuidString, forKey: Self.currentLayoutKey) } else { defaults.removeObject(forKey: Self.currentLayoutKey) }
    }

    private func persistSavedLayouts() {
        if let data = try? JSONEncoder().encode(savedLayouts) { defaults.set(data, forKey: Self.savedLayoutsKey) }
    }
}

/// The small questions the Stage asks: a layout's name, and whether to delete one.
@MainActor
enum StagePrompt {
    static func ask(title: String, message: String, initial: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func confirm(title: String, message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
