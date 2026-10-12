namespace MirrorWall.Core;

/// <summary>
/// Decides when to show each frame for Smoother Motion: at the pace the phone captured them
/// (their RTP timestamps), a short delay after they arrive, instead of in Wi-Fi's bursts.
///
/// Each frame is due at its capture time plus the quickest trip any recent frame made, plus
/// <see cref="Delay"/>. A frame that arrives later than that is shown at once. The quickest trip is
/// re-measured every <see cref="Window"/> seconds, so a network that gets slower (or the two clocks
/// drifting apart) doesn't leave every frame late. A timestamp that jumps backwards or more than
/// <see cref="MaxStep"/> ahead, such as after the screen was off, starts over.
/// </summary>
public sealed class PlayoutClock
{
    /// <summary>H.264 over RTP counts at 90 kHz.</summary>
    internal const double RtpRate = 90_000.0;
    internal const double MaxStep = 2.0;
    public const double DefaultDelay = 0.1;
    internal const double Window = 5.0;

    /// <summary>How long frames wait beyond the quickest trip, to absorb the network's jitter.</summary>
    public double Delay { get; }

    private uint? lastRtp;
    private double lastArrival;
    /// <summary>The current frame's capture time, in seconds on the clock's own timeline.</summary>
    private double media;
    /// <summary>The quickest trip (arrival minus capture time) in use, and the quickest in this window.</summary>
    private double? bestTrip;
    private double? windowBest;
    private double windowStart;
    private double lastDue = double.NegativeInfinity;

    public PlayoutClock(double delay = DefaultDelay)
    {
        Delay = delay;
    }

    /// <summary>When to show a frame stamped <paramref name="rtp"/> that arrived at
    /// <paramref name="arrival"/> (seconds on any steady clock), on the same clock. Never earlier
    /// than <paramref name="arrival"/> or than the frame before it.</summary>
    public double Due(uint rtp, double arrival)
    {
        if (lastRtp is uint previous)
        {
            double step = unchecked((int)(rtp - previous)) / RtpRate;
            if (step < 0 || step > MaxStep)
            {
                media += Math.Max(arrival - lastArrival, 0);
                bestTrip = null;
                windowBest = null;
            }
            else
            {
                media += step;
            }
        }
        lastRtp = rtp;
        lastArrival = arrival;

        double trip = arrival - media;
        if (bestTrip == null || trip < bestTrip) bestTrip = trip;
        if (windowBest == null || trip < windowBest) windowBest = trip;
        if (arrival - windowStart >= Window)
        {
            bestTrip = windowBest;
            windowBest = trip;
            windowStart = arrival;
        }

        double due = Math.Max(Math.Max(media + bestTrip!.Value + Delay, arrival), lastDue);
        lastDue = due;
        return due;
    }

    /// <summary>Forgets the stream, e.g. when a new phone connects.</summary>
    public void Reset()
    {
        lastRtp = null;
        lastArrival = 0;
        media = 0;
        bestTrip = null;
        windowBest = null;
        windowStart = 0;
        lastDue = double.NegativeInfinity;
    }
}
