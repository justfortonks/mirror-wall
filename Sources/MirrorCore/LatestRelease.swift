import Foundation

/// The newest Mirror Wall release on GitHub, as Check for Update sees it: its build number (the
/// commit count, as in the app's own version "0.N"), its "What's new" notes and the download for
/// this computer.
public struct LatestRelease: Equatable {
    /// The release's page, for when the app can't install it itself.
    public static let pageURL = URL(string: "https://github.com/justfortonks/mirror-wall/releases/latest")!
    /// GitHub's description of the newest release (not a pre-release or draft).
    public static let apiURL = URL(string: "https://api.github.com/repos/justfortonks/mirror-wall/releases/latest")!

    /// 109 for release v0.109.
    public var build: Int
    /// The "What's new" part of the release notes, without the install instructions.
    public var notes: String
    /// The named file attached to the release, if it has one.
    public var downloadURL: URL?

    public var version: String { "0.\(build)" }

    public init(build: Int, notes: String, downloadURL: URL?) {
        self.build = build
        self.notes = notes
        self.downloadURL = downloadURL
    }

    /// Reads GitHub's answer for the newest release; `asset` is the download wanted, e.g.
    /// "MirrorWall.dmg". Nil if it isn't a release this app can compare itself with.
    public init?(json: Data, asset: String) {
        struct Answer: Decodable {
            struct Asset: Decodable {
                var name: String
                var browser_download_url: URL
            }
            var tag_name: String
            var body: String?
            var assets: [Asset]
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: json),
              let build = Self.build(fromTag: answer.tag_name) else { return nil }
        self.init(build: build,
                  notes: Self.whatsNew(in: answer.body ?? ""),
                  downloadURL: answer.assets.first { $0.name == asset }?.browser_download_url)
    }

    /// "v0.109" → 109.
    public static func build(fromTag tag: String) -> Int? {
        let parts = tag.drop { $0 == "v" }.split(separator: ".")
        guard parts.count == 2, parts[0] == "0" else { return nil }
        return Int(parts[1])
    }

    /// The release notes' "What's new" section (what .github/workflows/release.yml writes before
    /// "## Install"), with markdown headings and bullets turned into plain text.
    public static func whatsNew(in body: String) -> String {
        var lines: [String] = []
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("## ") {
                if text == "## What's new" { continue }
                break
            }
            if text.hasPrefix("### ") {
                lines.append(String(text.dropFirst(4)))
            } else if text.hasPrefix("- ") {
                lines.append("• " + text.dropFirst(2))
            } else if !text.isEmpty, let last = lines.indices.last, !lines[last].isEmpty {
                lines[last] += " " + text
            } else {
                lines.append(text)
            }
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
