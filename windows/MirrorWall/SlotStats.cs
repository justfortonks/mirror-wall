using MirrorWall.Core;

namespace MirrorWall;

/// <summary>What the Stats for Nerds overlay shows for one slot. Changes on the UI thread only.</summary>
internal sealed class SlotStats : Observable
{
    private StreamSnapshot? stream;
    /// <summary>The last second of video, measured as it arrives.</summary>
    public StreamSnapshot? Stream { get => stream; set => Set(ref stream, value); }

    private string? codec;
    public string? Codec { get => codec; set => Set(ref codec, value); }

    private double? roundTrip;
    /// <summary>Network round trip to the phone, in seconds.</summary>
    public double? RoundTrip { get => roundTrip; set => Set(ref roundTrip, value); }

    private double? lag;
    /// <summary>How far the latest frame's arrival is behind its timestamp, compared with the
    /// smallest such gap this connection, in seconds. The phone's timestamps run ahead of the
    /// computer's clock by a fixed amount that differs per phone, so only this change is
    /// meaningful: it rises when the stream falls behind.</summary>
    public double? Lag { get => lag; private set => Set(ref lag, value); }
    private double? bestLatency;

    /// <summary>A latency report from uxplay: the frame's arrival time minus its timestamp.</summary>
    public void RecordLatency(double seconds)
    {
        double best = Math.Min(bestLatency ?? seconds, seconds);
        bestLatency = best;
        Lag = seconds - best;
    }

    private string? phoneModel;
    /// <summary>The phone's model, e.g. "iPhone 15 Pro Max".</summary>
    public string? PhoneModel { get => phoneModel; set => Set(ref phoneModel, value); }

    private int connections;
    /// <summary>Phones that have connected since the app started.</summary>
    public int Connections { get => connections; set => Set(ref connections, value); }

    public DateTime? LastHeartbeatAt { get; private set; }
    /// <summary>Seconds between the phone's last two check-ins.</summary>
    public double? HeartbeatInterval { get; private set; }

    public void Heartbeat()
    {
        var now = DateTime.Now;
        if (LastHeartbeatAt is DateTime last) HeartbeatInterval = (now - last).TotalSeconds;
        LastHeartbeatAt = now;
    }

    /// <summary>Forgets the current stream's numbers when its receiver stops.</summary>
    public void ClearStream()
    {
        Stream = null;
        Codec = null;
        RoundTrip = null;
        Lag = null;
        bestLatency = null;
        LastHeartbeatAt = null;
        HeartbeatInterval = null;
    }
}
