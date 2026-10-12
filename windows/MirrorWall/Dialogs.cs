using System.Collections.Specialized;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>A slot's recent receiver output.</summary>
internal sealed class LogWindow : Window
{
    private static readonly Dictionary<int, LogWindow> Open = new();
    private readonly Slot slot;
    private readonly TextBox text = new()
    {
        IsReadOnly = true,
        FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        FontSize = 11,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        TextWrapping = TextWrapping.NoWrap,
    };

    public static void Show(Window owner, Slot slot)
    {
        if (Open.TryGetValue(slot.Id, out var existing))
        {
            existing.Activate();
            return;
        }
        var window = new LogWindow(slot) { Owner = owner };
        Open[slot.Id] = window;
        window.Show();
    }

    private LogWindow(Slot slot)
    {
        this.slot = slot;
        Title = $"{slot.Name} log";
        Width = 760;
        Height = 460;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var copy = new Button { Content = "Copy", Padding = new Thickness(14, 4, 14, 4) };
        copy.Click += (_, _) => Clipboard.SetText(string.Join(Environment.NewLine, slot.Log));
        var folder = new Button { Content = "Show Log Files", Padding = new Thickness(14, 4, 14, 4), Margin = new Thickness(8, 0, 0, 0) };
        folder.Click += (_, _) => Native.ShowFolder(AppPaths.Logs);
        var done = new Button { Content = "Done", IsDefault = true, IsCancel = true, Padding = new Thickness(14, 4, 14, 4), HorizontalAlignment = HorizontalAlignment.Right };
        done.Click += (_, _) => Close();
        var buttons = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        DockPanel.SetDock(copy, Dock.Left);
        DockPanel.SetDock(folder, Dock.Left);
        buttons.Children.Add(copy);
        buttons.Children.Add(folder);
        buttons.Children.Add(done);

        var root = new DockPanel { Margin = new Thickness(12) };
        DockPanel.SetDock(buttons, Dock.Bottom);
        root.Children.Add(buttons);
        root.Children.Add(text);
        Content = root;

        Refresh();
        slot.Log.CollectionChanged += LogChanged;
        Closed += (_, _) =>
        {
            slot.Log.CollectionChanged -= LogChanged;
            Open.Remove(slot.Id);
        };
    }

    private void LogChanged(object? sender, NotifyCollectionChangedEventArgs e) => Refresh();

    private void Refresh()
    {
        bool atEnd = text.VerticalOffset + text.ViewportHeight >= text.ExtentHeight - 4;
        text.Text = string.Join(Environment.NewLine, slot.Log);
        if (atEnd) text.ScrollToEnd();
    }
}

/// <summary>Renames a slot: the name the iPhone shows in Screen Mirroring.</summary>
internal static class RenameDialog
{
    public static void Show(Window owner, Slot slot, SlotStore store)
    {
        var window = new Window
        {
            Title = "Rename slot",
            Owner = owner,
            SizeToContent = SizeToContent.WidthAndHeight,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false,
        };
        var box = new TextBox { Text = slot.Name, MaxLength = 60, Width = 340, Margin = new Thickness(0, 10, 0, 0) };
        var message = new TextBlock
        {
            Text = $"This is the name the iPhone shows in Screen Mirroring, up to {SlotConfig.MaxNameLength} characters. The slot restarts, so a phone mirroring to it will need to reconnect.",
            TextWrapping = TextWrapping.Wrap,
            Width = 340,
        };
        var rename = new Button { Content = "Rename", IsDefault = true, Padding = new Thickness(14, 4, 14, 4) };
        rename.Click += (_, _) => { store.Rename(slot, box.Text); window.Close(); };
        var reset = new Button { Content = "Use the PC's Name", Padding = new Thickness(14, 4, 14, 4), Margin = new Thickness(8, 0, 0, 0) };
        reset.Click += (_, _) => { store.ResetName(slot); window.Close(); };
        var cancel = new Button { Content = "Cancel", IsCancel = true, Padding = new Thickness(14, 4, 14, 4), Margin = new Thickness(8, 0, 0, 0) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        buttons.Children.Add(rename);
        buttons.Children.Add(reset);
        buttons.Children.Add(cancel);
        var root = new StackPanel { Margin = new Thickness(16) };
        root.Children.Add(message);
        root.Children.Add(box);
        root.Children.Add(buttons);
        window.Content = root;
        window.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        window.ShowDialog();
    }
}
