import SwiftUI
import UIKit

/// Mirror Wall's look on the iPhone, from the design system (stagecraft × neon): the same
/// colors as the Mac's Brand.swift and the Android app's colors.xml, resolving on the phone's
/// light or dark appearance. Fraunces for the wordmark; the system font for everything else.
enum Brand {
    static let lamp = Color(hex: 0xFFB030)
    static let gel = Color(hex: 0xFF3D8F)
    static let signal = Color(hex: 0x27E0FF)
    static let hot = Color(hex: 0xE5484D)
    static let night = Color(hex: 0x0B0D16)
    static let onNight = Color(hex: 0xEEF0FF)
    static let onNightMuted = Color(hex: 0xA9AFD6)
    /// Ink on lamp: the only text that reads on it.
    static let onLamp = Color(hex: 0x121015)

    static let surface = adaptive(0xF5F0E6, 0x0B0D16)
    static let surfaceRaised = adaptive(0xFFFFFF, 0x141829)
    static let surfaceSunken = adaptive(0xECE6D9, 0x06070C)
    static let ink = adaptive(0x10121C, 0xEEF0FF)
    static let inkMuted = adaptive(0x5A5B6E, 0xA9AFD6)
    static let line = adaptive(0xD9D2C4, 0x262B45)
    static let lampText = adaptive(0x8A5A00, 0xFFD27A)
    static let signalText = adaptive(0x0A7F94, 0x27E0FF)
    static let standby = adaptive(0x8E8FA3, 0x4A5078)

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    /// Fraunces Bold if it's bundled, else the system serif.
    static func display(_ size: CGFloat) -> Font {
        UIFont(name: "Fraunces-Bold", size: size) != nil ? .custom("Fraunces-Bold", size: size) : .system(size: size, weight: .bold, design: .serif)
    }

    /// The small uppercase section labels, in signal and mono as on Android.
    static func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(signalText)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The mark: a phone standing in a disc of lamp light with a gel rim.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(Brand.lamp).frame(width: size * 0.82, height: size * 0.82)
            Circle().strokeBorder(Brand.gel, lineWidth: max(1, size * 0.04)).frame(width: size * 0.9, height: size * 0.9)
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .fill(Brand.night)
                .frame(width: size * 0.3, height: size * 0.5)
                .offset(y: size * 0.12)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
