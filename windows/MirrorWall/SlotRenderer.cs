using System.Collections.Concurrent;
using System.Diagnostics;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// Decodes a slot's frames once and shows each picture in a bitmap that its tile and its own
/// window both display, so a slot can be on screen in two places.
///
/// Frames are shown the moment they arrive (no timestamp sync), which is what keeps the picture
/// alive after a phone sleeps and wakes. With <see cref="SmoothMotion"/>, each picture instead
/// waits a moment and is shown at the pace the phone captured it (see <see cref="PlayoutClock"/>).
///
/// <see cref="Render"/> and <see cref="Reset"/> run on the slot's UDP thread or after it has
/// stopped; <see cref="Bitmap"/> lives on the UI thread.
/// </summary>
internal sealed class SlotRenderer : Observable
{
    private readonly Dispatcher dispatcher;
    private VideoDecoder? decoder;
    private byte[]? sps;

    private readonly object gate = new();
    // Guarded by `gate`.
    private Picture? current;
    private bool smoothing;
    private readonly PlayoutClock playout = new();
    /// <summary>Counts pictures, so one held back can't replace a later one already shown.</summary>
    private long pictureNumber;
    private long shownNumber;
    private bool uiUpdatePending;
    private BlockingCollection<(Picture Picture, double Due, long Number)>? playoutQueue;

    public SlotRenderer()
    {
        dispatcher = Dispatcher.CurrentDispatcher;
    }

    /// <summary>Shows pictures at the pace the phone captured them, about a tenth of a second later,
    /// rather than as Wi-Fi delivers them.</summary>
    public bool SmoothMotion
    {
        get { lock (gate) return smoothing; }
        set
        {
            lock (gate)
            {
                smoothing = value;
                playout.Reset();
                if (value && playoutQueue == null)
                {
                    playoutQueue = new BlockingCollection<(Picture, double, long)>();
                    var queue = playoutQueue;
                    new Thread(() => PlayOut(queue)) { Name = "Mirror Wall playout", IsBackground = true, Priority = ThreadPriority.Highest }.Start();
                }
            }
        }
    }

    /// <summary>The slot's picture, for the tile and the slot's own window. UI thread only.</summary>
    public WriteableBitmap? Bitmap { get; private set; }

    /// <summary>Current picture size in pixels, once known. Read on the UDP thread.</summary>
    public (int Width, int Height)? Dimensions { get; private set; }

    /// <summary>Called with each decoded picture, for recording. Runs on the UDP thread; the
    /// picture is only lent for the call.</summary>
    public Action<Picture>? OnPicture { get; set; }

    /// <summary>Called with each picture as it goes on screen (after Smoother Motion's wait), e.g.
    /// to send it to OBS. The picture is only lent for the call: retain it to keep it.</summary>
    public Action<Picture>? OnShow { get; set; }

    /// <summary>The picture on screen now, if any, retained for the caller, who must release it.</summary>
    public Picture? CurrentPicture()
    {
        lock (gate) return current?.Retain();
    }

    /// <summary>The stream's codec, profile and level, e.g. "H.264 High 4.2". Read on the UDP thread.</summary>
    public string? CodecDescription => sps == null ? null
        : decoder?.Codec == VideoCodec.Hevc ? CodecDescriptions.Hevc(sps) : CodecDescriptions.H264(sps);

    /// <summary>Decodes a frame that arrived at <paramref name="arrival"/> (seconds, <see cref="Clock.Now"/>).
    /// Returns true if it produced a picture.</summary>
    public bool Render(VideoFrame frame, double arrival)
    {
        if (decoder == null || decoder.Codec != frame.Codec)
        {
            // A new stream, or the receiver restarted in the other mode.
            decoder?.Dispose();
            decoder = new VideoDecoder(frame.Codec);
            sps = null;
        }
        foreach (var nal in frame.NalUnits)
        {
            bool isSps = frame.Codec == VideoCodec.Hevc ? HevcNalType.Of(nal) == HevcNalType.Sps : H264NalType.Of(nal) == H264NalType.Sps;
            if (isSps) sps = nal;
        }
        var picture = decoder.Decode(frame);
        if (picture == null) return false;
        Dimensions = (picture.Width, picture.Height);
        OnPicture?.Invoke(picture);
        Present(picture, frame.Timestamp, arrival);
        return true;
    }

    /// <summary>Shows a decoded picture now or, with Smoother Motion, when it's due. Takes over the
    /// caller's reference.</summary>
    private void Present(Picture picture, uint rtp, double arrival)
    {
        long number;
        double due;
        BlockingCollection<(Picture, double, long)>? queue;
        lock (gate)
        {
            number = ++pictureNumber;
            if (!smoothing)
            {
                Show(picture, number);
                return;
            }
            due = playout.Due(rtp, arrival);
            queue = playoutQueue;
        }
        try
        {
            queue!.Add((picture, due, number));
        }
        catch (InvalidOperationException)
        {
            picture.Release(); // the renderer has just been disposed
        }
    }

    /// <summary>Shows queued pictures when they're due. Due times never go backwards, so a queue in
    /// arrival order is in showing order too.</summary>
    private void PlayOut(BlockingCollection<(Picture Picture, double Due, long Number)> queue)
    {
        foreach (var (picture, due, number) in queue.GetConsumingEnumerable())
        {
            double wait = due - Clock.Now;
            if (wait > 0.002) Thread.Sleep(TimeSpan.FromSeconds(wait - 0.001));
            while (Clock.Now < due) Thread.SpinWait(50);
            lock (gate) Show(picture, number);
        }
    }

    /// <summary>Makes a picture the current one and gets it on screen. Call with `gate` held. Takes
    /// over the caller's reference.</summary>
    private void Show(Picture picture, long number)
    {
        if (number <= shownNumber)
        {
            picture.Release();
            return;
        }
        shownNumber = number;
        current?.Release();
        current = picture;
        OnShow?.Invoke(picture);
        if (uiUpdatePending) return;
        uiUpdatePending = true;
        dispatcher.BeginInvoke(DispatcherPriority.Render, UpdateBitmap);
    }

    /// <summary>Copies the latest picture into the bitmap. Several pictures arriving between two
    /// screen refreshes cost one copy.</summary>
    private void UpdateBitmap()
    {
        Picture? picture;
        lock (gate)
        {
            uiUpdatePending = false;
            picture = current?.Retain();
        }
        if (picture == null) return;
        try
        {
            if (Bitmap == null || Bitmap.PixelWidth != picture.Width || Bitmap.PixelHeight != picture.Height)
            {
                Bitmap = new WriteableBitmap(picture.Width, picture.Height, 96, 96, PixelFormats.Bgr32, null);
                Changed(nameof(Bitmap));
            }
            Bitmap.WritePixels(new Int32Rect(0, 0, picture.Width, picture.Height), picture.Pixels, picture.Stride, 0);
        }
        finally
        {
            picture.Release();
        }
    }

    /// <summary>Ends the playout thread, when the slot is removed or the app quits.</summary>
    public void Dispose()
    {
        lock (gate)
        {
            playoutQueue?.CompleteAdding();
            playoutQueue = null;
            smoothing = false;
        }
    }

    /// <summary>Clears the picture, e.g. when the slot stops. Only call it once rendering has stopped.</summary>
    public void Reset()
    {
        decoder?.Dispose();
        decoder = null;
        sps = null;
        Dimensions = null;
        lock (gate)
        {
            current?.Release();
            current = null;
            playout.Reset();
            shownNumber = pictureNumber;
        }
    }
}

/// <summary>Seconds on a steady clock, for timing frames.</summary>
internal static class Clock
{
    public static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
}
