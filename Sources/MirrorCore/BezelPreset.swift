import Foundation

/// Illustrative vector frames. Model presets preserve the source aspect ratio and remain
/// selectable when a device does not advertise a recognizable model code.
public struct BezelPreset: Hashable, Identifiable {
    public let id: String
    public let title: String
    public let group: String
    public let style: BezelStyle
    public let portraitAspect: Double
    public let aliases: [String]
    public static let automatic = "automatic"
    public static let generic = BezelPreset(id: "generic", title: "Generic phone", group: "Other", style: .plain, portraitAspect: 0.48, aliases: [])
    public static let catalog: [BezelPreset] = [
        .init(id: "iphone-se-1st-generation", title: "iPhone SE (1st generation)", group: "SE", style: .homeButton, portraitAspect: 0.475000, aliases: ["iPhone8,4"]),
        .init(id: "iphone-se-2nd-generation", title: "iPhone SE (2nd generation)", group: "SE", style: .homeButton, portraitAspect: 0.485000, aliases: ["iPhone12,8"]),
        .init(id: "iphone-se-3rd-generation", title: "iPhone SE (3rd generation)", group: "SE", style: .homeButton, portraitAspect: 0.485000, aliases: ["iPhone14,6"]),
        .init(id: "iphone-12-mini", title: "iPhone 12 mini", group: "12", style: .notch, portraitAspect: 0.488000, aliases: ["iPhone13,1"]),
        .init(id: "iphone-12", title: "iPhone 12", group: "12", style: .notch, portraitAspect: 0.485000, aliases: ["iPhone13,2"]),
        .init(id: "iphone-12-pro", title: "iPhone 12 Pro", group: "12", style: .notch, portraitAspect: 0.485000, aliases: ["iPhone13,3"]),
        .init(id: "iphone-12-pro-max", title: "iPhone 12 Pro Max", group: "12", style: .notch, portraitAspect: 0.484000, aliases: ["iPhone13,4"]),
        .init(id: "iphone-13-mini", title: "iPhone 13 mini", group: "13", style: .compactNotch, portraitAspect: 0.488000, aliases: ["iPhone14,4"]),
        .init(id: "iphone-13", title: "iPhone 13", group: "13", style: .compactNotch, portraitAspect: 0.485000, aliases: ["iPhone14,5"]),
        .init(id: "iphone-13-pro", title: "iPhone 13 Pro", group: "13", style: .compactNotch, portraitAspect: 0.485000, aliases: ["iPhone14,2"]),
        .init(id: "iphone-13-pro-max", title: "iPhone 13 Pro Max", group: "13", style: .compactNotch, portraitAspect: 0.484000, aliases: ["iPhone14,3"]),
        .init(id: "iphone-14", title: "iPhone 14", group: "14", style: .compactNotch, portraitAspect: 0.485000, aliases: ["iPhone14,7"]),
        .init(id: "iphone-14-plus", title: "iPhone 14 Plus", group: "14", style: .compactNotch, portraitAspect: 0.484000, aliases: ["iPhone14,8"]),
        .init(id: "iphone-14-pro", title: "iPhone 14 Pro", group: "14", style: .dynamicIsland, portraitAspect: 0.485000, aliases: ["iPhone15,2"]),
        .init(id: "iphone-14-pro-max", title: "iPhone 14 Pro Max", group: "14", style: .dynamicIsland, portraitAspect: 0.484000, aliases: ["iPhone15,3"]),
        .init(id: "iphone-15", title: "iPhone 15", group: "15", style: .dynamicIsland, portraitAspect: 0.485000, aliases: ["iPhone15,4"]),
        .init(id: "iphone-15-plus", title: "iPhone 15 Plus", group: "15", style: .dynamicIsland, portraitAspect: 0.484000, aliases: ["iPhone15,5"]),
        .init(id: "iphone-15-pro", title: "iPhone 15 Pro", group: "15", style: .dynamicIsland, portraitAspect: 0.485000, aliases: ["iPhone16,1"]),
        .init(id: "iphone-15-pro-max", title: "iPhone 15 Pro Max", group: "15", style: .dynamicIsland, portraitAspect: 0.484000, aliases: ["iPhone16,2"]),
        .init(id: "iphone-16", title: "iPhone 16", group: "16", style: .dynamicIsland, portraitAspect: 0.485000, aliases: ["iPhone17,3"]),
        .init(id: "iphone-16-plus", title: "iPhone 16 Plus", group: "16", style: .dynamicIsland, portraitAspect: 0.484000, aliases: ["iPhone17,4"]),
        .init(id: "iphone-16-pro", title: "iPhone 16 Pro", group: "16", style: .dynamicIsland, portraitAspect: 0.477000, aliases: ["iPhone17,1"]),
        .init(id: "iphone-16-pro-max", title: "iPhone 16 Pro Max", group: "16", style: .dynamicIsland, portraitAspect: 0.484000, aliases: ["iPhone17,2"]),
        .init(id: "iphone-16e", title: "iPhone 16e", group: "16", style: .compactNotch, portraitAspect: 0.485000, aliases: ["iPhone17,5"]),
        .init(id: "iphone-17", title: "iPhone 17", group: "17", style: .dynamicIsland, portraitAspect: 0.485000, aliases: ["iPhone18,3"]),
        .init(id: "iphone-air", title: "iPhone Air", group: "17", style: .dynamicIsland, portraitAspect: 0.478000, aliases: ["iPhone18,4"]),
        .init(id: "iphone-17-pro", title: "iPhone 17 Pro", group: "17", style: .dynamicIsland, portraitAspect: 0.477000, aliases: ["iPhone18,1"]),
        .init(id: "iphone-17-pro-max", title: "iPhone 17 Pro Max", group: "17", style: .dynamicIsland, portraitAspect: 0.484000, aliases: ["iPhone18,2"]),
        .init(id: "iphone-17e", title: "iPhone 17e", group: "17", style: .compactNotch, portraitAspect: 0.487000, aliases: ["A3575", "A3635", "A3634"]),
        .init(id: "iphone-18-pro", title: "iPhone 18 Pro", group: "18", style: .smallIsland, portraitAspect: 0.479000, aliases: ["A3472", "A3713", "A3715", "A3714"]),
        .init(id: "iphone-18-pro-max", title: "iPhone 18 Pro Max", group: "18", style: .smallIsland, portraitAspect: 0.477000, aliases: ["A3473", "A3716", "A3718", "A3717"]),
        // Photo frames (see BezelArtwork): the picture sits in the photo's screen.
        .init(id: "zebra-hc50", title: "Zebra HC50", group: "Zebra", style: .zebraHC50, portraitAspect: 1280.0 / 2640.0, aliases: ["HC50"]),
        .init(id: "zebra-tc53e", title: "Zebra TC53e", group: "Zebra", style: .rugged, portraitAspect: 0.469357, aliases: ["TC53e"]),
        .init(id: "honeywell-ct37", title: "Honeywell CT37", group: "Honeywell", style: .honeywellCT37, portraitAspect: 1360.0 / 2880.0, aliases: ["CT37", "CT37HC"]),
        .init(id: "spectralink-versity-95-96", title: "Spectralink Versity 95/96", group: "Spectralink", style: .versity95, portraitAspect: 1360.0 / 2640.0,
              aliases: ["9540", "9553", "9640", "9653", "Versity 9540", "Versity 9553", "Versity 9640", "Versity 9653"]),
        .init(id: "spectralink-versity-97", title: "Spectralink Versity 97", group: "Spectralink", style: .versity97, portraitAspect: 1360.0 / 2640.0,
              aliases: ["9740", "9753", "Versity 9740", "Versity 9753"]),
        .init(id: "ipad-11-a16", title: "iPad (11th generation / A16)", group: "iPad", style: .tablet,
              portraitAspect: 179.5 / 248.6,
              aliases: ["iPad15,7", "iPad15,8", "A3354", "A3355", "A3356", "iPad (A16)", "iPad (11th generation)"]),
        generic,
    ]

    public static func resolve(selection: String? = nil, model: String?) -> BezelPreset? {
        if let selection, selection != automatic,
           let chosen = catalog.first(where: { $0.id == selection }) { return chosen }
        let key = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return catalog.first { preset in
            preset.title.lowercased() == key || preset.aliases.contains {
                let alias = $0.lowercased()
                return key == alias || key.hasSuffix(" " + alias)
            }
        }
    }
}
