namespace MirrorWall.Core;

/// <summary>The video format a phone sends: H.264, or H.265 (HEVC) with the sharper picture.</summary>
public enum VideoCodec { H264, Hevc }

/// <summary>One video frame (access unit): the NAL units that share an RTP timestamp, without
/// start codes.</summary>
public sealed class VideoFrame : IEquatable<VideoFrame>
{
    public VideoFrame(IReadOnlyList<byte[]> nalUnits, uint timestamp, VideoCodec codec = VideoCodec.H264)
    {
        NalUnits = nalUnits;
        Timestamp = timestamp;
        Codec = codec;
    }

    public IReadOnlyList<byte[]> NalUnits { get; }
    public uint Timestamp { get; }
    public VideoCodec Codec { get; }

    public bool IsKeyframe => Codec switch
    {
        VideoCodec.H264 => NalUnits.Any(nal => H264NalType.Of(nal) == H264NalType.Idr),
        _ => NalUnits.Any(nal => HevcNalType.Of(nal) is byte type && HevcNalType.IsKeyframe(type)),
    };

    /// <summary>The frame in Annex B form (each NAL unit after a 00 00 00 01 start code), as FFmpeg's
    /// decoders take it.</summary>
    public byte[] ToAnnexB(Func<byte[], bool>? include = null)
    {
        var units = include == null ? NalUnits : NalUnits.Where(include).ToList();
        var output = new byte[units.Sum(nal => nal.Length + 4)];
        int offset = 0;
        foreach (var nal in units)
        {
            output[offset + 3] = 1;
            nal.CopyTo(output, offset + 4);
            offset += nal.Length + 4;
        }
        return output;
    }

    public bool Equals(VideoFrame? other) =>
        other != null && Timestamp == other.Timestamp && Codec == other.Codec &&
        NalUnits.Count == other.NalUnits.Count &&
        NalUnits.Zip(other.NalUnits).All(pair => pair.First.AsSpan().SequenceEqual(pair.Second));

    public override bool Equals(object? obj) => Equals(obj as VideoFrame);
    public override int GetHashCode() => HashCode.Combine(Timestamp, Codec, NalUnits.Count);
    public override string ToString() =>
        $"{Codec} frame @{Timestamp}: " + string.Join(" | ", NalUnits.Select(nal => Convert.ToHexString(nal)));
}

/// <summary>H.264 NAL unit types the app cares about.</summary>
public static class H264NalType
{
    public const byte Slice = 1;
    public const byte Idr = 5;
    public const byte Sei = 6;
    public const byte Sps = 7;
    public const byte Pps = 8;
    public const byte AccessUnitDelimiter = 9;
    public const byte StapA = 24;
    public const byte FuA = 28;

    public static byte? Of(byte[] nal) => nal.Length > 0 ? (byte)(nal[0] & 0x1F) : null;
}

/// <summary>H.265 NAL unit types the app cares about (ITU-T H.265 table 7-1, RFC 7798).</summary>
public static class HevcNalType
{
    public const byte Vps = 32;
    public const byte Sps = 33;
    public const byte Pps = 34;
    public const byte AccessUnitDelimiter = 35;
    internal const byte Aggregation = 48;
    internal const byte Fragment = 49;

    /// <summary>The type from a NAL unit's two-byte header.</summary>
    public static byte? Of(byte[] nal) => nal.Length > 0 ? (byte)((nal[0] >> 1) & 0x3F) : null;

    /// <summary>IRAP pictures (BLA, IDR, CRA): the decoder can start at one.</summary>
    public static bool IsKeyframe(byte type) => type >= 16 && type <= 21;
}

/// <summary>
/// Reassembles video frames from RTP packets: H.264 as GStreamer's rtph264pay sends it (RFC 6184
/// non-interleaved mode: single NAL unit packets, STAP-A and FU-A), or H.265 as rtph265pay sends
/// it (RFC 7798: single NAL unit packets, aggregation packets and fragmentation units).
///
/// The codec is read from the stream: from the parameter sets that come before every keyframe
/// (the receiver runs rtph26xpay with config-interval=1). Their first bytes can't be mistaken for
/// the other codec's. Until one arrives, the stream is taken to be H.264, the phones' usual format;
/// anything collected before it is dropped when it shows otherwise.
///
/// Not thread-safe: feed it from one thread.
/// </summary>
public sealed class Depacketizer
{
    /// <summary>The codec the stream is in: H.264 until a parameter set shows otherwise.</summary>
    public VideoCodec Codec { get; private set; } = VideoCodec.H264;
    private List<byte[]> pending = new();
    private uint? pendingTimestamp;
    private List<byte>? fragment;
    private ushort? lastSequence;

    /// <summary>Number of gaps seen in RTP sequence numbers.</summary>
    public int SequenceGaps { get; private set; }
    /// <summary>Number of packets missing from those gaps.</summary>
    public int LostPackets { get; private set; }

    /// <summary>
    /// Adds a packet and returns any frames it completed. A frame is complete when a packet
    /// carries the RTP marker bit, or when a packet with a new timestamp arrives while the
    /// previous frame is still open (its marker was lost).
    /// </summary>
    public List<VideoFrame> Push(RtpPacket packet)
    {
        var completed = new List<VideoFrame>();

        if (lastSequence is ushort last && packet.SequenceNumber != (ushort)(last + 1))
        {
            SequenceGaps++;
            int missing = (ushort)(packet.SequenceNumber - last - 1);
            // A packet arriving late looks like a gap of almost 65536; it isn't a loss.
            if (missing < 1000) LostPackets += missing;
            fragment = null;
        }
        lastSequence = packet.SequenceNumber;

        var payload = packet.Payload;
        if (CodecOfParameterSets(payload) is VideoCodec detected && detected != Codec)
        {
            // The stream is in the other codec: drop whatever was collected as this one.
            Codec = detected;
            pending = new();
            pendingTimestamp = null;
            fragment = null;
        }

        if (pendingTimestamp is uint timestamp && timestamp != packet.Timestamp)
        {
            if (pending.Count > 0) completed.Add(new VideoFrame(pending, timestamp, Codec));
            pending = new();
            fragment = null;
        }
        pendingTimestamp = packet.Timestamp;

        if (Codec == VideoCodec.Hevc)
        {
            PushHevc(payload);
        }
        else if (payload.Length > 0)
        {
            byte header = payload[0];
            switch (header & 0x1F)
            {
                case >= 1 and <= 23:
                    pending.Add(payload);
                    break;
                case H264NalType.StapA:
                    CollectAggregated(payload, 1);
                    break;
                case H264NalType.FuA:
                    if (payload.Length < 2) break;
                    byte fuHeader = payload[1];
                    bool isStart = (fuHeader & 0x80) != 0;
                    bool isEnd = (fuHeader & 0x40) != 0;
                    if (isStart)
                    {
                        fragment = new List<byte>(payload.Length * 4) { (byte)((header & 0xE0) | (fuHeader & 0x1F)) };
                        fragment.AddRange(payload.AsSpan(2).ToArray());
                    }
                    else
                    {
                        fragment?.AddRange(payload.AsSpan(2).ToArray());
                    }
                    if (isEnd && fragment != null)
                    {
                        pending.Add(fragment.ToArray());
                        fragment = null;
                    }
                    break;
                default:
                    break; // STAP-B, MTAP and FU-B are not used in non-interleaved mode.
            }
        }

        if (packet.Marker)
        {
            if (pending.Count > 0) completed.Add(new VideoFrame(pending, packet.Timestamp, Codec));
            pending = new();
            pendingTimestamp = null;
            fragment = null;
        }
        return completed;
    }

    /// <summary>Collects the NAL units in one H.265 packet's payload.</summary>
    private void PushHevc(byte[] payload)
    {
        if (payload.Length < 3 || HevcNalType.Of(payload) is not byte type) return;
        switch (type)
        {
            case HevcNalType.Aggregation:
                CollectAggregated(payload, 2);
                break;
            case HevcNalType.Fragment:
                byte fuHeader = payload[2];
                bool isStart = (fuHeader & 0x80) != 0;
                bool isEnd = (fuHeader & 0x40) != 0;
                if (isStart)
                {
                    // The NAL header again, with the fragment's own type in place of 49.
                    fragment = new List<byte>(payload.Length * 4) { (byte)((payload[0] & 0x81) | (fuHeader & 0x3F) << 1), payload[1] };
                    fragment.AddRange(payload.AsSpan(3).ToArray());
                }
                else
                {
                    fragment?.AddRange(payload.AsSpan(3).ToArray());
                }
                if (isEnd && fragment != null)
                {
                    pending.Add(fragment.ToArray());
                    fragment = null;
                }
                break;
            case < HevcNalType.Aggregation:
                pending.Add(payload);
                break;
            default:
                break; // PACI and reserved types aren't sent by rtph265pay.
        }
    }

    /// <summary>The NAL units of a STAP-A or H.265 aggregation packet, each after a 2-byte size.</summary>
    private void CollectAggregated(byte[] payload, int index)
    {
        while (index + 2 <= payload.Length)
        {
            int size = payload[index] << 8 | payload[index + 1];
            index += 2;
            if (size <= 0 || index + size > payload.Length) break;
            pending.Add(payload[index..(index + size)]);
            index += size;
        }
    }

    /// <summary>
    /// The codec a packet shows, if it carries a parameter set: an H.265 VPS (alone or first in an
    /// aggregation packet) or an H.264 SPS (alone or first in a STAP-A). Every other packet, null.
    ///
    /// H.265 NAL headers from a phone always have an even first byte (layer 0), and an H.264 SPS's
    /// is odd, so the two can't be confused. 0x40 or 0x60 in H.264 would be type 0, which isn't used.
    /// </summary>
    public static VideoCodec? CodecOfParameterSets(byte[] payload)
    {
        if (payload.Length < 2) return null;
        byte first = payload[0];
        if (payload[1] == 0x01)
        {
            if (first == 0x40) return VideoCodec.Hevc;
            if (first == 0x60 && payload.Length >= 5 && payload[4] == 0x40) return VideoCodec.Hevc;
        }
        if ((first & 0x80) == 0 && (first & 0x1F) == H264NalType.Sps) return VideoCodec.H264;
        if ((first & 0x80) == 0 && (first & 0x1F) == H264NalType.StapA &&
            payload.Length >= 4 && (payload[3] & 0x1F) == H264NalType.Sps)
        {
            return VideoCodec.H264;
        }
        return null;
    }

    /// <summary>Drops any partial frame and forgets the codec, for example when the phone reconnects.</summary>
    public void Reset()
    {
        pending = new();
        pendingTimestamp = null;
        fragment = null;
        lastSequence = null;
        Codec = VideoCodec.H264;
    }
}
