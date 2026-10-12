using System.Collections.Specialized;
using System.ComponentModel;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// The wall: a tile per slot, in as many columns as fit, with the menu bar above. Double-click a
/// tile (or use its ⋯ menu) to show only that slot. Closing this window quits Mirror Wall.
/// </summary>
internal sealed class MainWindow : Window
{
    private readonly SlotStore store;
    private readonly Dictionary<int, SlotTile> tiles = new();
    private readonly AdaptiveGrid grid = new() { Margin = new Thickness(16) };
    private readonly ScrollViewer scroller = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly ContentControl body = new();
    private readonly Button addButton = new();
    private int? focusedSlotId;

    /// <summary>Brings the wall to the front, e.g. from a slot's own window.</summary>
    public static void ShowMain()
    {
        if (Application.Current.MainWindow is not { } window) return;
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Show();
        window.Activate();
    }

    public MainWindow(SlotStore store)
    {
        this.store = store;
        Title = "Mirror Wall";
        Icon = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/AppIcon.ico"));
        MinWidth = 480;
        MinHeight = 420;
        Width = 900;
        Height = 700;
        RestoreSavedBounds();

        addButton.Style = (Style)Application.Current.Resources["IconButton"];
        addButton.Content = Glyphs.Add;
        addButton.ToolTip = "Add a slot another iPhone can mirror to";
        addButton.Click += (_, _) => store.AddSlot();
        var settingsButton = new Button
        {
            Style = (Style)Application.Current.Resources["IconButton"],
            Content = Glyphs.Settings,
            ToolTip = "Choose which phones can mirror, and alerts",
        };
        settingsButton.Click += (_, _) => SettingsWindow.Show(this, store);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        buttons.Children.Add(addButton);
        buttons.Children.Add(settingsButton);
        var bar = new DockPanel();
        DockPanel.SetDock(buttons, Dock.Right);
        bar.Children.Add(buttons);
        bar.Children.Add(MenuBar());

        scroller.Content = grid;
        scroller.SizeChanged += (_, _) => FitToWindow();
        var root = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        root.Children.Add(bar);
        root.Children.Add(body);
        Content = root;

        foreach (var slot in store.Slots) AddTile(slot);
        store.Slots.CollectionChanged += SlotsChanged;
        store.PropertyChanged += StoreChanged;
        Closing += (_, _) =>
        {
            SaveBounds();
            store.BeginExit();
        };
        Update();
    }

    private Menu MenuBar()
    {
        var menu = new Menu { VerticalAlignment = VerticalAlignment.Center, Background = Brushes.Transparent };
        menu.Items.Add(Menus.Dynamic("_File", () => new object[]
        {
            Menus.Item("Add Slot", store.AddSlot, enabled: store.CanAddSlot),
            Menus.Item("Choose uxplay…", store.ChooseUxPlay),
            new Separator(),
            Menus.Item("Record All Slots", store.StartAllRecordings, enabled: store.Slots.Any(slot => slot.ShowsPicture && slot.RecordingSince == null)),
            Menus.Item("Stop All Recordings", store.StopAllRecordings, enabled: store.IsAnyRecording),
            Menus.Item("Show Recordings Folder", () => Native.ShowFolder(SaveFolders.Recordings)),
            new Separator(),
            Menus.Item("Screenshot All Slots", store.ScreenshotAll, enabled: store.Slots.Any(slot => slot.ShowsPicture)),
            Menus.Item("Show Screenshots Folder", () => Native.ShowFolder(SaveFolders.Screenshots)),
            new Separator(),
            Menus.Item("Settings…", () => SettingsWindow.Show(this, store)),
            new Separator(),
            Menus.Item("Exit", Close),
        }));
        menu.Items.Add(Menus.Dynamic("_View", () => new object[]
        {
            Menus.Item("Stats for Nerds", () => store.ShowStats = !store.ShowStats, isChecked: store.ShowStats),
            new Separator(),
            Menus.Submenu("Frame Rate Limit", SlotConfig.FrameRates.Select(rate =>
                (object)Menus.Item($"{rate} frames a second", () => store.SetMaxFrameRate(rate), isChecked: store.MaxFrameRate == rate))),
            Menus.Item("Smoother Motion", () => store.SetSmoothMotion(!store.SmoothMotion), isChecked: store.SmoothMotion),
            Menus.Item("Sharper Picture (H.265)", () => store.SetSharpPicture(!store.SharpPicture), isChecked: store.SharpPicture),
            new Separator(),
            Menus.Submenu("Pop-out Window Size", Menus.PopOutSizeItems(store)),
        }));
        menu.Items.Add(Menus.Dynamic("_Window", () => WindowItems()));
        menu.Items.Add(Menus.Dynamic("_Help", () => new object[]
        {
            Menus.Item("About Mirror Wall", () => AboutWindow.Show(this)),
        }));
        return menu;
    }

    /// <summary>Each slot's own window: ticked when open, click to open or bring it forward.</summary>
    private IEnumerable<object> WindowItems()
    {
        foreach (var slot in store.Slots)
        {
            yield return Menus.Item($"{slot.Name} in Own Window", () => store.OpenOwnWindow(slot), isChecked: store.IsPoppedOut(slot));
        }
        if (focusedSlotId != null)
        {
            yield return new Separator();
            yield return Menus.Item("Back to All Slots", () => SetFocus(null));
        }
    }

    private void SlotsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        foreach (var id in tiles.Keys.Where(id => store.Slots.All(slot => slot.Id != id)).ToList())
        {
            tiles[id].Detach();
            tiles.Remove(id);
        }
        foreach (var slot in store.Slots.Where(slot => !tiles.ContainsKey(slot.Id))) AddTile(slot);
        if (focusedSlotId is int focused && !tiles.ContainsKey(focused)) focusedSlotId = null;
        Update();
    }

    private void StoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(SlotStore.UxPlayPath) or nameof(SlotStore.CanAddSlot)) Update();
    }

    private void AddTile(Slot slot) => tiles[slot.Id] = new SlotTile(slot, store, ToggleFocus);

    private void ToggleFocus(Slot slot) => SetFocus(focusedSlotId == null ? slot.Id : null);

    private void SetFocus(int? id)
    {
        focusedSlotId = id;
        Update();
    }

    /// <summary>Shows the wall (or the one focused slot), or the setup screen when uxplay is missing.</summary>
    private void Update()
    {
        addButton.IsEnabled = store.CanAddSlot;
        if (store.UxPlayPath == null)
        {
            body.Content = SetupView();
            return;
        }
        body.Content = scroller;
        grid.Children.Clear();
        foreach (var slot in store.Slots)
        {
            if (focusedSlotId != null && slot.Id != focusedSlotId) continue;
            var tile = tiles[slot.Id];
            tile.IsFocusedSlot = focusedSlotId != null;
            grid.Children.Add(tile);
        }
        FitToWindow();
    }

    /// <summary>
    /// Sizes the tiles so the whole wall fits the window, footers included: picks the number of
    /// columns that gives the biggest pictures, then caps their height to fit the rows. With many
    /// slots in a small window the tiles stop shrinking at a readable size and the wall scrolls.
    /// </summary>
    private void FitToWindow()
    {
        const double spacing = 16, margin = 16, footer = 64, smallest = 160;
        const double portrait = 9.0 / 19.5; // planned for portrait phones; landscape ones fit easily
        int count = grid.Children.Count;
        double width = scroller.ActualWidth - 2 * margin - SystemParameters.VerticalScrollBarWidth;
        double height = scroller.ActualHeight - 2 * margin;
        if (count == 0 || width <= 0 || height <= 0) return;

        int bestColumns = 1;
        double bestHeight = 0;
        int maxColumns = focusedSlotId == null ? count : 1;
        for (int columns = 1; columns <= maxColumns; columns++)
        {
            int rows = (count + columns - 1) / columns;
            double columnWidth = (width - spacing * (columns - 1)) / columns;
            double rowHeight = (height - spacing * (rows - 1)) / rows - footer;
            double pictureHeight = Math.Min(columnWidth / portrait, rowHeight);
            if (pictureHeight > bestHeight + 0.5)
            {
                bestHeight = pictureHeight;
                bestColumns = columns;
            }
        }
        grid.FixedColumns = bestColumns;
        double rowsHeight = (height - spacing * ((count + bestColumns - 1) / bestColumns - 1)) / ((count + bestColumns - 1) / bestColumns) - footer;
        double cap = Math.Max(smallest, rowsHeight);
        foreach (SlotTile tile in grid.Children) tile.MaxPictureHeight = cap;
    }

    private UIElement SetupView()
    {
        var panel = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 420, Margin = new Thickness(40) };
        panel.Children.Add(new TextBlock { FontFamily = (FontFamily)Application.Current.Resources["Icons"], Text = Glyphs.Warning, FontSize = 40, Opacity = 0.6, HorizontalAlignment = HorizontalAlignment.Center });
        panel.Children.Add(new TextBlock { Text = "Mirror Wall needs uxplay", FontSize = 22, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 0) });
        panel.Children.Add(new TextBlock
        {
            Text = "The receiver that comes with Mirror Wall is missing, so reinstalling should fix this. Or point it at a uxplay.exe you built.",
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            Opacity = 0.7,
            Margin = new Thickness(0, 14, 0, 0),
        });
        var choose = new Button { Content = "Choose uxplay…", IsDefault = true, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 0), Padding = new Thickness(14, 6, 14, 6) };
        choose.Click += (_, _) => store.ChooseUxPlay();
        panel.Children.Add(choose);
        return panel;
    }

    // MARK: Window position

    private void RestoreSavedBounds()
    {
        if (Settings.Current.MainWindowBounds is [double left, double top, double width, double height, ..] bounds &&
            left >= SystemParameters.VirtualScreenLeft - 50 && top >= SystemParameters.VirtualScreenTop - 50 &&
            left < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 100 &&
            top < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 100)
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = left;
            Top = top;
            Width = Math.Max(MinWidth, width);
            Height = Math.Max(MinHeight, height);
            if (bounds.Length > 4 && bounds[4] == 1) WindowState = WindowState.Maximized;
        }
        else
        {
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }
    }

    private void SaveBounds()
    {
        var normal = RestoreBounds;
        if (normal.IsEmpty) return;
        Settings.Current.MainWindowBounds = new[] { normal.Left, normal.Top, normal.Width, normal.Height, WindowState == WindowState.Maximized ? 1.0 : 0 };
        Settings.Current.Save();
    }
}

/// <summary>Help › About: the version and the change it was built from.</summary>
internal static class AboutWindow
{
    /// <summary>"0.71", plus the commit and its date when the build recorded them
    /// (InformationalVersion "0.71+abc1234.2026-10-12").</summary>
    public static string Version
    {
        get
        {
            var assembly = Assembly.GetExecutingAssembly();
            string full = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "";
            string[] parts = full.Split('+', 2);
            string version = parts[0];
            if (parts.Length < 2) return version;
            string[] build = parts[1].Split('.', 2);
            return build.Length == 2 ? $"{version} ({build[0]}, {build[1]})" : $"{version} ({build[0]})";
        }
    }

    public static void Show(Window owner)
    {
        MessageBox.Show(owner,
            $"Mirror Wall {Version}\n\nShows iPhones mirrored over Wi-Fi (AirPlay), a tile per phone, with windows and Spout feeds for OBS.\n\nThe receiver is UxPlay (GPL-3.0), with GStreamer and FFmpeg (LGPL). Spout2 is BSD-licensed.",
            "About Mirror Wall", MessageBoxButton.OK, MessageBoxImage.Information);
    }
}
