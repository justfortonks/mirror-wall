import Foundation

/// The kind of phone frame drawn around a slot's picture when bezels are on, picked from the
/// phone's model code. The frame sits around the picture and never covers any of it, so a notch
/// or Dynamic Island is drawn in the frame's top edge rather than over the screen.
public enum BezelStyle: String, CaseIterable {
    /// Deep top and bottom edges with a round home button: iPhone 8 and the SEs.
    case homeButton
    /// Even edges with a notch: iPhone X to 14, and 16e.
    case notch
    /// Even edges with a Dynamic Island: iPhone 14 Pro and later, and iPhones newer than this list.
    case dynamicIsland
    /// Any other phone (Android, or no phone yet): even edges, a little deeper at top and bottom,
    /// with a front camera.
    case plain
    /// Android phones drawn from a photo of their front (see `BezelArtwork`).
    case zebraHC50
    case honeywellCT37
    case versity95
    case versity97

    /// "iPhone14,6" → .homeButton, "iPhone18,2" → .dynamicIsland, "Zebra Technologies HC50" →
    /// .zebraHC50, another Android phone or nil → .plain.
    public init(modelCode: String?) {
        guard let code = modelCode, code.hasPrefix("iPhone") else {
            self = modelCode.flatMap(Self.android) ?? .plain
            return
        }
        let numbers = code.dropFirst("iPhone".count).split(separator: ",").compactMap { Int($0) }
        guard numbers.count == 2 else {
            self = .plain
            return
        }
        switch (numbers[0], numbers[1]) {
        case (10, 3), (10, 6): self = .notch                   // iPhone X
        case (12, 8), (14, 6): self = .homeButton              // iPhone SE (2nd and 3rd generation)
        case (14, 7), (14, 8), (17, 5): self = .notch          // iPhone 14, 14 Plus, 16e
        case (...10, _): self = .homeButton                    // iPhone 8 and earlier
        case (...14, _): self = .notch                         // iPhone XS to 13
        default: self = .dynamicIsland
        }
    }
}

extension BezelStyle {
    /// The Android phones with their own frame, from the model the Android app sends: its maker
    /// and model, e.g. "Zebra Technologies HC50", "Honeywell CT37", "Spectralink Versity 9640".
    /// Only whole model numbers count, so an HC20, CT30 or Versity 9240 gets the plain frame.
    static func android(_ model: String) -> BezelStyle? {
        let makers: Set<String> = ["ZEBRA", "TECHNOLOGIES", "HONEYWELL", "SPECTRALINK", "VERSITY"]
        let words = model.uppercased().split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        var code = String(words.drop(while: { makers.contains(String($0)) }).joined())
        if code == "HC50" { return .zebraHC50 }
        // CT37, CT37HC, CT37X0N…, but not CT370.
        if code.hasPrefix("CT37"), code.dropFirst(4).first.map({ $0.isLetter }) ?? true { return .honeywellCT37 }
        if code.hasPrefix("V") { code.removeFirst() }
        switch code {
        case "9540", "9553", "9640", "9653": return .versity95
        case "9740", "9753": return .versity97
        default: return nil
        }
    }

    /// The photo this style is drawn from, if it has one.
    public var artwork: BezelArtwork? {
        switch self {
        case .zebraHC50:
            return BezelArtwork(name: "zebra-hc50-front", canvasWidth: 1280, canvasHeight: 2640,
                                screen: BezelRect(x: 100, y: 240, width: 1080, height: 2160), diagonal: 6)
        case .honeywellCT37:
            return BezelArtwork(name: "honeywell-ct37-white-front", canvasWidth: 1360, canvasHeight: 2880,
                                screen: BezelRect(x: 140, y: 320, width: 1080, height: 2280), diagonal: 6)
        case .versity95:
            return BezelArtwork(name: "spectralink-versity95-96-front", canvasWidth: 1360, canvasHeight: 2640,
                                screen: BezelRect(x: 140, y: 400, width: 1080, height: 1920), diagonal: 5.2)
        case .versity97:
            return BezelArtwork(name: "spectralink-versity97-front", canvasWidth: 1360, canvasHeight: 2640,
                                screen: BezelRect(x: 140, y: 340, width: 1080, height: 1920), diagonal: 5.2)
        default:
            return nil
        }
    }
}

/// A rectangle, y counting down from the top.
public struct BezelRect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A phone frame drawn from a photo of the phone's front: a portrait PNG (in the app's Bezels
/// resources, shared by the Mac and Windows apps) that is see-through outside the phone and in
/// its screen. Measured in the PNG's pixels. The picture goes under it, filling the screen.
public struct BezelArtwork: Equatable {
    /// The PNG's file name, without ".png".
    public let name: String
    public let canvasWidth: Double
    public let canvasHeight: Double
    /// The see-through screen, upright.
    public let screen: BezelRect
    /// The phone's screen diagonal in inches, for true-to-life sizes.
    public let diagonal: Double
}

/// The frame around a slot's picture, measured in units of the picture's shorter side, so it
/// scales with the picture. Turns with the picture: the portrait top edge becomes the left edge
/// when the phone is held sideways.
public struct BezelGeometry: Equatable {
    public let style: BezelStyle
    public let landscape: Bool
    /// The frame's edges around the picture, as on screen.
    public let top: Double
    public let left: Double
    public let bottom: Double
    public let right: Double
    /// The rounding of the picture's corners and of the frame's outside.
    public let screenCornerRadius: Double
    public let outerCornerRadius: Double
    /// For a frame drawn from a photo: the photo's screen, from the frame's top left, as on
    /// screen. Painted black where the picture doesn't cover it (a picture a little narrower than
    /// the phone's screen, say), since the picture is never stretched to fit.
    public let artworkScreen: BezelRect?

    /// Portrait edges: top, sides, bottom; then the two corner radii.
    private static func portrait(_ style: BezelStyle) -> (top: Double, side: Double, bottom: Double, screen: Double, outer: Double) {
        switch style {
        case .homeButton: return (0.215, 0.06, 0.215, 0, 0.17)
        case .notch: return (0.075, 0.05, 0.05, 0.08, 0.13)
        case .dynamicIsland: return (0.07, 0.04, 0.04, 0.09, 0.13)
        default: return (0.1, 0.045, 0.1, 0.03, 0.08) // .plain
        }
    }

    public init(style: BezelStyle, pictureWidth: Double, pictureHeight: Double) {
        self.style = style
        landscape = pictureWidth > pictureHeight
        if let artwork = style.artwork {
            // The photo, turned a quarter left for a sideways phone, scaled so the picture fits
            // its screen and centered there.
            let shorter = max(1e-9, min(pictureWidth, pictureHeight))
            let picture = (width: max(pictureWidth, 1e-9) / shorter, height: max(pictureHeight, 1e-9) / shorter)
            let canvas = landscape ? (width: artwork.canvasHeight, height: artwork.canvasWidth) : (width: artwork.canvasWidth, height: artwork.canvasHeight)
            let upright = artwork.screen
            // A quarter turn left: (x, y, w, h) in a W×H canvas → (y, W − x − w, h, w).
            let screen = landscape
                ? BezelRect(x: upright.y, y: artwork.canvasWidth - upright.x - upright.width, width: upright.height, height: upright.width)
                : upright
            let scale = min(screen.width / picture.width, screen.height / picture.height) // pixels per unit
            let left = (screen.x + (screen.width - picture.width * scale) / 2) / scale
            let top = (screen.y + (screen.height - picture.height * scale) / 2) / scale
            self.left = left
            self.top = top
            right = canvas.width / scale - left - picture.width
            bottom = canvas.height / scale - top - picture.height
            screenCornerRadius = 0
            outerCornerRadius = 0
            artworkScreen = BezelRect(x: screen.x / scale, y: screen.y / scale, width: screen.width / scale, height: screen.height / scale)
            return
        }
        let edges = Self.portrait(style)
        artworkScreen = nil
        if landscape {
            top = edges.side
            left = edges.top
            bottom = edges.side
            right = edges.bottom
        } else {
            top = edges.top
            left = edges.side
            bottom = edges.bottom
            right = edges.side
        }
        screenCornerRadius = edges.screen
        outerCornerRadius = edges.outer
    }

    public init(modelCode: String?, pictureWidth: Double, pictureHeight: Double) {
        self.init(style: BezelStyle(modelCode: modelCode), pictureWidth: pictureWidth, pictureHeight: pictureHeight)
    }

    /// The whole frame's size, for a picture of this size, in units of the picture's shorter side.
    public func outerSize(pictureWidth: Double, pictureHeight: Double) -> (width: Double, height: Double) {
        let shorter = max(1e-9, min(pictureWidth, pictureHeight))
        return (pictureWidth / shorter + left + right, pictureHeight / shorter + top + bottom)
    }

    /// The frame's portrait size for a picture of this size (its longer side upright), in units of
    /// the shorter side: the space the frame's details are laid out in before turning sideways.
    public func portraitOuterSize(pictureWidth: Double, pictureHeight: Double) -> (width: Double, height: Double) {
        let size = outerSize(pictureWidth: pictureWidth, pictureHeight: pictureHeight)
        return landscape ? (size.height, size.width) : size
    }
}
