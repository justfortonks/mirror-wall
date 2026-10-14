import MirrorCore
import SwiftUI

/// A phone-shaped frame around a slot's picture: the phone's body, drawn around the picture
/// without covering any of it, with a notch, Dynamic Island, home button or front camera to match
/// the phone's model. Takes the frame's shape itself, so it can be placed like the bare picture.
struct PhoneBezel<Content: View>: View {
    let geometry: BezelGeometry
    /// The picture's size (or shape), which the frame is built around.
    let picture: CGSize
    @ViewBuilder let content: Content

    static var bodyColor: Color { Color(red: 0.11, green: 0.11, blue: 0.12) }
    static var rimColor: Color { Color(red: 0.32, green: 0.32, blue: 0.34) }

    var body: some View {
        let outer = geometry.outerSize(pictureWidth: picture.width, pictureHeight: picture.height)
        GeometryReader { proxy in
            // Points per unit: one unit is the picture's shorter side.
            let unit = proxy.size.width / outer.width
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawFrame(in: &context, size: size, unit: unit)
                }
                content
                    .frame(
                        width: max(0, proxy.size.width - (geometry.left + geometry.right) * unit),
                        height: max(0, proxy.size.height - (geometry.top + geometry.bottom) * unit)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: geometry.screenCornerRadius * unit, style: .continuous))
                    .offset(x: geometry.left * unit, y: geometry.top * unit)
            }
        }
        .aspectRatio(outer.width / outer.height, contentMode: .fit)
    }

    /// Draws the frame upright and turns it a quarter left for a sideways phone, so the portrait
    /// top edge (notch, camera) ends up on the left.
    private func drawFrame(in context: inout GraphicsContext, size: CGSize, unit: CGFloat) {
        let upright = geometry.landscape ? CGSize(width: size.height, height: size.width) : size
        if geometry.landscape {
            context.translateBy(x: 0, y: size.height)
            context.rotate(by: .degrees(-90))
        }
        let phone = Path(roundedRect: CGRect(origin: .zero, size: upright), cornerRadius: geometry.outerCornerRadius * unit, style: .continuous)
        context.fill(phone, with: .color(Self.bodyColor))
        let rim = 0.012 * unit
        context.stroke(
            Path(roundedRect: CGRect(origin: .zero, size: upright).insetBy(dx: rim / 2, dy: rim / 2),
                 cornerRadius: max(0, geometry.outerCornerRadius * unit - rim / 2), style: .continuous),
            with: .color(Self.rimColor), lineWidth: rim
        )

        // Portrait top and bottom edges, whichever way the phone is held.
        let topEdge = (geometry.landscape ? geometry.left : geometry.top) * unit
        let bottomEdge = (geometry.landscape ? geometry.right : geometry.bottom) * unit
        let centerX = upright.width / 2
        let black = GraphicsContext.Shading.color(.black)
        let detail = GraphicsContext.Shading.color(Color(red: 0.2, green: 0.2, blue: 0.22))
        switch geometry.style {
        case .homeButton:
            let speaker = CGRect(x: centerX - 0.09 * unit, y: topEdge / 2 - 0.012 * unit, width: 0.18 * unit, height: 0.024 * unit)
            context.fill(Path(roundedRect: speaker, cornerRadius: speaker.height / 2), with: black)
            let camera = CGRect(x: centerX - 0.17 * unit, y: topEdge / 2 - 0.016 * unit, width: 0.032 * unit, height: 0.032 * unit)
            context.fill(Path(ellipseIn: camera), with: black)
            let diameter = 0.15 * unit
            let button = CGRect(x: centerX - diameter / 2, y: upright.height - bottomEdge / 2 - diameter / 2, width: diameter, height: diameter)
            context.stroke(Path(ellipseIn: button), with: detail, lineWidth: 0.012 * unit)
        case .notch:
            let notch = CGRect(x: centerX - 0.22 * unit, y: 0.012 * unit, width: 0.44 * unit, height: topEdge - 0.012 * unit)
            context.fill(Path(roundedRect: notch, cornerRadius: 0.04 * unit, style: .continuous), with: black)
            let speaker = CGRect(x: centerX - 0.06 * unit, y: topEdge / 2 - 0.008 * unit, width: 0.12 * unit, height: 0.016 * unit)
            context.fill(Path(roundedRect: speaker, cornerRadius: speaker.height / 2), with: detail)
        case .dynamicIsland:
            let island = CGRect(x: centerX - 0.15 * unit, y: topEdge / 2 - 0.022 * unit, width: 0.3 * unit, height: 0.044 * unit)
            context.fill(Path(roundedRect: island, cornerRadius: island.height / 2), with: black)
        case .plain:
            let camera = CGRect(x: centerX - 0.018 * unit, y: topEdge / 2 - 0.018 * unit, width: 0.036 * unit, height: 0.036 * unit)
            context.fill(Path(ellipseIn: camera), with: black)
            let speaker = CGRect(x: centerX - 0.08 * unit, y: topEdge / 4 - 0.008 * unit, width: 0.16 * unit, height: 0.016 * unit)
            context.fill(Path(roundedRect: speaker, cornerRadius: speaker.height / 2), with: black)
        }
    }
}
