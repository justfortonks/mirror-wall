using System.Windows;
using System.Windows.Controls;

namespace MirrorWall;

/// <summary>
/// Lays tiles out in as many equal columns as fit at <see cref="MinColumnWidth"/> or wider, like the
/// Mac app's adaptive grid. Each row is as tall as its tallest tile.
/// </summary>
public sealed class AdaptiveGrid : Panel
{
    public double MinColumnWidth { get; set; } = 220;
    public double Spacing { get; set; } = 16;

    private int Columns(double width) =>
        Math.Max(1, Math.Min(InternalChildren.Count, (int)((width + Spacing) / (MinColumnWidth + Spacing))));

    private double ColumnWidth(double width, int columns) => Math.Max(0, (width - Spacing * (columns - 1)) / columns);

    protected override Size MeasureOverride(Size available)
    {
        if (InternalChildren.Count == 0) return new Size(0, 0);
        double width = double.IsInfinity(available.Width) ? (MinColumnWidth + Spacing) * InternalChildren.Count : available.Width;
        int columns = Columns(width);
        double columnWidth = ColumnWidth(width, columns);
        double height = 0, rowHeight = 0;
        for (int i = 0; i < InternalChildren.Count; i++)
        {
            var child = InternalChildren[i];
            child.Measure(new Size(columnWidth, available.Height));
            rowHeight = Math.Max(rowHeight, child.DesiredSize.Height);
            if (i % columns == columns - 1 || i == InternalChildren.Count - 1)
            {
                height += rowHeight + (height > 0 ? Spacing : 0);
                rowHeight = 0;
            }
        }
        return new Size(width, height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        int columns = Columns(final.Width);
        double columnWidth = ColumnWidth(final.Width, columns);
        double y = 0;
        for (int row = 0; row * columns < InternalChildren.Count; row++)
        {
            var children = Enumerable.Range(row * columns, Math.Min(columns, InternalChildren.Count - row * columns)).Select(i => InternalChildren[i]).ToList();
            double rowHeight = children.Max(child => child.DesiredSize.Height);
            for (int column = 0; column < children.Count; column++)
            {
                children[column].Arrange(new Rect(column * (columnWidth + Spacing), y, columnWidth, rowHeight));
            }
            y += rowHeight + Spacing;
        }
        return final;
    }
}

/// <summary>
/// Gives its content a fixed shape (width ÷ height = <see cref="Ratio"/>) as wide as it's offered,
/// or as tall as <see cref="MaxContentHeight"/> allows, centred.
/// </summary>
public sealed class AspectBox : Decorator
{
    public static readonly DependencyProperty RatioProperty = DependencyProperty.Register(
        nameof(Ratio), typeof(double), typeof(AspectBox),
        new FrameworkPropertyMetadata(9.0 / 19.5, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public double Ratio
    {
        get => (double)GetValue(RatioProperty);
        set => SetValue(RatioProperty, value);
    }

    public static readonly DependencyProperty MaxContentHeightProperty = DependencyProperty.Register(
        nameof(MaxContentHeight), typeof(double), typeof(AspectBox),
        new FrameworkPropertyMetadata(double.PositiveInfinity, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public double MaxContentHeight
    {
        get => (double)GetValue(MaxContentHeightProperty);
        set => SetValue(MaxContentHeightProperty, value);
    }

    private Size Fit(Size available)
    {
        double ratio = Ratio > 0 ? Ratio : 9.0 / 19.5;
        double width = double.IsInfinity(available.Width) ? 300 : available.Width;
        double height = width / ratio;
        double limit = Math.Min(MaxContentHeight, available.Height);
        if (height > limit)
        {
            height = limit;
            width = height * ratio;
        }
        return new Size(width, height);
    }

    protected override Size MeasureOverride(Size available)
    {
        var size = Fit(available);
        Child?.Measure(size);
        return size;
    }

    protected override Size ArrangeOverride(Size final)
    {
        var size = Fit(final);
        Child?.Arrange(new Rect((final.Width - size.Width) / 2, 0, size.Width, size.Height));
        return final;
    }
}
