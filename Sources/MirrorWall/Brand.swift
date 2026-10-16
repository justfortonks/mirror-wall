import AppKit
import CoreText
import SwiftUI

/// Imprivata brand styling (2026 Brand Style Guide): colors, Barlow, the logo and the hex pattern.
/// Kept in one place so the look can be changed, or made switchable, without touching every view.
enum Brand {
    // Primary
    static let blue = Color(hex: 0x2C3F57)
    static let red = Color(hex: 0xCC0033)
    // Secondary
    static let teal = Color(hex: 0x2CD5C4)
    static let midBlue = Color(hex: 0x426DA9)
    static let sky = Color(hex: 0x4698CB)
    static let ice = Color(hex: 0xD2E4F9)
    // Shades of Imprivata Blue for the dark wall
    static let blueDeep = Color(hex: 0x24344A)
    static let blueRaised = Color(hex: 0x33495F)
    static let blueMuted = Color(hex: 0x7C8DA3)

    static let nsBlue = NSColor(srgbRed: 0x2C / 255, green: 0x3F / 255, blue: 0x57 / 255, alpha: 1)

    /// The guide's Imprivata Blue → #4698CB gradient, for the stage.
    static let stageGradient = LinearGradient(
        colors: [blue, Color(hex: 0x2F4D6E), sky],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Type

    /// Barlow at a weight, falling back to the system font if Barlow isn't installed.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        registerFonts()
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Barlow-Bold"
        case .semibold, .medium: name = "Barlow-SemiBold"
        default: name = "Barlow-Regular"
        }
        return available ? .custom(name, size: size) : .system(size: size, weight: weight)
    }

    private static var registered = false
    private static var available = false

    /// Registers the bundled Barlow files for this process, once.
    static func registerFonts() {
        guard !registered else { return }
        registered = true
        for name in ["Barlow-Regular", "Barlow-SemiBold", "Barlow-Bold"] {
            guard let url = asset(name, "ttf") else { continue }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                available = true
            } else if NSFont(name: name, size: 12) != nil {
                available = true // already installed on this Mac
            }
        }
    }

    // MARK: Logo

    /// The official white logo, if it's been put in Resources/Brand. It's kept out of git
    /// (see .gitignore), so builds without it simply don't show one.
    static let whiteLogo: NSImage? = asset("imprivata-logo-white", "png").flatMap(NSImage.init(contentsOf:))

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

/// The brand's hex pattern as a corner accent: full hexagons, turning into chevrons toward the
/// bottom, upright as the guide shows them (never rotated). At most three colors.
struct HexPattern: View {
    var colors: [Color] = [Brand.blueRaised, Brand.midBlue, Brand.sky]
    /// Hexagon radius in points.
    var radius: CGFloat = 16
    var columns = 5
    var rows = 6
    var density = 0.7
    var seed: UInt64 = 7
    var opacity = 1.0

    var body: some View {
        Canvas { context, size in
            let r = radius
            let w = sqrt(3) * r
            var random = SeededRandom(seed: seed)
            for row in 0..<rows {
                for column in 0..<columns {
                    // Denser toward the top right, so it reads as a corner accent.
                    let fade = density * (1 - Double(row) / (Double(rows) * 1.4)) * (0.55 + Double(column) / Double(columns) * 0.6)
                    let keep = random.next() <= fade
                    let colorPick = random.next()
                    let chevronPick = random.next()
                    guard keep else { continue }
                    // Laid out from the right edge.
                    let cx = size.width - (CGFloat(columns - 1 - column) * w + (row % 2 == 1 ? w / 2 : 0) + w / 2)
                    let cy = CGFloat(row) * 1.5 * r + r
                    let chevron = Double(row) >= Double(rows) * 0.45 && chevronPick > 0.35
                    let path = chevron ? Self.chevron(cx, cy, r * 0.96) : Self.hexagon(cx, cy, r * 0.96)
                    let color = colors[min(colors.count - 1, Int(colorPick * Double(colors.count)))]
                    context.fill(path, with: .color(color.opacity(opacity)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func hexagon(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
        Path { path in
            for k in 0..<6 {
                let angle = CGFloat.pi / 180 * CGFloat(60 * k - 90)
                let point = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
                if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }

    /// A hexagon with a V notch in its top: the guide's chevron.
    private static func chevron(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
        let w = sqrt(3) / 2 * r
        return Path { path in
            path.move(to: CGPoint(x: cx - w, y: cy - r / 2))
            path.addLine(to: CGPoint(x: cx, y: cy))
            path.addLine(to: CGPoint(x: cx + w, y: cy - r / 2))
            path.addLine(to: CGPoint(x: cx + w, y: cy + r / 2))
            path.addLine(to: CGPoint(x: cx, y: cy + r))
            path.addLine(to: CGPoint(x: cx - w, y: cy + r / 2))
            path.closeSubpath()
        }
    }
}

/// Same pattern every time for the same seed, so the hexes don't jump around on redraw.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }

    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 10_000) / 10_000
    }
}
