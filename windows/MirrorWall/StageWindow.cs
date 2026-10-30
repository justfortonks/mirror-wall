using System.Collections.Specialized;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Shell;
using System.Windows.Threading;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// One window showing every phone that's mirroring, side by side at their true relative sizes,
/// for sharing a single window in Teams, Zoom or OBS. Titled "MacMirror-Stage", as on the Mac, so
/// OBS finds it again by name. Like the slots' own windows it is all picture: drag it anywhere to
/// move it, drag its edges to resize it, and right-click for the layout. Moving the pointer over
/// it fades in a control bar, which fades out again a couple of seconds after the pointer stops,
/// so the shared picture stays clean.
/// </summary>
internal sealed class StageWindow : Window
{
    public const string StageTitle = "MacMirror-Stage";

    private readonly SlotStore store;
    private readonly Rectangle background = new();
    private readonly Canvas canvas = new() { Background = Brushes.Transparent, ClipToBounds = true };
    /// <summary>Before any phone is on stage: "Ready for phones" and how to connect to each slot.</summary>
    private readonly ContentControl empty = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Focusable = false };
    /// <summary>The "Live demo" strip along the bottom.</summary>
    private readonly Border caption = new() { Background = new SolidColorBrush(Color.FromArgb(46, 0, 0, 0)) };
    private readonly RowDefinition captionRow = new() { Height = new GridLength(0) };
    /// <summary>Slots without a phone, along the bottom while the controls show.</summary>
    private readonly Border controls = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 36, 0, 0), Opacity = 0, IsHitTestVisible = false };
    private readonly Button closeButton = new();
    private readonly DispatcherTimer hideTimer = new() { Interval = TimeSpan.FromSeconds(2.2) };
    private readonly Dictionary<Slot, StagePhone> phones = new();
    private readonly List<Slot> watched = new();
    private bool controlsVisible;
    /// <summary>What the controls, empty screen and caption were last built from, so they're only
    /// rebuilt when it changes (slots change with every frame).</summary>
    private string builtFrom = "";

    public StageWindow(SlotStore store)
    {
        this.store = store;
        Title = StageTitle;
        Icon = Application.Current.MainWindow?.Icon;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.CanResize;
        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 0,
            ResizeBorderThickness = new Thickness(6),
            GlassFrameThickness = new Thickness(0),
            UseAeroCaptionButtons = false,
        });
        Background = Brushes.Black;
        Foreground = Brushes.White;
        ShowInTaskbar = true;
        Width = 1280;
        Height = 720;
        MinWidth = 320;
        MinHeight = 180;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        closeButton.Style = (Style)Application.Current.Resources["IconButton"];
        closeButton.Content = Glyphs.Close;
        closeButton.Foreground = Brushes.White;
        closeButton.Background = new SolidColorBrush(Color.FromArgb(150, 0, 0, 0));
        closeButton.Width = closeButton.Height = 28;
        closeButton.Margin = new Thickness(8);
        closeButton.HorizontalAlignment = HorizontalAlignment.Right;
        closeButton.VerticalAlignment = VerticalAlignment.Top;
        closeButton.ToolTip = "Close the stage";
        closeButton.Visibility = Visibility.Collapsed;
        WindowChrome.SetIsHitTestVisibleInChrome(closeButton, true);
        closeButton.Click += (_, _) => Close();

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition());
        root.RowDefinitions.Add(captionRow);
        Grid.SetRowSpan(background, 2);
        Grid.SetRow(caption, 1);
        root.Children.Add(background);
        root.Children.Add(canvas);
        root.Children.Add(empty);
        root.Children.Add(caption);
        root.Children.Add(controls);
        Grid.SetRowSpan(closeButton, 2);
        root.Children.Add(closeButton);
        Content = root;
        // The close button only shows under the pointer, so captures stay clean.
        MouseEnter += (_, _) => closeButton.Visibility = Visibility.Visible;
        MouseLeave += (_, _) =>
        {
            closeButton.Visibility = Visibility.Collapsed;
            ScheduleHide();
        };
        MouseMove += (_, _) => ShowControls();
        hideTimer.Tick += (_, _) =>
        {
            hideTimer.Stop();
            if (controls.IsMouseOver || controls.IsKeyboardFocusWithin) ScheduleHide();
            else SetControlsVisible(false);
        };
        MouseLeftButtonDown += (_, e) =>
        {
            if (e.ButtonState == MouseButtonState.Pressed && e.OriginalSource is not Button && !controls.IsMouseOver) DragMove();
        };
        ContextMenu = Menus.Context(() => Menus.StageLayoutItems(store).Concat(new object[]
        {
            Menus.Item("Show Caption Bar", () => store.SetShowsStageCaption(!store.ShowsStageCaption), isChecked: store.ShowsStageCaption),
            new Separator(),
            Menus.Submenu("Phones on Stage", Menus.StageSlotItems(store)),
            new Separator(),
            Menus.Item("Show Wall", MainWindow.ShowMain),
            Menus.Item("Close Stage", Close),
        }));

        canvas.SizeChanged += (_, _) => Layout();
        root.SizeChanged += (_, _) => SizeCaption();
        store.Slots.CollectionChanged += SlotsChanged;
        store.PropertyChanged += StoreChanged;
        background.Fill = Themes.StageBackground();
        Watch();
        Closed += (_, _) =>
        {
            hideTimer.Stop();
            store.Slots.CollectionChanged -= SlotsChanged;
            store.PropertyChanged -= StoreChanged;
            Unwatch();
        };
    }

    private void SlotsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        Unwatch();
        Watch();
    }

    private void StoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(SlotStore.StageLayout)) Layout();
        if (e.PropertyName is nameof(SlotStore.ShowsStageCaption)) SizeCaption();
        if (e.PropertyName is nameof(SlotStore.ShowsStageCaption) or nameof(SlotStore.CanAddSlot)
            or nameof(SlotStore.BezelsForAllSlots) or nameof(SlotStore.IsPoppedOut))
        {
            builtFrom = "";
            Refresh();
        }
    }

    private void Watch()
    {
        foreach (var slot in store.Slots)
        {
            slot.PropertyChanged += SlotChanged;
            slot.Renderer.PropertyChanged += SlotChanged;
            watched.Add(slot);
        }
        Refresh();
    }

    private void Unwatch()
    {
        foreach (var slot in watched)
        {
            slot.PropertyChanged -= SlotChanged;
            slot.Renderer.PropertyChanged -= SlotChanged;
        }
        watched.Clear();
    }

    private void SlotChanged(object? sender, PropertyChangedEventArgs e) => Refresh();

    /// <summary>Puts the phones that are mirroring on stage and takes the others off.</summary>
    private void Refresh()
    {
        foreach (var slot in phones.Keys.Where(slot => !OnStage(slot) || !store.Slots.Contains(slot)).ToList())
        {
            canvas.Children.Remove(phones[slot].Element);
            phones.Remove(slot);
        }
        foreach (var slot in store.Slots.Where(OnStage))
        {
            if (!phones.TryGetValue(slot, out var phone))
            {
                phone = new StagePhone(slot);
                phones[slot] = phone;
                canvas.Children.Add(phone.Element);
            }
            phone.Update();
        }
        Layout();
        RebuildIfChanged();
    }

    private static bool OnStage(Slot slot) => slot.ShowsPicture && slot.ShowsOnStage;

    private void Layout()
    {
        var onStage = store.Slots.Where(phones.ContainsKey).ToList();
        empty.Visibility = onStage.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var sizes = onStage.Select(slot =>
        {
            var shape = StagePhone.PictureShape(slot);
            return Stage.PhoneSize(slot.Config.LastPhoneModel, shape.Width, shape.Height, slot.ShowsBezel);
        }).ToList();
        var frames = Stage.Frames(sizes, store.StageLayout, canvas.ActualWidth, canvas.ActualHeight);
        for (int i = 0; i < onStage.Count; i++) phones[onStage[i]].Place(frames[i]);
    }

    /// <summary>Sizes the caption bar to the window.</summary>
    private void SizeCaption()
    {
        double height = ((FrameworkElement)Content).ActualHeight;
        double captionHeight = store.ShowsStageCaption ? Math.Min(64, Math.Max(34, height * 0.085)) : 0;
        captionRow.Height = new GridLength(captionHeight);
        caption.Visibility = captionHeight > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (captionHeight > 0) caption.Child = Caption(captionHeight);
    }

    // MARK: Controls

    private void ShowControls()
    {
        if (!controlsVisible) SetControlsVisible(true);
        ScheduleHide();
    }

    private void ScheduleHide()
    {
        hideTimer.Stop();
        hideTimer.Start();
    }

    private void SetControlsVisible(bool visible)
    {
        controlsVisible = visible;
        controls.IsHitTestVisible = visible;
        var fade = new DoubleAnimation(visible ? 1 : 0, TimeSpan.FromSeconds(visible ? 0.15 : 0.4));
        controls.BeginAnimation(OpacityProperty, fade);
    }

    /// <summary>Rebuilds the control bar, the empty screen and the caption when what they show changes.</summary>
    private void RebuildIfChanged()
    {
        string state = string.Join("|", store.Slots.Select(slot =>
            $"{slot.Id},{slot.Name},{slot.PhoneName},{slot.State},{slot.ShowsPicture},{slot.ShowsOnStage},{slot.ShowsBezel},{slot.RecordingSince != null}"))
            + $"|{store.CanAddSlot}|{store.BezelsForAllSlots}|{store.IsAnyRecording}|{store.ShowsStageCaption}";
        if (state == builtFrom) return;
        builtFrom = state;
        controls.Child = ControlBar();
        empty.Content = EmptyState();
        SizeCaption();
    }

    /// <summary>A chip per connected phone (its menu has the slot's options), then add slot, layout,
    /// bezels, record and more.</summary>
    private UIElement ControlBar()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var connected = store.Slots.Where(slot => slot.ShowsPicture).ToList();
        foreach (var slot in connected) row.Children.Add(SlotChip(slot));
        if (connected.Count > 0)
        {
            row.Children.Add(new Rectangle { Width = 1, Height = 18, Fill = new SolidColorBrush(Color.FromArgb(36, 255, 255, 255)), Margin = new Thickness(4, 0, 4, 0) });
        }
        var add = HudButton("Slot", Glyphs.Add, store.AddSlot);
        add.IsEnabled = store.CanAddSlot;
        add.ToolTip = "Add a slot another phone can mirror to";
        row.Children.Add(add);
        row.Children.Add(HudMenuButton("Layout", Glyphs.Layout, () => Menus.StageLayoutItems(store)));
        var bezels = HudButton("Bezels", Glyphs.Phone, () => store.SetBezelsForAllSlots(!store.BezelsForAllSlots), isOn: store.BezelsForAllSlots);
        bezels.ToolTip = "Phone frames around every phone";
        row.Children.Add(bezels);
        bool recording = store.IsAnyRecording;
        var record = HudButton(recording ? "Stop" : "Record", recording ? Glyphs.Stop : Glyphs.Record,
            () => { if (store.IsAnyRecording) store.StopAllRecordings(); else store.StartAllRecordings(); }, fill: Themes.RedBrush());
        record.ToolTip = recording ? "Stop all recordings" : "Record every phone";
        row.Children.Add(record);
        row.Children.Add(HudMenuButton(null, Glyphs.Settings, () => new object[]
        {
            Menus.Item("Caption Bar", () => store.SetShowsStageCaption(!store.ShowsStageCaption), isChecked: store.ShowsStageCaption),
            Menus.Item("Screenshot All Phones", store.ScreenshotAll, enabled: store.Slots.Any(slot => slot.ShowsPicture)),
            new Separator(),
            Menus.Item("Show Wall", MainWindow.ShowMain),
            Menus.Item("Settings…", () => SettingsWindow.Show(this, store)),
        }));
        var panel = Themes.Panel();
        controls.Background = new SolidColorBrush(Color.FromArgb(217, panel.R, panel.G, panel.B));
        controls.CornerRadius = new CornerRadius(13);
        controls.BorderBrush = new SolidColorBrush(Color.FromArgb(15, 255, 255, 255));
        controls.BorderThickness = new Thickness(1);
        controls.Padding = new Thickness(5);
        controls.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 28, ShadowDepth = 6, Direction = 270, Opacity = 0.35 };
        return row;
    }

    /// <summary>A connected phone in the control bar; its menu has what the wall tile's ⋯ menu had.</summary>
    private UIElement SlotChip(Slot slot)
    {
        var label = new StackPanel { Orientation = Orientation.Horizontal };
        label.Children.Add(new Ellipse { Width = 8, Height = 8, Fill = Themes.StatusBrush(slot.State), Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
        label.Children.Add(new TextBlock { Text = slot.PhoneName ?? slot.Name, FontWeight = FontWeights.SemiBold, FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        if (slot.RecordingSince != null)
        {
            label.Children.Add(new TextBlock { Text = "REC", Foreground = Themes.RedBrush(), FontWeight = FontWeights.SemiBold, FontSize = 12, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        }
        var chip = new Button
        {
            Content = label,
            Foreground = Brushes.White,
            Background = new SolidColorBrush(Color.FromArgb(26, 255, 255, 255)),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(10, 0, 10, 0),
            Height = 28,
            MinWidth = 0,
            Margin = new Thickness(2, 0, 2, 0),
            Opacity = slot.ShowsOnStage ? 1 : 0.55,
            ToolTip = slot.ShowsOnStage ? "On the Stage. Click for this phone's options." : "Off the Stage. Click to put it back.",
        };
        chip.Click += (_, _) => OpenMenu(chip, new object[]
        {
            Menus.Item("On Stage", () => store.SetShowsOnStage(slot, !slot.ShowsOnStage), isChecked: slot.ShowsOnStage),
            Menus.Item("Phone Bezel", () => store.SetBezel(slot, !slot.ShowsBezel), isChecked: slot.ShowsBezel),
            new Separator(),
            Menus.Item("Take Screenshot", slot.TakeScreenshot),
            slot.RecordingSince == null ? Menus.Item("Start Recording", slot.StartRecording) : Menus.Item("Stop Recording", () => slot.StopRecording()),
            new Separator(),
            store.IsPoppedOut(slot) ? Menus.Item("Close Own Window", () => store.CloseOwnWindow(slot)) : Menus.Item("Open in Own Window", () => store.OpenOwnWindow(slot)),
            Menus.Item("More in the Wall…", MainWindow.ShowMain),
        });
        return chip;
    }

    /// <summary>One item in the control bar.</summary>
    private Button HudButton(string? title, string glyph, Action action, bool isOn = false, Brush? fill = null)
    {
        var label = new StackPanel { Orientation = Orientation.Horizontal };
        label.Children.Add(new TextBlock { FontFamily = (FontFamily)Application.Current.Resources["Icons"], Text = glyph, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
        if (title != null)
        {
            label.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, FontSize = 12, Margin = new Thickness(5, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        }
        var button = new Button
        {
            Content = label,
            Foreground = fill != null || isOn ? Brushes.White : Themes.ControlText(),
            Background = fill ?? (isOn ? new SolidColorBrush(Color.FromArgb(36, 255, 255, 255)) : Brushes.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(9, 0, 9, 0),
            Height = 28,
            MinWidth = 0,
            Margin = new Thickness(2, 0, 2, 0),
        };
        button.Click += (_, _) => action();
        return button;
    }

    private Button HudMenuButton(string? title, string glyph, Func<IEnumerable<object>> items)
    {
        Button? button = null;
        button = HudButton(title, glyph, () => OpenMenu(button!, items()));
        return button;
    }

    private void OpenMenu(Button under, IEnumerable<object> items)
    {
        var menu = Menus.Context(() => items);
        menu.PlacementTarget = under;
        menu.Placement = PlacementMode.Bottom;
        menu.IsOpen = true;
    }

    /// <summary>The Stage before any phone is mirroring: how to connect, slot by slot. The meeting
    /// may see this, so it reads as a friendly "about to start" screen.</summary>
    private UIElement EmptyState()
    {
        var stack = new StackPanel { Margin = new Thickness(16) };
        stack.Children.Add(new TextBlock { Text = "Ready for phones", FontSize = 28, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center });
        stack.Children.Add(new TextBlock { Text = "Each phone appears here as it connects.", FontSize = 15, Opacity = 0.7, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) });
        var list = new StackPanel();
        foreach (var slot in store.Slots)
        {
            var row = new DockPanel { Margin = new Thickness(0, list.Children.Count == 0 ? 0 : 10, 0, 0) };
            var dot = new Ellipse { Width = 8, Height = 8, Fill = Themes.StatusBrush(slot.State), Margin = new Thickness(0, 6, 10, 0), VerticalAlignment = VerticalAlignment.Top };
            DockPanel.SetDock(dot, Dock.Left);
            row.Children.Add(dot);
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = slot.Name, FontSize = 14, FontWeight = FontWeights.SemiBold });
            text.Children.Add(new TextBlock
            {
                Text = $"iPhone: Control Center › Screen Mirroring › “{slot.Name}”   ·   Android: Mirror Wall Cast",
                FontSize = 12,
                Opacity = 0.65,
                Margin = new Thickness(0, 2, 0, 0),
            });
            row.Children.Add(text);
            list.Children.Add(row);
        }
        var panel = Themes.Panel();
        stack.Children.Add(new Border
        {
            Child = list,
            Padding = new Thickness(16),
            Margin = new Thickness(0, 18, 0, 0),
            CornerRadius = new CornerRadius(12),
            Background = new SolidColorBrush(Color.FromArgb(115, panel.R, panel.G, panel.B)),
        });
        return stack;
    }

    /// <summary>"Live demo · Tom's iPhone and Zebra HC50".</summary>
    private UIElement Caption(double height)
    {
        var row = new DockPanel { Margin = new Thickness(height * 0.5, 0, height * 0.5, 0), VerticalAlignment = VerticalAlignment.Center };
        var bar = new Rectangle { Width = 4, Height = height * 0.5, RadiusX = 2, RadiusY = 2, Fill = Themes.RedBrush(), Margin = new Thickness(0, 0, height * 0.3, 0) };
        DockPanel.SetDock(bar, Dock.Left);
        row.Children.Add(bar);
        var title = new TextBlock { Text = "Live demo", FontWeight = FontWeights.Bold, FontSize = height * 0.36, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(title, Dock.Left);
        row.Children.Add(title);
        var names = store.Slots.Where(OnStage).Select(slot => slot.PhoneName ?? slot.Name).ToList();
        if (names.Count > 0)
        {
            string list = names.Count == 1 ? names[0] : string.Join(", ", names.Take(names.Count - 1)) + " and " + names[^1];
            row.Children.Add(new TextBlock
            {
                Text = $"· {list}",
                FontSize = height * 0.36,
                Opacity = 0.75,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Margin = new Thickness(height * 0.3, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        return row;
    }

    /// <summary>One phone on the stage: its picture, in its phone frame when the slot has one on.</summary>
    private sealed class StagePhone
    {
        public ContentControl Element { get; } = new();
        private readonly Slot slot;
        private readonly Grid screen = new() { Background = Brushes.Black };
        private readonly Image picture = new() { Stretch = Stretch.Uniform };
        private readonly PhoneBezelFrame bezelFrame = new();

        public StagePhone(Slot slot)
        {
            this.slot = slot;
            RenderOptions.SetBitmapScalingMode(picture, BitmapScalingMode.HighQuality);
            screen.Children.Add(picture);
            Element.Content = screen;
        }

        /// <summary>The picture's shape: the phone's, or a portrait iPhone until the first picture arrives.</summary>
        public static Size PictureShape(Slot slot) =>
            slot.VideoSize is { Width: > 0, Height: > 0 } size ? size : (slot.LastPictureSize ?? new Size(9, 19.5));

        public void Update()
        {
            if (slot.ShowsBezel)
            {
                var shape = PictureShape(slot);
                bezelFrame.Update(slot.Bezel(shape), shape);
                if (bezelFrame.Content != screen)
                {
                    Element.Content = null;
                    screen.Clip = null;
                    bezelFrame.Content = screen;
                    Element.Content = bezelFrame;
                }
            }
            else if (Element.Content != screen)
            {
                Element.Content = null;
                bezelFrame.Content = null;
                Element.Content = screen;
            }
            if (picture.Source != slot.Renderer.Bitmap) picture.Source = slot.Renderer.Bitmap;
        }

        public void Place(StageRect frame)
        {
            Canvas.SetLeft(Element, frame.X);
            Canvas.SetTop(Element, frame.Y);
            Element.Width = frame.Width;
            Element.Height = frame.Height;
            // Without a frame, the picture gets slightly rounded corners, like a phone's screen.
            if (!slot.ShowsBezel)
            {
                double radius = Math.Min(frame.Width, frame.Height) * 0.04;
                screen.Clip = new RectangleGeometry(new Rect(0, 0, frame.Width, frame.Height), radius, radius);
            }
        }
    }
}
