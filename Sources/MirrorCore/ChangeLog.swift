import Foundation

/// One entry of CHANGELOG.md: a `## <date>: <title>` heading and the lines under it.
public struct ChangeLogEntry: Equatable {
    public var heading: String
    /// The entry's text with each bullet's wrapped lines joined, one bullet per item.
    public var items: [String]

    /// The newest entry (the first `##` section) of a change log written as CHANGELOG.md is.
    public static func latest(in markdown: String) -> ChangeLogEntry? {
        var entry: ChangeLogEntry?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("## ") {
                if entry != nil { break }
                entry = ChangeLogEntry(heading: String(text.dropFirst(3)), items: [])
            } else if entry != nil, !text.isEmpty {
                if text.hasPrefix("- ") {
                    entry!.items.append(String(text.dropFirst(2)))
                } else if let last = entry!.items.indices.last {
                    entry!.items[last] += " " + text
                } else {
                    entry!.items.append(text)
                }
            }
        }
        return entry
    }
}
