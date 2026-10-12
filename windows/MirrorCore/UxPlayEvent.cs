using System.Globalization;

namespace MirrorWall.Core;

/// <summary>Connection events recognised in uxplay's output (it must run with <c>-d 1</c> for
/// <see cref="OpenConnections"/>).</summary>
public abstract record UxPlayEvent
{
    /// <summary>An iPhone asked to connect: "connection request from NAME (MODEL) with deviceID = ..."</summary>
    public sealed record ClientConnecting(string Name, string Model, string DeviceId) : UxPlayEvent;
    /// <summary>uxplay's count of open connections changed; 0 means no phone is attached.</summary>
    public sealed record OpenConnections(int Count) : UxPlayEvent;
    /// <summary>uxplay gave up on a phone that stopped sending heartbeats.</summary>
    public sealed record LostConnection : UxPlayEvent;
    /// <summary>The phone paused the video stream, which iOS does when its screen locks.</summary>
    public sealed record StreamPaused : UxPlayEvent;
    /// <summary>The phone started or resumed the video stream.</summary>
    public sealed record StreamStarted : UxPlayEvent;
    /// <summary>The phone's regular check-in ("POST /feedback", every 2 seconds while it's connected).</summary>
    public sealed record Heartbeat : UxPlayEvent;
    /// <summary>Network round trip to the phone, in seconds, from uxplay's clock sync.</summary>
    public sealed record NetworkRoundTrip(double Seconds) : UxPlayEvent;
    /// <summary>A frame's arrival time at uxplay minus the phone's timestamp for it, in seconds
    /// (offset by a fixed, unknown amount per phone). Printed once a second by a uxplay with
    /// patches/uxplay-latency-report.patch.</summary>
    public sealed record VideoLatency(double Seconds) : UxPlayEvent;

    public static UxPlayEvent? Parse(string line)
    {
        int request = line.IndexOf("connection request from ", StringComparison.Ordinal);
        if (request >= 0)
        {
            int nameStart = request + "connection request from ".Length;
            int tail = line.IndexOf(" with deviceID", nameStart, StringComparison.Ordinal);
            if (tail >= 0)
            {
                string nameAndModel = line[nameStart..tail];
                string rest = line[(tail + " with deviceID".Length)..].TrimStart(' ', '=');
                string deviceId = new string(rest.TakeWhile(c => !char.IsWhiteSpace(c)).ToArray());
                // The name may itself contain parentheses, so split on the last " (".
                int open = nameAndModel.LastIndexOf(" (", StringComparison.Ordinal);
                if (open >= 0 && nameAndModel.EndsWith(')'))
                {
                    return new ClientConnecting(nameAndModel[..open], nameAndModel[(open + 2)..^1], deviceId);
                }
                return new ClientConnecting(nameAndModel, "", deviceId);
            }
        }
        int connections = line.IndexOf("Open connections: ", StringComparison.Ordinal);
        if (connections >= 0)
        {
            string digits = new string(line[(connections + "Open connections: ".Length)..].TakeWhile(char.IsDigit).ToArray());
            return int.TryParse(digits, out int count) ? new OpenConnections(count) : null;
        }
        if (line.Contains("raop_rtp video:") && Number("latency = ", line) is double latency)
            return new VideoLatency(latency);
        if (line.Contains("best NTP data:") && Number("delay ", line) is double delay)
            return new NetworkRoundTrip(delay);
        if (line.Contains("POST /feedback")) return new Heartbeat();
        if (line.Contains("lost connection with client")) return new LostConnection();
        if (line.Contains("video stream is stopping")) return new StreamPaused();
        if (line.Contains("codec packet from client"))
        {
            int header = line.IndexOf(" header ", StringComparison.Ordinal);
            if (header < 0) return null;
            // "... header 01 00 56 01 ..." when the stream stops, "... header 01 00 16 01 ..." when it
            // (re)starts: the third byte's 0x40 bit marks a stop.
            var bytes = line[(header + " header ".Length)..].Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(3).ToArray();
            if (bytes.Length != 3 || !byte.TryParse(bytes[2], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out byte flags))
                return null;
            return (flags & 0x40) != 0 ? new StreamPaused() : new StreamStarted();
        }
        // Not "begin video stream": uxplay prints that after a stop as well as a start.
        if (line.Contains("video renderer resumed") || line.Contains("starting mirroring")) return new StreamStarted();
        return null;
    }

    /// <summary>The number following <paramref name="label"/>, e.g. 0.0079 in "latency =  0.007900, ts = ...".</summary>
    private static double? Number(string label, string line)
    {
        int index = line.IndexOf(label, StringComparison.Ordinal);
        if (index < 0) return null;
        string text = new string(line[(index + label.Length)..].TrimStart(' ').TakeWhile(c => char.IsDigit(c) || c == '.' || c == '-').ToArray());
        return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out double value) ? value : null;
    }
}
