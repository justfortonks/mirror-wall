namespace MirrorWall.Core;

/// <summary>How the Stage window arranges the phones that are mirroring.</summary>
public enum StageLayout
{
    /// <summary>In a row, lined up on their middles.</summary>
    SideBySide,
    /// <summary>In a column, lined up on their middles.</summary>
    Stacked,
    /// <summary>In rows of equal cells, the last row centered.</summary>
    Grid,
}

/// <summary>Where one phone goes on the stage, y pointing down.</summary>
public readonly record struct StageRect(double X, double Y, double Width, double Height);

public static class Stage
{
    public static string Title(StageLayout layout) => layout switch
    {
        StageLayout.SideBySide => "Side by Side",
        StageLayout.Stacked => "Stacked",
        _ => "Grid",
    };

    /// <summary>
    /// A phone's size on the stage, in units where an iPhone 17 Pro Max picture's longer side is 1,
    /// so phones keep their true relative sizes: the picture's shape, scaled to the phone's real
    /// screen, plus its frame when it has one.
    /// </summary>
    public static (double Width, double Height) PhoneSize(string? modelCode, double pictureWidth, double pictureHeight, bool bezel)
    {
        bool known = pictureWidth > 0 && pictureHeight > 0;
        double width = known ? pictureWidth : 9, height = known ? pictureHeight : 19.5;
        double longSide = PhoneModels.TrueToLifeLongSide(1, modelCode, width, height);
        double scale = longSide / Math.Max(width, height);
        if (!bezel) return (width * scale, height * scale);
        var outer = new BezelGeometry(modelCode, width, height).OuterSize(width, height);
        double unit = Math.Min(width, height) * scale;
        return (outer.Width * unit, outer.Height * unit);
    }

    /// <summary>
    /// Lays phones of these sizes (any units, kept relative to each other) out on a stage of this
    /// size: as big as fits, centered, with gaps between them and around the edge of
    /// <paramref name="spacing"/> times the biggest phone's longer side.
    /// </summary>
    public static StageRect[] Frames(IReadOnlyList<(double Width, double Height)> sizes, StageLayout layout, double areaWidth, double areaHeight, double spacing = 0.06)
    {
        if (sizes.Count == 0) return [];
        double gap = spacing * sizes.Max(s => Math.Max(s.Width, s.Height));
        var placed = new StageRect[sizes.Count];
        double contentWidth = 0, contentHeight = 0;

        switch (layout)
        {
            case StageLayout.SideBySide:
                contentHeight = sizes.Max(s => s.Height);
                for (int i = 0; i < sizes.Count; i++)
                {
                    if (i > 0) contentWidth += gap;
                    placed[i] = new StageRect(contentWidth, (contentHeight - sizes[i].Height) / 2, sizes[i].Width, sizes[i].Height);
                    contentWidth += sizes[i].Width;
                }
                break;
            case StageLayout.Stacked:
                contentWidth = sizes.Max(s => s.Width);
                for (int i = 0; i < sizes.Count; i++)
                {
                    if (i > 0) contentHeight += gap;
                    placed[i] = new StageRect((contentWidth - sizes[i].Width) / 2, contentHeight, sizes[i].Width, sizes[i].Height);
                    contentHeight += sizes[i].Height;
                }
                break;
            default:
                int columns = (int)Math.Ceiling(Math.Sqrt(sizes.Count));
                int rows = (sizes.Count + columns - 1) / columns;
                double cellWidth = sizes.Max(s => s.Width), cellHeight = sizes.Max(s => s.Height);
                contentWidth = columns * cellWidth + (columns - 1) * gap;
                contentHeight = rows * cellHeight + (rows - 1) * gap;
                for (int i = 0; i < sizes.Count; i++)
                {
                    int row = i / columns;
                    int inRow = Math.Min(columns, sizes.Count - row * columns);
                    double indent = (columns - inRow) * (cellWidth + gap) / 2;
                    double cellX = indent + i % columns * (cellWidth + gap);
                    double cellY = row * (cellHeight + gap);
                    placed[i] = new StageRect(cellX + (cellWidth - sizes[i].Width) / 2, cellY + (cellHeight - sizes[i].Height) / 2, sizes[i].Width, sizes[i].Height);
                }
                break;
        }

        if (areaWidth <= 0 || areaHeight <= 0) return placed.Select(_ => new StageRect(0, 0, 0, 0)).ToArray();
        double scale = Math.Min(areaWidth / (contentWidth + 2 * gap), areaHeight / (contentHeight + 2 * gap));
        double originX = (areaWidth - contentWidth * scale) / 2, originY = (areaHeight - contentHeight * scale) / 2;
        return placed.Select(r => new StageRect(originX + r.X * scale, originY + r.Y * scale, r.Width * scale, r.Height * scale)).ToArray();
    }
}
