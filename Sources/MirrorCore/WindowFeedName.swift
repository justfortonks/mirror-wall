import Foundation

/// Names for Mac windows that Mirror Wall sends to OBS (File › Send a Window to OBS), as OBS's
/// Syphon Client lists them after "[Mirror Wall]".
public enum WindowFeedName {
    /// The longest name made from a window's title, so a browser tab's page title doesn't make
    /// an unreadable entry in OBS's list.
    public static let longestTitle = 60

    /// "Screen Sharing – Studio Mac" from the app's name and the window's title; just the app's
    /// name when the window has no title, or the title is the app's name; "Window" when macOS
    /// gave neither.
    public static func make(app: String?, title: String?) -> String {
        let app = clean(app)
        var title = clean(title)
        if let long = title, long.count > longestTitle {
            title = String(long.prefix(longestTitle)).trimmingCharacters(in: .whitespaces) + "…"
        }
        if let app, let title, title != app { return "\(app) – \(title)" }
        return app ?? title ?? "Window"
    }

    /// `name`, or `name 2`, `name 3`… when it's already taken, so two windows from the same app
    /// stay apart in OBS's list.
    public static func unique(_ name: String, among taken: [String]) -> String {
        guard taken.contains(name) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
