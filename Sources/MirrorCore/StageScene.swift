import Foundation

// What the Stage shows and where: phones, Mac windows and cameras, placed by one of the automatic
// layouts (StageLayout.swift) or freely, by dragging. A set of them is an arrangement, which can
// be saved under a name as a layout.

/// What kind of picture an item on the Stage shows.
public enum StageSourceKind: String, Codable, CaseIterable {
    case phone
    case window
    case camera
}

/// One picture on the Stage: which source it shows, and where it goes in a free arrangement.
public struct StageItem: Codable, Equatable, Identifiable {
    public var id: UUID
    public var kind: StageSourceKind
    /// Which source: a phone's slot number ("2"), a Mac window's name as Mirror Wall calls it
    /// ("Safari – Docs"), or a camera's device ID.
    public var key: String
    /// A name to show while the source isn't there: "Slot 2", "Safari – Docs", "Logitech Brio".
    public var label: String
    /// Where it goes in a free arrangement, as fractions of the Stage's width and height (y
    /// pointing down). The picture fits inside this box, centered. Nil until it has been placed.
    public var frame: StageRect?

    public init(id: UUID = UUID(), kind: StageSourceKind, key: String, label: String, frame: StageRect? = nil) {
        self.id = id
        self.kind = kind
        self.key = key
        self.label = label
        self.frame = frame
    }
}

/// The items on the Stage, and how they're placed.
public struct StageArrangement: Codable, Equatable {
    /// How items are placed for you, or nil to place them freely, each where its `frame` says.
    public var automatic: StageLayout?
    /// In drawing order: later items are in front of earlier ones.
    public var items: [StageItem]

    public init(automatic: StageLayout? = .sideBySide, items: [StageItem] = []) {
        self.automatic = automatic
        self.items = items
    }

    public var isFree: Bool { automatic == nil }
}

/// An arrangement saved under a name, to come back to.
public struct SavedStageLayout: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var arrangement: StageArrangement

    public init(id: UUID = UUID(), name: String, arrangement: StageArrangement) {
        self.id = id
        self.name = name
        self.arrangement = arrangement
    }
}

// MARK: - Sizes

/// The size of a Mac window's or camera's picture on the Stage in an automatic layout, in the
/// same units as `stagePhoneSize` (an iPhone 17 Pro Max's longer side is 1): a landscape picture
/// is 1.2 wide, so a window beside a phone is a little shorter than the phone, and a portrait one
/// is 1 tall.
public func stageSourceSize(aspect: Double) -> (width: Double, height: Double) {
    guard aspect > 0 else { return (1.2, 1.2 * 9 / 16) }
    return aspect >= 1 ? (1.2, 1.2 / aspect) : (aspect, 1)
}

/// A starting box for an item put into a free arrangement; each new one sits a little lower and
/// further right than the one before, so they don't hide each other.
public func stageDefaultFrame(index: Int) -> StageRect {
    let step = Double(max(0, index) % 6) * 0.03
    return StageRect(x: 0.2 + step, y: 0.12 + step, width: 0.3, height: 0.6)
}

// MARK: - Fitting, moving and resizing

extension StageRect {
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    /// Every coordinate and size multiplied: x and width by `sx`, y and height by `sy`. Turns a
    /// rectangle in fractions of the Stage into points, or back.
    public func scaled(x sx: Double, y sy: Double) -> StageRect {
        StageRect(x: x * sx, y: y * sy, width: width * sx, height: height * sy)
    }

    public func offsetBy(dx: Double, dy: Double) -> StageRect {
        StageRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// Moved the least it takes to lie inside `bounds`, at the same size; a rectangle bigger than
    /// the bounds lines up with their top left.
    public func clamped(inside bounds: StageRect) -> StageRect {
        let farthestX = max(bounds.x, bounds.maxX - width)
        let farthestY = max(bounds.y, bounds.maxY - height)
        return StageRect(x: min(max(x, bounds.x), farthestX), y: min(max(y, bounds.y), farthestY), width: width, height: height)
    }

    /// Resized by dragging `corner` by (`dx`, `dy`) while the opposite corner stays put and the
    /// shape stays the same, no smaller than `minWidth` wide (unless `bounds` leaves no room)
    /// and no bigger than fits inside `bounds`.
    public func resizing(corner: StageCorner, dx: Double, dy: Double, minWidth: Double, bounds: StageRect) -> StageRect {
        guard width > 0, height > 0 else { return self }
        // Dragging outward grows it, whichever corner it is.
        let growX = corner.isLeft ? -dx : dx
        let growY = corner.isTop ? -dy : dy
        let scale = ((width + growX) * width + (height + growY) * height) / (width * width + height * height)
        let ratio = height / width
        let anchorX = corner.isLeft ? maxX : x
        let anchorY = corner.isTop ? maxY : y
        let roomX = corner.isLeft ? anchorX - bounds.x : bounds.maxX - anchorX
        let roomY = corner.isTop ? anchorY - bounds.y : bounds.maxY - anchorY
        let newWidth = max(0, min(max(minWidth, width * scale), roomX, roomY / ratio))
        let newHeight = newWidth * ratio
        return StageRect(x: corner.isLeft ? anchorX - newWidth : anchorX, y: corner.isTop ? anchorY - newHeight : anchorY, width: newWidth, height: newHeight)
    }
}

/// The corners of an item that can be dragged to resize it.
public enum StageCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    public var isTop: Bool { self == .topLeft || self == .topRight }
}

/// The biggest rectangle of this shape (width over height) that fits in `box`, centered in it.
/// With no sensible shape, or an empty box, the box itself.
public func stageFit(aspect: Double, in box: StageRect) -> StageRect {
    guard aspect > 0, box.width > 0, box.height > 0 else { return box }
    if aspect > box.width / box.height {
        let height = box.width / aspect
        return StageRect(x: box.x, y: box.y + (box.height - height) / 2, width: box.width, height: height)
    }
    let width = box.height * aspect
    return StageRect(x: box.x + (box.width - width) / 2, y: box.y, width: width, height: box.height)
}

/// How far to shift a rectangle being dragged so that its left, middle or right lines up with
/// one of `xTargets`, and its top, middle or bottom with one of `yTargets`, when one is within
/// `threshold`; zero on an axis where nothing is close enough.
public func stageSnapOffset(for rect: StageRect, xTargets: [Double], yTargets: [Double], threshold: Double) -> (dx: Double, dy: Double) {
    func nearest(of edges: [Double], to targets: [Double]) -> Double {
        var best: Double?
        for edge in edges {
            for target in targets {
                let delta = target - edge
                if abs(delta) <= threshold, best == nil || abs(delta) < abs(best!) { best = delta }
            }
        }
        return best ?? 0
    }
    return (nearest(of: [rect.x, rect.midX, rect.maxX], to: xTargets), nearest(of: [rect.y, rect.midY, rect.maxY], to: yTargets))
}
