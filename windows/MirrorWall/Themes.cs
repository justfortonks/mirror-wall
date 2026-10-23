using System.Windows.Media;

namespace MirrorWall;

/// <summary>The colors the Stage draws with, as on the Mac (Theme.swift). A new look goes here
/// rather than as colors hard-coded in windows.</summary>
internal static class Themes
{
    /// <summary>Recording dots and buttons, and trouble.</summary>
    public static Brush RedBrush() => Brushes.Red;

    public static Brush StatusBrush(SlotState state) => state switch
    {
        SlotState.Live => Brushes.LimeGreen,
        SlotState.Waiting or SlotState.Connecting or SlotState.Paused => Brushes.Gold,
        SlotState.Disconnected => Brushes.Orange,
        SlotState.Stopped => Brushes.Gray,
        _ => Brushes.Red,
    };

    // MARK: Stage

    public static Brush StageBackground() => Brushes.Black;

    /// <summary>The Stage's control bar, pills and "Ready for phones" panel.</summary>
    public static Color Panel() => Rgb(0x1A1A1A);

    /// <summary>Text on the control bar's buttons.</summary>
    public static Brush ControlText() => Frozen(Color.FromArgb(217, 255, 255, 255));

    public static Color Rgb(uint hex) => Color.FromRgb((byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);

    public static SolidColorBrush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}
