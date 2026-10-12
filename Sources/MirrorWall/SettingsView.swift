import MirrorCore
import SwiftUI

/// Mirror Wall › Settings: who can mirror, the standby picture, and alerts.
struct SettingsView: View {
    @EnvironmentObject private var store: SlotStore
    @AppStorage(SlotStore.bounceKey) private var bounceOnDisconnect = true
    // Read so the rows update when a folder is chosen; SaveFolders reads the same keys.
    @AppStorage(SaveFolders.Kind.recordings.key) private var recordingsPath = ""
    @AppStorage(SaveFolders.Kind.screenshots.key) private var screenshotsPath = ""

    var body: some View {
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
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560)
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
