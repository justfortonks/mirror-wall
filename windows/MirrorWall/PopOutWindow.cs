using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// A slot in a window of its own, showing only the phone's picture so OBS (or anything else) can
/// capture it cleanly. OBS finds the window again by its title, so the store keeps that title
/// stable: "MacMirror-&lt;phone&gt;", the same as on the Mac.
///
/// The window is all picture: no title bar or border. Drag it anywhere to move it; a close button
/// appears under the pointer, and right-click has the rest. Its size never shifts an OBS layout:
/// Small, Medium or Large show phones at their real relative sizes (an iPhone 17 Pro Max's longer
/// side is 600, 800 or 1000), or Custom, where each window keeps a size of its own that can be
/// locked. It always takes the phone's shape, so it turns wide if the phone rotates.
/// </summary>
internal sealed class PopOutWindow : Window
{
    private readonly Slot slot;
    private readonly SlotStore store;
    private readonly Image picture = new() { Stretch = Stretch.Uniform };
    private readonly Grid standby = new();
    private readonly Button closeButton = new();
    /// <summary>The picture or standby picture, alone or in a phone bezel.</summary>
    private readonly Grid screen = new() { Background = Brushes.Black };
    private readonly ContentControl screenHolder = new();
    private readonly PhoneBezelFrame bezelFrame = new();
    private bool userResizing;

    public PopOutWindow(Slot slot, SlotStore store, string title)
    {
        this.slot = slot;
        this.store = store;
        Title = title;
        Icon = Application.Current.MainWindow?.Icon;
        WindowStyle = WindowStyle.None;
        Background = Brushes.Black;
        ShowInTaskbar = true;
        RenderOptions.SetBitmapScalingMode(picture, BitmapScalingMode.HighQuality);

        closeButton.Style = (Style)Application.Current.Resources["IconButton"];
        closeButton.Content = Glyphs.Close;
        closeButton.Foreground = Brushes.White;
        closeButton.Background = new SolidColorBrush(Color.FromArgb(150, 0, 0, 0));
        closeButton.Width = closeButton.Height = 28;
        closeButton.Margin = new Thickness(8);
        closeButton.HorizontalAlignment = HorizontalAlignment.Right;
        closeButton.VerticalAlignment = VerticalAlignment.Top;
        closeButton.ToolTip = "Close this window";
        closeButton.Visibility = Visibility.Collapsed;
        closeButton.Click += (_, _) => Close();

        screen.Children.Add(standby);
        screen.Children.Add(picture);
        var root = new Grid { Background = Brushes.Black };
        root.Children.Add(screenHolder);
        root.Children.Add(closeButton);
        Content = root;
        // The button only shows under the pointer, so captures stay clean.
        MouseEnter += (_, _) => closeButton.Visibility = Visibility.Visible;
        MouseLeave += (_, _) => closeButton.Visibility = Visibility.Collapsed;
        MouseLeftButtonDown += (_, e) =>
        {
            if (e.ButtonState == MouseButtonState.Pressed && e.OriginalSource is not Button) DragMove();
        };
        ContextMenu = Menus.Context(() => new object[]
        {
            Menus.Item("Show Mirror Wall Window", MainWindow.ShowMain),
            Menus.Dynamic("Window Size", () => Menus.PopOutSizeItems(store)),
            Menus.Item("Close This Window", Close),
        });

        if (store.PopOutPosition(slot) is [double left, double top] && OnSomeScreen(left, top))
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = left;
            Top = top;
        }
        else
        {
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }
        UpdateResizable();
        Fit();
        Update();

        slot.PropertyChanged += SlotChanged;
        slot.Renderer.PropertyChanged += SlotChanged;
        store.PropertyChanged += StoreChanged;
        LocationChanged += (_, _) => { if (IsLoaded) store.SetPopOutPosition(slot, Left, Top, save: false); };
        SourceInitialized += (_, _) => HwndSource.FromHwnd(new WindowInteropHelper(this).Handle)?.AddHook(WindowMessage);
        Closed += (_, _) =>
        {
            slot.PropertyChanged -= SlotChanged;
            slot.Renderer.PropertyChanged -= SlotChanged;
            store.PropertyChanged -= StoreChanged;
        };
    }

    private void SlotChanged(object? sender, PropertyChangedEventArgs e)
    {
        Update();
        // A different phone may be a different size.
        if (e.PropertyName is nameof(Slot.VideoSize) or nameof(Slot.PhoneName) or nameof(Slot.Config) or nameof(Slot.ShowsBezel)) Fit();
    }

    private void StoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(SlotStore.DefaultStandby)) Update();
    }

    private void Update()
    {
        if (slot.ShowsBezel)
        {
            bezelFrame.Update(slot.Bezel(PictureShape), PictureShape);
            if (bezelFrame.Content != screen)
            {
                screenHolder.Content = null;
                bezelFrame.Content = screen;
                screenHolder.Content = bezelFrame;
            }
        }
        else if (screenHolder.Content != screen)
        {
            screenHolder.Content = null;
            bezelFrame.Content = null;
            screenHolder.Content = screen;
        }
        picture.Source = slot.Renderer.Bitmap;
        picture.Visibility = slot.ShowsPicture ? Visibility.Visible : Visibility.Hidden;
        standby.Children.Clear();
        if (!slot.ShowsPicture) standby.Children.Add(StandbyView.Make(store.StandbyFor(slot), slot));
    }

    /// <summary>Resizable by dragging its edges only with an unlocked Custom size.</summary>
    public void UpdateResizable()
    {
        ResizeMode = store.PopOutSize == PopOutSize.Custom && !store.PopOutSizeLocked ? ResizeMode.CanResize : ResizeMode.NoResize;
    }

    /// <summary>The picture's shape: the phone's, or a portrait iPhone until the first picture arrives.</summary>
    private Size PictureShape =>
        slot.VideoSize is { Width: > 0, Height: > 0 } size ? size : (slot.LastPictureSize ?? new Size(9, 19.5));

    /// <summary>The window's shape: the picture's, or with a phone bezel, the bezel's around it.</summary>
    private Size WindowShape
    {
        get
        {
            var shape = PictureShape;
            if (!slot.ShowsBezel) return shape;
            var outer = slot.Bezel(shape).OuterSize(shape.Width, shape.Height);
            double unit = Math.Min(shape.Width, shape.Height);
            return new Size(outer.Width * unit, outer.Height * unit);
        }
    }

    /// <summary>The picture's longer side: the preset's, scaled to this phone's real screen size, or
    /// this slot's remembered Custom size (which is the whole window's).</summary>
    private double LongSide(Size shape)
    {
        double? preset = store.PopOutSize switch
        {
            PopOutSize.Small => 600,
            PopOutSize.Medium => 800,
            PopOutSize.Large => 1000,
            _ => null,
        };
        if (preset is double reference)
            return PhoneModels.TrueToLifeLongSide(reference, slot.Config.LastPhoneModel, shape.Width, shape.Height);
        return store.CustomLongSide(slot) is double saved && saved >= 200 ? saved : 800;
    }

    /// <summary>Gives the window the picture's shape at the chosen size, keeping its top-left corner
    /// where it is.</summary>
    public void Fit()
    {
        UpdateResizable();
        var pictureShape = PictureShape;
        var shape = WindowShape;
        // A preset sizes the picture, and a bezel adds to it; a Custom size is the whole window's.
        double measured = store.PopOutSize == PopOutSize.Custom ? Math.Max(shape.Width, shape.Height) : Math.Max(pictureShape.Width, pictureShape.Height);
        double scale = LongSide(pictureShape) / measured;
        double width = Math.Round(shape.Width * scale), height = Math.Round(shape.Height * scale);
        if (Math.Abs(Width - width) < 0.5 && Math.Abs(Height - height) < 0.5) return;
        Width = width;
        Height = height;
    }

    private IntPtr WindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        const int WM_ENTERSIZEMOVE = 0x0231, WM_EXITSIZEMOVE = 0x0232, WM_SIZING = 0x0214;
        switch (message)
        {
            case WM_ENTERSIZEMOVE:
                userResizing = true;
                break;
            case WM_SIZING:
                KeepShape(wParam, lParam);
                break;
            case WM_EXITSIZEMOVE:
                // Remembers a Custom size, per slot, once the user has finished resizing.
                if (userResizing && store.PopOutSize == PopOutSize.Custom && ResizeMode == ResizeMode.CanResize)
                    store.SetCustomLongSide(slot, Math.Max(ActualWidth, ActualHeight));
                userResizing = false;
                // Saved once a move (or resize) ends, not on every step of the drag.
                store.SetPopOutPosition(slot, Left, Top, save: true);
                break;
        }
        return IntPtr.Zero;
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    /// <summary>Resizing by dragging keeps the window's shape.</summary>
    private void KeepShape(IntPtr edge, IntPtr rectangle)
    {
        var shape = WindowShape;
        double ratio = shape.Width / shape.Height;
        var rect = System.Runtime.InteropServices.Marshal.PtrToStructure<RECT>(rectangle);
        int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
        const int left = 1, right = 2, top = 3, bottom = 6;
        int dragged = edge.ToInt32();
        if (dragged is top or bottom)
        {
            rect.Right = rect.Left + (int)Math.Round(height * ratio);
        }
        else
        {
            int newHeight = (int)Math.Round(width / ratio);
            // Dragging a top corner moves the top edge; anything else moves the bottom.
            if (dragged is 3 or 4 or 5) rect.Top = rect.Bottom - newHeight;
            else rect.Bottom = rect.Top + newHeight;
        }
        _ = (left, right);
        System.Runtime.InteropServices.Marshal.StructureToPtr(rect, rectangle, false);
    }

    private static bool OnSomeScreen(double left, double top) =>
        left >= SystemParameters.VirtualScreenLeft - 50 && top >= SystemParameters.VirtualScreenTop - 50 &&
        left < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 50 &&
        top < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 50;
}
