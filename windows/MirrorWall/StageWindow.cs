using System.Collections.Specialized;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shell;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// One window showing every phone that's mirroring, side by side at their true relative sizes,
/// for sharing a single window in Teams, Zoom or OBS. Titled "MacMirror-Stage", as on the Mac, so
/// OBS finds it again by name. Like the slots' own windows it is all picture: drag it anywhere to
/// move it, drag its edges to resize it, and right-click for the layout.
/// </summary>
internal sealed class StageWindow : Window
{
    public const string StageTitle = "MacMirror-Stage";

    private readonly SlotStore store;
    private readonly Canvas canvas = new() { Background = Brushes.Black, ClipToBounds = true };
    private readonly TextBlock empty = new()
    {
        Text = "Phones on stage show up here while they're mirroring.",
        Foreground = new SolidColorBrush(Color.FromArgb(128, 255, 255, 255)),
        FontSize = 18,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly Button closeButton = new();
    private readonly Dictionary<Slot, StagePhone> phones = new();
    private readonly List<Slot> watched = new();

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

        var root = new Grid { Background = Brushes.Black };
        root.Children.Add(canvas);
        root.Children.Add(empty);
        root.Children.Add(closeButton);
        Content = root;
        // The button only shows under the pointer, so captures stay clean.
        MouseEnter += (_, _) => closeButton.Visibility = Visibility.Visible;
        MouseLeave += (_, _) => closeButton.Visibility = Visibility.Collapsed;
        MouseLeftButtonDown += (_, e) =>
        {
            if (e.ButtonState == MouseButtonState.Pressed && e.OriginalSource is not Button) DragMove();
        };
        ContextMenu = Menus.Context(() => Menus.StageLayoutItems(store).Concat(new object[]
        {
            new Separator(),
            Menus.Submenu("Phones on Stage", Menus.StageSlotItems(store)),
            new Separator(),
            Menus.Item("Show Mirror Wall Window", MainWindow.ShowMain),
            Menus.Item("Close Stage", Close),
        }));

        canvas.SizeChanged += (_, _) => Layout();
        store.Slots.CollectionChanged += SlotsChanged;
        store.PropertyChanged += StoreChanged;
        Watch();
        Closed += (_, _) =>
        {
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
