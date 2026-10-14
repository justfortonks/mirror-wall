import Foundation

/// How the Stage window arranges the phones that are mirroring.
public enum StageLayout: String, CaseIterable, Identifiable {
    /// In a row, lined up on their middles.
    case sideBySide
    /// In a column, lined up on their middles.
    case stacked
    /// In rows of equal cells, the last row centered.
    case grid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sideBySide: return "Side by Side"
        case .stacked: return "Stacked"
        case .grid: return "Grid"
        }
    }
}

/// Where one phone goes on the stage, y pointing down.
public struct StageRect: Equatable {
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

/// A phone's size on the stage, in units where an iPhone 17 Pro Max picture's longer side is 1,
/// so phones keep their true relative sizes: the picture's shape, scaled to the phone's real
/// screen, plus its frame when it has one.
public func stagePhoneSize(modelCode: String?, pictureWidth: Double, pictureHeight: Double, bezel: Bool) -> (width: Double, height: Double) {
    let width = pictureWidth > 0 && pictureHeight > 0 ? pictureWidth : 9
    let height = pictureWidth > 0 && pictureHeight > 0 ? pictureHeight : 19.5
    let longSide = trueToLifeLongSide(reference: 1, modelCode: modelCode, pictureWidth: width, pictureHeight: height)
    let scale = longSide / max(width, height)
    guard bezel else { return (width * scale, height * scale) }
    let outer = BezelGeometry(modelCode: modelCode, pictureWidth: width, pictureHeight: height)
        .outerSize(pictureWidth: width, pictureHeight: height)
    let unit = min(width, height) * scale
    return (outer.width * unit, outer.height * unit)
}

/// Lays phones of these sizes (any units, kept relative to each other) out on a stage of this
/// size: as big as fits, centered, with gaps between them and around the edge of `spacing` times
/// the biggest phone's longer side.
public func stageFrames(sizes: [(width: Double, height: Double)], layout: StageLayout, areaWidth: Double, areaHeight: Double, spacing: Double = 0.06) -> [StageRect] {
    guard !sizes.isEmpty else { return [] }
    let gap = spacing * sizes.map { max($0.width, $0.height) }.max()!
    var placed: [StageRect] = []
    var contentWidth = 0.0
    var contentHeight = 0.0

    switch layout {
    case .sideBySide:
        contentHeight = sizes.map(\.height).max()!
        for size in sizes {
            if !placed.isEmpty { contentWidth += gap }
            placed.append(StageRect(x: contentWidth, y: (contentHeight - size.height) / 2, width: size.width, height: size.height))
            contentWidth += size.width
        }
    case .stacked:
        contentWidth = sizes.map(\.width).max()!
        for size in sizes {
            if !placed.isEmpty { contentHeight += gap }
            placed.append(StageRect(x: (contentWidth - size.width) / 2, y: contentHeight, width: size.width, height: size.height))
            contentHeight += size.height
        }
    case .grid:
        let columns = Int(Double(sizes.count).squareRoot().rounded(.up))
        let rows = (sizes.count + columns - 1) / columns
        let cellWidth = sizes.map(\.width).max()!
        let cellHeight = sizes.map(\.height).max()!
        contentWidth = Double(columns) * cellWidth + Double(columns - 1) * gap
        contentHeight = Double(rows) * cellHeight + Double(rows - 1) * gap
        for (index, size) in sizes.enumerated() {
            let row = index / columns
            let inRow = min(columns, sizes.count - row * columns)
            let indent = Double(columns - inRow) * (cellWidth + gap) / 2
            let cellX = indent + Double(index % columns) * (cellWidth + gap)
            let cellY = Double(row) * (cellHeight + gap)
            placed.append(StageRect(x: cellX + (cellWidth - size.width) / 2, y: cellY + (cellHeight - size.height) / 2, width: size.width, height: size.height))
        }
    }

    guard areaWidth > 0, areaHeight > 0 else {
        return placed.map { _ in StageRect(x: 0, y: 0, width: 0, height: 0) }
    }
    let scale = min(areaWidth / (contentWidth + 2 * gap), areaHeight / (contentHeight + 2 * gap))
    let originX = (areaWidth - contentWidth * scale) / 2
    let originY = (areaHeight - contentHeight * scale) / 2
    return placed.map {
        StageRect(x: originX + $0.x * scale, y: originY + $0.y * scale, width: $0.width * scale, height: $0.height * scale)
    }
}
