using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// One slot on the wall: its picture (or what it shows while no phone is mirroring) and a footer
/// with its name, status, timers and buttons. Double-click the picture to show only this slot.
/// </summary>
internal sealed class SlotTile : UserControl
{
    private readonly Slot slot;
    private readonly SlotStore store;
    private readonly Action<Slot> toggleFocus;
    public bool IsFocusedSlot { get; set; }

    private readonly AspectBox pictureBox = new();
    private readonly Border frame = new() { Background = Brushes.Black, CornerRadius = new CornerRadius(12), ClipToBounds = true };
    /// <summary>Holds <see cref="frame"/> while the slot shows a phone bezel.</summary>
    private readonly PhoneBezelFrame bezelFrame = new();
    private readonly Image picture = new() { Stretch = Stretch.Uniform };
    private readonly Grid standby = new();
    private readonly StackPanel placeholder = new() { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(14) };
    private readonly TextBlock placeholderIcon = new() { FontSize = 28, HorizontalAlignment = HorizontalAlignment.Center, Foreground = Faint };
    private readonly TextBlock placeholderText = new() { FontSize = 13, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Foreground = Faint, Margin = new Thickness(0, 10, 0, 0) };
    private readonly Border pausedBanner = new()
    {
        VerticalAlignment = VerticalAlignment.Bottom,
        Background = new SolidColorBrush(Color.FromArgb(180, 0, 0, 0)),
        Padding = new Thickness(8),
        Child = new TextBlock
        {
            Text = "Screen off. Turn it on within about a minute or the iPhone stops mirroring.",
            Foreground = Brushes.White, FontSize = 11, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center,
        },
    };
    private readonly StatsOverlay stats;
    private readonly Button popOutButton = new();
    /// <summary>Imprivata theme only: the brand's hex pattern in the corner while the slot waits.</summary>
    private readonly HexPattern hexPattern;

    private readonly Ellipse dot = new() { Width = 8, Height = 8, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock nameText = new() { FontWeight = FontWeights.SemiBold, FontSize = 14, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock obsIcon = new() { FontFamily = IconFont, Text = Glyphs.Broadcast, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Opacity = 0.7 };
    private readonly Button recordButton = new();
    private readonly Button screenshotButton = new();
    private readonly Button moreButton = new();
    private readonly TextBlock phoneText = new() { FontSize = 12, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock statusText = new() { FontSize = 12, Opacity = 0.7 };
    private readonly TextBlock recordingText = new() { FontSize = 12, Foreground = Brushes.Red, Margin = new Thickness(0, 0, 6, 0) };
    private readonly TextBlock savedText = new() { FontSize = 12, Opacity = 0.7, Text = "Screenshot saved", Margin = new Thickness(0, 0, 6, 0) };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };

    private static readonly Brush Faint = new SolidColorBrush(Color.FromArgb(190, 255, 255, 255));
    private static FontFamily IconFont => (FontFamily)Application.Current.Resources["Icons"];

    public SlotTile(Slot slot, SlotStore store, Action<Slot> toggleFocus)
    {
        this.slot = slot;
        this.store = store;
        this.toggleFocus = toggleFocus;
        stats = new StatsOverlay(slot);
        VerticalAlignment = VerticalAlignment.Top;
        hexPattern = new HexPattern
        {
            Radius = 13, Columns = 5, Rows = 5, Density = 0.75, Seed = (ulong)slot.Id + 7,
            Height = 120, VerticalAlignment = VerticalAlignment.Top,
        };

        RenderOptions.SetBitmapScalingMode(picture, BitmapScalingMode.HighQuality);
        placeholder.Children.Add(placeholderIcon);
        placeholder.Children.Add(placeholderText);
        placeholderIcon.FontFamily = IconFont;

        popOutButton.Style = (Style)Application.Current.Resources["IconButton"];
        popOutButton.Foreground = Brushes.White;
        popOutButton.Background = new SolidColorBrush(Color.FromArgb(140, 0, 0, 0));
        popOutButton.Width = popOutButton.Height = 28;
        popOutButton.Margin = new Thickness(8);
        popOutButton.HorizontalAlignment = HorizontalAlignment.Right;
        popOutButton.VerticalAlignment = VerticalAlignment.Top;
        popOutButton.Click += (_, _) =>
        {
            if (store.IsPoppedOut(slot)) store.CloseOwnWindow(slot); else store.OpenOwnWindow(slot);
        };

        var layers = new Grid();
        layers.Children.Add(hexPattern);
        layers.Children.Add(standby);
        layers.Children.Add(picture);
        layers.Children.Add(placeholder);
        layers.Children.Add(pausedBanner);
        layers.Children.Add(stats);
        layers.Children.Add(popOutButton);
        frame.Child = layers;
        frame.SizeChanged += (_, _) => ClipFrame();
        frame.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2) toggleFocus(slot);
        };
        pictureBox.Child = frame;

        SetUpButton(recordButton, () => { if (slot.RecordingSince == null) slot.StartRecording(); else slot.StopRecording(); });
        SetUpButton(screenshotButton, slot.TakeScreenshot);
        screenshotButton.Content = Glyphs.Camera;
        SetUpButton(moreButton, () =>
        {
            var menu = Menus.Context(MenuItems);
            menu.PlacementTarget = moreButton;
            menu.Placement = PlacementMode.Bottom;
            menu.IsOpen = true;
        });
        moreButton.Content = Glyphs.More;
        moreButton.ToolTip = "More";

        var top = new DockPanel { LastChildFill = true };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(recordButton);
        buttons.Children.Add(screenshotButton);
        buttons.Children.Add(moreButton);
        DockPanel.SetDock(buttons, Dock.Right);
        top.Children.Add(buttons);
        DockPanel.SetDock(dot, Dock.Left);
        top.Children.Add(dot);
        DockPanel.SetDock(obsIcon, Dock.Right);
        top.Children.Add(obsIcon);
        top.Children.Add(nameText);

        // The phone's name gives way when space is short; the status never does.
        var bottom = new DockPanel { Margin = new Thickness(14, 0, 4, 0) };
        var status = new StackPanel { Orientation = Orientation.Horizontal };
        status.Children.Add(savedText);
        status.Children.Add(recordingText);
        status.Children.Add(statusText);
        DockPanel.SetDock(status, Dock.Right);
        bottom.Children.Add(status);
        bottom.Children.Add(phoneText);

        var footer = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        footer.Children.Add(top);
        footer.Children.Add(bottom);

        var root = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        root.Children.Add(pictureBox);
        Content = root;
        ContextMenu = Menus.Context(MenuItems);

        slot.PropertyChanged += SlotChanged;
        slot.Renderer.PropertyChanged += SlotChanged;
        store.PropertyChanged += SlotChanged;
        timer.Tick += (_, _) => UpdateTimes();
        Loaded += (_, _) => timer.Start();
        Unloaded += (_, _) => timer.Stop();
        Update();
    }

    /// <summary>Stops listening, when the tile is removed for good.</summary>
    public void Detach()
    {
        timer.Stop();
        slot.PropertyChanged -= SlotChanged;
        slot.Renderer.PropertyChanged -= SlotChanged;
        store.PropertyChanged -= SlotChanged;
        stats.Detach();
    }

    /// <summary>Keeps the picture short enough for the wall to fit the window. The tile narrows
    /// to match, so its footer stays under its picture.</summary>
    public double MaxPictureHeight
    {
        get => pictureBox.MaxContentHeight;
        set
        {
            pictureBox.MaxContentHeight = value;
            UpdateMaxWidth();
        }
    }

    private void UpdateMaxWidth() =>
        MaxWidth = double.IsInfinity(pictureBox.MaxContentHeight) ? double.PositiveInfinity : Math.Max(160, pictureBox.MaxContentHeight * pictureBox.Ratio);

    private IEnumerable<object> MenuItems() =>
        Menus.SlotItems(slot, store, IsFocusedSlot, () => toggleFocus(slot), Window.GetWindow(this));

    private void SetUpButton(Button button, Action action)
    {
        button.Style = (Style)Application.Current.Resources["IconButton"];
        button.Click += (_, _) => action();
    }

    private void SlotChanged(object? sender, PropertyChangedEventArgs e) => Update();

    private void Update()
    {
        bool showsPicture = slot.ShowsPicture;
        var standbyPicture = store.StandbyFor(slot);
        bool hasStandbyImage = standbyPicture.Kind == StandbyKind.Image;

        var shape = slot.VideoSize is { Width: > 0, Height: > 0 } size ? size : new Size(9, 19.5);
        if (slot.ShowsBezel)
        {
            bezelFrame.Update(slot.Bezel(shape), shape);
            if (pictureBox.Child != bezelFrame)
            {
                pictureBox.Child = null;
                bezelFrame.Content = frame;
                pictureBox.Child = bezelFrame;
                ClipFrame();
            }
            pictureBox.Ratio = bezelFrame.Ratio;
        }
        else
        {
            if (pictureBox.Child != frame)
            {
                bezelFrame.Content = null;
                pictureBox.Child = frame;
                ClipFrame();
            }
            pictureBox.Ratio = shape.Width / shape.Height;
        }
        UpdateMaxWidth();
        picture.Source = slot.Renderer.Bitmap;
        picture.Visibility = showsPicture ? Visibility.Visible : Visibility.Hidden;

        // Shown as the slot's own window shows it; the footer still gives the status.
        standby.Children.Clear();
        if (!showsPicture && hasStandbyImage) standby.Children.Add(StandbyView.Make(standbyPicture, slot));
        placeholder.Visibility = !showsPicture && !hasStandbyImage ? Visibility.Visible : Visibility.Collapsed;
        var theme = store.Theme;
        bool waiting = !showsPicture && !hasStandbyImage;
        // Black behind a phone's picture; the theme's color while the slot waits for one.
        frame.Background = waiting ? Themes.EmptyTileBackground(theme) : Brushes.Black;
        hexPattern.Visibility = waiting && theme == Theme.Imprivata ? Visibility.Visible : Visibility.Collapsed;
        bool problem = slot.State is SlotState.Failed or SlotState.Disconnected;
        placeholderIcon.Foreground = theme != Theme.Imprivata ? Faint : problem ? Themes.RedBrush(theme) : Themes.Frozen(Themes.Teal);
        placeholderIcon.Text = slot.State switch
        {
            SlotState.Failed => Glyphs.Warning,
            SlotState.Stopped => Glyphs.Paused,
            _ => Glyphs.Phone,
        };
        placeholderText.Text = slot.State switch
        {
            SlotState.Connecting => $"Connecting to {slot.PhoneName ?? "iPhone"}…",
            SlotState.Disconnected => $"{slot.PhoneName ?? "The iPhone"} stopped mirroring. To reconnect, pick “{slot.Name}” in Screen Mirroring on the phone.",
            SlotState.Stopped => "Stopped",
            SlotState.Failed => slot.FailureMessage ?? "Error",
            _ => $"On your iPhone, open Control Center › Screen Mirroring and pick “{slot.Name}”.",
        };
        pausedBanner.Visibility = showsPicture && slot.State == SlotState.Paused ? Visibility.Visible : Visibility.Collapsed;
        stats.Visibility = store.ShowStats ? Visibility.Visible : Visibility.Collapsed;

        bool poppedOut = store.IsPoppedOut(slot);
        popOutButton.Content = poppedOut ? Glyphs.PopIn : Glyphs.PopOut;
        popOutButton.ToolTip = poppedOut ? "Close this slot's own window" : "Open this slot in its own window, for OBS";

        dot.Fill = Themes.StatusBrush(theme, slot.State);
        recordingText.Foreground = Themes.RedBrush(theme);
        nameText.Text = slot.Name;
        obsIcon.Visibility = slot.ObsFeedName != null ? Visibility.Visible : Visibility.Collapsed;
        obsIcon.ToolTip = $"Sending to OBS: add a Spout2 Capture source and pick \"{slot.ObsFeedName}\"";

        recordButton.Content = slot.RecordingSince == null ? Glyphs.Record : Glyphs.Stop;
        recordButton.Foreground = slot.RecordingSince == null ? (Brush)GetValue(ForegroundProperty) : Themes.RedBrush(theme);
        recordButton.ToolTip = slot.RecordingSince != null ? "Stop recording"
            : slot.ShowsPicture ? $"Start recording to {System.IO.Path.GetFileName(SaveFolders.Recordings)}"
            : $"Record to {System.IO.Path.GetFileName(SaveFolders.Recordings)} when a phone connects";
        screenshotButton.IsEnabled = showsPicture;
        screenshotButton.ToolTip = $"Save a screenshot to {System.IO.Path.GetFileName(SaveFolders.Screenshots)}";
        phoneText.Text = slot.State == SlotState.Disconnected ? "" : slot.PhoneName ?? "";
        UpdateTimes();
    }

    /// <summary>Rounds the picture's corners on the bare wall; in a bezel, the bezel rounds them.</summary>
    private void ClipFrame()
    {
        double radius = slot.ShowsBezel ? 0 : 12;
        frame.CornerRadius = new CornerRadius(radius);
        frame.Clip = new RectangleGeometry(new Rect(frame.RenderSize), radius, radius);
    }

    private void UpdateTimes()
    {
        var now = DateTime.Now;
        savedText.Visibility = slot.ScreenshotSavedAt is DateTime saved && (now - saved).TotalSeconds < 2 ? Visibility.Visible : Visibility.Collapsed;
        if (slot.RecordingSince is DateTime since)
        {
            recordingText.Visibility = Visibility.Visible;
            recordingText.Text = $"● REC {Format(now - since)}";
            recordingText.ToolTip = slot.RecordingError ?? $"Recording to {SaveFolders.Recordings}";
        }
        else
        {
            recordingText.Visibility = Visibility.Collapsed;
        }
        statusText.Text = slot.State switch
        {
            SlotState.Stopped => "Stopped",
            SlotState.Failed => "Error",
            SlotState.Waiting => "Waiting",
            SlotState.Connecting => "Connecting",
            SlotState.Disconnected => "Disconnected",
            SlotState.Paused => $"Screen off {Format(now - slot.StateSince)}",
            _ => slot.ConnectedSince is DateTime connected ? $"Live {Format(now - connected)}" : "Live",
        };
        if (store.ShowStats) stats.Refresh();
    }

    /// <summary>"0:42", "12:05" or "1:03:20".</summary>
    public static string Format(TimeSpan interval)
    {
        int total = Math.Max(0, (int)interval.TotalSeconds);
        int hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60;
        return hours > 0 ? $"{hours}:{minutes:00}:{seconds:00}" : $"{minutes}:{seconds:00}";
    }
}
