using System.Buffers;
using System.Runtime.InteropServices;
using FFmpeg.AutoGen;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// A decoded picture in BGRA, shared by everything that shows or saves it (the tile, the slot's
/// own window, the OBS feed, screenshots, recordings). Its pixels come from a pool and go back
/// when the last holder releases it.
/// </summary>
public sealed class Picture
{
    public int Width { get; }
    public int Height { get; }
    public int Stride => Width * 4;
    public byte[] Pixels { get; }
    /// <summary>The frame's RTP timestamp, or null for a still (a standby picture).</summary>
    public uint? RtpTimestamp { get; }
    private int references = 1;

    public Picture(int width, int height, uint? rtpTimestamp)
    {
        Width = width;
        Height = height;
        RtpTimestamp = rtpTimestamp;
        Pixels = ArrayPool<byte>.Shared.Rent(width * height * 4);
    }

    public int Length => Width * Height * 4;

    /// <summary>Another holder; each must <see cref="Release"/>.</summary>
    public Picture Retain()
    {
        Interlocked.Increment(ref references);
        return this;
    }

    public void Release()
    {
        if (Interlocked.Decrement(ref references) == 0) ArrayPool<byte>.Shared.Return(Pixels);
    }
}

/// <summary>
/// Decodes one slot's H.264 or H.265 frames with FFmpeg and converts each picture to BGRA.
/// Created per codec: the slot makes a new one when the stream switches.
///
/// Frames are decoded the moment they arrive, one at a time, with no reordering delay (iPhones
/// don't use B-frames), which keeps the picture as current as the Mac's.
/// </summary>
internal sealed unsafe class VideoDecoder : IDisposable
{
    public VideoCodec Codec { get; }
    private AVCodecContext* context;
    private AVFrame* frame;
    private AVPacket* packet;
    private SwsContext* scaler;
    private (int Width, int Height, AVPixelFormat Format, AVColorSpace Space, AVColorRange Range) scalerInput;
    private bool waitingForKeyframe = true;

    public VideoDecoder(VideoCodec codec)
    {
        Codec = codec;
        FFmpegLibraries.Load();
        AVCodec* decoder = ffmpeg.avcodec_find_decoder(codec == VideoCodec.Hevc ? AVCodecID.AV_CODEC_ID_HEVC : AVCodecID.AV_CODEC_ID_H264);
        if (decoder == null) throw new InvalidOperationException($"FFmpeg has no {codec} decoder");
        context = ffmpeg.avcodec_alloc_context3(decoder);
        context->flags |= ffmpeg.AV_CODEC_FLAG_LOW_DELAY;
        // One thread: frame threading would hold each picture back a frame per extra thread.
        context->thread_count = 1;
        int status = ffmpeg.avcodec_open2(context, decoder, null);
        if (status < 0) throw new InvalidOperationException($"couldn't open the {codec} decoder ({FFmpegLibraries.Describe(status)})");
        frame = ffmpeg.av_frame_alloc();
        packet = ffmpeg.av_packet_alloc();
    }

    /// <summary>
    /// Decodes a frame and returns its picture, or null if there's none to show yet (waiting for a
    /// keyframe, or a decoding error, after which it waits for the next keyframe).
    /// </summary>
    public Picture? Decode(VideoFrame videoFrame)
    {
        if (waitingForKeyframe)
        {
            if (!videoFrame.IsKeyframe) return null;
            waitingForKeyframe = false;
        }
        // Access unit delimiters carry nothing the decoder needs.
        byte[] data = videoFrame.ToAnnexB(nal => !IsDelimiter(nal));
        if (data.Length == 0) return null;

        Picture? picture = null;
        fixed (byte* bytes = data)
        {
            packet->data = bytes;
            packet->size = data.Length;
            packet->pts = videoFrame.Timestamp;
            int status = ffmpeg.avcodec_send_packet(context, packet);
            packet->data = null;
            packet->size = 0;
            // A damaged frame is dropped and decoding carries on: an iPhone may not send another
            // keyframe for a long time, so waiting for one could freeze a still screen.
            if (status < 0 && status != ffmpeg.AVERROR(ffmpeg.EAGAIN)) return null;
        }
        while (true)
        {
            int status = ffmpeg.avcodec_receive_frame(context, frame);
            if (status < 0) break; // EAGAIN: needs more data
            picture?.Release();
            picture = Convert(frame, videoFrame.Timestamp);
            ffmpeg.av_frame_unref(frame);
        }
        return picture;
    }

    private bool IsDelimiter(byte[] nal) => Codec == VideoCodec.Hevc
        ? HevcNalType.Of(nal) == HevcNalType.AccessUnitDelimiter
        : H264NalType.Of(nal) == H264NalType.AccessUnitDelimiter;

    /// <summary>The decoded picture as BGRA, with the colours the phone tagged it with.</summary>
    private Picture? Convert(AVFrame* decoded, uint timestamp)
    {
        int width = decoded->width, height = decoded->height;
        if (width <= 0 || height <= 0) return null;
        var format = (AVPixelFormat)decoded->format;
        var input = (width, height, format, decoded->colorspace, decoded->color_range);
        if (scaler == null || input != scalerInput)
        {
            scaler = ffmpeg.sws_getCachedContext(scaler, width, height, format, width, height, AVPixelFormat.AV_PIX_FMT_BGRA,
                (int)SwsFlags.SWS_POINT, null, null, null);
            if (scaler == null) return null;
            // iPhones send BT.709, usually limited range; swscale assumes BT.601 unless told.
            int space = decoded->colorspace == AVColorSpace.AVCOL_SPC_BT470BG || decoded->colorspace == AVColorSpace.AVCOL_SPC_SMPTE170M
                ? ffmpeg.SWS_CS_ITU601 : ffmpeg.SWS_CS_ITU709;
            int* coefficients = ffmpeg.sws_getCoefficients(space);
            var table = new int_array4();
            for (uint i = 0; i < 4; i++) table[i] = coefficients[i];
            int fullRange = decoded->color_range == AVColorRange.AVCOL_RANGE_JPEG ? 1 : 0;
            ffmpeg.sws_setColorspaceDetails(scaler, table, fullRange, table, 1, 0, 1 << 16, 1 << 16);
            scalerInput = input;
        }
        var picture = new Picture(width, height, timestamp);
        fixed (byte* pixels = picture.Pixels)
        {
            var destination = new byte_ptrArray4();
            destination[0] = pixels;
            var strides = new int_array4();
            strides[0] = picture.Stride;
            ffmpeg.sws_scale(scaler, decoded->data, decoded->linesize, 0, height, destination, strides);
        }
        return picture;
    }

    public void Dispose()
    {
        if (scaler != null) ffmpeg.sws_freeContext(scaler);
        scaler = null;
        var frameToFree = frame;
        ffmpeg.av_frame_free(&frameToFree);
        frame = null;
        var packetToFree = packet;
        ffmpeg.av_packet_free(&packetToFree);
        packet = null;
        var contextToFree = context;
        ffmpeg.avcodec_free_context(&contextToFree);
        context = null;
    }
}

/// <summary>Finds FFmpeg's libraries, which ship in the app's "ffmpeg" folder.</summary>
internal static class FFmpegLibraries
{
    private static bool loaded;

    /// <summary>Uses the FFmpeg that comes with the receiver (MSYS2's build), or the one beside a
    /// uxplay picked by hand.</summary>
    public static void Load()
    {
        if (loaded) return;
        var folders = new List<string> { Path.Combine(AppPaths.App, "receiver"), Path.Combine(AppPaths.App, "ffmpeg") };
        if (Path.GetDirectoryName(SlotStore.LocateUxPlay(Settings.Current.UxPlayPath)) is { } uxplayFolder) folders.Add(uxplayFolder);
        string folder = folders.FirstOrDefault(candidate => Directory.Exists(candidate) && Directory.EnumerateFiles(candidate, "avcodec-*.dll").Any())
            ?? AppPaths.App;
        ffmpeg.RootPath = folder;
        // So the libraries FFmpeg's own libraries load are found in the same folder.
        SetDllDirectory(folder);
        loaded = true;
    }

    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetDllDirectory(string path);

    public static unsafe string Describe(int status)
    {
        const int size = 256;
        byte* buffer = stackalloc byte[size];
        ffmpeg.av_strerror(status, buffer, size);
        return Marshal.PtrToStringUTF8((IntPtr)buffer) ?? status.ToString();
    }
}
