namespace MirrorWall.Core;

/// <summary>
/// The kind of phone frame drawn around a slot's picture when bezels are on, picked from the
/// phone's model code. The frame sits around the picture and never covers any of it, so a notch
/// or Dynamic Island is drawn in the frame's top edge rather than over the screen. The Mac app's
/// BezelStyle.
/// </summary>
public enum BezelStyle
{
    /// <summary>Deep top and bottom edges with a round home button: iPhone 8 and the SEs.</summary>
    HomeButton,
    /// <summary>Even edges with a notch: iPhone X to 14, and 16e.</summary>
    Notch,
    /// <summary>Even edges with a Dynamic Island: iPhone 14 Pro and later, and iPhones newer than this list.</summary>
    DynamicIsland,
    /// <summary>Any other phone (Android, or no phone yet): even edges, a little deeper at top and
    /// bottom, with a front camera.</summary>
    Plain,
}

/// <summary>
/// The frame around a slot's picture, measured in units of the picture's shorter side, so it
/// scales with the picture. Turns with the picture: the portrait top edge becomes the left edge
/// when the phone is held sideways. The Mac app's BezelGeometry.
/// </summary>
public sealed record BezelGeometry
{
    public BezelStyle Style { get; }
    public bool Landscape { get; }
    /// <summary>The frame's edges around the picture, as on screen.</summary>
    public double Top { get; }
    public double Left { get; }
    public double Bottom { get; }
    public double Right { get; }
    /// <summary>The rounding of the picture's corners and of the frame's outside.</summary>
    public double ScreenCornerRadius { get; }
    public double OuterCornerRadius { get; }

    /// <summary>"iPhone14,6" → HomeButton, "iPhone18,2" → DynamicIsland, "Zebra HC50" or null → Plain.</summary>
    public static BezelStyle StyleFor(string? modelCode)
    {
        if (modelCode == null || !modelCode.StartsWith("iPhone", StringComparison.Ordinal)) return BezelStyle.Plain;
        string[] numbers = modelCode["iPhone".Length..].Split(',');
        if (numbers.Length != 2 || !int.TryParse(numbers[0], out int major) || !int.TryParse(numbers[1], out int minor))
            return BezelStyle.Plain;
        return (major, minor) switch
        {
            (10, 3) or (10, 6) => BezelStyle.Notch,                  // iPhone X
            (12, 8) or (14, 6) => BezelStyle.HomeButton,             // iPhone SE (2nd and 3rd generation)
            (14, 7) or (14, 8) or (17, 5) => BezelStyle.Notch,       // iPhone 14, 14 Plus, 16e
            ( <= 10, _) => BezelStyle.HomeButton,                    // iPhone 8 and earlier
            ( <= 14, _) => BezelStyle.Notch,                         // iPhone XS to 13
            _ => BezelStyle.DynamicIsland,
        };
    }

    /// <summary>Portrait edges: top, sides, bottom; then the two corner radii.</summary>
    private static (double Top, double Side, double Bottom, double Screen, double Outer) Portrait(BezelStyle style) => style switch
    {
        BezelStyle.HomeButton => (0.215, 0.06, 0.215, 0, 0.17),
        BezelStyle.Notch => (0.075, 0.05, 0.05, 0.08, 0.13),
        BezelStyle.DynamicIsland => (0.07, 0.04, 0.04, 0.09, 0.13),
        _ => (0.1, 0.045, 0.1, 0.03, 0.08),
    };

    public BezelGeometry(BezelStyle style, double pictureWidth, double pictureHeight)
    {
        var edges = Portrait(style);
        Style = style;
        Landscape = pictureWidth > pictureHeight;
        if (Landscape)
        {
            (Top, Left, Bottom, Right) = (edges.Side, edges.Top, edges.Side, edges.Bottom);
        }
        else
        {
            (Top, Left, Bottom, Right) = (edges.Top, edges.Side, edges.Bottom, edges.Side);
        }
        ScreenCornerRadius = edges.Screen;
        OuterCornerRadius = edges.Outer;
    }

    public BezelGeometry(string? modelCode, double pictureWidth, double pictureHeight)
        : this(StyleFor(modelCode), pictureWidth, pictureHeight)
    {
    }

    /// <summary>The whole frame's size, for a picture of this size, in units of the picture's shorter side.</summary>
    public (double Width, double Height) OuterSize(double pictureWidth, double pictureHeight)
    {
        double shorter = Math.Max(1e-9, Math.Min(pictureWidth, pictureHeight));
        return (pictureWidth / shorter + Left + Right, pictureHeight / shorter + Top + Bottom);
    }
}
