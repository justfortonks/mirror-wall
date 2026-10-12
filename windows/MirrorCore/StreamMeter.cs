namespace MirrorWall.Core;

/// <summary>One second's worth of a slot's video stream, for the Stats for Nerds overlay.</summary>
public sealed record StreamSnapshot
{
    /// <summary>Frames that reached the screen, per second.</summary>
    public double FramesPerSecond { get; init; }
    /// <summary>Video data arriving, in bits per second.</summary>
    public double BitsPerSecond { get; init; }
    /// <summary>How unevenly frames arrive: the standard deviation of the gaps between them, in seconds.</summary>
    public double FrameJitter { get; init; }
    /// <summary>Average time the PC took to decode a frame and hand it to the screen, in seconds.</summary>
    public double? DecodeTime { get; init; }
    /// <summary>RTP packets that never arrived from uxplay (local drops), in this second and in total.</summary>
    public int PacketsLost { get; init; }
    public int TotalPacketsLost { get; init; }
    /// <summary>Frames that couldn't be shown (waiting for a keyframe after a loss, or a decode error).</summary>
    public int TotalFramesSkipped { get; init; }
    public int TotalKeyframes { get; init; }
    /// <summary>Seconds between the last two keyframes.</summary>
    public double? KeyframeInterval { get; init; }
}

/// <summary>
/// Measures a video stream as it arrives and sums it up once a second.
///
/// Not thread-safe: feed it from one thread (the slot's UDP thread). Times are in seconds on any
/// steady clock.
/// </summary>
public sealed class StreamMeter
{
    private readonly double window;
    private double? windowStart;
    private int bytes;
    private int shown;
    private int lost;
    private double decodeTimeTotal;
    private int decodeTimeCount;
    private List<double> gaps = new();
    private double? lastFrameAt;
    private double? lastKeyframeAt;
    private double? keyframeInterval;
    private int totalLost;
    private int totalSkipped;
    private int totalKeyframes;

    internal const double PauseGap = 0.5;

    public StreamMeter(double window = 1)
    {
        this.window = window;
    }

    /// <summary>A packet of <paramref name="bytes"/> arrived; <paramref name="lost"/> packets were missing before it.</summary>
    public void Packet(int bytes, int lost, double time)
    {
        windowStart ??= time;
        this.bytes += bytes;
        this.lost += lost;
        totalLost += lost;
    }

    /// <summary>A complete frame arrived. <paramref name="decodeTime"/> is how long decoding and
    /// display took, or null if the frame couldn't be shown.</summary>
    public void Frame(double time, bool isKeyframe, double? decodeTime)
    {
        windowStart ??= time;
        if (decodeTime is not double took)
        {
            totalSkipped++;
            return;
        }
        shown++;
        decodeTimeTotal += took;
        decodeTimeCount++;
        // A longer gap is a pause (an unchanging screen sends no frames), not jitter.
        if (lastFrameAt is double previous && time - previous < PauseGap) gaps.Add(time - previous);
        lastFrameAt = time;
        if (isKeyframe)
        {
            totalKeyframes++;
            if (lastKeyframeAt is double previousKeyframe) keyframeInterval = time - previousKeyframe;
            lastKeyframeAt = time;
        }
    }

    /// <summary>Once a window has passed, sums it up and starts the next one; otherwise null.</summary>
    public StreamSnapshot? SnapshotIfDue(double time)
    {
        if (windowStart is not double start || time - start < window) return null;
        double elapsed = time - start;
        var snapshot = new StreamSnapshot
        {
            FramesPerSecond = shown / elapsed,
            BitsPerSecond = bytes * 8.0 / elapsed,
            FrameJitter = StandardDeviation(gaps),
            DecodeTime = decodeTimeCount > 0 ? decodeTimeTotal / decodeTimeCount : null,
            PacketsLost = lost,
            TotalPacketsLost = totalLost,
            TotalFramesSkipped = totalSkipped,
            TotalKeyframes = totalKeyframes,
            KeyframeInterval = keyframeInterval,
        };
        windowStart = time;
        bytes = 0;
        shown = 0;
        lost = 0;
        decodeTimeTotal = 0;
        decodeTimeCount = 0;
        gaps = new();
        return snapshot;
    }

    /// <summary>Starts over, for a new connection.</summary>
    public void Reset()
    {
        windowStart = null;
        bytes = 0;
        shown = 0;
        lost = 0;
        decodeTimeTotal = 0;
        decodeTimeCount = 0;
        gaps = new();
        lastFrameAt = null;
        lastKeyframeAt = null;
        keyframeInterval = null;
        totalLost = 0;
        totalSkipped = 0;
        totalKeyframes = 0;
    }

    internal static double StandardDeviation(List<double> values)
    {
        if (values.Count <= 1) return 0;
        double mean = values.Average();
        double variance = values.Sum(value => (value - mean) * (value - mean)) / values.Count;
        return Math.Sqrt(variance);
    }
}

public static class CodecDescriptions
{
    /// <summary>"H.264 High 4.2" from a sequence parameter set (its profile and level bytes).</summary>
    public static string H264(byte[] sps)
    {
        if (sps.Length < 4) return "H.264";
        string profile = sps[1] switch
        {
            66 => "Baseline", 77 => "Main", 88 => "Extended", 100 => "High",
            110 => "High 10", 122 => "High 4:2:2", 244 => "High 4:4:4",
            var other => $"profile {other}",
        };
        int level = sps[3];
        return $"H.264 {profile} {level / 10}.{level % 10}";
    }

    /// <summary>"H.265 Main 5.1" from an H.265 sequence parameter set (its profile_tier_level).</summary>
    public static string Hevc(byte[] sps)
    {
        // Undo emulation prevention (00 00 03 → 00 00), which the all-zero constraint flags often need.
        var bytes = new List<byte>(sps.Length);
        int zeros = 0;
        foreach (byte value in sps)
        {
            if (zeros >= 2 && value == 3) { zeros = 0; continue; }
            zeros = value == 0 ? zeros + 1 : 0;
            bytes.Add(value);
        }
        // 2-byte NAL header, 1 byte of IDs, then profile space/tier/profile, 4 bytes of compatibility
        // flags, 6 bytes of constraint flags, and the level.
        if (bytes.Count < 15) return "H.265";
        int profileId = bytes[3] & 0x1F;
        string profile = profileId switch
        {
            1 => "Main", 2 => "Main 10", 3 => "Main Still Picture", 4 => "Range Extensions",
            _ => $"profile {profileId}",
        };
        int level = bytes[14];
        return $"H.265 {profile} {level / 30}.{level % 30 / 3}";
    }
}
