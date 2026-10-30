using System.Collections.Concurrent;
using FFmpeg.AutoGen;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// Writes one slot's pictures to MP4 files, compressing them with the PC's H.264 encoder.
///
/// It records the pictures already decoded for the tile rather than copying the phone's video,
/// because a copied stream can only start on a keyframe, and an iPhone sends one only when
/// mirroring starts, the screen wakes or it rotates. Re-compressing lets a recording start the
/// moment it's asked for.
///
/// The video is a square, sized when the file starts to hold the phone's picture either way up,
/// so turning the phone doesn't start a new file: each picture is scaled to fit it, upright with
/// black bars at the sides, sideways with bars above and below. (Turning can change the picture's
/// longer side, not just swap its width and height: an iPhone sends 498×1080 upright but
/// 1920×884 sideways.) A new file starts when a new connection begins. Frames are timed from the stream's own timestamps where it has them
/// (<see cref="RecordingClock"/>), not their bursty arrival. Encoding happens on a thread of its
/// own, so the slot's stream never waits for it.
/// </summary>
internal sealed class SlotRecorder
{
    private readonly string folder;
    private readonly BlockingCollection<Action> work = new(boundedCapacity: 30);
    private readonly Thread thread;

    // Touched only on the recorder's thread.
    private Mp4Writer? writer;
    private int part;
    private DateTime startedAt = DateTime.Now;
    private RecordingClock clock = new();
    private Picture? last;

    /// <summary>Names later files, e.g. after the phone that's mirroring. Set on the UI thread.</summary>
    public volatile string BaseName;
    /// <summary>Called (on any thread) with a message when writing fails.</summary>
    public Action<string>? OnError { get; set; }

    public SlotRecorder(string folder, string baseName)
    {
        this.folder = folder;
        BaseName = baseName;
        thread = new Thread(() => { foreach (var job in work.GetConsumingEnumerable()) job(); })
        {
            Name = "Mirror Wall recorder",
            IsBackground = true,
        };
        thread.Start();
    }

    /// <summary>Adds a decoded picture stamped <paramref name="rtp"/> (null if unknown) that arrived at
    /// <paramref name="arrival"/> (<see cref="Clock.Now"/>). The picture is only lent for the call.</summary>
    public void Append(Picture picture, uint? rtp, double arrival)
    {
        var held = picture.Retain();
        // Dropped if the encoder has fallen far behind, rather than holding up the stream.
        if (!work.TryAdd(() => Write(held, rtp, arrival))) held.Release();
    }

    /// <summary>Finishes the current file but keeps recording: the next picture starts a new one.</summary>
    public void EndFile()
    {
        double now = Clock.Now;
        work.Add(() => Finish(now));
    }

    /// <summary>Finishes the current file and stops for good, waiting until the file is complete.</summary>
    public void Close()
    {
        EndFile();
        work.CompleteAdding();
        thread.Join(5000);
    }

    private void Write(Picture picture, uint? rtp, double arrival)
    {
        try
        {
            if (writer == null)
            {
                clock = new RecordingClock();
                Start(Mp4Writer.SideFor(picture.Width, picture.Height));
            }
            if (writer == null) return;
            writer.Write(picture, clock.Time(rtp, arrival));
            last?.Release();
            last = picture.Retain();
        }
        catch (InvalidOperationException error)
        {
            OnError?.Invoke($"recording failed: {error.Message}");
            Abandon();
        }
        finally
        {
            picture.Release();
        }
    }

    private void Start(int side)
    {
        part++;
        if (part == 1) startedAt = DateTime.Now;
        string path = Path.Combine(folder, FileName(BaseName, startedAt, part));
        try
        {
            Directory.CreateDirectory(folder);
            writer = new Mp4Writer(path, side);
        }
        catch (Exception error) when (error is InvalidOperationException or IOException or UnauthorizedAccessException or DllNotFoundException or NotSupportedException)
        {
            OnError?.Invoke($"couldn't record to {Path.GetFileName(path)}: {error.Message}");
            writer = null;
        }
    }

    private void Finish(double arrival)
    {
        if (writer == null) return;
        try
        {
            // Keep the last picture on screen until now, e.g. through a still screen that sent no frames.
            if (last != null) writer.Write(last, clock.TimeAtArrival(arrival));
            writer.Finish();
        }
        catch (InvalidOperationException error)
        {
            OnError?.Invoke($"recording failed: {error.Message}");
        }
        Abandon();
    }

    private void Abandon()
    {
        writer?.Dispose();
        writer = null;
        last?.Release();
        last = null;
    }

    /// <summary>"iPhone 2026-10-11 21.05.33.mp4", then "… part 2.mp4" and so on.</summary>
    public static string FileName(string baseName, DateTime startedAt, int part) =>
        $"{FileNames.Safe(baseName)} {startedAt:yyyy-MM-dd HH.mm.ss}{(part > 1 ? $" part {part}" : "")}.mp4";
}

/// <summary>One MP4 file being written: FFmpeg's H.264 encoder and MP4 muxer. The video is a square;
/// each picture is fitted into it, centred, with black around it.</summary>
internal sealed unsafe class Mp4Writer : IDisposable
{
    /// <summary>Fine enough that frames a few milliseconds apart never share a time.</summary>
    private const int Timescale = 90_000;

    /// <summary>Encoders to try, best first: Windows' own (Media Foundation, which uses the graphics
    /// card where it can), then the graphics makers' own, then software ones if present.</summary>
    private static readonly string[] Encoders = { "h264_mf", "h264_qsv", "h264_nvenc", "h264_amf", "libopenh264", "libx264" };

    /// <summary>The square's side in pixels (see <see cref="SideFor"/>).</summary>
    public int Side { get; }
    private AVFormatContext* format;
    private AVCodecContext* encoder;
    private AVStream* stream;
    private AVFrame* frame;
    private AVPacket* packet;
    private SwsContext* converter;
    /// <summary>The picture size <see cref="converter"/> takes, and where it puts it in the square.</summary>
    private (int Width, int Height) converterFrom;
    private (int X, int Y, int Width, int Height) placed;
    private long lastPts = -1;
    private bool headerWritten;

    /// <summary>The square's side for a recording whose first picture is this size: long enough for
    /// the phone turned the other way too. The stream fits a 16:9 box, so an upright picture's height
    /// is the box's height and a sideways one may be up to 16/9 of that wide (1080 → 1920). Capped at
    /// 2560, within what H.264 encoders take, so Sharper Picture's 3840-wide landscape is scaled down
    /// a little. Even, as H.264 in NV12 needs.</summary>
    public static int SideFor(int width, int height)
    {
        int longSide = Math.Max(width, height);
        int roomy = height > width ? Math.Max(longSide, longSide * 16 / 9) : longSide;
        return Math.Min(roomy, 2560) & ~1;
    }

    public Mp4Writer(string path, int side)
    {
        FFmpegLibraries.Load();
        Side = side;
        try
        {
            Open(path);
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    private void Open(string path)
    {
        AVFormatContext* newFormat = null;
        Check(ffmpeg.avformat_alloc_output_context2(&newFormat, null, "mp4", path), "couldn't create the file");
        format = newFormat;

        encoder = OpenEncoder(needsGlobalHeader: (format->oformat->flags & ffmpeg.AVFMT_GLOBALHEADER) != 0);

        stream = ffmpeg.avformat_new_stream(format, null);
        if (stream == null) throw new InvalidOperationException("couldn't add the video track");
        stream->time_base = new AVRational { num = 1, den = Timescale };
        Check(ffmpeg.avcodec_parameters_from_context(stream->codecpar, encoder), "couldn't set up the video track");

        Check(ffmpeg.avio_open(&format->pb, path, ffmpeg.AVIO_FLAG_WRITE), "couldn't create the file");
        Check(ffmpeg.avformat_write_header(format, null), "couldn't start the file");
        headerWritten = true;

        frame = ffmpeg.av_frame_alloc();
        frame->format = (int)encoder->pix_fmt;
        frame->width = Side;
        frame->height = Side;
        Check(ffmpeg.av_frame_get_buffer(frame, 0), "out of memory");
        packet = ffmpeg.av_packet_alloc();
    }

    /// <summary>Sets up the converter for pictures of this size, fitted into the square and centred.
    /// Positions and sizes are even, so NV12's half-size colour plane lines up.</summary>
    private void Convert(int width, int height)
    {
        if (converter != null && converterFrom == (width, height)) return;
        if (converter != null) ffmpeg.sws_freeContext(converter);
        // Scaled to fill the square's side either way, as the Mac's letterboxing does.
        double scale = Side / (double)Math.Max(width, height);
        int fitWidth = Math.Max(2, (int)(width * scale) & ~1);
        int fitHeight = Math.Max(2, (int)(height * scale) & ~1);
        placed = (((Side - fitWidth) / 2) & ~1, ((Side - fitHeight) / 2) & ~1, fitWidth, fitHeight);
        converterFrom = (width, height);
        converter = ffmpeg.sws_getContext(width, height, AVPixelFormat.AV_PIX_FMT_BGRA, fitWidth, fitHeight, encoder->pix_fmt,
            (int)SwsFlags.SWS_BILINEAR, null, null, null);
        if (converter == null) throw new InvalidOperationException("couldn't convert the picture for the encoder");
        // Tag the colours as the phone sent them: BT.709, limited range.
        var table = new int_array4();
        int* coefficients = ffmpeg.sws_getCoefficients(ffmpeg.SWS_CS_ITU709);
        for (uint i = 0; i < 4; i++) table[i] = coefficients[i];
        ffmpeg.sws_setColorspaceDetails(converter, table, 1, table, 0, 0, 1 << 16, 1 << 16);
    }

    /// <summary>Paints the whole square black (limited-range NV12: Y 16, U and V 128).</summary>
    private void FillBlack()
    {
        for (int y = 0; y < Side; y++) new Span<byte>(frame->data[0] + (long)y * frame->linesize[0], Side).Fill(16);
        for (int y = 0; y < Side / 2; y++) new Span<byte>(frame->data[1] + (long)y * frame->linesize[1], Side).Fill(128);
    }

    /// <summary>The first encoder on this PC that opens for this picture size.</summary>
    private AVCodecContext* OpenEncoder(bool needsGlobalHeader)
    {
        var failures = new List<string>();
        foreach (string name in Encoders)
        {
            AVCodec* codec = ffmpeg.avcodec_find_encoder_by_name(name);
            if (codec == null) continue;
            AVCodecContext* context = ffmpeg.avcodec_alloc_context3(codec);
            context->width = Side;
            context->height = Side;
            context->time_base = new AVRational { num = 1, den = Timescale };
            context->framerate = new AVRational { num = 60, den = 1 };
            context->pix_fmt = AVPixelFormat.AV_PIX_FMT_NV12;
            // Enough for a 16:9 picture as wide as the square to look like what the phone sent (the
            // black bars cost almost nothing; a phone's screen is mostly still): about 9 Mbps for a
            // 1920 square. H.264 rather than the Mac's HEVC, which many PCs can't play without a
            // paid extension.
            context->bit_rate = (long)Math.Max(3_000_000, Side * (Side * 9 / 16) * 60 * 0.07);
            // A keyframe every 2 seconds so players can jump around the file, and no reordering.
            context->gop_size = 120;
            context->max_b_frames = 0;
            context->color_primaries = AVColorPrimaries.AVCOL_PRI_BT709;
            context->color_trc = AVColorTransferCharacteristic.AVCOL_TRC_BT709;
            context->colorspace = AVColorSpace.AVCOL_SPC_BT709;
            context->color_range = AVColorRange.AVCOL_RANGE_MPEG;
            if (needsGlobalHeader) context->flags |= ffmpeg.AV_CODEC_FLAG_GLOBAL_HEADER;
            int status = ffmpeg.avcodec_open2(context, codec, null);
            if (status >= 0) return context;
            failures.Add($"{name}: {FFmpegLibraries.Describe(status)}");
            ffmpeg.avcodec_free_context(&context);
        }
        throw new InvalidOperationException(failures.Count == 0
            ? "no H.264 encoder found"
            : $"no H.264 encoder would record a {Side}×{Side} video ({string.Join("; ", failures)})");
    }

    /// <summary>Adds a picture shown <paramref name="seconds"/> into the recording.</summary>
    public void Write(Picture picture, double seconds)
    {
        long pts = (long)Math.Round(seconds * Timescale);
        if (pts <= lastPts) pts = lastPts + 1;
        lastPts = pts;
        Check(ffmpeg.av_frame_make_writable(frame), "out of memory");
        Convert(picture.Width, picture.Height);
        // The encoder may still hold the last buffer, so this one may be new: black it every time.
        FillBlack();
        fixed (byte* pixels = picture.Pixels)
        {
            var source = new byte_ptrArray4();
            source[0] = pixels;
            var strides = new int_array4();
            strides[0] = picture.Stride;
            var target = new byte_ptrArray4();
            target[0] = frame->data[0] + (long)placed.Y * frame->linesize[0] + placed.X;
            target[1] = frame->data[1] + (long)(placed.Y / 2) * frame->linesize[1] + placed.X;
            var targetStrides = new int_array4();
            targetStrides[0] = frame->linesize[0];
            targetStrides[1] = frame->linesize[1];
            ffmpeg.sws_scale(converter, source, strides, 0, picture.Height, target, targetStrides);
        }
        frame->pts = pts;
        Check(ffmpeg.avcodec_send_frame(encoder, frame), "the encoder refused a picture");
        Drain();
    }

    /// <summary>Writes out what the encoder still holds and completes the file.</summary>
    public void Finish()
    {
        ffmpeg.avcodec_send_frame(encoder, null);
        Drain();
        Check(ffmpeg.av_write_trailer(format), "couldn't complete the file");
        headerWritten = false;
    }

    private void Drain()
    {
        while (ffmpeg.avcodec_receive_packet(encoder, packet) >= 0)
        {
            ffmpeg.av_packet_rescale_ts(packet, encoder->time_base, stream->time_base);
            packet->stream_index = stream->index;
            int status = ffmpeg.av_interleaved_write_frame(format, packet);
            ffmpeg.av_packet_unref(packet);
            Check(status, "couldn't write to the file");
        }
    }

    private static void Check(int status, string what)
    {
        if (status < 0) throw new InvalidOperationException($"{what} ({FFmpegLibraries.Describe(status)})");
    }

    public void Dispose()
    {
        if (converter != null) ffmpeg.sws_freeContext(converter);
        converter = null;
        var frameToFree = frame;
        if (frameToFree != null) ffmpeg.av_frame_free(&frameToFree);
        frame = null;
        var packetToFree = packet;
        if (packetToFree != null) ffmpeg.av_packet_free(&packetToFree);
        packet = null;
        var encoderToFree = encoder;
        if (encoderToFree != null) ffmpeg.avcodec_free_context(&encoderToFree);
        encoder = null;
        if (format != null)
        {
            if (headerWritten) ffmpeg.av_write_trailer(format);
            if (format->pb != null) ffmpeg.avio_closep(&format->pb);
            ffmpeg.avformat_free_context(format);
            format = null;
        }
    }
}
