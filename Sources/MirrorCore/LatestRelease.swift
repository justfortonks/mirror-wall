import Foundation

/// Which releases Check for Update offers: Stable only offers regular releases; Beta also offers
/// test builds published as GitHub pre-releases (tagged v0.N-beta.K), whichever is newest.
public enum UpdateChannel: String, CaseIterable {
    case stable, beta
}

/// A build's place in line: its build number (the commit count, as in the version "0.N") and, for
/// a beta, its beta number. A release outranks a beta with the same build number.
public struct BuildNumber: Comparable, Hashable {
    public var build: Int
    /// 7 for "0.112 beta 7"; nil for a regular release.
    public var beta: Int?

    public init(build: Int, beta: Int? = nil) {
        self.build = build
        self.beta = beta
    }

    /// "0.112" or "0.112 beta 7".
    public var version: String { beta.map { "0.\(build) beta \($0)" } ?? "0.\(build)" }

    /// "v0.109" → 0.109; "v0.112-beta.7" → 0.112 beta 7.
    public init?(tag: String) {
        let parts = tag.drop { $0 == "v" }.split(separator: "-", maxSplits: 1)
        guard let first = parts.first else { return nil }
        let numbers = first.split(separator: ".")
        guard numbers.count == 2, numbers[0] == "0", let build = Int(numbers[1]) else { return nil }
        var beta: Int?
        if parts.count == 2 {
            guard parts[1].hasPrefix("beta."), let number = Int(parts[1].dropFirst(5)) else { return nil }
            beta = number
        }
        self.init(build: build, beta: beta)
    }

    public static func < (lhs: BuildNumber, rhs: BuildNumber) -> Bool {
        (lhs.build, lhs.beta ?? .max) < (rhs.build, rhs.beta ?? .max)
    }
}

/// The newest Mirror Wall release on GitHub, as Check for Update sees it: its number, its
/// "What's new" notes and the download for this computer.
public struct LatestRelease: Equatable {
    /// The releases page, for when the app can't install it itself.
    public static let pageURL = URL(string: "https://github.com/yurtbeer/mirror-wall/releases")!
    /// GitHub's description of the newest regular release (not a pre-release or draft).
    public static let apiURL = URL(string: "https://api.github.com/repos/yurtbeer/mirror-wall/releases/latest")!
    /// GitHub's recent releases, pre-releases (betas) included, newest first.
    public static let listURL = URL(string: "https://api.github.com/repos/yurtbeer/mirror-wall/releases?per_page=30")!

    public static func url(for channel: UpdateChannel) -> URL { channel == .beta ? listURL : apiURL }

    public var number: BuildNumber
    /// The "What's new" part of the release notes, without the install instructions.
    public var notes: String
    /// The named file attached to the release, if it has one.
    public var downloadURL: URL?

    /// 109 for release v0.109.
    public var build: Int { number.build }
    public var version: String { number.version }

    public init(number: BuildNumber, notes: String, downloadURL: URL?) {
        self.number = number
        self.notes = notes
        self.downloadURL = downloadURL
    }

    /// Reads GitHub's answer from `url(for: channel)`: for Stable, the newest release; for Beta,
    /// the highest-numbered of the listed releases and pre-releases that have `asset`.
    public init?(json: Data, asset: String, channel: UpdateChannel) {
        switch channel {
        case .stable:
            self.init(json: json, asset: asset)
        case .beta:
            guard let list = try? JSONSerialization.jsonObject(with: json) as? [Any] else { return nil }
            let releases = list.compactMap { item -> LatestRelease? in
                guard let dictionary = item as? [String: Any], dictionary["draft"] as? Bool != true,
                      let data = try? JSONSerialization.data(withJSONObject: dictionary) else { return nil }
                return LatestRelease(json: data, asset: asset)
            }
            guard let newest = releases.filter({ $0.downloadURL != nil }).max(by: { $0.number < $1.number }) else { return nil }
            self = newest
        }
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
              let number = BuildNumber(tag: answer.tag_name) else { return nil }
        self.init(number: number,
                  notes: Self.whatsNew(in: answer.body ?? ""),
                  downloadURL: answer.assets.first { $0.name == asset }?.browser_download_url)
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
