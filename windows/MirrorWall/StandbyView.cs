using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>What a slot's own window, its tile and its OBS feed show while no phone is mirroring:
/// the waiting message, nothing, or an image scaled to fit (black bars if its shape differs).</summary>
internal static class StandbyView
{
    public static UIElement Make(StandbyPicture standby, Slot slot)
    {
        switch (standby.Kind)
        {
            case StandbyKind.Image when standby.FileName is { } fileName && StandbyPictures.Image(fileName) is { } image:
                return new Image { Source = image, Stretch = Stretch.Uniform };
            case StandbyKind.Blank:
            case StandbyKind.Image:
                return new Grid();
            default:
                return new TextBlock
                {
                    Text = WaitingText(slot),
                    Foreground = new SolidColorBrush(Color.FromArgb(128, 255, 255, 255)),
                    FontSize = 13,
                    TextWrapping = TextWrapping.Wrap,
                    TextAlignment = TextAlignment.Center,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(16),
                };
        }
    }

    public static string WaitingText(Slot slot) => $"Waiting for {slot.Config.LastPhoneName ?? "an iPhone"} to mirror to “{slot.Name}”";
}

/// <summary>Glyphs from Windows' icon font.</summary>
internal static class Glyphs
{
    public const string Add = "";
    public const string Settings = "";
    public const string More = "";
    public const string Camera = "";
    public const string Record = "";
    public const string Stop = "";
    public const string PopOut = "";
    public const string PopIn = "";
    public const string Phone = "";
    public const string Warning = "";
    public const string Paused = "";
    public const string Moon = "";
    public const string Broadcast = "";
    public const string Close = "";
    public const string Layout = "\uF0E2"; // GridView
    public const string Folder = "\uE8B7";
}
