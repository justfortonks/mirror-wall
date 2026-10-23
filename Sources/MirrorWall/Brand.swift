import AppKit
import CoreText
import SwiftUI

/// Mirror Wall's own look (the design system's "stagecraft" direction): colors with a light and a
/// dark value, Fraunces for display and Inter for UI, and the mark. Kept in one place so every
/// view reads the same names.
///
/// Two rules the colors encode:
/// - The Stage is a theater. `stage*` colors are the same in both appearances, because the
///   customer is looking at it. Use them for anything drawn on the Stage, pop-out windows and the
///   OBS feed.
/// - Everything else follows the system appearance. `surface*` and `ink*` resolve on the current
///   appearance; never put a fixed hex on a window that isn't the Stage.
enum Brand {
    // MARK: Identity (the same in both appearances)

    /// The spotlight: primary actions, the live device's pool of light, focus. Ink goes on it, never white.
    static let lamp = Color(hex: 0xFFB030)
    /// The lighting gel: live and recording states only.
    static let gel = Color(hex: 0xFF4F8B)
    /// Alerts and destructive actions: lost connection, failed slot.
    static let hot = Color(hex: 0xE5484D)

    // MARK: The Stage (always dark)

    static let stage = Color(hex: 0x121015)
    static let stageRaised = Color(hex: 0x1B191F)
    static let stageLine = Color(hex: 0x2D2A33)
    static let stageInk = Color(hex: 0xF5F0E6)
    static let stageInkMuted = Color(hex: 0xB8B2A7)
    static let nsStage = NSColor(srgbRed: 0x12 / 255, green: 0x10 / 255, blue: 0x15 / 255, alpha: 1)

    /// The pool of lamp light the devices stand in. Drawn under the phones, over `stage`.
    static func stageLight(center: UnitPoint = .init(x: 0.5, y: 0.45)) -> RadialGradient {
        RadialGradient(
            colors: [lamp.opacity(0.22), lamp.opacity(0.06), lamp.opacity(0)],
            center: center, startRadius: 0, endRadius: 520
        )
    }

    // MARK: Surfaces and ink (follow the system appearance)

    static let surface = adaptive(0xF5F0E6, 0x121015)
    static let surfaceRaised = adaptive(0xFFFFFF, 0x1B191F)
    static let surfaceSunken = adaptive(0xECE6D9, 0x0C0B0E)
    static let ink = adaptive(0x121015, 0xF5F0E6)
    static let inkMuted = adaptive(0x5C5763, 0xB8B2A7)
    static let inkFaint = adaptive(0x8E889A, 0x6A6472)
    static let line = adaptive(0xD9D2C4, 0x2D2A33)
    /// Lamp as text or a link on a surface (lamp itself fails contrast on cream).
    static let lampText = adaptive(0x8A5A00, 0xFFD27A)
    /// A tint of lamp for a selected row or chip.
    static let lampWash = adaptive(0xFFF1D6, 0x3A2A0C)
    static let gelText = adaptive(0xB3215A, 0xFF8DB4)
    static let hotText = adaptive(0xB52A2F, 0xFF8A8E)
    /// The dot for a slot that is waiting, disconnected or stopped.
    static let standby = adaptive(0x8E889A, 0x6A6472)

    static var nsSurface: NSColor { nsAdaptive(0xF5F0E6, 0x121015) }

    /// A color that resolves on the window's appearance, so the Wall and Settings follow the system.
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: nsAdaptive(light, dark))
    }

    static func nsAdaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    /// Dot color for a slot's state, shared by the Stage, the Wall and the menu bar.
    static func dot(for state: Slot.State) -> Color {
        switch state {
        case .live: return gel
        case .connecting, .paused: return lamp
        case .waiting, .stopped: return standby
        case .disconnected, .failed: return hot
        }
    }

    // MARK: Type

    /// Inter at a weight, for everything people operate. Falls back to the system font.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        registerFonts()
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Inter-Bold"
        case .semibold, .medium: name = "Inter-SemiBold"
        default: name = "Inter-Regular"
        }
        return interAvailable ? .custom(name, size: size) : .system(size: size, weight: weight)
    }

    /// Fraunces, for the wordmark and headlines the audience reads ("Demo starting shortly").
    static func display(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        registerFonts()
        let name = weight == .bold || weight == .heavy || weight == .black ? "Fraunces-Bold" : "Fraunces-Medium"
        return frauncesAvailable ? .custom(name, size: size) : .system(size: size, weight: weight, design: .serif)
    }

    private static var registered = false
    private static var interAvailable = false
    private static var frauncesAvailable = false

    /// Registers the bundled font files for this process, once.
    static func registerFonts() {
        guard !registered else { return }
        registered = true
        for name in ["Inter-Regular", "Inter-SemiBold", "Inter-Bold"] where register(name) { interAvailable = true }
        for name in ["Fraunces-Medium", "Fraunces-Bold"] where register(name) { frauncesAvailable = true }
    }

    private static func register(_ name: String) -> Bool {
        guard let url = asset(name, "ttf") else { return NSFont(name: name, size: 12) != nil }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        return NSFont(name: name, size: 12) != nil // already installed on this Mac
    }

    // MARK: Marks

    /// The menu bar glyph as a template image, so macOS tints it for the bar: an outlined disc
    /// while idle, filled with the phone punched out while a device is live or recording.
    static func menuBarImage(inUse: Bool) -> NSImage? {
        guard let url = asset(inUse ? "menubar-live" : "menubar-idle", "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    // MARK: Files

    /// A file from Resources/Brand: inside MirrorWall.app (scripts/build-app.sh copies the folder
    /// there), or in SwiftPM's resource bundle next to the executable when run with `swift run`.
    /// Doesn't use Bundle.module, which stops the app if its bundle is missing.
    static func asset(_ name: String, _ ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Brand") {
            return url
        }
        let executableFolder = Bundle.main.executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL
        for candidate in [executableFolder, Bundle.main.bundleURL] {
            let bundleURL = candidate.appendingPathComponent("MirrorWall_MirrorWall.bundle")
            if let bundle = Bundle(url: bundleURL),
               let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Brand")
                ?? bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The mark, drawn: a phone standing in a disc of light. `disc` is lamp when something is live,
/// gel when recording, otherwise the current ink. Reads at 12 points and at 120.
struct BrandGlyph: View {
    var size: CGFloat = 16
    var disc: Color = .primary
    /// The phone's fill; nil punches it out of the disc, which is how the menu bar draws it.
    var phone: Color? = nil

    var body: some View {
        ZStack(alignment: .top) {
            Circle()
                .fill(disc)
                .frame(width: size * 0.82, height: size * 0.82)
                .offset(y: size * 0.03)
            RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
                .fill(phone ?? .black)
                .frame(width: size * 0.31, height: size * 0.56)
                .offset(y: size * 0.375)
                .blendMode(phone == nil ? .destinationOut : .normal)
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .accessibilityHidden(true)
    }
}

/// The glyph beside "Mirror Wall" in Fraunces, for the caption bar and About.
struct Wordmark: View {
    var height: CGFloat = 20
    var color: Color = Brand.stageInk
    var disc: Color? = nil

    var body: some View {
        HStack(spacing: height * 0.4) {
            BrandGlyph(size: height * 0.95, disc: disc ?? color)
            Text("Mirror Wall")
                .font(Brand.display(height * 0.85, .bold))
                .tracking(-0.3)
        }
        .foregroundStyle(color)
        .accessibilityLabel("Mirror Wall")
    }
}
