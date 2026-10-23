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
    /// The lighting gel: live and recording states only. Glows.
    static let gel = Color(hex: 0xFF3D8F)
    /// Signal: links, addresses, the QR chip, "connecting". The cyan in the floor grid.
    static let signal = Color(hex: 0x27E0FF)
    /// Haze: the violet glow in the Stage's corners. Never a fill, never text.
    static let haze = Color(hex: 0x6B4CFF)
    /// Alerts and destructive actions: lost connection, failed slot.
    static let hot = Color(hex: 0xE5484D)

    // MARK: The Stage (always dark)

    /// Night: a blue-black, not black, so the Stage has depth.
    static let stage = Color(hex: 0x0B0D16)
    static let stageRaised = Color(hex: 0x141829)
    static let stageLine = Color(hex: 0x262B45)
    static let stageInk = Color(hex: 0xEEF0FF)
    static let stageInkMuted = Color(hex: 0xA9AFD6)
    static let nsStage = NSColor(srgbRed: 0x0B / 255, green: 0x0D / 255, blue: 0x16 / 255, alpha: 1)

    /// The pool of lamp light the devices stand in. Drawn under the phones, over `stage`.
    static func stageLight(center: UnitPoint = .init(x: 0.5, y: 0.45)) -> RadialGradient {
        RadialGradient(
            colors: [lamp.opacity(0.26), lamp.opacity(0.07), lamp.opacity(0)],
            center: center, startRadius: 0, endRadius: 520
        )
    }

    // MARK: Surfaces and ink (follow the system appearance)

    static let surface = adaptive(0xF5F0E6, 0x0B0D16)
    static let surfaceRaised = adaptive(0xFFFFFF, 0x141829)
    static let surfaceSunken = adaptive(0xECE6D9, 0x06070C)
    static let ink = adaptive(0x10121C, 0xEEF0FF)
    static let inkMuted = adaptive(0x5A5B6E, 0xA9AFD6)
    static let inkFaint = adaptive(0x8E8FA3, 0x6F77A8)
    static let line = adaptive(0xD9D2C4, 0x262B45)
    /// Lamp as text or a link on a surface (lamp itself fails contrast on cream).
    static let lampText = adaptive(0x8A5A00, 0xFFD27A)
    /// A tint of lamp for a selected row or chip.
    static let lampWash = adaptive(0xFFF1D6, 0x3A2A0C)
    static let gelText = adaptive(0xB3215A, 0xFF8DB4)
    /// Signal as text or a link on a surface.
    static let signalText = adaptive(0x0A7F94, 0x27E0FF)
    static let hotText = adaptive(0xB52A2F, 0xFF8A8E)
    /// The dot for a slot that is waiting, disconnected or stopped.
    static let standby = adaptive(0x8E8FA3, 0x4A5078)

    static var nsSurface: NSColor { nsAdaptive(0xF5F0E6, 0x0B0D16) }

    /// A soft glow in a state's own color; live and recording glow, nothing else does.
    static func glow(_ color: Color, on: Bool = true, radius: CGFloat = 5) -> some ViewModifier {
        Glow(color: color, on: on, radius: radius)
    }

    private struct Glow: ViewModifier {
        let color: Color
        let on: Bool
        let radius: CGFloat
        func body(content: Content) -> some View {
            content.shadow(color: on ? color.opacity(0.85) : .clear, radius: radius)
        }
    }

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
        case .connecting: return signal
        case .paused: return lamp
        case .waiting, .stopped: return standby
        case .disconnected, .failed: return hot
        }
    }

    /// Whether a state's dot glows: only the ones that mean "something is happening right now".
    static func glows(_ state: Slot.State) -> Bool {
        state == .live || state == .connecting
    }

    /// Monospaced, for addresses, ports and codes.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
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

/// The Stage's backdrop: night, a violet haze in the top-left and a faint magenta one bottom-right,
/// a cyan perspective floor that fades toward the horizon, and the pool of lamp light with its
/// magenta rim where the devices stand. The customer sees this behind the phones, so every part
/// of it is quiet: no motion, nothing brighter than the live dot.
struct StageBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Brand.stage
                RadialGradient(colors: [Brand.haze.opacity(0.28), Brand.haze.opacity(0)], center: .init(x: 0.08, y: 0.05), startRadius: 0, endRadius: size.width * 0.42)
                RadialGradient(colors: [Brand.gel.opacity(0.14), Brand.gel.opacity(0)], center: .init(x: 1.0, y: 1.0), startRadius: 0, endRadius: size.width * 0.4)
                StageFloor()
                    .frame(height: size.height * 0.3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Brand.stageLight()
                Circle()
                    .strokeBorder(Brand.gel.opacity(0.5), lineWidth: 1)
                    .frame(width: size.height * 0.62, height: size.height * 0.62)
                    .shadow(color: Brand.gel.opacity(0.35), radius: 14)
                    .position(x: size.width * 0.5, y: size.height * 0.45)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The cyan perspective grid under the devices: horizontals that bunch toward the horizon and
/// lines that fan out from a vanishing point, fading in from the top edge.
struct StageFloor: View {
    var body: some View {
        Canvas { context, size in
            let horizon = CGPoint(x: size.width / 2, y: size.height * 0.2)
            var grid = Path()
            // Horizontals, closer together near the horizon.
            for step in 0..<7 {
                let t = pow(Double(step) / 6, 1.7)
                let y = horizon.y + (size.height - horizon.y) * t
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            // Fan lines from the vanishing point to the bottom edge.
            for k in -5...5 {
                let x = size.width / 2 + CGFloat(k) * size.width * 0.22
                grid.move(to: horizon)
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [
                    .init(color: Brand.signal.opacity(0), location: 0),
                    .init(color: Brand.signal.opacity(0.26), location: 0.4),
                    .init(color: Brand.signal.opacity(0.05), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)
            )
            context.stroke(grid, with: shading, lineWidth: 1)
        }
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
