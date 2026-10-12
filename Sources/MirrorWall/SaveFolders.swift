import AppKit

/// Where recordings and screenshots are saved: ~/Documents/MirrorWall/Recordings and
/// ~/Documents/MirrorWall/Screenshots unless another folder is chosen in Settings. A chosen folder
/// that can't be reached (an unplugged drive) falls back to the default.
enum SaveFolders {
    enum Kind {
        case recordings, screenshots

        /// The UserDefaults key holding a chosen folder's path.
        var key: String {
            switch self {
            case .recordings: return "recordingsFolder"
            case .screenshots: return "screenshotsFolder"
            }
        }

        var defaultFolder: URL {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
            let base = documents.appendingPathComponent("MirrorWall")
            switch self {
            case .recordings: return base.appendingPathComponent("Recordings")
            case .screenshots: return base.appendingPathComponent("Screenshots")
            }
        }
    }

    static var recordings: URL { folder(.recordings) }
    static var screenshots: URL { folder(.screenshots) }

    static func folder(_ kind: Kind) -> URL {
        if let path = UserDefaults.standard.string(forKey: kind.key), !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
                return url
            }
        }
        return kind.defaultFolder
    }

    /// Asks for a folder to save to from now on.
    @MainActor
    static func choose(_ kind: Kind) {
        let panel = NSOpenPanel()
        panel.title = kind == .recordings ? "Save recordings to" : "Save screenshots to"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder(kind)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: kind.key)
    }

    static func reset(_ kind: Kind) {
        UserDefaults.standard.removeObject(forKey: kind.key)
    }

    static func showInFinder(_ kind: Kind) {
        let url = folder(kind)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
