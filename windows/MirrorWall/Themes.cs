using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace MirrorWall;

/// <summary>The app's look, chosen in Settings › General › Theme, as on the Mac. Standard is Mirror
/// Wall's own look; Imprivata is the brand styling (2026 Brand Style Guide). Only colors, type and
/// decoration change: what the app does is the same in every theme.</summary>
public enum Theme { Standard, Imprivata }

/// <summary>What each theme looks like. Windows ask for the current one as they draw, and redraw
/// when <see cref="SlotStore.Theme"/> changes.</summary>
internal static class Themes
{
    // Imprivata primary and secondary colors.
    public static readonly Color Blue = Rgb(0x2C3F57);
    public static readonly Color Red = Rgb(0xCC0033);
    public static readonly Color Teal = Rgb(0x2CD5C4);
    public static readonly Color MidBlue = Rgb(0x426DA9);
    public static readonly Color Sky = Rgb(0x4698CB);
    public static readonly Color Ice = Rgb(0xD2E4F9);
    // Shades of Imprivata Blue for the dark wall.
    public static readonly Color BlueDeep = Rgb(0x24344A);
    public static readonly Color BlueRaised = Rgb(0x33495F);
    public static readonly Color BlueMuted = Rgb(0x7C8DA3);

    public static Theme Current => Settings.Current.Theme;

    /// <summary>Called at launch and when the theme changes: Imprivata Blue needs dark controls,
    /// menus and dialogs to read on it; Standard follows Windows' light or dark mode.</summary>
    public static void Apply(Theme theme)
    {
#pragma warning disable WPF0001
        Application.Current.ThemeMode = theme == Theme.Imprivata ? ThemeMode.Dark : ThemeMode.System;
#pragma warning restore WPF0001
    }

    // MARK: Type

    private static FontFamily? barlow;

    /// <summary>Barlow (bundled, SIL Open Font License) for Imprivata; Windows' own font for Standard.</summary>
    public static FontFamily Font(Theme theme)
    {
        if (theme != Theme.Imprivata) return SystemFonts.MessageFontFamily;
        return barlow ??= new FontFamily(new Uri("pack://application:,,,/"), "./Brand/#Barlow, Segoe UI");
    }

    /// <summary>Sets a window's or control's text in the theme's font. Standard clears it, so it
    /// keeps the font Windows gives it.</summary>
    public static void UseFont(System.Windows.Controls.Control control, Theme theme)
    {
        if (theme == Theme.Imprivata) control.FontFamily = Font(theme);
        else control.ClearValue(System.Windows.Controls.Control.FontFamilyProperty);
    }

    // MARK: Wall

    /// <summary>Behind the tiles. Null keeps Windows' own window color, light or dark.</summary>
    public static Brush? WallBackground(Theme theme) => theme == Theme.Imprivata ? Frozen(Blue) : null;

    /// <summary>Behind a tile while it waits for a phone (a phone's picture always sits on black).</summary>
    public static Brush EmptyTileBackground(Theme theme) => theme == Theme.Imprivata ? Frozen(BlueDeep) : Brushes.Black;

    /// <summary>Recording dots and buttons, and trouble.</summary>
    public static Brush RedBrush(Theme theme) => theme == Theme.Imprivata ? Frozen(Red) : Brushes.Red;

    public static Brush StatusBrush(Theme theme, SlotState state) => theme == Theme.Imprivata
        // Brand palette: teal live, blues in between, red only for trouble (and recording).
        ? state switch
        {
            SlotState.Live => Frozen(Teal),
            SlotState.Connecting or SlotState.Paused => Frozen(Sky),
            SlotState.Waiting => Frozen(BlueMuted),
            SlotState.Disconnected => Brushes.Orange,
            SlotState.Stopped => Brushes.Gray,
            _ => Frozen(Red),
        }
        : state switch
        {
            SlotState.Live => Brushes.LimeGreen,
            SlotState.Waiting or SlotState.Connecting or SlotState.Paused => Brushes.Gold,
            SlotState.Disconnected => Brushes.Orange,
            SlotState.Stopped => Brushes.Gray,
            _ => Brushes.Red,
        };

    // MARK: Stage

    public static Brush StageBackground(Theme theme) => theme == Theme.Imprivata
        // The guide's Imprivata Blue → #4698CB gradient.
        ? Freeze(new LinearGradientBrush(new GradientStopCollection
        {
            new GradientStop(Blue, 0),
            new GradientStop(Rgb(0x2F4D6E), 0.5),
            new GradientStop(Sky, 1),
        }, new Point(0, 0), new Point(1, 1)))
        : Brushes.Black;

    /// <summary>The Stage's control bar, pills and "Ready for phones" panel.</summary>
    public static Color Panel(Theme theme) => theme == Theme.Imprivata ? Rgb(0x141E2D) : Rgb(0x1A1A1A);

    /// <summary>Text on the control bar's buttons.</summary>
    public static Brush ControlText(Theme theme) => theme == Theme.Imprivata ? Frozen(Ice) : Frozen(Color.FromArgb(217, 255, 255, 255));

    private static BitmapImage? logo;
    private static bool lookedForLogo;

    /// <summary>The white Imprivata logo, if it's been put in the app's Brand folder. It's kept out
    /// of this public repository, so builds without it simply don't show one.</summary>
    public static ImageSource? Logo(Theme theme)
    {
        if (theme != Theme.Imprivata) return null;
        if (!lookedForLogo)
        {
            lookedForLogo = true;
            string path = Path.Combine(AppContext.BaseDirectory, "Brand", "imprivata-logo-white.png");
            if (File.Exists(path))
            {
                try
                {
                    logo = new BitmapImage();
                    logo.BeginInit();
                    logo.CacheOption = BitmapCacheOption.OnLoad;
                    logo.UriSource = new Uri(path);
                    logo.EndInit();
                    logo.Freeze();
                }
                catch (Exception error) when (error is IOException or NotSupportedException or UriFormatException)
                {
                    logo = null;
                }
            }
        }
        return logo;
    }

    public static Color Rgb(uint hex) => Color.FromRgb((byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);

    public static SolidColorBrush Frozen(Color color) => Freeze(new SolidColorBrush(color));

    private static T Freeze<T>(T brush) where T : Brush
    {
        brush.Freeze();
        return brush;
    }
}

/// <summary>
/// The brand's hex pattern as a corner accent: full hexagons, turning into chevrons toward the
/// bottom, upright as the guide shows them (never rotated), in at most three colors. Laid out from
/// the top right, so put it in a top-right corner.
/// </summary>
internal sealed class HexPattern : FrameworkElement
{
    public Color[] Colors { get; init; } = new[] { Themes.BlueRaised, Themes.MidBlue, Themes.Sky };
    /// <summary>Hexagon radius.</summary>
    public double Radius { get; set; } = 16;
    public int Columns { get; init; } = 5;
    public int Rows { get; init; } = 6;
    public double Density { get; init; } = 0.7;
    public ulong Seed { get; init; } = 7;
    public double PatternOpacity { get; init; } = 1;

    public HexPattern()
    {
        IsHitTestVisible = false;
    }

    protected override void OnRender(DrawingContext context)
    {
        double r = Radius, w = Math.Sqrt(3) * r;
        var brushes = Colors.Select(color => Themes.Frozen(Color.FromArgb((byte)(PatternOpacity * 255), color.R, color.G, color.B))).ToArray();
        var random = new SeededRandom(Seed);
        for (int row = 0; row < Rows; row++)
        {
            for (int column = 0; column < Columns; column++)
            {
                // Denser toward the top right, so it reads as a corner accent.
                double fade = Density * (1 - (double)row / (Rows * 1.4)) * (0.55 + (double)column / Columns * 0.6);
                bool keep = random.Next() <= fade;
                double colorPick = random.Next();
                double chevronPick = random.Next();
                if (!keep) continue;
                double cx = ActualWidth - ((Columns - 1 - column) * w + (row % 2 == 1 ? w / 2 : 0) + w / 2);
                double cy = row * 1.5 * r + r;
                bool chevron = row >= Rows * 0.45 && chevronPick > 0.35;
                var brush = brushes[Math.Min(brushes.Length - 1, (int)(colorPick * brushes.Length))];
                context.DrawGeometry(brush, null, chevron ? Chevron(cx, cy, r * 0.96) : Hexagon(cx, cy, r * 0.96));
            }
        }
    }

    private static Geometry Hexagon(double cx, double cy, double r) =>
        Shape(Enumerable.Range(0, 6).Select(k =>
        {
            double angle = Math.PI / 180 * (60 * k - 90);
            return new Point(cx + r * Math.Cos(angle), cy + r * Math.Sin(angle));
        }));

    /// <summary>A hexagon with a V notch in its top: the guide's chevron.</summary>
    private static Geometry Chevron(double cx, double cy, double r)
    {
        double w = Math.Sqrt(3) / 2 * r;
        return Shape(new[]
        {
            new Point(cx - w, cy - r / 2), new Point(cx, cy), new Point(cx + w, cy - r / 2),
            new Point(cx + w, cy + r / 2), new Point(cx, cy + r), new Point(cx - w, cy + r / 2),
        });
    }

    private static Geometry Shape(IEnumerable<Point> points)
    {
        var list = points.ToList();
        var figure = new PathFigure { StartPoint = list[0], IsClosed = true, IsFilled = true };
        figure.Segments.Add(new PolyLineSegment(list.Skip(1), isStroked: false));
        var geometry = new PathGeometry(new[] { figure });
        geometry.Freeze();
        return geometry;
    }

    /// <summary>Same pattern every time for the same seed, so the hexes don't jump around on redraw.
    /// The same numbers as the Mac's, so both draw the same pattern.</summary>
    private struct SeededRandom
    {
        private ulong state;

        public SeededRandom(ulong seed) => state = unchecked(seed * 0x9E3779B97F4A7C15) | 1;

        public double Next()
        {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            return state % 10_000 / 10_000.0;
        }
    }
}
