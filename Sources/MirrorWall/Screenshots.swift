import AppKit
import CoreImage
import MirrorCore
import UniformTypeIdentifiers

/// Saves a slot's current picture as a PNG at the stream's full size.
enum Screenshots {
    /// Documents › MirrorWall › Screenshots, or the folder chosen in Settings.
    static var folder: URL { SaveFolders.screenshots }

    private static let context = CIContext()

    /// Writes "iPhone 2026-10-12 09.41.07.png" (with " 2", " 3"… if taken within the same second).
    static func save(_ image: CVImageBuffer, baseName: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safe = baseName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let stem = "\(safe) \(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent(stem + ".png")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) \(number).png")
            number += 1
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        try context.writePNGRepresentation(of: CIImage(cvImageBuffer: image), to: url, format: .RGBA8, colorSpace: colorSpace)
        return url
    }

    static func showInFinder() {
        SaveFolders.showInFinder(.screenshots)
    }
}

/// Keeps copies of the images chosen as slots' standby pictures, so the originals can be moved
/// or deleted.
@MainActor
enum StandbyPictures {
    /// ~/Library/Application Support/Mirror Wall/Standby.
    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Mirror Wall/Standby")
    }

    private static var cache: [String: NSImage] = [:]

    /// Asks for an image and keeps a copy, its file name starting with `label`. Nil if
    /// cancelled or unreadable.
    static func choose(label: String) -> StandbyPicture? {
        let panel = NSOpenPanel()
        panel.title = "Choose a standby picture"
        panel.message = "Shown while no phone is mirroring. It's scaled to fit, with black bars if its shape differs."
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url, NSImage(contentsOf: source) != nil else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
            let fileName = "\(label)-\(UUID().uuidString).\(ext)"
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(fileName))
            return .image(fileName: fileName)
        } catch {
            NSSound.beep()
            return nil
        }
    }

    /// Deletes the copy behind a standby picture that's no longer used.
    static func discard(_ standby: StandbyPicture?) {
        guard case .image(let fileName)? = standby else { return }
        cache[fileName] = nil
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName))
    }

    static func image(named fileName: String) -> NSImage? {
        if let image = cache[fileName] { return image }
        let image = NSImage(contentsOf: folder.appendingPathComponent(fileName))
        cache[fileName] = image
        return image
    }
}
