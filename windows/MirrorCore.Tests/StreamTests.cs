using MirrorWall.Core;

namespace MirrorWall.Core.Tests;

public class RtpPacketTests
{
    [Fact]
    public void ParsesHeaderAndPayload()
    {
        var packet = new RtpPacket(96, true, 0xBEEF, 0x0102_0304, 0xCAFE_F00D, new byte[] { 0x65, 1, 2 });
        var parsed = RtpPacket.Parse(packet.ToBytes());
        Assert.NotNull(parsed);
        Assert.Equal(packet.Marker, parsed.Marker);
        Assert.Equal(packet.SequenceNumber, parsed.SequenceNumber);
        Assert.Equal(packet.Timestamp, parsed.Timestamp);
        Assert.Equal(packet.Ssrc, parsed.Ssrc);
        Assert.Equal(packet.Payload, parsed.Payload);
    }

    [Fact]
    public void SkipsCsrcsExtensionAndPadding()
    {
        var bytes = new List<byte> { 0x80 | 0x20 | 0x10 | 0x01, 96, 0, 1, 0, 0, 0, 9, 0, 0, 0, 7 };
        bytes.AddRange(new byte[] { 1, 2, 3, 4 });                  // one CSRC
        bytes.AddRange(new byte[] { 0xBE, 0xDE, 0, 1, 9, 9, 9, 9 }); // header extension, one word
        bytes.AddRange(new byte[] { 0x41, 0xAA });                  // payload
        bytes.AddRange(new byte[] { 0, 0, 3 });                     // three bytes of padding
        var parsed = RtpPacket.Parse(bytes.ToArray());
        Assert.NotNull(parsed);
        Assert.Equal(new byte[] { 0x41, 0xAA }, parsed.Payload);
        Assert.Equal(9u, parsed.Timestamp);
    }

    [Fact]
    public void RejectsGarbage()
    {
        Assert.Null(RtpPacket.Parse(new byte[] { 0x80, 96, 0 }));
        Assert.Null(RtpPacket.Parse(new byte[20])); // version 0
    }
}

public class DepacketizerTests
{
    private static RtpPacket Packet(ushort sequence, uint timestamp, bool marker, params byte[] payload) =>
        new(marker, sequence, timestamp, payload);

    private static VideoFrame Frame(uint timestamp, params byte[][] nals) => new(nals, timestamp);

    [Fact]
    public void SingleNalUnits()
    {
        var d = new Depacketizer();
        Assert.Empty(d.Push(Packet(1, 100, false, 0x67, 1)));
        Assert.Empty(d.Push(Packet(2, 100, false, 0x68, 2)));
        var frames = d.Push(Packet(3, 100, true, 0x65, 3));
        Assert.Equal(new[] { Frame(100, new byte[] { 0x67, 1 }, new byte[] { 0x68, 2 }, new byte[] { 0x65, 3 }) }, frames);
        Assert.True(frames[0].IsKeyframe);
    }

    [Fact]
    public void StapA()
    {
        var d = new Depacketizer();
        var frames = d.Push(Packet(1, 5, true, 0x78, 0, 2, 0x67, 1, 0, 3, 0x68, 2, 3));
        Assert.Equal(new[] { Frame(5, new byte[] { 0x67, 1 }, new byte[] { 0x68, 2, 3 }) }, frames);
    }

    [Fact]
    public void FuAReassembly()
    {
        var d = new Depacketizer();
        // NAL header 0x65 (nri 3, type 5) split into three fragments.
        Assert.Empty(d.Push(Packet(1, 7, false, 0x7C, 0x85, 1, 2)));
        Assert.Empty(d.Push(Packet(2, 7, false, 0x7C, 0x05, 3)));
        var frames = d.Push(Packet(3, 7, true, 0x7C, 0x45, 4, 5));
        Assert.Equal(new[] { Frame(7, new byte[] { 0x65, 1, 2, 3, 4, 5 }) }, frames);
    }

    [Fact]
    public void FragmentWithGapIsDropped()
    {
        var d = new Depacketizer();
        d.Push(Packet(1, 7, false, 0x7C, 0x85, 1));
        // Sequence 2 lost.
        Assert.Empty(d.Push(Packet(3, 7, true, 0x7C, 0x45, 4)));
        Assert.Equal(1, d.SequenceGaps);
        Assert.Equal(1, d.LostPackets);
    }

    [Fact]
    public void LatePacketIsNotCountedAsLost()
    {
        var d = new Depacketizer();
        d.Push(Packet(10, 1, true, 0x41));
        d.Push(Packet(9, 1, true, 0x41));
        Assert.Equal(0, d.LostPackets);
    }

    [Fact]
    public void NewTimestampClosesFrameWhoseMarkerWasLost()
    {
        var d = new Depacketizer();
        d.Push(Packet(1, 10, false, 0x41, 1));
        Assert.Equal(new[] { Frame(10, new byte[] { 0x41, 1 }) }, d.Push(Packet(2, 20, false, 0x41, 2)));
        Assert.Equal(new[] { Frame(20, new byte[] { 0x41, 2 }, new byte[] { 0x41, 3 }) }, d.Push(Packet(3, 20, true, 0x41, 3)));
    }

    [Fact]
    public void SequenceWrapIsNotAGap()
    {
        var d = new Depacketizer();
        d.Push(Packet(0xFFFF, 1, true, 0x41));
        d.Push(Packet(0, 2, true, 0x41));
        Assert.Equal(0, d.SequenceGaps);
        Assert.Equal(0, d.LostPackets);
    }

    [Fact]
    public void AnnexB()
    {
        var frame = Frame(1, new byte[] { 0x65, 1 }, new byte[] { 0x06 });
        Assert.Equal(new byte[] { 0, 0, 0, 1, 0x65, 1, 0, 0, 0, 1, 0x06 }, frame.ToAnnexB());
        Assert.Equal(new byte[] { 0, 0, 0, 1, 0x06 }, frame.ToAnnexB(nal => nal[0] == 0x06));
    }
}

public class HevcDepacketizerTests
{
    private static RtpPacket Packet(ushort sequence, uint timestamp, bool marker, params byte[] payload) =>
        new(marker, sequence, timestamp, payload);

    private static readonly byte[] Vps = { 0x40, 0x01, 0xAA };
    private static readonly byte[] Sps = { 0x42, 0x01, 0xBB };
    private static readonly byte[] Pps = { 0x44, 0x01, 0xCC };

    /// <summary>Parameter sets as single packets, then an IDR picture in three fragments.</summary>
    [Fact]
    public void ReassemblesParameterSetsAndFragments()
    {
        var d = new Depacketizer();
        Assert.Empty(d.Push(Packet(1, 9, false, Vps)));
        Assert.Equal(VideoCodec.Hevc, d.Codec);
        d.Push(Packet(2, 9, false, Sps));
        d.Push(Packet(3, 9, false, Pps));
        // FU header: start bit, type 19 (IDR_W_RADL).
        d.Push(Packet(4, 9, false, 0x62, 0x01, 0x80 | 19, 1, 2));
        d.Push(Packet(5, 9, false, 0x62, 0x01, 19, 3));
        var frames = d.Push(Packet(6, 9, true, 0x62, 0x01, 0x40 | 19, 4));
        Assert.Equal(new[] { new VideoFrame(new[] { Vps, Sps, Pps, new byte[] { 0x26, 0x01, 1, 2, 3, 4 } }, 9, VideoCodec.Hevc) }, frames);
        Assert.True(frames[0].IsKeyframe);
    }

    [Fact]
    public void AggregationPacket()
    {
        var d = new Depacketizer();
        var ap = new List<byte> { 0x60, 0x01 };
        foreach (var nal in new[] { Vps, Sps, Pps })
        {
            ap.AddRange(new byte[] { 0, (byte)nal.Length });
            ap.AddRange(nal);
        }
        var frames = d.Push(Packet(1, 3, true, ap.ToArray()));
        Assert.Equal(new[] { new VideoFrame(new[] { Vps, Sps, Pps }, 3, VideoCodec.Hevc) }, frames);
    }

    [Fact]
    public void TrailingPictureIsNotAKeyframe()
    {
        var d = new Depacketizer();
        d.Push(Packet(1, 1, true, Vps));
        var frames = d.Push(Packet(2, 2, true, 0x02, 0x01, 7)); // TRAIL_R
        Assert.Single(frames);
        Assert.False(frames[0].IsKeyframe);
    }

    /// <summary>A slot whose receiver is restarted can get the other codec next; a parameter set switches.</summary>
    [Fact]
    public void SwitchesCodecOnParameterSets()
    {
        var d = new Depacketizer();
        d.Push(Packet(1, 1, true, Vps));
        Assert.Equal(VideoCodec.Hevc, d.Codec);
        d.Push(Packet(2, 2, true, 0x67, 0x64, 0, 0x2A));
        Assert.Equal(VideoCodec.H264, d.Codec);
        Assert.Equal(VideoCodec.H264, Depacketizer.CodecOfParameterSets(new byte[] { 0x78, 0, 2, 0x67, 1, 0, 2, 0x68, 2 }));
        // H.264 slices and fragments, and H.265 slices, show nothing.
        foreach (var payload in new[]
        {
            new byte[] { 0x41, 1 }, new byte[] { 0x65, 1 }, new byte[] { 0x7C, 0x85, 1 },
            new byte[] { 0x02, 0x01, 1 }, new byte[] { 0x26, 0x01, 1 }, new byte[] { 0x62, 0x01, 0x93 },
        })
        {
            Assert.Null(Depacketizer.CodecOfParameterSets(payload));
        }
        d.Reset();
        Assert.Equal(VideoCodec.H264, d.Codec);
    }

    [Fact]
    public void ReadsProfileAndLevelThroughEmulationPrevention()
    {
        // NAL header, IDs, Main profile, compatibility flags, constraint flags with an emulation
        // prevention byte, level 5.1 (153).
        byte[] sps = { 0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 153, 0xA0 };
        Assert.Equal("H.265 Main 5.1", CodecDescriptions.Hevc(sps));
        Assert.Equal("H.265", CodecDescriptions.Hevc(new byte[] { 0x42, 0x01 }));
    }
}

public class StreamMeterTests
{
    [Fact]
    public void SumsUpEachSecond()
    {
        var meter = new StreamMeter();
        meter.Packet(1000, 0, 0);
        meter.Frame(0, true, 0.002);
        Assert.Null(meter.SnapshotIfDue(0.5));
        meter.Packet(1000, 2, 0.5);
        meter.Frame(0.5, false, 0.004);
        meter.Frame(0.6, false, null);
        var snapshot = meter.SnapshotIfDue(1);
        Assert.NotNull(snapshot);
        Assert.Equal(2, snapshot.FramesPerSecond);
        Assert.Equal(16000, snapshot.BitsPerSecond);
        Assert.Equal(0.003, snapshot.DecodeTime!.Value, 9);
        Assert.Equal(2, snapshot.PacketsLost);
        Assert.Equal(1, snapshot.TotalFramesSkipped);
        Assert.Equal(1, snapshot.TotalKeyframes);

        // The next second starts empty, but totals carry on.
        meter.Packet(10, 1, 1.2);
        var next = meter.SnapshotIfDue(2);
        Assert.NotNull(next);
        Assert.Equal(0, next.FramesPerSecond);
        Assert.Equal(1, next.PacketsLost);
        Assert.Equal(3, next.TotalPacketsLost);
    }

    [Fact]
    public void JitterIgnoresPauses()
    {
        var meter = new StreamMeter();
        foreach (double time in new[] { 0.0, 0.1, 0.2, 2.0, 2.1 }) meter.Frame(time, false, 0.001);
        Assert.Equal(0, meter.SnapshotIfDue(2.2)!.FrameJitter, 9);
    }

    [Fact]
    public void KeyframeInterval()
    {
        var meter = new StreamMeter();
        meter.Frame(0, true, 0.001);
        meter.Frame(0.4, false, 0.001);
        meter.Frame(0.9, true, 0.001);
        var snapshot = meter.SnapshotIfDue(1)!;
        Assert.Equal(0.9, snapshot.KeyframeInterval!.Value, 9);
        Assert.Equal(2, snapshot.TotalKeyframes);
    }

    [Fact]
    public void CodecDescription()
    {
        Assert.Equal("H.264 High 4.2", CodecDescriptions.H264(new byte[] { 0x67, 100, 0, 42 }));
        Assert.Equal("H.264 Main 3.1", CodecDescriptions.H264(new byte[] { 0x67, 77, 0, 31 }));
        Assert.Equal("H.264", CodecDescriptions.H264(new byte[] { 0x67 }));
    }
}

public class RecordingClockTests
{
    [Fact]
    public void TimesFramesFromStampsNotBurstyArrival()
    {
        var clock = new RecordingClock();
        const uint start = 1000;
        Assert.Equal(0, clock.Time(start, 10.000));
        // Three frames 1/60 s apart that arrived together.
        Assert.Equal(1.0 / 60, clock.Time(start + 1500, 10.050), 9);
        Assert.Equal(2.0 / 60, clock.Time(start + 3000, 10.051), 9);
        Assert.Equal(3.0 / 60, clock.Time(start + 4500, 10.052), 9);
    }

    [Fact]
    public void HandlesWrapAround()
    {
        var clock = new RecordingClock();
        clock.Time(uint.MaxValue - 499, 0);
        Assert.Equal(1500 / RecordingClock.RtpRate, clock.Time(1000, 0.0167), 9);
    }

    [Fact]
    public void FallsBackToArrivalOnBadStamps()
    {
        var clock = new RecordingClock();
        clock.Time(90_000, 5);
        // Backwards stamp: use the time between arrivals.
        Assert.Equal(0.5, clock.Time(0, 5.5), 9);
        // Repeated stamp: still moves forward.
        Assert.True(clock.Time(0, 5.5) > 0.5);
    }

    [Fact]
    public void UnknownStampUsesArrival()
    {
        var clock = new RecordingClock();
        Assert.Equal(0, clock.Time(null, 3));
        Assert.Equal(0.2, clock.Time(45_000, 3.2), 9);
        Assert.Equal(0.2 + 1.0 / 60, clock.Time(46_500, 3.3), 9);
    }

    [Fact]
    public void StaysNearArrivalTime()
    {
        var clock = new RecordingClock();
        clock.Time(0, 0);
        // Stamps claim 1.9 s each while only 0.1 s passes: pulled back to the wall clock.
        clock.Time(171_000, 0.1);
        Assert.Equal(0.2, clock.Time(342_000, 0.2), 9);
        Assert.Equal(1.2, clock.TimeAtArrival(1.2), 9);
    }
}

public class PlayoutClockTests
{
    /// <summary>Frames captured 1/30 s apart that arrived in bursts come out evenly spaced.</summary>
    [Fact]
    public void SpacesBurstyFramesEvenly()
    {
        var clock = new PlayoutClock(0.1);
        const uint step = 3000; // 1/30 s
        double first = clock.Due(0, 10.000);
        Assert.Equal(10.1, first, 9);
        // The next three arrive in a burst, the first of them late.
        double second = clock.Due(step, 10.105);
        double third = clock.Due(2 * step, 10.106);
        double fourth = clock.Due(3 * step, 10.107);
        Assert.Equal(1.0 / 30, second - first, 9);
        Assert.Equal(1.0 / 30, third - second, 9);
        Assert.Equal(1.0 / 30, fourth - third, 9);
    }

    [Fact]
    public void FasterTripLowersTheDelay()
    {
        var clock = new PlayoutClock(0.1);
        clock.Due(0, 10.05);
        // Captured 0.1 s later, this frame made the trip 40 ms quicker: it waits only the delay.
        Assert.Equal(10.21, clock.Due(9000, 10.11), 9);
    }

    [Fact]
    public void LateFrameShowsAtOnceAndNeverBeforeThePreviousOne()
    {
        var clock = new PlayoutClock(0.1);
        clock.Due(0, 0);
        // Arrives 300 ms after its capture time: beyond the delay, so shown on arrival.
        Assert.Equal(0.3333, clock.Due(3000, 0.3333), 9);
        // Its successor came quickly, but can't go before it.
        Assert.Equal(0.3334, clock.Due(6000, 0.3334), 9);
    }

    [Fact]
    public void StartsOverAfterAJump()
    {
        var clock = new PlayoutClock(0.1);
        clock.Due(0, 0);
        // The screen was off for a minute: the stamp jumps 60 s.
        Assert.Equal(60.1, clock.Due(5_400_000, 60), 9);
        // Backwards (a new stream): starts over too.
        Assert.Equal(61.1, clock.Due(100, 61), 9);
    }

    /// <summary>A network that gets slower stops making every frame late once the window turns over.</summary>
    [Fact]
    public void AdaptsWhenTheNetworkSlows()
    {
        var clock = new PlayoutClock(0.1);
        double arrival = 0;
        uint rtp = 0;
        clock.Due(rtp, arrival);
        // From now on every frame takes 200 ms longer.
        double lastWait = 0;
        for (int i = 0; i < 30 * 11; i++)
        {
            rtp = unchecked(rtp + 3000);
            arrival += 1.0 / 30;
            lastWait = clock.Due(rtp, arrival + 0.2) - (arrival + 0.2);
        }
        Assert.Equal(0.1, lastWait, 6);
    }
}
