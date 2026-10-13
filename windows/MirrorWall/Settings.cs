using System.Text.Json;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>The size of slots' own windows (see <see cref="PopOutWindow"/>).</summary>
public enum PopOutSize { Small, Medium, Large, Custom }

/// <summary>
/// Everything the app remembers, saved as JSON in %APPDATA%\Mirror Wall\settings.json (the Mac
/// app keeps the same things in its user defaults).
/// </summary>
internal sealed class Settings
{
    public List<SlotConfig>? Slots { get; set; }
    /// <summary>The uxplay chosen with File › Choose uxplay…, if any.</summary>
    public string? UxPlayPath { get; set; }
    /// <summary>Slots whose own windows were open when the app last quit.</summary>
    public List<int> PoppedOut { get; set; } = new();
    /// <summary>Reopen those windows when the app starts. Off by default.</summary>
    public bool ReopenOwnWindows { get; set; }
    /// <summary>Every slot sends its picture to OBS through Spout unless its own menu says
    /// otherwise (<see cref="SlotConfig.ObsFeed"/>). Off by default.</summary>
    public bool ObsFeedForAllSlots { get; set; }
    /// <summary>Where each slot's own window was, by slot number.</summary>
    public Dictionary<int, double[]> PopOutPositions { get; set; } = new();
    /// <summary>Each slot's own Custom size: its window's longer side, by slot number.</summary>
    public Dictionary<int, double> PopOutCustomLongSides { get; set; } = new();
    public int MaxFrameRate { get; set; } = 30;
    public bool SmoothMotion { get; set; }
    public bool SharpPicture { get; set; }
    public PopOutSize PopOutSize { get; set; } = PopOutSize.Medium;
    public bool PopOutSizeLocked { get; set; } = true;
    public List<KnownPhone> KnownPhones { get; set; } = new();
    public bool AllowListEnabled { get; set; }
    public List<string> AllowedDevices { get; set; } = new();
    public StandbyPicture DefaultStandby { get; set; } = StandbyPicture.Message;
    /// <summary>Flash the taskbar button when a mirroring phone drops.</summary>
    public bool FlashOnDisconnect { get; set; } = true;
    public bool ShowStats { get; set; }
    public string? RecordingsFolder { get; set; }
    public string? ScreenshotsFolder { get; set; }
    /// <summary>Whether the first launch's check for OBS's Spout2 plugin has run.</summary>
    public bool CheckedObsSpoutPlugin { get; set; }
    /// <summary>The main window's place: left, top, width, height.</summary>
    public double[]? MainWindowBounds { get; set; }

    private static string FilePath => Path.Combine(AppPaths.Data, "settings.json");
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static Settings Current { get; } = Load();

    private static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath)) return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), Options) ?? new Settings();
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException)
        {
            // A damaged file starts over rather than keeping the app from opening.
            try { File.Copy(FilePath, FilePath + ".damaged", overwrite: true); } catch (IOException) { }
        }
        return new Settings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(AppPaths.Data);
            string temporary = FilePath + ".new";
            File.WriteAllText(temporary, JsonSerializer.Serialize(this, Options));
            File.Move(temporary, FilePath, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
        }
    }
}
