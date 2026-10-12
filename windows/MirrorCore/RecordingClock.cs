namespace MirrorWall.Core;

/// <summary>
/// Times a recording's frames from the stream's own RTP timestamps, so playback is as smooth as
/// the phone made it. Arrival times alone come in network bursts (2 ms, 2 ms, then 47 ms) and
/// sometimes tie, which players show as stutter.
///
/// Falls back to arrival time when a timestamp jumps backwards or too far, and pulls back to it
/// if the two drift more than a second apart, so a bad stamp can't throw the timeline off.
/// </summary>
public sealed class RecordingClock
{
    /// <summary>H.264 over RTP counts at 90 kHz.</summary>
    public const double RtpRate = 90_000.0;
    internal const double MaxStep = 2.0;
    internal const double MaxDrift = 1.0;
    internal const double MinStep = 0.001;

    private double? start;
    private (uint? Rtp, double Arrival, double Time)? last;

    /// <summary>Seconds into the recording for a frame stamped <paramref name="rtp"/> that arrived
    /// at <paramref name="arrival"/> (seconds on any steady clock). Always later than the previous
    /// frame's. A null stamp (a picture whose stamp isn't known, such as the one on screen when
    /// recording starts) is timed by arrival, and so is the frame after it.</summary>
    public double Time(uint? rtp, double arrival)
    {
        if (last is not { } previous || start is not double begin)
        {
            start = arrival;
            last = (rtp, arrival, 0);
            return 0;
        }
        double stamped = rtp is uint now && previous.Rtp is uint before ? unchecked(now - before) / RtpRate : -1;
        double time = previous.Time + (stamped > 0 && stamped <= MaxStep ? stamped : arrival - previous.Arrival);
        double wall = arrival - begin;
        if (Math.Abs(time - wall) > MaxDrift) time = wall;
        time = Math.Max(time, previous.Time + MinStep);
        last = (rtp, arrival, time);
        return time;
    }

    /// <summary>Seconds into the recording at <paramref name="arrival"/>, for ending it: the last
    /// frame stays on screen until then.</summary>
    public double TimeAtArrival(double arrival) =>
        last is { } previous ? previous.Time + Math.Max(arrival - previous.Arrival, MinStep) : 0;

    /// <summary>Seconds from the first frame to the last.</summary>
    public double Duration => last?.Time ?? 0;
}
