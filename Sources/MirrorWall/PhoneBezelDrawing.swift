import CoreGraphics
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
        shapes.append(Shape(path: Path(roundedRect: CGRect(origin: .zero, size: upright), cornerRadius: geometry.outerCornerRadius * unit, style: .continuous), color: geometry.style == .healthcare ? CGColor(gray: 0.87, alpha: 1) : bodyColor))
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
            // A16 iPad camera is on the long edge; rotation carries it to the top/bottom edge.
            let side = (geometry.landscape ? geometry.top : geometry.left) * unit
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
        case .plain:
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

    static func overlay(style: BezelStyle, width: Int, height: Int, portraitAspect: Double? = nil) -> Overlay? {
        guard width > 0, height > 0 else { return nil }
        let geometry = BezelGeometry(style: style, pictureWidth: Double(width), pictureHeight: Double(height), portraitAspect: portraitAspect)
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
}
