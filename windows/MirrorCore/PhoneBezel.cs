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
    /// <summary>Android phones drawn from a photo of their front (see <see cref="BezelArtwork"/>).</summary>
    ZebraHC50,
    HoneywellCT37,
    Versity95,
    Versity97,
}

/// <summary>A rectangle, y counting down from the top.</summary>
public readonly record struct BezelRect(double X, double Y, double Width, double Height);

/// <summary>
/// A phone frame drawn from a photo of the phone's front: a portrait PNG (in the Mac app's
/// Resources/Bezels, shared with this app) that is see-through outside the phone and in its
/// screen. Measured in the PNG's pixels. The picture goes under it, filling the screen. The Mac
/// app's BezelArtwork.
/// </summary>
/// <param name="Name">The PNG's file name, without ".png".</param>
/// <param name="Screen">The see-through screen, upright.</param>
/// <param name="Diagonal">The phone's screen diagonal in inches, for true-to-life sizes.</param>
public sealed record BezelArtwork(string Name, double CanvasWidth, double CanvasHeight, BezelRect Screen, double Diagonal)
{
    /// <summary>The photo a style is drawn from, if it has one.</summary>
    public static BezelArtwork? For(BezelStyle style) => style switch
    {
        BezelStyle.ZebraHC50 => new("zebra-hc50-front", 1280, 2640, new(100, 240, 1080, 2160), 6),
        BezelStyle.HoneywellCT37 => new("honeywell-ct37-white-front", 1360, 2880, new(140, 320, 1080, 2280), 6),
        BezelStyle.Versity95 => new("spectralink-versity95-96-front", 1360, 2640, new(140, 400, 1080, 1920), 5.2),
        BezelStyle.Versity97 => new("spectralink-versity97-front", 1360, 2640, new(140, 340, 1080, 1920), 5.2),
        _ => null,
    };

    /// <summary>
    /// The Android phones with their own frame, from the model the Android app sends: its maker
    /// and model, e.g. "Zebra Technologies HC50", "Honeywell CT37", "Spectralink Versity 9640".
    /// Only whole model numbers count, so an HC20, CT30 or Versity 9240 gets the plain frame.
    /// </summary>
    public static BezelStyle? AndroidStyle(string model)
    {
        string[] makers = ["ZEBRA", "TECHNOLOGIES", "HONEYWELL", "SPECTRALINK", "VERSITY"];
        var words = model.ToUpperInvariant().Split([' ', '-', '_'], StringSplitOptions.RemoveEmptyEntries);
        string code = string.Concat(words.SkipWhile(word => makers.Contains(word)));
        if (code == "HC50") return BezelStyle.ZebraHC50;
        // CT37, CT37HC, CT37X0N…, but not CT370.
        if (code.StartsWith("CT37", StringComparison.Ordinal) && (code.Length == 4 || char.IsLetter(code[4]))) return BezelStyle.HoneywellCT37;
        if (code.StartsWith('V')) code = code[1..];
        return code switch
        {
            "9540" or "9553" or "9640" or "9653" => BezelStyle.Versity95,
            "9740" or "9753" => BezelStyle.Versity97,
            _ => null,
        };
    }
}

/// <summary>
/// The frame around a slot's picture, measured in units of the picture's shorter side, so it
/// scales with the picture. Turns with the phone: the portrait top edge becomes the left edge
/// when the phone is held sideways (or the right edge, or the bottom, when the phone says so).
/// The Mac app's BezelGeometry.
/// </summary>
public sealed record BezelGeometry
{
    public BezelStyle Style { get; }
    public bool Landscape { get; }
    /// <summary>Quarter turns left from upright: 0 or 2 for a portrait picture, 1 or 3 for a sideways one.</summary>
    public int QuarterTurns { get; }
    /// <summary>The frame's edges around the picture, as on screen.</summary>
    public double Top { get; }
    public double Left { get; }
    public double Bottom { get; }
    public double Right { get; }
    /// <summary>The rounding of the picture's corners and of the frame's outside.</summary>
    public double ScreenCornerRadius { get; }
    public double OuterCornerRadius { get; }
    /// <summary>For a frame drawn from a photo: the photo's screen, from the frame's top left, as
    /// on screen. Painted black where the picture doesn't cover it (a picture a little narrower
    /// than the phone's screen, say), since the picture is never stretched to fit.</summary>
    public BezelRect? ArtworkScreen { get; }

    /// <summary>"iPhone14,6" → HomeButton, "iPhone18,2" → DynamicIsland, "Zebra Technologies HC50" →
    /// ZebraHC50, another Android phone or null → Plain.</summary>
    public static BezelStyle StyleFor(string? modelCode)
    {
        if (modelCode == null) return BezelStyle.Plain;
        if (!modelCode.StartsWith("iPhone", StringComparison.Ordinal)) return BezelArtwork.AndroidStyle(modelCode) ?? BezelStyle.Plain;
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

    /// <summary><paramref name="turns"/>: quarter turns left the phone is held at, if it says
    /// (Android phones do): 0 upright, 1 sideways with its top on the left, 2 upside down, 3
    /// sideways with its top on the right. Ignored when it doesn't match the picture's shape (the
    /// phone turned and its new picture hasn't arrived yet); a sideways picture then has its top
    /// on the left.</summary>
    public BezelGeometry(BezelStyle style, double pictureWidth, double pictureHeight, int? turns = null)
    {
        Style = style;
        Landscape = pictureWidth > pictureHeight;
        QuarterTurns = turns is int t && ((t & 1) == 1) == Landscape ? t & 3 : Landscape ? 1 : 0;
        if (BezelArtwork.For(style) is { } artwork)
        {
            // The photo, turned as the phone is, scaled so the picture fits its screen and
            // centered there.
            double shorter = Math.Max(1e-9, Math.Min(pictureWidth, pictureHeight));
            double pictureW = Math.Max(pictureWidth, 1e-9) / shorter, pictureH = Math.Max(pictureHeight, 1e-9) / shorter;
            double canvasW = artwork.CanvasWidth, canvasH = artwork.CanvasHeight;
            var screen = artwork.Screen;
            for (int turn = 0; turn < QuarterTurns; turn++)
            {
                // A quarter turn left: (x, y, w, h) in a W×H canvas → (y, W − x − w, h, w).
                screen = new BezelRect(screen.Y, canvasW - screen.X - screen.Width, screen.Height, screen.Width);
                (canvasW, canvasH) = (canvasH, canvasW);
            }
            double scale = Math.Min(screen.Width / pictureW, screen.Height / pictureH); // pixels per unit
            Left = (screen.X + (screen.Width - pictureW * scale) / 2) / scale;
            Top = (screen.Y + (screen.Height - pictureH * scale) / 2) / scale;
            Right = canvasW / scale - Left - pictureW;
            Bottom = canvasH / scale - Top - pictureH;
            ArtworkScreen = new BezelRect(screen.X / scale, screen.Y / scale, screen.Width / scale, screen.Height / scale);
            return;
        }
        var edges = Portrait(style);
        // Upright edges, then turned: each quarter turn left takes the right edge to the top.
        var around = (Top: edges.Top, Left: edges.Side, Bottom: edges.Bottom, Right: edges.Side);
        for (int turn = 0; turn < QuarterTurns; turn++)
        {
            around = (around.Right, around.Top, around.Left, around.Bottom);
        }
        (Top, Left, Bottom, Right) = around;
        ScreenCornerRadius = edges.Screen;
        OuterCornerRadius = edges.Outer;
    }

    public BezelGeometry(string? modelCode, double pictureWidth, double pictureHeight, int? turns = null)
        : this(StyleFor(modelCode), pictureWidth, pictureHeight, turns)
    {
    }

    /// <summary>The frame's edges at the phone's upright top and bottom, whichever way it's held.</summary>
    public double UprightTop => QuarterTurns switch { 1 => Left, 2 => Bottom, 3 => Right, _ => Top };
    public double UprightBottom => QuarterTurns switch { 1 => Right, 2 => Top, 3 => Left, _ => Bottom };

    /// <summary>The whole frame's size, for a picture of this size, in units of the picture's shorter side.</summary>
    public (double Width, double Height) OuterSize(double pictureWidth, double pictureHeight)
    {
        double shorter = Math.Max(1e-9, Math.Min(pictureWidth, pictureHeight));
        return (pictureWidth / shorter + Left + Right, pictureHeight / shorter + Top + Bottom);
    }
}
