using System.Buffers.Binary;
using System.Text;
using MirrorWall.Core;

namespace MirrorWall.Core.Tests;

/// <summary>The Mac app's CastProtocolTests, for the Windows side of Mirror Wall Cast.</summary>
public class CastProtocolTests
{
    [Fact]
    public void RoundTripsEveryMessageOneByteAtATime()
    {
        var messages = new List<CastMessage>
        {
            new CastMessage.Hello(new CastHello("Front Desk", "Zebra HC50", "abc123")),
            new CastMessage.Welcome(new CastWelcome("Mirror Wall 1 · PC", 30)),
            new CastMessage.Video(1_234_567_890_123, new byte[] { 0, 0, 0, 1, 0x65, 9 }),
            new CastMessage.Paused(), new CastMessage.Resumed(), new CastMessage.Heartbeat(),
            new CastMessage.Busy(new CastBusy("In use")),
            new CastMessage.Welcome(new CastWelcome("Mirror Wall 2", 60, sharpPicture: true)),
            new CastMessage.Ping(0x0102_0304_0506_0708), new CastMessage.Pong(42),
            new CastMessage.Bye(),
        };
        var reader = new CastReader();
        var decoded = new List<CastMessage>();
        foreach (byte b in messages.SelectMany(message => message.Encoded()))
        {
            decoded.AddRange(reader.Push(new[] { b }));
        }
        Assert.Equal(messages, decoded);
    }

    [Fact]
    public void ReadsMessagesArrivingTogetherAndPictures()
    {
        var picture = new byte[200_000];
        new Random(7).NextBytes(picture);
        var messages = new List<CastMessage> { new CastMessage.Heartbeat(), new CastMessage.Video(5, picture), new CastMessage.Bye() };
        var reader = new CastReader();
        Assert.Equal(messages, reader.Push(messages.SelectMany(message => message.Encoded()).ToArray()));
    }

    [Fact]
    public void SkipsUnknownMessagesAndRejectsHugeOnes()
    {
        var reader = new CastReader();
        var bytes = new byte[] { 0x40, 0, 0, 0, 2, 7, 7 }.Concat(new CastMessage.Heartbeat().Encoded()).ToArray();
        Assert.Equal(new CastMessage[] { new CastMessage.Heartbeat() }, reader.Push(bytes));
        Assert.Throws<CastStreamException>(() => new CastReader().Push(new byte[] { 0x02, 0x7F, 0, 0, 0 }));
    }

    /// <summary>
    /// Phones and Mirror Walls of any version have to understand each other (see "Compatibility"
    /// in docs/mirror-wall-cast.md). These are messages exactly as 0.90 and 0.91 sent them, plus a
    /// newer phone's hello with a field and a version this Mirror Wall doesn't know.
    /// </summary>
    [Fact]
    public void UnderstandsOlderAndNewerPeers()
    {
        static byte[] PayloadMessage(CastMessageType type, string json)
        {
            byte[] payload = Encoding.UTF8.GetBytes(json);
            var message = new byte[5 + payload.Length];
            message[0] = (byte)type;
            BinaryPrimitives.WriteUInt32BigEndian(message.AsSpan(1), (uint)payload.Length);
            payload.CopyTo(message, 5);
            return message;
        }
        var reader = new CastReader();
        Assert.Equal(
            new CastMessage[] { new CastMessage.Hello(new CastHello("HC50", "Zebra Technologies HC50", "android-1", protocol: 1)) },
            reader.Push(PayloadMessage(CastMessageType.Hello, """{"protocol":1,"name":"HC50","model":"Zebra Technologies HC50","deviceID":"android-1"}""")));
        Assert.Equal(
            new CastMessage[] { new CastMessage.Hello(new CastHello("HC50", "Zebra", "android-2", protocol: 9)) },
            reader.Push(PayloadMessage(CastMessageType.Hello, """{"protocol":9,"name":"HC50","model":"Zebra","deviceID":"android-2","battery":80}""")));
        Assert.Equal(
            new CastMessage[] { new CastMessage.Welcome(new CastWelcome("Mirror Wall 1", 30, sharpPicture: false, protocol: null)) },
            reader.Push(PayloadMessage(CastMessageType.Welcome, """{"slot":"Mirror Wall 1","maxFrameRate":30,"sharpPicture":false}""")));
        string welcome = Encoding.UTF8.GetString(new CastMessage.Welcome(new CastWelcome("S", 30)).Encoded().AsSpan(5));
        Assert.Contains($"\"protocol\":{CastProtocol.Version}", welcome);
    }

    [Fact]
    public void WritesWelcomeAndBusyAsCompactJson()
    {
        string welcome = Encoding.UTF8.GetString(new CastMessage.Welcome(new CastWelcome("Mirror Wall 1 · PC", 60, sharpPicture: true)).Encoded().AsSpan(5));
        Assert.Equal("""{"protocol":1,"slot":"Mirror Wall 1 · PC","maxFrameRate":60,"sharpPicture":true}""", welcome);
        string busy = Encoding.UTF8.GetString(new CastMessage.Busy(new CastBusy("In use")).Encoded().AsSpan(5));
        Assert.Equal("""{"reason":"In use"}""", busy);
    }

    [Fact]
    public void SplitsAnnexB()
    {
        var stream = new byte[] { 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5 };
        Assert.Equal(new[] { new byte[] { 0x67, 1, 2 }, new byte[] { 0x68, 3 }, new byte[] { 0x65, 4, 5 } }, CastProtocol.AnnexBNalUnits(stream));
        Assert.Empty(CastProtocol.AnnexBNalUnits(new byte[] { 0x65, 1 }));
    }

    [Fact]
    public void TellsTheCodecFromAKeyframesParameterSets()
    {
        Assert.Equal(VideoCodec.H264, CastProtocol.Codec(new[] { new byte[] { 0x67, 0x64, 0x00, 0x2A }, new byte[] { 0x68, 1 }, new byte[] { 0x65, 2 } }));
        Assert.Equal(VideoCodec.Hevc, CastProtocol.Codec(new[] { new byte[] { 0x40, 0x01, 0x0C }, new byte[] { 0x42, 0x01 }, new byte[] { 0x44, 0x01 }, new byte[] { 0x26, 0x01 } }));
        Assert.Null(CastProtocol.Codec(new[] { new byte[] { 0x41, 0x9A } })); // an H.264 P slice, whose first byte looks like a VPS
        Assert.Null(CastProtocol.Codec(new[] { new byte[] { 0x41, 0x01, 0x9A } }));
        Assert.Null(CastProtocol.Codec(new[] { new byte[] { 0x02, 0x01 } }));
    }

    [Fact]
    public void CaptureTimeBecomesNinetyKilohertz()
    {
        Assert.Equal(90_000u, CastProtocol.RtpTimestamp(1_000_000));
        Assert.Equal(2_999u, unchecked(CastProtocol.RtpTimestamp(1_000_000 + 33_333) - CastProtocol.RtpTimestamp(1_000_000)));
    }

    [Fact]
    public void CastPortsSitBesideEachSlotsAirPlayPorts()
    {
        Assert.Equal(7350, new SlotConfig(1, "a").CastPort);
        Assert.Equal(8050, new SlotConfig(8, "a").CastPort);
    }
}
