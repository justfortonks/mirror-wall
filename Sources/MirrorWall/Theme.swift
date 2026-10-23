import AppKit
import SwiftUI

/// The app's look: the colors and type the Stage draws with. There's one look today,
/// Standard; a new one goes here as another case rather than as colors hard-coded in views.
/// A look saved by an older build that's no longer offered falls back to Standard.
enum Theme: String, CaseIterable, Identifiable {
    case standard

    static let key = "theme"

    /// The theme, for code that isn't a view.
    static var current: Theme { Theme(name: UserDefaults.standard.string(forKey: key)) }

    init(name: String?) {
        self = name.flatMap(Theme.init(rawValue:)) ?? .standard
    }

    var id: String { rawValue }

    // MARK: Type

    /// `standard` when given, so the wall keeps its usual text styles, else the system font at
    /// the same size.
    func font(_ size: CGFloat, _ weight: Font.Weight = .regular, standard: Font? = nil) -> Font {
        standard ?? .system(size: size, weight: weight)
    }

    // MARK: Colors

    /// Recording dots and buttons, and trouble.
    var red: Color { .red }

    func statusColor(_ state: Slot.State) -> Color {
        switch state {
        case .live: return .green
        case .waiting, .connecting, .paused: return .yellow
        case .disconnected: return .orange
        case .stopped: return .gray
        case .failed: return .red
        }
    }

    // MARK: Stage

    var stageBackground: Color { .black }

    /// The Stage window's own color, seen only for a moment while it resizes.
    var stageWindowColor: NSColor { .black }

    /// The Stage's control bar, pills and "Ready for phones" panel.
    var panel: Color { Color(white: 0.1) }

    /// Text on the control bar's buttons.
    var controlText: Color { .white.opacity(0.85) }
}

/// The theme, for a view: `@CurrentTheme private var theme`. Redraws the view if the saved
/// theme changes.
@propertyWrapper
struct CurrentTheme: DynamicProperty {
    @AppStorage(Theme.key) private var name = Theme.standard.rawValue

    var wrappedValue: Theme { Theme(name: name) }
}

/// Whether the Stage shows its "Live demo" caption bar. Off until changed.
@propertyWrapper
struct StageCaptionSetting: DynamicProperty {
    @AppStorage("stageCaptionBar.standard") private var shows = false

    var wrappedValue: Bool {
        get { shows }
        nonmutating set { shows = newValue }
    }

    var projectedValue: Binding<Bool> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
