import AppKit
import SwiftUI

/// The app's look, chosen in Settings › General › Theme. Standard is Mirror Wall's own look;
/// Imprivata is the brand styling from Brand.swift. Only colors, type and decoration change:
/// what the app does is the same in every theme.
enum Theme: String, CaseIterable, Identifiable {
    case standard
    case imprivata

    static let key = "theme"

    /// The chosen theme, for code that isn't a view. Views read `Theme.key` with @AppStorage, so
    /// they redraw when it changes.
    static var current: Theme { Theme(name: UserDefaults.standard.string(forKey: key)) }

    init(name: String?) {
        self = name.flatMap(Theme.init(rawValue:)) ?? .standard
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .imprivata: return "Imprivata"
        }
    }

    // MARK: Type

    /// Barlow for Imprivata. Standard uses `standard` when given, so the wall keeps its usual
    /// text styles, else the system font at the same size.
    func font(_ size: CGFloat, _ weight: Font.Weight = .regular, standard: Font? = nil) -> Font {
        switch self {
        case .standard: return standard ?? .system(size: size, weight: weight)
        case .imprivata: return Brand.font(size, weight)
        }
    }

    // MARK: Wall

    /// Behind the tiles. Nil keeps the system's window color, light or dark.
    var wallBackground: Color? {
        self == .imprivata ? Brand.blue : nil
    }

    /// Imprivata Blue needs dark appearance so text, menus and controls read on it.
    var colorScheme: ColorScheme? {
        self == .imprivata ? .dark : nil
    }

    var toolbarBackground: Color? {
        self == .imprivata ? Brand.blueDeep : nil
    }

    /// Behind a tile while it waits for a phone (a phone's picture always sits on black).
    var emptyTileBackground: Color {
        self == .imprivata ? Brand.blueDeep : .black
    }

    /// The hex pattern in the corner of empty tiles and the Stage.
    var showsHexPattern: Bool { self == .imprivata }

    /// Recording dots and buttons, and trouble.
    var red: Color {
        self == .imprivata ? Brand.red : .red
    }

    /// The icon on an empty tile when nothing's wrong.
    var placeholderIcon: Color {
        self == .imprivata ? Brand.teal : .white.opacity(0.75)
    }

    func statusColor(_ state: Slot.State) -> Color {
        switch self {
        case .standard:
            switch state {
            case .live: return .green
            case .waiting, .connecting, .paused: return .yellow
            case .disconnected: return .orange
            case .stopped: return .gray
            case .failed: return .red
            }
        case .imprivata:
            // Brand palette: teal live, blues in between, red only for trouble (and recording).
            switch state {
            case .live: return Brand.teal
            case .connecting, .paused: return Brand.sky
            case .waiting: return Brand.blueMuted
            case .disconnected: return .orange
            case .stopped: return .gray
            case .failed: return Brand.red
            }
        }
    }

    // MARK: Stage

    @ViewBuilder var stageBackground: some View {
        switch self {
        case .standard: Color.black
        case .imprivata: Brand.stageGradient
        }
    }

    /// The Stage window's own color, seen only for a moment while it resizes.
    var stageWindowColor: NSColor {
        self == .imprivata ? Brand.nsBlue : .black
    }

    /// The Stage's control bar, pills and "Ready for phones" panel.
    var panel: Color {
        self == .imprivata ? Color(hex: 0x141E2D) : Color(white: 0.1)
    }

    /// Text on the control bar's buttons.
    var controlText: Color {
        self == .imprivata ? Brand.ice : .white.opacity(0.85)
    }

    /// The logo at the right of the Stage's caption bar, when the theme has one installed.
    var logo: NSImage? {
        self == .imprivata ? Brand.whiteLogo : nil
    }
}

/// The chosen theme, for a view: `@CurrentTheme private var theme`. Redraws the view when the
/// theme changes in Settings.
@propertyWrapper
struct CurrentTheme: DynamicProperty {
    @AppStorage(Theme.key) private var name = Theme.standard.rawValue

    var wrappedValue: Theme { Theme(name: name) }
}

/// Whether the Stage shows its "Live demo" caption bar. Each theme remembers its own choice: off
/// for Standard, on for Imprivata, until changed.
@propertyWrapper
struct StageCaptionSetting: DynamicProperty {
    @AppStorage(Theme.key) private var name = Theme.standard.rawValue
    @AppStorage("stageCaptionBar.standard") private var standard = false
    @AppStorage("stageCaptionBar.imprivata") private var imprivata = true

    var wrappedValue: Bool {
        get { Theme(name: name) == .imprivata ? imprivata : standard }
        nonmutating set {
            if Theme(name: name) == .imprivata { imprivata = newValue } else { standard = newValue }
        }
    }

    var projectedValue: Binding<Bool> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
