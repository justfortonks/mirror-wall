import Foundation

/// The kind of phone frame drawn around a slot's picture when bezels are on, picked from the
/// phone's model code. The frame sits around the picture and never covers any of it, so a notch
/// or Dynamic Island is drawn in the frame's top edge rather than over the screen.
public enum BezelStyle: String, CaseIterable, Hashable {
    /// Deep top and bottom edges with a round home button: iPhone 8 and the SEs.
    case homeButton
    /// Even edges with a notch: iPhone X to 14, and 16e.
    case notch
    /// Even edges with a Dynamic Island: iPhone 14 Pro and later, and iPhones newer than this list.
    case dynamicIsland
    /// Any other phone (Android, or no phone yet): even edges, a little deeper at top and bottom,
    /// with a front camera.
    case plain
    case compactNotch, smallIsland, healthcare, rugged, tablet

    /// "iPhone14,6" → .homeButton, "iPhone18,2" → .dynamicIsland, "Zebra HC50" or nil → .plain.
    public init(modelCode: String?) {
        if let preset = BezelPreset.resolve(model: modelCode) {
            self = preset.style
            return
        }
        guard let code = modelCode, code.hasPrefix("iPhone") else {
            self = .plain
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

    /// Portrait edges: top, sides, bottom; then the two corner radii.
    private static func portrait(_ style: BezelStyle) -> (top: Double, side: Double, bottom: Double, screen: Double, outer: Double) {
        switch style {
        case .homeButton: return (0.215, 0.06, 0.215, 0, 0.17)
        case .compactNotch: return (0.065, 0.045, 0.045, 0.08, 0.13)
        case .smallIsland: return (0.06, 0.035, 0.035, 0.09, 0.13)
        case .healthcare: return (0.20, 0.095, 0.22, 0.015, 0.10)
        case .rugged: return (0.21, 0.11, 0.23, 0.015, 0.07)
        case .tablet: return (0.065, 0.065, 0.065, 0.025, 0.065)
        case .notch: return (0.075, 0.05, 0.05, 0.08, 0.13)
        case .dynamicIsland: return (0.07, 0.04, 0.04, 0.09, 0.13)
        case .plain: return (0.1, 0.045, 0.1, 0.03, 0.08)
        }
    }

    public init(style: BezelStyle, pictureWidth: Double, pictureHeight: Double, portraitAspect: Double? = nil) {
        var edges = Self.portrait(style)
        // Add frame area to fit the model silhouette; never stretch or crop the stream.
        if let aspect = portraitAspect, aspect.isFinite, aspect > 0,
           pictureWidth.isFinite, pictureHeight.isFinite, pictureWidth > 0, pictureHeight > 0 {
            let screenHeight = max(pictureWidth, pictureHeight) / min(pictureWidth, pictureHeight)
            let width = 1 + 2 * edges.side
            let height = screenHeight + edges.top + edges.bottom
            if width / height > aspect {
                let extra = (width / aspect - height) / 2
                edges.top += extra
                edges.bottom += extra
            } else {
                edges.side += (height * aspect - width) / 2
            }
        }
        self.style = style
        landscape = pictureWidth > pictureHeight
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
        self.init(style: BezelStyle(modelCode: modelCode), pictureWidth: pictureWidth, pictureHeight: pictureHeight,
                  portraitAspect: BezelPreset.resolve(model: modelCode)?.portraitAspect)
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
