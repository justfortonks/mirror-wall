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
    /// the picture's shorter side. Laid out upright and turned a quarter left for a sideways
    /// phone, so the portrait top edge (notch, camera) ends up on the left.
    static func shapes(geometry: BezelGeometry, size: CGSize, unit: CGFloat) -> [Shape] {
        let upright = geometry.landscape ? CGSize(width: size.height, height: size.width) : size
        var shapes: [Shape] = []
        shapes.append(Shape(path: Path(roundedRect: CGRect(origin: .zero, size: upright), cornerRadius: geometry.outerCornerRadius * unit, style: .continuous), color: bodyColor))
        let rim = 0.012 * unit
        shapes.append(Shape(
            path: Path(roundedRect: CGRect(origin: .zero, size: upright).insetBy(dx: rim / 2, dy: rim / 2),
                       cornerRadius: max(0, geometry.outerCornerRadius * unit - rim / 2), style: .continuous),
            color: rimColor, lineWidth: rim
        ))

        // Portrait top and bottom edges, whichever way the phone is held.
        let topEdge = (geometry.landscape ? geometry.left : geometry.top) * unit
        let bottomEdge = (geometry.landscape ? geometry.right : geometry.bottom) * unit
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
        case .notch:
            let notch = CGRect(x: centerX - 0.22 * unit, y: 0.012 * unit, width: 0.44 * unit, height: max(0, topEdge - 0.012 * unit))
            shapes.append(Shape(path: Path(roundedRect: notch, cornerRadius: 0.04 * unit, style: .continuous), color: black))
            let speaker = CGRect(x: centerX - 0.06 * unit, y: topEdge / 2 - 0.008 * unit, width: 0.12 * unit, height: 0.016 * unit)
            shapes.append(Shape(path: Path(roundedRect: speaker, cornerRadius: speaker.height / 2), color: detailColor))
        case .dynamicIsland:
            let island = CGRect(x: centerX - 0.15 * unit, y: topEdge / 2 - 0.022 * unit, width: 0.3 * unit, height: 0.044 * unit)
            shapes.append(Shape(path: Path(roundedRect: island, cornerRadius: island.height / 2), color: black))
        default: // .plain; frames drawn from photos don't come here.
            let camera = CGRect(x: centerX - 0.018 * unit, y: topEdge / 2 - 0.018 * unit, width: 0.036 * unit, height: 0.036 * unit)
            shapes.append(Shape(path: Path(ellipseIn: camera), color: black))
            let speaker = CGRect(x: centerX - 0.08 * unit, y: topEdge / 4 - 0.008 * unit, width: 0.16 * unit, height: 0.016 * unit)
            shapes.append(Shape(path: Path(roundedRect: speaker, cornerRadius: speaker.height / 2), color: black))
        }
        guard geometry.landscape else { return shapes }
        // A quarter turn left: (x, y) → (y, height − x).
        let turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.height)
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

    static func overlay(style: BezelStyle, width: Int, height: Int) -> Overlay? {
        guard width > 0, height > 0 else { return nil }
        let geometry = BezelGeometry(style: style, pictureWidth: Double(width), pictureHeight: Double(height))
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
        guard let screen = geometry.artworkScreen, let photo = artworkImage(geometry.style, landscape: geometry.landscape) else { return nil }
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

    /// The photo a frame is drawn from, upright or turned a quarter left for a sideways phone, so
    /// its top edge (camera, earpiece) is on the left. Nil if the style has none or it's missing.
    static func artworkImage(_ style: BezelStyle, landscape: Bool) -> CGImage? {
        guard let artwork = style.artwork else { return nil }
        let key = "\(artwork.name) \(landscape)"
        artworkLock.lock()
        defer { artworkLock.unlock() }
        if let image = artworkCache[key] { return image }
        guard let upright = loadArtwork(artwork.name) else { return nil }
        var image = upright
        if landscape {
            guard let context = CGContext(
                data: nil,
                width: upright.height,
                height: upright.width,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }
            // y up: a quarter turn left takes the top edge to the left.
            context.translateBy(x: CGFloat(upright.height), y: 0)
            context.rotate(by: .pi / 2)
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
