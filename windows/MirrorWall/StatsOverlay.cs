using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace MirrorWall;

/// <summary>Stats for Nerds: a panel over a slot's tile with the stream's numbers. Main window only;
/// the slots' own windows stay clean for OBS.</summary>
internal sealed class StatsOverlay : Border
{
    private readonly Slot slot;
    private readonly Grid grid = new();

    public StatsOverlay(Slot slot)
    {
        this.slot = slot;
        Background = new SolidColorBrush(Color.FromArgb(166, 0, 0, 0));
        CornerRadius = new CornerRadius(6);
        Padding = new Thickness(6);
        Margin = new Thickness(6);
        HorizontalAlignment = HorizontalAlignment.Left;
        VerticalAlignment = VerticalAlignment.Top;
        IsHitTestVisible = false;
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Child = new Viewbox { Child = grid, StretchDirection = StretchDirection.DownOnly };
        slot.Stats.PropertyChanged += StatsChanged;
    }

    public void Detach() => slot.Stats.PropertyChanged -= StatsChanged;

    private void StatsChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (Visibility == Visibility.Visible) Refresh();
    }

    public void Refresh()
    {
        var rows = Rows(DateTime.Now).ToList();
        while (grid.RowDefinitions.Count < rows.Count) grid.RowDefinitions.Add(new RowDefinition());
        grid.Children.Clear();
        for (int i = 0; i < rows.Count; i++)
        {
            grid.Children.Add(Cell(rows[i].Label, i, 0, 0.6));
            grid.Children.Add(Cell(rows[i].Value, i, 1, 1));
        }
    }

    private static TextBlock Cell(string text, int row, int column, double opacity)
    {
        var block = new TextBlock
        {
            Text = text,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 10,
            Foreground = Brushes.White,
            Opacity = opacity,
            Margin = new Thickness(0, 0, column == 0 ? 8 : 0, 1),
        };
        Grid.SetRow(block, row);
        Grid.SetColumn(block, column);
        return block;
    }

    private IEnumerable<(string Label, string Value)> Rows(DateTime now)
    {
        var stats = slot.Stats;
        var stream = stats.Stream;
        yield return ("Phone", stats.PhoneModel ?? "–");
        if (stats.Codec is { } codec) yield return ("Codec", codec);
        if (slot.VideoSize is { } size) yield return ("Picture", $"{size.Width:0}×{size.Height:0}");
        if (stream != null)
        {
            yield return ("Frames", $"{stream.FramesPerSecond:0}/s");
            yield return ("Bitrate", Bitrate(stream.BitsPerSecond));
        }
        yield return ("Lag vs best", stats.Lag is double lag ? "+" + Milliseconds(lag) : "not reported");
        yield return ("Decode", stream?.DecodeTime is double decode ? Milliseconds(decode) : "–");
        yield return ("Round trip", stats.RoundTrip is double trip ? Milliseconds(trip) : "–");
        if (stream != null)
        {
            yield return ("Jitter", Milliseconds(stream.FrameJitter));
            string every = stream.KeyframeInterval is double interval ? $", every {interval:0.0} s" : "";
            yield return ("Keyframes", $"{stream.TotalKeyframes}{every}");
            yield return ("Lost", $"{stream.TotalPacketsLost} packets, {stream.TotalFramesSkipped} frames");
        }
        if (slot.LastFrameAt is DateTime lastFrame) yield return ("Last frame", Ago(now - lastFrame));
        if (stats.LastHeartbeatAt is DateTime lastHeartbeat)
        {
            string every = stats.HeartbeatInterval is double interval ? $"every {interval:0.0} s, " : "";
            yield return ("Check-ins", every + Ago(now - lastHeartbeat));
        }
        yield return ("Connections", stats.Connections.ToString());
    }

    private static string Milliseconds(double seconds) =>
        Math.Abs(seconds) < 0.01 ? $"{seconds * 1000:0.0} ms" : $"{seconds * 1000:0} ms";

    private static string Bitrate(double bitsPerSecond) =>
        bitsPerSecond >= 1_000_000 ? $"{bitsPerSecond / 1_000_000:0.0} Mbps" : $"{bitsPerSecond / 1000:0} kbps";

    private static string Ago(TimeSpan interval) => interval.TotalSeconds < 1 ? "just now" : $"{(int)interval.TotalSeconds} s ago";
}
