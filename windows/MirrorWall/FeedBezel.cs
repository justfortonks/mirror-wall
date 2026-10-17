using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// The phone frame for a slot's OBS feed, around pictures of one size: the phone's body with a
/// see-through screen and see-through corners (or a photo of the phone's front), drawn once, then
/// laid over each picture. Built on
/// the feed's own thread, which must be STA, since it draws with WPF.
/// </summary>
internal sealed class FeedBezel
{
    public BezelStyle Style { get; }
    public int? Turns { get; }
    public int PictureWidth { get; }
    public int PictureHeight { get; }

    private readonly int width, height, left, top;
    /// <summary>The frame in premultiplied BGRA, <see cref="width"/> × 4 bytes a row.</summary>
    private readonly byte[] pixels;
    /// <summary>Per picture row, the run of frame pixels that are wholly see-through, where the
    /// picture is copied as it is.</summary>
    private readonly int[] clearStart, clearEnd;
    /// <summary>Frame pixels over the picture that are partly see-through (the screen's rounded
    /// edges), where the two are blended.</summary>
    private readonly int[] blended;

    public FeedBezel(BezelStyle style, int pictureWidth, int pictureHeight, int? turns = null)
    {
        Style = style;
        Turns = turns;
        PictureWidth = pictureWidth;
        PictureHeight = pictureHeight;
        var geometry = new BezelGeometry(style, pictureWidth, pictureHeight, turns);
        double unit = Math.Min(pictureWidth, pictureHeight);
        left = (int)Math.Round(geometry.Left * unit);
        top = (int)Math.Round(geometry.Top * unit);
        width = pictureWidth + left + (int)Math.Round(geometry.Right * unit);
        height = pictureHeight + top + (int)Math.Round(geometry.Bottom * unit);

        var visual = new DrawingVisual();
        RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality);
        var photo = geometry.ArtworkScreen != null ? BezelPhotos.Get(style, geometry.QuarterTurns) : null;
        using (var dc = visual.RenderOpen())
        {
            double radius = geometry.ScreenCornerRadius * unit;
            var screen = new RectangleGeometry(new Rect(left, top, pictureWidth, pictureHeight), radius, radius);
            dc.PushClip(new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(new Rect(0, 0, width, height)), screen));
            if (photo != null && geometry.ArtworkScreen is { } opening)
            {
                // Black in any of the photo's screen the picture doesn't cover, then the photo
                // over everything (its screen's rounded corners can sit over the picture's).
                dc.DrawRectangle(Brushes.Black, null, new Rect(opening.X * unit, opening.Y * unit, opening.Width * unit, opening.Height * unit));
                dc.Pop();
                dc.DrawImage(photo, new Rect(0, 0, width, height));
            }
            else
            {
                PhoneBezelFrame.Draw(dc, geometry, new Size(width, height), unit);
                dc.Pop();
            }
        }
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        pixels = new byte[width * 4 * height];
        bitmap.CopyPixels(pixels, width * 4, 0);

        clearStart = new int[pictureHeight];
        clearEnd = new int[pictureHeight];
        var partly = new List<int>();
        for (int row = 0; row < pictureHeight; row++)
        {
            int y = top + row, start = -1, end = -1;
            for (int x = left; x < left + pictureWidth; x++)
            {
                byte alpha = pixels[(y * width + x) * 4 + 3];
                if (alpha == 0)
                {
                    if (start < 0) start = x;
                    end = x + 1;
                }
                else if (alpha < 255)
                {
                    partly.Add(y * width + x);
                }
            }
            clearStart[row] = start < 0 ? 0 : start;
            clearEnd[row] = start < 0 ? 0 : end;
        }
        blended = partly.ToArray();
    }

    /// <summary>A new picture: <paramref name="picture"/> (of this frame's picture size) inside
    /// the frame.</summary>
    public Picture Frame(Picture picture)
    {
        var output = new Picture(width, height, picture.RtpTimestamp);
        byte[] into = output.Pixels, from = picture.Pixels;
        int rowBytes = width * 4;
        for (int y = 0; y < height; y++) Buffer.BlockCopy(pixels, y * rowBytes, into, y * output.Stride, rowBytes);
        for (int row = 0; row < PictureHeight; row++)
        {
            int count = clearEnd[row] - clearStart[row];
            if (count <= 0) continue;
            Buffer.BlockCopy(from, row * picture.Stride + (clearStart[row] - left) * 4, into, (top + row) * output.Stride + clearStart[row] * 4, count * 4);
        }
        foreach (int index in blended)
        {
            int x = index % width, y = index / width;
            int frame = index * 4, under = (y - top) * picture.Stride + (x - left) * 4, to = y * output.Stride + x * 4;
            int show = 255 - pixels[frame + 3];
            for (int channel = 0; channel < 3; channel++)
            {
                into[to + channel] = (byte)Math.Min(255, pixels[frame + channel] + (from[under + channel] * show + 127) / 255);
            }
            into[to + 3] = 255;
        }
        return output;
    }
}
