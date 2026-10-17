import CoreGraphics
import Foundation
import ImageIO
import MirrorCore
import SwiftUI

/// The shapes of a phone frame (see `PhoneBezel`), shared by the frame drawn on screen and the
/// one sent down a slot's OBS feed, so they look the same.
enum PhoneBezelDrawing {
    static let bodyColor = CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    static let rimColor = CGColor(srgbRed: 0.32, green: 0.32, blue: 0.34, alpha: 1)
    static let detailColor = CGColor(srgbRed: 0.2, green: 0.2, blue: 0.22, alpha: 1)
    static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    struct Shape {
        let path: Path
        let color: CGColor
        /// Nil to fill the path, else the width of its outline.
        var lineWidth: CGFloat?
    }

    /// The frame filling `size`, in back-to-front order, with y pointing down and `unit` points to
    /// the picture's shorter side. Laid out upright and turned as the phone is held, so for a
    /// sideways phone the portrait top edge (notch, camera) usually ends up on the left.
    static func shapes(geometry: BezelGeometry, size: CGSize, unit: CGFloat) -> [Shape] {
        let upright = geometry.landscape ? CGSize(width: size.height, height: size.width) : size
        var shapes: [Shape] = []
        shapes.append(Shape(path: Path(roundedRect: CGRect(origin: .zero, size: upright), cornerRadius: geometry.outerCornerRadius * unit, style: .continuous), color: geometry.style == .healthcare ? CGColor(gray: 0.87, alpha: 1) : bodyColor))
        let rim = 0.012 * unit
        shapes.append(Shape(
            path: Path(roundedRect: CGRect(origin: .zero, size: upright).insetBy(dx: rim / 2, dy: rim / 2),
                       cornerRadius: max(0, geometry.outerCornerRadius * unit - rim / 2), style: .continuous),
            color: rimColor, lineWidth: rim
        ))

        // Portrait top and bottom edges, whichever way the phone is held.
        let topEdge = geometry.uprightTop * unit
        let bottomEdge = geometry.uprightBottom * unit
        let centerX = upright.width / 2
        switch geometry.style {
        case .homeButton:
            let speaker = CGRect(x: centerX - 0.09 * unit, y: topEdge / 2 - 0.012 * unit, width: 0.18 * unit, height: 0.024 * unit)
            shapes.append(Shape(path: Path(roundedRect: speaker, cornerRadius: speaker.height / 2), color: black))
            let camera = CGRect(x: centerX - 0.17 * unit, y: topEdge / 2 - 0.016 * unit, width: 0.032 * unit, height: 0.032 * unit)
            shapes.append(Shape(path: Path(ellipseIn: camera), color: black))
            let diameter = 0.15 * unit
            let button = CGRect(x: centerX - diameter / 2, y: upright.height - bottomEdge / 2 - diameter / 2, width: diameter, height: diameter)
            shapes.append(Shape(path: Path(ellipseIn: button), color: detailColor, lineWidth: 0.012 * unit))
        case .notch, .compactNotch:
            let notchWidth = (geometry.style == .compactNotch ? 0.32 : 0.44) * unit
            let notch = CGRect(x: centerX - notchWidth / 2, y: 0.012 * unit, width: notchWidth, height: max(0, topEdge - 0.012 * unit))
            shapes.append(Shape(path: Path(roundedRect: notch, cornerRadius: 0.04 * unit, style: .continuous), color: black))
            let speaker = CGRect(x: centerX - 0.06 * unit, y: topEdge / 2 - 0.008 * unit, width: 0.12 * unit, height: 0.016 * unit)
            shapes.append(Shape(path: Path(roundedRect: speaker, cornerRadius: speaker.height / 2), color: detailColor))
        case .dynamicIsland, .smallIsland:
            let islandWidth = (geometry.style == .smallIsland ? 0.23 : 0.30) * unit
            let island = CGRect(x: centerX - islandWidth / 2, y: topEdge / 2 - 0.022 * unit, width: islandWidth, height: 0.044 * unit)
            shapes.append(Shape(path: Path(roundedRect: island, cornerRadius: island.height / 2), color: black))
        case .tablet:
            // The A16 iPad's camera is on its long edge (drawn upright here, then turned with the
            // rest); its edges are all the same width.
            let side = topEdge
            let camera = CGRect(x: side / 2 - 0.012 * unit, y: upright.height / 2 - 0.012 * unit, width: 0.024 * unit, height: 0.024 * unit)
            shapes.append(Shape(path: Path(ellipseIn: camera), color: black))
        case .healthcare, .rugged:
            let speaker = CGRect(x: centerX - 0.16 * unit, y: topEdge * 0.35, width: 0.32 * unit, height: 0.025 * unit)
            shapes.append(Shape(path: Path(roundedRect: speaker, cornerRadius: 0.01 * unit), color: black))
            let camera = CGRect(x: centerX + 0.22 * unit, y: topEdge * 0.35, width: 0.035 * unit, height: 0.035 * unit)
            shapes.append(Shape(path: Path(ellipseIn: camera), color: black))
            for x in [-0.13, 0.0, 0.13] {
                let grille = CGRect(x: centerX + x * unit - 0.035 * unit, y: upright.height - bottomEdge * 0.55, width: 0.07 * unit, height: 0.018 * unit)
                shapes.append(Shape(path: Path(roundedRect: grille, cornerRadius: 0.006 * unit), color: black))
            }
            if geometry.style == .rugged {
                let bumper = CGRect(x: 0.015 * unit, y: upright.height * 0.18, width: 0.035 * unit, height: upright.height * 0.64)
                shapes.append(Shape(path: Path(roundedRect: bumper, cornerRadius: 0.01 * unit), color: rimColor))
                shapes.append(Shape(path: Path(roundedRect: bumper.offsetBy(dx: upright.width - 0.065 * unit, dy: 0), cornerRadius: 0.01 * unit), color: rimColor))
            }
        default: // .plain; frames drawn from photos don't come here.
            let camera = CGRect(x: centerX - 0.018 * unit, y: topEdge / 2 - 0.018 * unit, width: 0.036 * unit, height: 0.036 * unit)
            shapes.append(Shape(path: Path(ellipseIn: camera), color: black))
            let speaker = CGRect(x: centerX - 0.08 * unit, y: topEdge / 4 - 0.008 * unit, width: 0.16 * unit, height: 0.016 * unit)
            shapes.append(Shape(path: Path(roundedRect: speaker, cornerRadius: speaker.height / 2), color: black))
        }
        let turn: CGAffineTransform
        switch geometry.quarterTurns {
        case 1: turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.height)          // (x, y) → (y, height − x)
        case 2: turn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height) // (x, y) → (width − x, height − y)
        case 3: turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.width, ty: 0)           // (x, y) → (width − y, x)
        default: return shapes
        }
        return shapes.map { Shape(path: $0.path.applying(turn), color: $0.color, lineWidth: $0.lineWidth) }
    }

    /// A frame for the OBS feed, around a picture of `width`×`height` pixels: the phone's body
    /// with a see-through screen for the picture to show through, see-through outside its
    /// rounded corners too. The insets say where the picture goes, in whole pixels.
    struct Overlay {
        let image: CGImage
        let left: Int
        let top: Int
        let bottom: Int
    }

    static func overlay(style: BezelStyle, width: Int, height: Int, portraitAspect: Double? = nil, turns: Int? = nil) -> Overlay? {
        guard width > 0, height > 0 else { return nil }
        let geometry = BezelGeometry(style: style, pictureWidth: Double(width), pictureHeight: Double(height), portraitAspect: portraitAspect, turns: turns)
        if geometry.artworkScreen != nil, let overlay = artworkOverlay(geometry: geometry, width: width, height: height) {
            return overlay
        }
        let unit = CGFloat(min(width, height))
        let left = Int((geometry.left * unit).rounded())
        let top = Int((geometry.top * unit).rounded())
        let right = Int((geometry.right * unit).rounded())
        let bottom = Int((geometry.bottom * unit).rounded())
        let size = CGSize(width: width + left + right, height: height + top + bottom)
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // y down, as on screen.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        for shape in shapes(geometry: geometry, size: size, unit: unit) {
            context.addPath(shape.path.cgPath)
            if let lineWidth = shape.lineWidth {
                context.setStrokeColor(shape.color)
                context.setLineWidth(lineWidth)
                context.strokePath()
            } else {
                context.setFillColor(shape.color)
                context.fillPath()
            }
        }
        let screen = CGRect(x: left, y: top, width: width, height: height)
        context.setBlendMode(.clear)
        context.addPath(Path(roundedRect: screen, cornerRadius: geometry.screenCornerRadius * unit, style: .continuous).cgPath)
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        return Overlay(image: image, left: left, top: top, bottom: bottom)
    }

    /// The photo frame for the OBS feed: black where the photo's screen isn't covered by the
    /// picture, see-through where it is, with the photo on top (its screen's rounded corners can
    /// sit over the picture's corners).
    private static func artworkOverlay(geometry: BezelGeometry, width: Int, height: Int) -> Overlay? {
        guard let screen = geometry.artworkScreen, let photo = artworkImage(geometry.style, turns: geometry.quarterTurns) else { return nil }
        let unit = CGFloat(min(width, height))
        let left = Int((geometry.left * unit).rounded())
        let top = Int((geometry.top * unit).rounded())
        let right = Int((geometry.right * unit).rounded())
        let bottom = Int((geometry.bottom * unit).rounded())
        let size = CGSize(width: width + left + right, height: height + top + bottom)
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // y up here.
        context.setFillColor(black)
        context.fill(CGRect(x: screen.x * unit, y: size.height - (screen.y + screen.height) * unit, width: screen.width * unit, height: screen.height * unit))
        context.clear(CGRect(x: left, y: bottom, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(photo, in: CGRect(origin: .zero, size: size))
        guard let image = context.makeImage() else { return nil }
        return Overlay(image: image, left: left, top: top, bottom: bottom)
    }

    private static let artworkLock = NSLock()
    private static var artworkCache: [String: CGImage] = [:]

    /// The photo a frame is drawn from, turned `turns` quarter turns left (1: its top edge, camera
    /// and earpiece, on the left). Nil if the style has none or it's missing.
    static func artworkImage(_ style: BezelStyle, turns: Int) -> CGImage? {
        guard let artwork = style.artwork else { return nil }
        let turns = turns & 3
        let key = "\(artwork.name) \(turns)"
        artworkLock.lock()
        defer { artworkLock.unlock() }
        if let image = artworkCache[key] { return image }
        guard let upright = loadArtwork(artwork.name) else { return nil }
        var image = upright
        if turns != 0 {
            let sideways = turns & 1 == 1
            guard let context = CGContext(
                data: nil,
                width: sideways ? upright.height : upright.width,
                height: sideways ? upright.width : upright.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }
            // y up, so positive angles turn left.
            switch turns {
            case 1: context.translateBy(x: CGFloat(upright.height), y: 0)
            case 2: context.translateBy(x: CGFloat(upright.width), y: CGFloat(upright.height))
            default: context.translateBy(x: 0, y: CGFloat(upright.width))
            }
            context.rotate(by: CGFloat(turns == 3 ? -1 : turns) * .pi / 2)
            context.draw(upright, in: CGRect(x: 0, y: 0, width: upright.width, height: upright.height))
            guard let turned = context.makeImage() else { return nil }
            image = turned
        }
        artworkCache[key] = image
        return image
    }

    /// From the app's Resources/Bezels, or the build folder's resource bundle when run unpackaged.
    private static func loadArtwork(_ name: String) -> CGImage? {
        var url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Bezels")
        if url == nil, Bundle.main.bundleURL.pathExtension != "app" {
            url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Bezels")
        }
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
