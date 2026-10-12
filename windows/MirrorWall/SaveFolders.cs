using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace MirrorWall;

/// <summary>
/// Where recordings and screenshots are saved: Documents\MirrorWall\Recordings and
/// Documents\MirrorWall\Screenshots unless another folder is chosen in Settings. A chosen folder
/// that can't be reached (an unplugged drive) falls back to the default.
/// </summary>
internal static class SaveFolders
{
    public static string DefaultRecordings => Path.Combine(Documents, "MirrorWall", "Recordings");
    public static string DefaultScreenshots => Path.Combine(Documents, "MirrorWall", "Screenshots");
    private static string Documents => Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);

    public static string Recordings => Usable(Settings.Current.RecordingsFolder, DefaultRecordings);
    public static string Screenshots => Usable(Settings.Current.ScreenshotsFolder, DefaultScreenshots);

    /// <summary>The chosen folder if it can be used, else the default.</summary>
    public static string Usable(string? chosen, string fallback)
    {
        if (!string.IsNullOrEmpty(chosen))
        {
            try
            {
                Directory.CreateDirectory(chosen);
                return chosen;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
            {
            }
        }
        return fallback;
    }
}

/// <summary>Saves a slot's current picture as a PNG at the stream's full size.</summary>
internal static class Screenshots
{
    /// <summary>Writes "iPhone 2026-10-12 09.41.07.png" (with " 2", " 3"… if taken within the same second).</summary>
    public static string Save(Picture picture, string baseName)
    {
        string folder = SaveFolders.Screenshots;
        Directory.CreateDirectory(folder);
        string stem = $"{FileNames.Safe(baseName)} {DateTime.Now:yyyy-MM-dd HH.mm.ss}";
        string path = Path.Combine(folder, stem + ".png");
        for (int number = 2; File.Exists(path); number++) path = Path.Combine(folder, $"{stem} {number}.png");

        var bitmap = BitmapSource.Create(picture.Width, picture.Height, 96, 96, PixelFormats.Bgr32, null, picture.Pixels, picture.Stride);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(path);
        encoder.Save(file);
        return path;
    }
}

internal static class FileNames
{
    /// <summary>A phone's name made safe for a file name: Windows refuses \ / : * ? " &lt; &gt; |.</summary>
    public static string Safe(string name)
    {
        var invalid = Path.GetInvalidFileNameChars().Concat(new[] { '/', '\\', ':', '*', '?', '"', '<', '>', '|' }).ToHashSet();
        string safe = new string(name.Select(c => invalid.Contains(c) ? '-' : c).ToArray()).Trim().TrimEnd('.');
        return safe.Length == 0 ? "iPhone" : safe;
    }
}

/// <summary>Keeps copies of the images chosen as slots' standby pictures, so the originals can be
/// moved or deleted.</summary>
internal static class StandbyPictures
{
    /// <summary>%APPDATA%\Mirror Wall\Standby.</summary>
    public static string Folder => Path.Combine(AppPaths.Data, "Standby");

    private static readonly Dictionary<string, BitmapImage?> Cache = new();

    /// <summary>Asks for an image and keeps a copy, its file name starting with <paramref name="label"/>.
    /// Null if cancelled or unreadable.</summary>
    public static Core.StandbyPicture? Choose(string label)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "Choose a standby picture",
            Filter = "Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff;*.heic;*.webp|All files|*.*",
        };
        if (dialog.ShowDialog() != true) return null;
        try
        {
            Directory.CreateDirectory(Folder);
            string extension = Path.GetExtension(dialog.FileName);
            string fileName = $"{label}-{Guid.NewGuid()}{(extension.Length > 0 ? extension : ".png")}";
            File.Copy(dialog.FileName, Path.Combine(Folder, fileName));
            if (Image(fileName) == null)
            {
                Discard(Core.StandbyPicture.Image(fileName));
                System.Media.SystemSounds.Beep.Play();
                return null;
            }
            return Core.StandbyPicture.Image(fileName);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            System.Media.SystemSounds.Beep.Play();
            return null;
        }
    }

    /// <summary>Deletes the copy behind a standby picture that's no longer used.</summary>
    public static void Discard(Core.StandbyPicture? standby)
    {
        if (standby is not { Kind: Core.StandbyKind.Image, FileName: { } fileName }) return;
        Cache.Remove(fileName);
        try { File.Delete(Path.Combine(Folder, fileName)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    public static BitmapImage? Image(string fileName)
    {
        if (Cache.TryGetValue(fileName, out var cached)) return cached;
        BitmapImage? image = null;
        try
        {
            image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.UriSource = new Uri(Path.Combine(Folder, fileName));
            image.EndInit();
            image.Freeze();
        }
        catch (Exception error) when (error is IOException or NotSupportedException or UriFormatException or FileFormatException or UnauthorizedAccessException)
        {
            image = null;
        }
        Cache[fileName] = image;
        return image;
    }
}
