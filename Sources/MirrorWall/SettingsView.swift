import MirrorCore
import SwiftUI

/// Mirror Wall › Settings, in tabs: General (staying awake, the menu bar icon, save folders,
/// alerts), Wall (standby picture, bezels), OBS, and Phones (who can mirror).
struct SettingsView: View {
    @EnvironmentObject private var store: SlotStore
    @AppStorage(SlotStore.bounceKey) private var bounceOnDisconnect = true
    @AppStorage(SlotStore.menuBarIconKey) private var showsMenuBarIcon = true
    // Read so the rows update when a folder is chosen; SaveFolders reads the same keys.
    @AppStorage(SaveFolders.Kind.recordings.key) private var recordingsPath = ""
    @AppStorage(SaveFolders.Kind.screenshots.key) private var screenshotsPath = ""
    @AppStorage(Updater.channelKey) private var updateChannel = UpdateChannel.stable.rawValue

    var body: some View {
        TabView {
            Form {
                Section {
                    Toggle("Keep the Mac and its screen awake while a phone is mirroring", isOn: Binding(
                        get: { store.keepsMacAwake },
                        set: { store.setKeepsMacAwake($0) }
                    ))
                    Toggle("Show Mirror Wall in the menu bar", isOn: $showsMenuBarIcon)
                } header: {
                    Text("While mirroring")
                } footer: {
                    Text("Awake also covers recording, and ends once no phone is mirroring. Closing the lid or choosing Sleep still works. With the menu bar icon, closing the wall's window leaves Mirror Wall running, so phones keep mirroring to their own windows and OBS; quit from the icon's menu or with ⌘Q.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    folderRow("Recordings", .recordings, chosen: recordingsPath)
                    folderRow("Screenshots", .screenshots, chosen: screenshotsPath)
                } header: {
                    Text("Save to")
                }

                Section {
                    Toggle("Bounce the Dock icon when a phone disconnects", isOn: $bounceOnDisconnect)
                } header: {
                    Text("Alerts")
                } footer: {
                    Text("It keeps bouncing until you click Mirror Wall. macOS doesn't bounce it while Mirror Wall is the app in front.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Check for Update offers", selection: $updateChannel) {
                        Text("Releases (Stable)").tag(UpdateChannel.stable.rawValue)
                        Text("Releases and test builds (Beta)").tag(UpdateChannel.beta.rawValue)
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("With Beta, Check for Update lists every test build on offer and the newest release, to install whichever you choose. To go back, choose Stable, then Check for Update › Go Back, or pick the release from the Beta list. Mirror Wall only checks when you choose Mirror Wall › Check for Update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    Picker("Show", selection: Binding(
                        get: { StandbyChoice(store.defaultStandby) },
                        set: { choice in
                            switch choice {
                            case .allSlots, .message: store.setDefaultStandby(.message)
                            case .blank: store.setDefaultStandby(.blank)
                            case .image: DispatchQueue.main.async { store.chooseDefaultStandbyImage() }
                            }
                        }
                    )) {
                        Text("Waiting message").tag(StandbyChoice.message)
                        Text("Blank").tag(StandbyChoice.blank)
                        Text("Image…").tag(StandbyChoice.image)
                    }
                    if case .image = store.defaultStandby {
                        Button("Choose a Different Image…") { DispatchQueue.main.async { store.chooseDefaultStandbyImage() } }
                    }
                } header: {
                    Text("Standby picture")
                } footer: {
                    Text("What every slot, and its own window, shows while no phone is mirroring. A slot can have its own from its ⋯ menu. Images are scaled to fit, with black bars if the shape differs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Show a phone frame around every slot", isOn: Binding(
                        get: { store.bezelsForAllSlots },
                        set: { store.setBezelsForAllSlots($0) }
                    ))
                } header: {
                    Text("Phone bezels")
                } footer: {
                    Text("Draws the phone around its picture, on the wall and in the slot's own window, styled after the phone's model (home button, notch or Dynamic Island). A slot's ⋯ menu can still turn its own frame off or on. Recordings and screenshots stay unframed; the OBS (Syphon) feed does too unless a slot's ⋯ menu › Phone Bezel › In the OBS Feed is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }
            .formStyle(.grouped)
            .tabItem { Label("Wall", systemImage: "rectangle.grid.2x2") }

            Form {
                Section {
                    Toggle("Send every slot to OBS (Syphon)", isOn: Binding(
                        get: { store.obsFeedForAllSlots },
                        set: { store.setOBSFeedForAllSlots($0) }
                    ))
                    Toggle("Reopen slots' own windows when Mirror Wall starts", isOn: Binding(
                        get: { store.reopensOwnWindows },
                        set: { store.setReopensOwnWindows($0) }
                    ))
                } header: {
                    Text("OBS and own windows")
                } footer: {
                    Text("Sending to OBS applies to every slot, including ones you add later; a slot's ⋯ menu can still turn its own feed off or on. Own windows that were open when Mirror Wall quit stay closed unless the second switch is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }
            .formStyle(.grouped)
            .tabItem { Label("OBS", systemImage: "video") }

            Form {
                Section {
                    Toggle("Only allow the phones ticked below", isOn: Binding(
                        get: { store.allowListEnabled },
                        set: { store.setAllowListEnabled($0) }
                    ))
                    if store.knownPhones.isEmpty {
                        Text("Phones appear here once they've mirrored to this Mac.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.knownPhones) { phone in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { store.allowedDeviceIDs.contains(phone.deviceID) },
                                set: { store.setAllowed(phone, $0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(phone.name)
                                    Text("\(phone.model.isEmpty ? "iPhone" : phoneModelName(phone.model)), last mirrored \(phone.lastSeen.formatted(.relative(presentation: .named)))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!store.allowListEnabled)
                            Button("Forget") { store.forget(phone) }
                                .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("Who can mirror")
                } footer: {
                    Text("Off: any iPhone on your network can mirror to a slot. Changing this restarts the slots, so phones mirroring now will need to reconnect. If a ticked phone can't connect, turn this off, mirror once, and turn it back on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }
            .formStyle(.grouped)
            .tabItem { Label("Phones", systemImage: "iphone") }
        }
        .frame(width: 500, height: 480)
    }

    private func folderRow(_ title: String, _ kind: SaveFolders.Kind, chosen: String) -> some View {
        let url = chosen.isEmpty ? kind.defaultFolder : URL(fileURLWithPath: chosen)
        let missing = !chosen.isEmpty && SaveFolders.folder(kind) != url
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if missing {
                    Text("Not available right now, so saving to the default folder")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if !chosen.isEmpty {
                Button("Default") { SaveFolders.reset(kind) }
            }
            Button("Choose…") { DispatchQueue.main.async { SaveFolders.choose(kind) } }
        }
    }
}
