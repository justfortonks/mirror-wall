using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// A phone-shaped frame around a slot's picture: the phone's body, drawn around the picture
/// without covering any of it, with a notch, Dynamic Island, home button or front camera to match
/// the phone's model. Put it in an <see cref="AspectBox"/> with <see cref="Ratio"/>, so it gets
/// the frame's shape. The Mac app's PhoneBezel.
/// </summary>
internal sealed class PhoneBezelFrame : Decorator
{
    private static readonly Brush BodyBrush = Frozen(new SolidColorBrush(Color.FromRgb(28, 28, 30)));
    private static readonly Brush RimBrush = Frozen(new SolidColorBrush(Color.FromRgb(82, 82, 87)));
    private static readonly Brush DetailBrush = Frozen(new SolidColorBrush(Color.FromRgb(51, 51, 56)));

    /// <summary>Holds the picture, clipped to the screen's rounded corners.</summary>
    private readonly Border screen = new() { Background = Brushes.Black };
    private BezelGeometry geometry = new(BezelStyle.Plain, 9, 19.5);
    private Size picture = new(9, 19.5);

    public PhoneBezelFrame()
    {
        Child = screen;
    }

    /// <summary>What goes on the phone's screen.</summary>
    public UIElement? Content
    {
        get => screen.Child;
        set => screen.Child = value;
    }

    /// <summary>Builds the frame for a picture of this size (or shape) from this phone model.</summary>
    public void Update(BezelGeometry newGeometry, Size newPicture)
    {
        if (newGeometry == geometry && newPicture == picture) return;
        geometry = newGeometry;
        picture = newPicture;
        InvalidateMeasure();
        InvalidateVisual();
    }

    /// <summary>The frame's width ÷ height.</summary>
    public double Ratio
    {
        get
        {
            var outer = geometry.OuterSize(picture.Width, picture.Height);
            return outer.Width / outer.Height;
        }
    }

    /// <summary>Pixels per unit: one unit is the picture's shorter side.</summary>
    private double Unit(Size size) => size.Width / geometry.OuterSize(picture.Width, picture.Height).Width;

    private Rect ScreenRect(Size size)
    {
        double unit = Unit(size);
        return new Rect(geometry.Left * unit, geometry.Top * unit,
            Math.Max(0, size.Width - (geometry.Left + geometry.Right) * unit),
            Math.Max(0, size.Height - (geometry.Top + geometry.Bottom) * unit));
    }

    protected override Size MeasureOverride(Size available)
    {
        var size = new Size(double.IsInfinity(available.Width) ? 300 : available.Width, double.IsInfinity(available.Height) ? 300 / Ratio : available.Height);
        screen.Measure(ScreenRect(size).Size);
        return size;
    }

    protected override Size ArrangeOverride(Size final)
    {
        var rect = ScreenRect(final);
        screen.Arrange(rect);
        double radius = geometry.ScreenCornerRadius * Unit(final);
        screen.Clip = new RectangleGeometry(new Rect(rect.Size), radius, radius);
        return final;
    }

    /// <summary>Draws the frame upright and turns it a quarter left for a sideways phone, so the
    /// portrait top edge (notch, camera) ends up on the left.</summary>
    protected override void OnRender(DrawingContext dc)
    {
        var size = RenderSize;
        if (size.Width <= 0 || size.Height <= 0) return;
        double unit = Unit(size);
        var upright = geometry.Landscape ? new Size(size.Height, size.Width) : size;
        if (geometry.Landscape) dc.PushTransform(new MatrixTransform(0, -1, 1, 0, 0, size.Height));

        double rim = 0.012 * unit, outer = geometry.OuterCornerRadius * unit;
        dc.DrawRoundedRectangle(BodyBrush, null, new Rect(upright), outer, outer);
        var rimRect = new Rect(rim / 2, rim / 2, Math.Max(0, upright.Width - rim), Math.Max(0, upright.Height - rim));
        dc.DrawRoundedRectangle(null, new Pen(RimBrush, rim), rimRect, Math.Max(0, outer - rim / 2), Math.Max(0, outer - rim / 2));

        // Portrait top and bottom edges, whichever way the phone is held.
        double topEdge = (geometry.Landscape ? geometry.Left : geometry.Top) * unit;
        double bottomEdge = (geometry.Landscape ? geometry.Right : geometry.Bottom) * unit;
        double centerX = upright.Width / 2;
        switch (geometry.Style)
        {
            case BezelStyle.HomeButton:
                Pill(dc, Brushes.Black, new Rect(centerX - 0.09 * unit, topEdge / 2 - 0.012 * unit, 0.18 * unit, 0.024 * unit));
                Dot(dc, Brushes.Black, centerX - 0.154 * unit, topEdge / 2, 0.016 * unit);
                dc.DrawEllipse(null, new Pen(DetailBrush, 0.012 * unit), new Point(centerX, upright.Height - bottomEdge / 2), 0.075 * unit, 0.075 * unit);
                break;
            case BezelStyle.Notch:
                double radius = 0.04 * unit;
                dc.DrawRoundedRectangle(Brushes.Black, null, new Rect(centerX - 0.22 * unit, 0.012 * unit, 0.44 * unit, Math.Max(0, topEdge - 0.012 * unit)), radius, radius);
                Pill(dc, DetailBrush, new Rect(centerX - 0.06 * unit, topEdge / 2 - 0.008 * unit, 0.12 * unit, 0.016 * unit));
                break;
            case BezelStyle.DynamicIsland:
                Pill(dc, Brushes.Black, new Rect(centerX - 0.15 * unit, topEdge / 2 - 0.022 * unit, 0.3 * unit, 0.044 * unit));
                break;
            default:
                Dot(dc, Brushes.Black, centerX, topEdge / 2, 0.018 * unit);
                Pill(dc, Brushes.Black, new Rect(centerX - 0.08 * unit, topEdge / 4 - 0.008 * unit, 0.16 * unit, 0.016 * unit));
                break;
        }
        if (geometry.Landscape) dc.Pop();
    }

    private static void Pill(DrawingContext dc, Brush brush, Rect rect) =>
        dc.DrawRoundedRectangle(brush, null, rect, rect.Height / 2, rect.Height / 2);

    private static void Dot(DrawingContext dc, Brush brush, double x, double y, double radius) =>
        dc.DrawEllipse(brush, null, new Point(x, y), radius, radius);

    private static Brush Frozen(Brush brush)
    {
        brush.Freeze();
        return brush;
    }
}
