using System.Buffers.Binary;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MirrorWall.Core;

// Mirror Wall Cast: how the Android app sends its screen to a slot (see docs/mirror-wall-cast.md).
// A port of the Mac app's CastProtocol.
//
// One TCP connection per phone. Every message is a one-byte type, a four-byte big-endian payload
// length, then the payload. The phone says hello, waits for welcome (or busy), then sends video.

public enum CastMessageType : byte
{
    // Phone to PC.
    Hello = 0x01,
    Video = 0x02,
    Paused = 0x03,
    Resumed = 0x04,
    Heartbeat = 0x05,
    Bye = 0x06,
    /// <summary>Answers a ping with the same payload, for measuring the round trip.</summary>
    Pong = 0x07,
    // PC to phone.
    Welcome = 0x81,
    Busy = 0x82,
    /// <summary>Eight bytes the phone sends straight back in a pong.</summary>
    Ping = 0x84,
}

/// <summary>The phone's introduction.</summary>
public sealed record CastHello
{
    [JsonConstructor]
    public CastHello() { }

    public CastHello(string name, string model, string deviceId, int protocol = 1)
    {
        Protocol = protocol;
        Name = name;
        Model = model;
        DeviceId = deviceId;
    }

    /// <summary>The newest protocol version the phone speaks.</summary>
    [JsonPropertyName("protocol")]
    public int Protocol { get; init; } = 1;
    /// <summary>The phone's name, e.g. "HC50 Front Desk".</summary>
    [JsonPropertyName("name")]
    public string Name { get; init; } = "";
    /// <summary>Maker and model, e.g. "Zebra HC50".</summary>
    [JsonPropertyName("model")]
    public string Model { get; init; } = "";
    /// <summary>A stable ID the app makes for the phone, for the allow-list.</summary>
    [JsonPropertyName("deviceID")]
    public string DeviceId { get; init; } = "";
}

/// <summary>The PC's answer to a hello.</summary>
public sealed record CastWelcome
{
    [JsonConstructor]
    public CastWelcome() { }

    public CastWelcome(string slot, int maxFrameRate, bool? sharpPicture = null, int? protocol = CastProtocol.Version)
    {
        Protocol = protocol;
        Slot = slot;
        MaxFrameRate = maxFrameRate;
        SharpPicture = sharpPicture;
    }

    /// <summary>The newest protocol version this Mirror Wall speaks. Absent from versions before
    /// 0.93, which speak version 1. Each side uses the lower of the two versions.</summary>
    [JsonPropertyName("protocol")]
    public int? Protocol { get; init; }
    /// <summary>The slot's name.</summary>
    [JsonPropertyName("slot")]
    public string Slot { get; init; } = "";
    /// <summary>The most frames a second the phone should send.</summary>
    [JsonPropertyName("maxFrameRate")]
    public int MaxFrameRate { get; init; }
    /// <summary>Sharper Picture is on: send H.265 at up to 2160 pixels tall if the phone can.</summary>
    [JsonPropertyName("sharpPicture")]
    public bool? SharpPicture { get; init; }
}

/// <summary>Why the PC turned a phone away, shown on the phone.</summary>
public sealed record CastBusy
{
    [JsonConstructor]
    public CastBusy() { }

    public CastBusy(string reason) => Reason = reason;

    [JsonPropertyName("reason")]
    public string Reason { get; init; } = "";
}

/// <summary>One Mirror Wall Cast message.</summary>
public abstract record CastMessage
{
    public sealed record Hello(CastHello Info) : CastMessage;

    /// <summary>One encoded picture (an H.264 or H.265 access unit, Annex B), captured at
    /// <paramref name="CaptureMicros"/> on the phone's steady clock.</summary>
    public sealed record Video(long CaptureMicros, byte[] AccessUnit) : CastMessage
    {
        public bool Equals(Video? other) =>
            other != null && CaptureMicros == other.CaptureMicros && AccessUnit.AsSpan().SequenceEqual(other.AccessUnit);

        public override int GetHashCode() => HashCode.Combine(CaptureMicros, AccessUnit.Length);
    }

    /// <summary>The phone's screen turned off.</summary>
    public sealed record Paused : CastMessage;
    public sealed record Resumed : CastMessage;
    public sealed record Heartbeat : CastMessage;
    public sealed record Bye : CastMessage;
    public sealed record Pong(ulong Value) : CastMessage;
    public sealed record Welcome(CastWelcome Info) : CastMessage;
    public sealed record Busy(CastBusy Info) : CastMessage;
    public sealed record Ping(ulong Value) : CastMessage;

    /// <summary>The message as sent over the connection.</summary>
    public byte[] Encoded()
    {
        CastMessageType type;
        byte[] payload = Array.Empty<byte>();
        switch (this)
        {
            case Hello hello:
                type = CastMessageType.Hello;
                payload = JsonSerializer.SerializeToUtf8Bytes(hello.Info, CastProtocol.JsonOptions);
                break;
            case Video video:
                type = CastMessageType.Video;
                payload = new byte[8 + video.AccessUnit.Length];
                BinaryPrimitives.WriteInt64BigEndian(payload, video.CaptureMicros);
                video.AccessUnit.CopyTo(payload, 8);
                break;
            case Paused: type = CastMessageType.Paused; break;
            case Resumed: type = CastMessageType.Resumed; break;
            case Heartbeat: type = CastMessageType.Heartbeat; break;
            case Bye: type = CastMessageType.Bye; break;
            case Pong pong:
                type = CastMessageType.Pong;
                payload = new byte[8];
                BinaryPrimitives.WriteUInt64BigEndian(payload, pong.Value);
                break;
            case Ping ping:
                type = CastMessageType.Ping;
                payload = new byte[8];
                BinaryPrimitives.WriteUInt64BigEndian(payload, ping.Value);
                break;
            case Welcome welcome:
                type = CastMessageType.Welcome;
                payload = JsonSerializer.SerializeToUtf8Bytes(welcome.Info, CastProtocol.JsonOptions);
                break;
            case Busy busy:
                type = CastMessageType.Busy;
                payload = JsonSerializer.SerializeToUtf8Bytes(busy.Info, CastProtocol.JsonOptions);
                break;
            default:
                throw new InvalidOperationException($"unknown message {GetType().Name}");
        }
        var message = new byte[5 + payload.Length];
        message[0] = (byte)type;
        BinaryPrimitives.WriteUInt32BigEndian(message.AsSpan(1), (uint)payload.Length);
        payload.CopyTo(message, 5);
        return message;
    }
}

/// <summary>A Mirror Wall Cast stream that can't be followed any more: a message too big to be
/// real (the stream is out of step), or one whose payload doesn't make sense.</summary>
public sealed class CastStreamException : Exception
{
    public CastStreamException(string message, Exception? inner = null) : base(message, inner) { }
}

/// <summary>
/// Splits a Mirror Wall Cast byte stream into messages, however the bytes arrive.
///
/// Not thread-safe: feed it from one thread.
/// </summary>
public sealed class CastReader
{
    /// <summary>No picture comes anywhere near this; anything bigger means the stream is out of step.</summary>
    public const int MaxPayload = 16 << 20;
    private byte[] buffer = new byte[64 * 1024];
    private int start;
    private int end;

    /// <summary>Adds bytes and returns the messages they complete. Unknown message types are
    /// skipped, so a newer phone app can add messages.</summary>
    /// <exception cref="CastStreamException">The stream can't be followed any more.</exception>
    public List<CastMessage> Push(ReadOnlySpan<byte> bytes)
    {
        Append(bytes);
        var messages = new List<CastMessage>();
        while (end - start >= 5)
        {
            byte type = buffer[start];
            uint length = BinaryPrimitives.ReadUInt32BigEndian(buffer.AsSpan(start + 1, 4));
            if (length > MaxPayload) throw new CastStreamException($"a message of {length} bytes");
            if (end - start < 5 + (int)length) break;
            var payload = buffer.AsSpan(start + 5, (int)length);
            start += 5 + (int)length;
            if (Decode(type, payload) is { } message) messages.Add(message);
        }
        if (start == end) start = end = 0;
        return messages;
    }

    /// <summary>Keeps the unread bytes and the new ones together, making room as needed.</summary>
    private void Append(ReadOnlySpan<byte> bytes)
    {
        if (end + bytes.Length > buffer.Length)
        {
            int unread = end - start;
            if (unread + bytes.Length > buffer.Length)
            {
                var bigger = new byte[Math.Max(buffer.Length * 2, unread + bytes.Length)];
                buffer.AsSpan(start, unread).CopyTo(bigger);
                buffer = bigger;
            }
            else
            {
                buffer.AsSpan(start, unread).CopyTo(buffer);
            }
            start = 0;
            end = unread;
        }
        bytes.CopyTo(buffer.AsSpan(end));
        end += bytes.Length;
    }

    private static CastMessage? Decode(byte rawType, ReadOnlySpan<byte> payload)
    {
        if (!Enum.IsDefined((CastMessageType)rawType)) return null;
        var type = (CastMessageType)rawType;
        try
        {
            switch (type)
            {
                case CastMessageType.Hello: return new CastMessage.Hello(Json<CastHello>(payload));
                case CastMessageType.Welcome: return new CastMessage.Welcome(Json<CastWelcome>(payload));
                case CastMessageType.Busy: return new CastMessage.Busy(Json<CastBusy>(payload));
                case CastMessageType.Video:
                    if (payload.Length < 8) throw Malformed(rawType);
                    return new CastMessage.Video(BinaryPrimitives.ReadInt64BigEndian(payload), payload[8..].ToArray());
                case CastMessageType.Paused: return new CastMessage.Paused();
                case CastMessageType.Resumed: return new CastMessage.Resumed();
                case CastMessageType.Heartbeat: return new CastMessage.Heartbeat();
                case CastMessageType.Bye: return new CastMessage.Bye();
                case CastMessageType.Pong:
                case CastMessageType.Ping:
                    if (payload.Length != 8) throw Malformed(rawType);
                    ulong value = BinaryPrimitives.ReadUInt64BigEndian(payload);
                    return type == CastMessageType.Pong ? new CastMessage.Pong(value) : new CastMessage.Ping(value);
                default:
                    return null;
            }
        }
        catch (Exception error) when (error is JsonException or ArgumentException or NotSupportedException or InvalidOperationException)
        {
            throw Malformed(rawType, error);
        }
    }

    private static T Json<T>(ReadOnlySpan<byte> payload) where T : class =>
        JsonSerializer.Deserialize<T>(payload, CastProtocol.JsonOptions) ?? throw new JsonException("null");

    private static CastStreamException Malformed(byte type, Exception? inner = null) =>
        new($"a malformed message of type 0x{type:X2}", inner);
}

public static class CastProtocol
{
    /// <summary>The newest Mirror Wall Cast version this app speaks. See "Compatibility" in
    /// docs/mirror-wall-cast.md before changing anything a phone or an older Mirror Wall relies on.</summary>
    public const int Version = 1;

    /// <summary>Fields with no value are left out, as the Mac app's JSON encoder does, and text
    /// isn't escaped beyond what JSON needs (slot names have "·" in them).</summary>
    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>The NAL units in an Annex B byte stream (each after a 00 00 01 or 00 00 00 01 start
    /// code), without their start codes.</summary>
    public static List<byte[]> AnnexBNalUnits(ReadOnlySpan<byte> bytes)
    {
        var units = new List<byte[]>();
        int? unitStart = null;
        int index = 0;
        while (index + 2 < bytes.Length)
        {
            if (bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1)
            {
                if (unitStart is int begin)
                {
                    int finish = index;
                    // A four-byte start code's leading zero belongs to it, not to the unit before.
                    if (finish > begin && bytes[finish - 1] == 0) finish--;
                    if (finish > begin) units.Add(bytes[begin..finish].ToArray());
                }
                index += 3;
                unitStart = index;
            }
            else
            {
                index++;
            }
        }
        if (unitStart is int last && last < bytes.Length) units.Add(bytes[last..].ToArray());
        return units;
    }

    /// <summary>
    /// The codec of a frame that starts with a parameter set (every keyframe from the phone does):
    /// an H.264 SPS, or an H.265 VPS or SPS. Null for other frames.
    ///
    /// An H.265 header is matched on both its bytes (layer 0, temporal ID 1), because its first
    /// byte alone can be an ordinary H.264 picture's: 0x41 is both an H.265 VPS and an H.264 P slice.
    /// </summary>
    public static VideoCodec? Codec(IReadOnlyList<byte[]> nalUnits)
    {
        if (nalUnits.Count == 0 || nalUnits[0] is not { Length: >= 2 } first) return null;
        if ((first[0] & 0x80) == 0 && (first[0] & 0x1F) == H264NalType.Sps && (first[0] & 0x60) != 0) return VideoCodec.H264;
        if ((first[0] == HevcNalType.Vps << 1 || first[0] == HevcNalType.Sps << 1) && first[1] == 0x01) return VideoCodec.Hevc;
        return null;
    }

    /// <summary>Converts the phone's capture time to the 90 kHz clock the renderer and recorder use for RTP.</summary>
    public static uint RtpTimestamp(long captureMicros) => unchecked((uint)(captureMicros * 9 / 100));
}
