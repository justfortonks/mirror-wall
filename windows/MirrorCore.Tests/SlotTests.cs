using System.Text.Json;
using MirrorWall.Core;

namespace MirrorWall.Core.Tests;

public class SlotConfigTests
{
    private static string After(List<string> arguments, string flag) => arguments[arguments.IndexOf(flag) + 1];

    [Fact]
    public void PortsAndDeviceIdsMatchTheMac()
    {
        var one = new SlotConfig(1, "Slot 1");
        var two = new SlotConfig(2, "Slot 2");
        Assert.Equal(7300, one.AirplayBasePort);
        Assert.Equal(7400, two.AirplayBasePort);
        Assert.Equal("02:00:00:00:00:01", one.DeviceId);
        Assert.Equal("02:00:00:00:00:0C", new SlotConfig(12, "x").DeviceId);
        Assert.Equal(5600, one.RtpPort);
        Assert.Equal(5602, two.RtpPort);
    }

    [Fact]
    public void ArgumentsTurnOffTimestampSyncAndForwardVideo()
    {
        var arguments = new SlotConfig(2, "Kitchen iPhone").UxPlayArguments();
        Assert.Equal("Kitchen iPhone", After(arguments, "-n"));
        Assert.Equal("no", After(arguments, "-vsync"));
        Assert.Equal("30", After(arguments, "-fps"));
        Assert.Equal("60", After(new SlotConfig(2, "x").UxPlayArguments(maxFrameRate: 60), "-fps"));
        Assert.Equal("7400", After(arguments, "-p"));
        Assert.EndsWith("udpsink sync=false host=127.0.0.1 port=5602", After(arguments, "-vrtp"));
        Assert.Equal("1", After(arguments, "-d"));
        Assert.Equal("no", After(arguments, "-nc"));
        Assert.DoesNotContain("-restrict", arguments);
        Assert.DoesNotContain("-h265", arguments);
        Assert.Contains("-h265", new SlotConfig(2, "x").UxPlayArguments(sharpPicture: true));
    }

    [Fact]
    public void AllowList()
    {
        var arguments = new SlotConfig(1, "x").UxPlayArguments(allowedDevices: new[] { "AA:BB", "CC:DD" });
        Assert.Equal(new[] { "-restrict", "-allow", "AA:BB", "-allow", "CC:DD" }, arguments.TakeLast(5));
    }

    [Fact]
    public void DefaultNamesUseTheComputersName()
    {
        Assert.Equal("Mirror Wall 1 · MacBook Air", SlotConfig.DefaultName(1, "Alex's MacBook Air"));
        Assert.Equal("Mirror Wall 2 · Mac Studio in", SlotConfig.DefaultName(2, "Alex’s Mac Studio in the Office"));
        Assert.Equal("Mirror Wall 2 · Studio-PC", SlotConfig.DefaultName(2, "Studio-PC"));
        Assert.Equal("Mirror Wall 3", SlotConfig.DefaultName(3, null));
        Assert.Equal("Mirror Wall 3", SlotConfig.DefaultName(3, "  "));
        Assert.True(SlotConfig.DefaultName(8, "Alex's Extremely Long Mac Name").Length <= SlotConfig.MaxNameLength);
    }

    [Fact]
    public void TidyNames()
    {
        Assert.Equal("Kitchen iPhone", SlotConfig.TidyName("  Kitchen   iPhone "));
        Assert.Equal("The Very Long Name Of My Demo", SlotConfig.TidyName("The Very Long Name Of My Demo Phone Number Two"));
        Assert.Equal("Supercalifragilisticexpialidoc", SlotConfig.TidyName("Supercalifragilisticexpialidocious-phone"));
        Assert.Equal("", SlotConfig.TidyName("   "));
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(SlotConfig.TidyName(string.Concat(Enumerable.Repeat("📱", 30)))) <= 60);
    }

    [Fact]
    public void SavesAndLoads()
    {
        var config = new SlotConfig(1, "Mirror Wall 1", "Phone") { Standby = StandbyPicture.Image("standby-1.png"), ObsFeed = true };
        var again = JsonSerializer.Deserialize<SlotConfig>(JsonSerializer.Serialize(config));
        Assert.Equal(config, again);
        var plain = JsonSerializer.Deserialize<SlotConfig>("""{"Id":2,"Name":"Desk"}""")!;
        Assert.Equal(2, plain.Id);
        Assert.Null(plain.Standby);
        Assert.Null(plain.LastPhoneName);
    }

    [Fact]
    public void WindowTitlesUseLastPhoneNameElseSlotName()
    {
        var titles = SlotConfig.WindowTitles(new[]
        {
            new SlotConfig(1, "Mirror Wall 1", "Tom’s iPhone"),
            new SlotConfig(2, "Mirror Wall 2"),
        });
        Assert.Equal(new Dictionary<int, string> { [1] = "MacMirror-Tom’s iPhone", [2] = "MacMirror-Mirror Wall 2" }, titles);
    }

    [Fact]
    public void ClashingTitlesGetTheSlotNumber()
    {
        var titles = SlotConfig.WindowTitles(new[]
        {
            new SlotConfig(1, "Mirror Wall 1", "iPhone"),
            new SlotConfig(2, "Mirror Wall 2", "iPhone"),
            new SlotConfig(3, "Mirror Wall 3", "iPad"),
        });
        Assert.Equal(new Dictionary<int, string> { [1] = "MacMirror-iPhone-1", [2] = "MacMirror-iPhone-2", [3] = "MacMirror-iPad" }, titles);
    }
}

public class UxPlayEventTests
{
    [Fact]
    public void ConnectionRequest()
    {
        Assert.Equal(
            new UxPlayEvent.ClientConnecting("t-bone's iPhone", "iPhone18,2", "12:34:56:78:9A:BC"),
            UxPlayEvent.Parse("connection request from t-bone's iPhone (iPhone18,2) with deviceID = 12:34:56:78:9A:BC"));
        Assert.Equal(
            new UxPlayEvent.ClientConnecting("Kid (2)", "iPhone14,6", "AA"),
            UxPlayEvent.Parse("connection request from Kid (2) (iPhone14,6) with deviceID = AA"));
    }

    [Fact]
    public void OpenConnections()
    {
        Assert.Equal(new UxPlayEvent.OpenConnections(0), UxPlayEvent.Parse("Open connections: 0"));
        Assert.Equal(new UxPlayEvent.OpenConnections(2), UxPlayEvent.Parse("Open connections: 2"));
    }

    [Fact]
    public void LostConnection() =>
        Assert.Equal(new UxPlayEvent.LostConnection(), UxPlayEvent.Parse("*** ERROR lost connection with client (network problem?)"));

    [Fact]
    public void StreamPauseAndResume()
    {
        Assert.Equal(new UxPlayEvent.StreamPaused(), UxPlayEvent.Parse("This packet indicates video stream is stopping"));
        Assert.Equal(new UxPlayEvent.StreamPaused(),
            UxPlayEvent.Parse("Received unencrypted codec packet from client: payload_size 37 header 01 00 56 01  ts_client = 1791738799.849069"));
        Assert.Equal(new UxPlayEvent.StreamStarted(),
            UxPlayEvent.Parse("Received unencrypted codec packet from client: payload_size 37 header 01 00 16 01  ts_client = 1791738808.749092"));
        Assert.Equal(new UxPlayEvent.StreamStarted(), UxPlayEvent.Parse("video renderer resumed: state PAUSED"));
        Assert.Equal(new UxPlayEvent.StreamStarted(), UxPlayEvent.Parse("raop_rtp_mirror starting mirroring"));
    }

    [Fact]
    public void Heartbeat() => Assert.Equal(new UxPlayEvent.Heartbeat(), UxPlayEvent.Parse("httpd: request POST /feedback RTSP/1.0"));

    [Fact]
    public void NetworkRoundTrip() =>
        Assert.Equal(new UxPlayEvent.NetworkRoundTrip(0.004812), UxPlayEvent.Parse("best NTP data: offset   0.152731, delay   0.004812"));

    [Fact]
    public void VideoLatency() =>
        Assert.Equal(new UxPlayEvent.VideoLatency(0.046789),
            UxPlayEvent.Parse("raop_rtp video: now = 8123.456789, ntp = 8123.410000, latency =  0.046789, ts = 1791738808.749092, 00 00 00 00 h264, size: 4123"));

    [Fact]
    public void BeginVideoStreamIsNotAResume() =>
        // uxplay prints this right after a stop too.
        Assert.Null(UxPlayEvent.Parse("begin video stream wxh = 498x1080; source 498x1080"));

    [Fact]
    public void OtherLinesAreIgnored()
    {
        Assert.Null(UxPlayEvent.Parse("Initialized server socket(s)"));
        Assert.Null(UxPlayEvent.Parse("Open connections: many"));
        Assert.Null(UxPlayEvent.Parse("video renderer pause: NO PREROLL"));
    }
}

public class PackagedReceiverTests
{
    private static readonly string Folder = Path.Combine("C:", "Program Files", "Mirror Wall", "receiver");

    [Fact]
    public void PackagedReceiverUsesOnlyItsOwnPlugins()
    {
        string plugins = Path.Combine(Folder, "lib", "gstreamer-1.0");
        var environment = PackagedReceiver.Environment(
            Path.Combine(Folder, "uxplay.exe"),
            new Dictionary<string, string> { ["USERPROFILE"] = "me", ["GST_PLUGIN_PATH"] = "elsewhere" },
            "registry.bin",
            path => path == plugins);
        Assert.NotNull(environment);
        Assert.Equal(plugins, environment["GST_PLUGIN_SYSTEM_PATH"]);
        Assert.Equal(Path.Combine(Folder, "gst-plugin-scanner.exe"), environment["GST_PLUGIN_SCANNER"]);
        Assert.Equal("registry.bin", environment["GST_REGISTRY"]);
        Assert.Equal("1", environment["MIRROR_WALL_QUIT_ON_EOF"]);
        Assert.False(environment.ContainsKey("GST_PLUGIN_PATH"));
        Assert.Equal("me", environment["USERPROFILE"]);
    }

    [Fact]
    public void OtherReceiversInheritTheEnvironment() =>
        Assert.Null(PackagedReceiver.Environment(Path.Combine("C:", "msys64", "ucrt64", "bin", "uxplay.exe"),
            new Dictionary<string, string>(), "registry.bin", _ => false));
}

public class PhoneModelTests
{
    [Fact]
    public void FriendlyNames()
    {
        Assert.Equal("iPhone 17 Pro Max", PhoneModels.Name("iPhone18,2"));
        Assert.Equal("iPhone SE (3rd generation)", PhoneModels.Name("iPhone14,6"));
        Assert.Equal("iPhone99,1", PhoneModels.Name("iPhone99,1"));
    }

    [Fact]
    public void TrueToLifeSizes()
    {
        // The 17 Pro Max is the reference; the SE's screen is about two-thirds as tall.
        Assert.InRange(PhoneModels.TrueToLifeLongSide(800, "iPhone18,2", 498, 1080), 797, 803);
        Assert.InRange(PhoneModels.TrueToLifeLongSide(800, "iPhone14,6", 608, 1080), 519, 529);
        // Landscape uses the same long side.
        Assert.InRange(PhoneModels.TrueToLifeLongSide(800, "iPhone14,6", 1080, 608), 519, 529);
        // Unknown phones keep the reference size.
        Assert.Equal(800, PhoneModels.TrueToLifeLongSide(800, "iPhone99,1", 498, 1080));
        Assert.Equal(800, PhoneModels.TrueToLifeLongSide(800, null, 498, 1080));
    }
}
