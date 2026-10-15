import MirrorCore
import SwiftUI

/// A phone-shaped frame around a slot's picture: the phone's body, drawn around the picture
/// without covering any of it, with a notch, Dynamic Island, home button or front camera to match
/// the phone's model, or a photo of the phone's front for the Android phones that have one. Takes
/// the frame's shape itself, so it can be placed like the bare picture.
struct PhoneBezel<Content: View>: View {
    let geometry: BezelGeometry
    /// The picture's size (or shape), which the frame is built around.
    let picture: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        let outer = geometry.outerSize(pictureWidth: picture.width, pictureHeight: picture.height)
        GeometryReader { proxy in
            // Points per unit: one unit is the picture's shorter side.
            let unit = proxy.size.width / outer.width
            if let screen = geometry.artworkScreen,
               let photo = PhoneBezelDrawing.artworkImage(geometry.style, landscape: geometry.landscape) {
                // A photo of the phone's front over the picture, with black showing in any of
                // its screen the picture doesn't cover.
                ZStack(alignment: .topLeading) {
                    Color.black
                        .frame(width: screen.width * unit, height: screen.height * unit)
                        .offset(x: screen.x * unit, y: screen.y * unit)
                    content
                        .frame(
                            width: max(0, proxy.size.width - (geometry.left + geometry.right) * unit),
                            height: max(0, proxy.size.height - (geometry.top + geometry.bottom) * unit)
                        )
                        .clipped()
                        .offset(x: geometry.left * unit, y: geometry.top * unit)
                    Image(decorative: photo, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .allowsHitTesting(false)
                }
            } else {
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
        }
        .aspectRatio(outer.width / outer.height, contentMode: .fit)
    }

    private func drawFrame(in context: inout GraphicsContext, size: CGSize, unit: CGFloat) {
        for shape in PhoneBezelDrawing.shapes(geometry: geometry, size: size, unit: unit) {
            let color = GraphicsContext.Shading.color(Color(cgColor: shape.color))
            if let lineWidth = shape.lineWidth {
                context.stroke(shape.path, with: color, lineWidth: lineWidth)
            } else {
                context.fill(shape.path, with: color)
            }
        }
    }
}
