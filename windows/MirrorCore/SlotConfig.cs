using System.Text;
using System.Text.Json.Serialization;

namespace MirrorWall.Core;

/// <summary>
/// One mirroring slot: an AirPlay receiver that a single iPhone can mirror to.
///
/// Each slot gets its own uxplay process with its own name, ports and device ID, because one
/// uxplay instance only accepts one phone at a time. Saved as JSON in the app's settings file.
/// </summary>
public sealed record SlotConfig
{
    /// <summary>1-based slot number. Ports and the device ID are derived from it, so it never changes.</summary>
    public int Id { get; init; }
    /// <summary>The name shown in Screen Mirroring on the iPhone.</summary>
    public string Name { get; set; } = "";
    /// <summary>The name of the last iPhone that mirrored to this slot. Kept after it disconnects so
    /// the slot's own window keeps the same title (OBS finds windows by title).</summary>
    public string? LastPhoneName { get; set; }
    /// <summary>The model code of that iPhone, e.g. "iPhone18,2", for sizing the slot's own window.</summary>
    public string? LastPhoneModel { get; set; }
    /// <summary>What the slot shows while no phone is mirroring; null to use the one set for all slots.</summary>
    public StandbyPicture? Standby { get; set; }
    /// <summary>Whether the slot also sends its picture to OBS through Spout. Off (null) by default.</summary>
    public bool? ObsFeed { get; set; }

    [JsonConstructor]
    public SlotConfig() { }

    public SlotConfig(int id, string name, string? lastPhoneName = null)
    {
        if (id < 1 || id > 99) throw new ArgumentOutOfRangeException(nameof(id), "slot id out of range");
        Id = id;
        Name = name;
        LastPhoneName = lastPhoneName;
    }

    /// <summary>"Mirror Wall 1 · Studio PC": the computer's name, without its owner, so phones can
    /// tell two computers' slots apart. "Mirror Wall" comes first because the phone's list cuts long
    /// names at the end.</summary>
    public static string DefaultName(int id, string? computerName)
    {
        string computer = computerName == null ? "" : Shortened(WithoutOwner(Collapsed(computerName)), MaxComputerNameLength);
        return $"Mirror Wall {id}" + (computer.Length == 0 ? "" : " · " + computer);
    }

    /// <summary>"Alex's MacBook Air" → "MacBook Air".</summary>
    internal static string WithoutOwner(string name)
    {
        foreach (string apostrophe in new[] { "'s ", "’s " })
        {
            int index = name.IndexOf(apostrophe, StringComparison.Ordinal);
            if (index >= 0 && index + apostrophe.Length < name.Length) return name[(index + apostrophe.Length)..];
        }
        return name;
    }

    internal const int MaxComputerNameLength = 14;
    /// <summary>Longer names get cut in the iPhone's Screen Mirroring list anyway.</summary>
    public const int MaxNameLength = 30;
    /// <summary>Bonjour allows 63 bytes; a little to spare.</summary>
    internal const int MaxNameBytes = 60;

    /// <summary>A name as typed, made tidy: single spaces, at most <see cref="MaxNameLength"/>
    /// characters, cut at a word where possible. Empty if nothing is left.</summary>
    public static string TidyName(string name) => Shortened(Collapsed(name), MaxNameLength);

    private static string Collapsed(string text) =>
        string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    /// <summary>Cuts <paramref name="text"/> to <paramref name="limit"/> characters (as people
    /// count them), at the last space if that keeps at least half of it.</summary>
    internal static string Shortened(string text, int limit)
    {
        var characters = TextElements(text.Trim());
        bool cut = false;
        if (characters.Count > limit)
        {
            var prefix = characters.Take(limit).ToList();
            int space = prefix.LastIndexOf(" ");
            characters = space >= limit / 2 ? prefix.Take(space).ToList() : prefix;
            cut = true;
        }
        while (Encoding.UTF8.GetByteCount(string.Concat(characters)) > MaxNameBytes)
        {
            characters.RemoveAt(characters.Count - 1);
            cut = true;
        }
        // Don't leave a dangling separator where the name was cut.
        while (cut && characters.Count > 0 && " -–,.;:&+/".Contains(characters[^1])) characters.RemoveAt(characters.Count - 1);
        return string.Concat(characters);
    }

    private static List<string> TextElements(string text)
    {
        var elements = new List<string>();
        var enumerator = System.Globalization.StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext()) elements.Add((string)enumerator.Current);
        return elements;
    }

    /// <summary>First of the three TCP/UDP ports uxplay uses (base, base+1, base+2): 7300, 7400, ...</summary>
    [JsonIgnore]
    public int AirplayBasePort => 7200 + Id * 100;

    /// <summary>Localhost UDP port uxplay forwards the decrypted video's RTP stream to: 5600, 5602, ...</summary>
    [JsonIgnore]
    public int RtpPort => 5598 + Id * 2;

    /// <summary>A locally administered MAC-style device ID, unique per slot.</summary>
    [JsonIgnore]
    public string DeviceId => "02:00:00:00:00:" + Id.ToString("X2");

    /// <summary>The highest frame rates the app offers to ask phones for. uxplay's own default is 30.</summary>
    public static readonly int[] FrameRates = { 30, 60 };

    /// <summary>
    /// Command-line arguments for this slot's uxplay process. <paramref name="maxFrameRate"/> is the
    /// most frames a second the phone is asked to send; it may send fewer. With
    /// <paramref name="allowedDevices"/>, only phones with those device IDs may connect. With
    /// <paramref name="sharpPicture"/>, phones are offered H.265 at up to 3840×2160, and send portrait
    /// pictures twice as tall and wide as with H.264's 1920×1080.
    /// </summary>
    public List<string> UxPlayArguments(int maxFrameRate = 30, IEnumerable<string>? allowedDevices = null, bool sharpPicture = false)
    {
        var arguments = new List<string>
        {
            "-n", Name,
            "-nh",                      // don't append "@hostname" to the name
            "-p", AirplayBasePort.ToString(),
            "-m", DeviceId,
            "-vsync", "no",             // show frames as they arrive; with sync on the picture froze after the phone slept
            "-as", "0",                 // view only: no audio
            "-d", "1",                  // debug log without packet dumps: reports connects and disconnects
            "-fps", maxFrameRate.ToString(),
            // Rebuild the video pipeline after every disconnect (see the Mac app's SlotConfig).
            "-nc", "no",
            // sync=false: send each frame on at once even when the receiver stamps it with the
            // phone's capture time (patches/uxplay-frame-timestamps.patch).
            "-vrtp", $"config-interval=1 ! udpsink sync=false host=127.0.0.1 port={RtpPort}",
        };
        if (sharpPicture) arguments.Add("-h265");
        if (allowedDevices != null)
        {
            arguments.Add("-restrict");
            foreach (string device in allowedDevices) arguments.AddRange(new[] { "-allow", device });
        }
        return arguments;
    }

    /// <summary>
    /// Titles for the slots' own windows, which their OBS feeds also go by: "MacMirror-" plus the
    /// last phone's name, or the slot's name before any phone has connected. Slots whose names would
    /// clash get "-&lt;slot number&gt;". The same names as on the Mac, so OBS scenes match.
    /// </summary>
    public static Dictionary<int, string> WindowTitles(IEnumerable<SlotConfig> slots)
    {
        var bases = slots.Select(slot => (slot.Id, Title: "MacMirror-" + (string.IsNullOrEmpty(slot.LastPhoneName) ? slot.Name : slot.LastPhoneName))).ToList();
        var counts = bases.GroupBy(entry => entry.Title).ToDictionary(group => group.Key, group => group.Count());
        return bases.ToDictionary(entry => entry.Id, entry => counts[entry.Title] > 1 ? $"{entry.Title}-{entry.Id}" : entry.Title);
    }
}

public enum StandbyKind { Message, Blank, Image }

/// <summary>What a slot shows while no phone is mirroring: the waiting message (the default),
/// nothing, or an image the app keeps a copy of, by its file name in the app's own folder.</summary>
public sealed record StandbyPicture(StandbyKind Kind, string? FileName = null)
{
    public static readonly StandbyPicture Message = new(StandbyKind.Message);
    public static readonly StandbyPicture Blank = new(StandbyKind.Blank);
    public static StandbyPicture Image(string fileName) => new(StandbyKind.Image, fileName);
}

/// <summary>A phone that has mirrored to this PC, remembered for the allow-list.</summary>
public sealed record KnownPhone(string DeviceId, string Name, string Model, DateTime LastSeen);
