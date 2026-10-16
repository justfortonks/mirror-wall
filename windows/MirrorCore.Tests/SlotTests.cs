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
        Assert.Equal("Mirror Wall 1 · MacBook Air", SlotConfig.DefaultName(1, "Thomas's MacBook Air"));
        Assert.Equal("Mirror Wall 2 · Mac Studio in", SlotConfig.DefaultName(2, "Thomas’s Mac Studio in the Office"));
        Assert.Equal("Mirror Wall 2 · Studio-PC", SlotConfig.DefaultName(2, "Studio-PC"));
        Assert.Equal("Mirror Wall 3", SlotConfig.DefaultName(3, null));
        Assert.Equal("Mirror Wall 3", SlotConfig.DefaultName(3, "  "));
        Assert.True(SlotConfig.DefaultName(8, "Thomas's Extremely Long Mac Name").Length <= SlotConfig.MaxNameLength);
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
    public void RenamedSlotsUseTheirOwnName()
    {
        var titles = SlotConfig.WindowTitles(new[]
        {
            new SlotConfig(1, "Desk", "Tom’s iPhone"),
            new SlotConfig(2, "Mirror Wall 2 · Studio-PC", "iPad"),
        });
        Assert.Equal(new Dictionary<int, string> { [1] = "MacMirror-Desk", [2] = "MacMirror-iPad" }, titles);
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

public class PhoneBezelTests
{
    [Theory]
    [InlineData("iPhone14,6", BezelStyle.HomeButton)]
    [InlineData("iPhone12,8", BezelStyle.HomeButton)]
    [InlineData("iPhone10,4", BezelStyle.HomeButton)]
    [InlineData("iPhone10,6", BezelStyle.Notch)]
    [InlineData("iPhone14,5", BezelStyle.Notch)]
    [InlineData("iPhone14,7", BezelStyle.Notch)]
    [InlineData("iPhone17,5", BezelStyle.Notch)]
    [InlineData("iPhone15,2", BezelStyle.DynamicIsland)]
    [InlineData("iPhone18,2", BezelStyle.DynamicIsland)]
    [InlineData("iPhone99,1", BezelStyle.DynamicIsland)]
    [InlineData("Pixel 8", BezelStyle.Plain)]
    [InlineData("Zebra Technologies HC50", BezelStyle.ZebraHC50)]
    [InlineData("Zebra HC50", BezelStyle.ZebraHC50)]
    [InlineData("HC50", BezelStyle.ZebraHC50)]
    [InlineData("Zebra Technologies HC20", BezelStyle.Plain)]
    [InlineData("Zebra Technologies HC55", BezelStyle.Plain)]
    [InlineData("Honeywell CT37", BezelStyle.HoneywellCT37)]
    [InlineData("Honeywell CT37 HC", BezelStyle.HoneywellCT37)]
    [InlineData("Honeywell CT37HC", BezelStyle.HoneywellCT37)]
    [InlineData("Honeywell CT30", BezelStyle.Plain)]
    [InlineData("Honeywell CT370", BezelStyle.Plain)]
    [InlineData("Spectralink 9640", BezelStyle.Versity95)]
    [InlineData("Spectralink Versity 9553", BezelStyle.Versity95)]
    [InlineData("Spectralink V9540", BezelStyle.Versity95)]
    [InlineData("Spectralink Versity 9753", BezelStyle.Versity97)]
    [InlineData("Spectralink 9740", BezelStyle.Versity97)]
    [InlineData("Spectralink 9240", BezelStyle.Plain)]
    [InlineData("iPhone", BezelStyle.Plain)]
    [InlineData(null, BezelStyle.Plain)]
    public void PicksAStyleFromTheModel(string? model, BezelStyle style) => Assert.Equal(style, BezelGeometry.StyleFor(model));

    [Fact]
    public void PhotoFrameFitsThePictureInItsScreen()
    {
        // HC50: 1280×2640 photo, 1080×2160 screen at (100, 240).
        var exact = new BezelGeometry(BezelStyle.ZebraHC50, 1080, 2160);
        Assert.Equal(100.0 / 1080, exact.Left, 9);
        Assert.Equal(240.0 / 1080, exact.Top, 9);
        Assert.Equal(100.0 / 1080, exact.Right, 9);
        Assert.Equal(240.0 / 1080, exact.Bottom, 9);
        var outer = exact.OuterSize(1080, 2160);
        Assert.Equal(1280.0 / 2640, outer.Width / outer.Height, 9);

        // A slightly narrower picture is centered, never stretched; the photo keeps its shape.
        var narrow = new BezelGeometry(BezelStyle.ZebraHC50, 1072, 2160);
        var narrowOuter = narrow.OuterSize(1072, 2160);
        Assert.Equal(1280.0 / 2640, narrowOuter.Width / narrowOuter.Height, 9);
        Assert.Equal(narrow.Left, narrow.Right, 9);
        Assert.True(narrow.Left > narrow.ArtworkScreen!.Value.X);

        // Sideways: the photo's top edge goes left. CT37: 1360×2880, screen 1080×2280 at (140, 320).
        var sideways = new BezelGeometry(BezelStyle.HoneywellCT37, 2280, 1080);
        Assert.True(sideways.Landscape);
        Assert.Equal(320.0 / 1080, sideways.Left, 9);
        Assert.Equal(280.0 / 1080, sideways.Right, 9);
        Assert.Equal(140.0 / 1080, sideways.Top, 9);
        Assert.Equal(140.0 / 1080, sideways.Bottom, 9);
        Assert.Equal(6, PhoneModels.ScreenDiagonal("Zebra Technologies HC50"));
    }

    [Fact]
    public void FrameTurnsTheWayThePhoneSays()
    {
        var upright = new BezelGeometry(BezelStyle.HomeButton, 750, 1334);
        var upsideDown = new BezelGeometry(BezelStyle.HomeButton, 750, 1334, 2);
        Assert.Equal(2, upsideDown.QuarterTurns);
        Assert.Equal(upright.Bottom, upsideDown.Top);
        Assert.Equal(upright.Top, upsideDown.UprightTop);
        var topRight = new BezelGeometry(BezelStyle.HomeButton, 1334, 750, 3);
        Assert.Equal(upright.Top, topRight.Right);
        Assert.Equal(upright.Bottom, topRight.Left);
        // A turn that doesn't match the picture (its new picture hasn't arrived) is ignored.
        Assert.Equal(0, new BezelGeometry(BezelStyle.HomeButton, 750, 1334, 1).QuarterTurns);
        Assert.Equal(1, new BezelGeometry(BezelStyle.HomeButton, 1334, 750, 0).QuarterTurns);

        // CT37 upside down: 1360×2880, screen 1080×2280 at (140, 320), so 280 above, 320 below.
        var photo = new BezelGeometry(BezelStyle.HoneywellCT37, 1080, 2280, 2);
        Assert.Equal(280.0 / 1080, photo.Top, 9);
        Assert.Equal(320.0 / 1080, photo.Bottom, 9);
        var photoRight = new BezelGeometry(BezelStyle.HoneywellCT37, 2280, 1080, 3);
        Assert.Equal(280.0 / 1080, photoRight.Left, 9);
        Assert.Equal(320.0 / 1080, photoRight.Right, 9);
    }

    [Fact]
    public void FrameTurnsWithThePicture()
    {
        var portrait = new BezelGeometry(BezelStyle.HomeButton, 750, 1334);
        Assert.False(portrait.Landscape);
        Assert.Equal(0.215, portrait.Top);
        Assert.Equal(0.06, portrait.Left);
        var landscape = new BezelGeometry(BezelStyle.HomeButton, 1334, 750);
        Assert.True(landscape.Landscape);
        Assert.Equal(portrait.Top, landscape.Left);
        Assert.Equal(portrait.Bottom, landscape.Right);
        Assert.Equal(portrait.Left, landscape.Top);

        var size = portrait.OuterSize(750, 1334);
        Assert.Equal(1.12, size.Width, 9);
        Assert.Equal(1334.0 / 750 + 0.43, size.Height, 9);
        var sideways = landscape.OuterSize(1334, 750);
        Assert.Equal(size.Height, sideways.Width, 9);
        Assert.Equal(size.Width, sideways.Height, 9);
    }

    [Fact]
    public void SlotRemembersItsOwnBezelChoice()
    {
        var config = new SlotConfig(1, "x") { Bezel = true };
        Assert.Equal(config, System.Text.Json.JsonSerializer.Deserialize<SlotConfig>(System.Text.Json.JsonSerializer.Serialize(config)));
        Assert.Null(System.Text.Json.JsonSerializer.Deserialize<SlotConfig>("""{"Id":2,"Name":"Desk"}""")!.Bezel);
    }
}

public class StageLayoutTests
{
    private static readonly (double Width, double Height) Big = (1, 2), Small = (0.5, 1);

    [Fact]
    public void SideBySideKeepsRelativeSizesAndCenters()
    {
        var frames = Stage.Frames([Big, Small], StageLayout.SideBySide, 1000, 1000, spacing: 0);
        Assert.Equal(2, frames.Length);
        Assert.Equal(0, frames[0].Y, 6);
        Assert.Equal(1000, frames[0].Height, 6);
        Assert.Equal(frames[0].X, 1000 - (frames[1].X + frames[1].Width), 6);
        Assert.Equal(frames[0].Height / 2, frames[1].Height, 6);
        Assert.Equal(500, frames[1].Y + frames[1].Height / 2, 6);
    }

    [Fact]
    public void StackedRunsTopToBottom()
    {
        var frames = Stage.Frames([Small, Small], StageLayout.Stacked, 1000, 1000);
        Assert.True(frames[0].Y + frames[0].Height < frames[1].Y);
        Assert.Equal(frames[0].X, frames[1].X, 6);
        Assert.Equal(500, frames[0].X + frames[0].Width / 2, 6);
    }

    [Theory]
    [InlineData(StageLayout.SideBySide)]
    [InlineData(StageLayout.Stacked)]
    [InlineData(StageLayout.Grid)]
    public void GapsAndMarginsKeepPhonesApartAndInside(StageLayout layout)
    {
        var frames = Stage.Frames([Big, Small, Big, Small, Big], layout, 1280, 720);
        for (int i = 0; i < frames.Length; i++)
        {
            var frame = frames[i];
            Assert.True(frame.X > 0 && frame.Y > 0 && frame.X + frame.Width < 1280 && frame.Y + frame.Height < 720);
            foreach (var other in frames.Skip(i + 1))
            {
                Assert.True(frame.X + frame.Width < other.X || other.X + other.Width < frame.X
                    || frame.Y + frame.Height < other.Y || other.Y + other.Height < frame.Y);
            }
        }
    }

    [Fact]
    public void GridCentersAShortLastRow()
    {
        var frames = Stage.Frames([Big, Big, Big], StageLayout.Grid, 1000, 1000);
        Assert.Equal(frames[0].Y, frames[1].Y, 6);
        Assert.True(frames[2].Y > frames[0].Y);
        Assert.Equal(500, frames[2].X + frames[2].Width / 2, 6);
    }

    [Fact]
    public void NoPhonesOrNoRoom()
    {
        Assert.Empty(Stage.Frames([], StageLayout.Grid, 100, 100));
        Assert.Equal(new[] { new StageRect(0, 0, 0, 0) }, Stage.Frames([Big], StageLayout.Grid, 0, 100));
    }

    [Fact]
    public void PhoneSizesAreTrueToLife()
    {
        var proMax = Stage.PhoneSize("iPhone18,2", 1320, 2868, bezel: false);
        Assert.Equal(1, Math.Max(proMax.Width, proMax.Height), 2);
        var se = Stage.PhoneSize("iPhone14,6", 750, 1334, bezel: false);
        Assert.True(se.Height < 0.8);
        Assert.Equal(750.0 / 1334, se.Width / se.Height, 6);
        var framed = Stage.PhoneSize("iPhone14,6", 750, 1334, bezel: true);
        Assert.True(framed.Height > se.Height && framed.Width > se.Width);
        var sideways = Stage.PhoneSize("iPhone18,2", 2868, 1320, bezel: false);
        Assert.True(sideways.Width > sideways.Height);
        var waiting = Stage.PhoneSize(null, 0, 0, bezel: false);
        Assert.Equal(1, waiting.Height, 6);
    }
}
