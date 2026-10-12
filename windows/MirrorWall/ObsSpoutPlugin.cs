using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace MirrorWall;

/// <summary>
/// OBS needs the separately installed Spout2 plugin to pick up a slot's Spout feed. The app looks
/// for it once, the first time it opens, and again whenever a slot's feed is turned on, and if it
/// isn't there offers the plugin's download page.
/// </summary>
internal static class ObsSpoutPlugin
{
    public const string DownloadPage = "https://github.com/Off-World-Live/obs-spout2-plugin/releases/latest";

    private const string PluginFile = "win-spout.dll";

    /// <summary>
    /// True when the plugin's DLL is where its installer puts it: ProgramData\obs-studio\plugins
    /// (or wherever the installer was pointed, which it records in the registry), the user's own
    /// OBS plugins folder, or the obs-plugins folder of the OBS install (older versions).
    /// </summary>
    public static bool IsInstalled()
    {
        try
        {
            return Candidates().Any(File.Exists);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return true; // Can't tell: don't nag.
        }
    }

    private static IEnumerable<string> Candidates()
    {
        foreach (var root in new[] { Environment.SpecialFolder.CommonApplicationData, Environment.SpecialFolder.ApplicationData })
        {
            string plugins = Path.Combine(Environment.GetFolderPath(root), "obs-studio", "plugins");
            if (!Directory.Exists(plugins)) continue;
            foreach (string plugin in Directory.EnumerateDirectories(plugins))
            {
                yield return Path.Combine(plugin, "bin", "64bit", PluginFile);
            }
        }
        foreach (string folder in RegistryFolders(@"SOFTWARE\Spout 2 OBS Plugin", "InstallDir"))
        {
            yield return Path.Combine(folder, "bin", "64bit", PluginFile);
            yield return Path.Combine(folder, "obs-plugins", "64bit", PluginFile);
        }
        var obsFolders = RegistryFolders(@"SOFTWARE\OBS Studio", null)
            .Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "obs-studio"));
        foreach (string folder in obsFolders)
        {
            yield return Path.Combine(folder, "obs-plugins", "64bit", PluginFile);
        }
    }

    /// <summary>A folder saved in HKLM under <paramref name="key"/>, in the 64- and 32-bit views.</summary>
    private static IEnumerable<string> RegistryFolders(string key, string? value)
    {
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            using var hive = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view);
            using var opened = hive.OpenSubKey(key);
            if (opened?.GetValue(value) is string folder && folder.Length > 0) yield return folder;
        }
    }

    /// <summary>The first time the app opens: offers the plugin if OBS can't receive Spout yet.</summary>
    public static void CheckOnFirstLaunch(Window owner)
    {
        var settings = Settings.Current;
        if (settings.CheckedObsSpoutPlugin) return;
        settings.CheckedObsSpoutPlugin = true;
        settings.Save();
        if (!IsInstalled()) ShowNotice(owner, firstLaunch: true);
    }

    /// <summary>When a slot's feed is turned on: offers the plugin if it's missing.</summary>
    public static void CheckWhenFeedTurnedOn(Window owner)
    {
        if (!IsInstalled()) ShowNotice(owner, firstLaunch: false);
    }

    private static void ShowNotice(Window owner, bool firstLaunch)
    {
        var window = new Window
        {
            Title = "Spout2 plugin for OBS",
            Owner = owner.IsLoaded ? owner : null,
            SizeToContent = SizeToContent.WidthAndHeight,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = owner.IsLoaded ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
            ShowInTaskbar = false,
        };
        string text = firstLaunch
            ? "Mirror Wall can send each phone straight to OBS through Spout, even with Mirror Wall minimized (a tile's ⋯ menu › Send to OBS (Spout)). OBS needs the free Spout2 plugin for that, and it isn't installed on this PC.\n\nYou only need it for Spout: capturing a slot's own window works without it."
            : "OBS needs the free Spout2 plugin to show this feed, and it isn't installed on this PC. Mirror Wall is sending the feed anyway, so once the plugin is installed, add a Spout2 Capture source in OBS.";
        var message = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Width = 380 };
        var hint = new TextBlock
        {
            Text = "On the download page, get OBS_Spout2_Plugin_Installer.exe, close OBS, and run it.",
            TextWrapping = TextWrapping.Wrap,
            Width = 380,
            Margin = new Thickness(0, 10, 0, 0),
            Foreground = SystemColors.GrayTextBrush,
        };
        var download = new Button { Content = "Get the Plugin", IsDefault = true, Padding = new Thickness(14, 4, 14, 4) };
        download.Click += (_, _) => { OpenDownloadPage(); window.Close(); };
        var later = new Button { Content = "Not Now", IsCancel = true, Padding = new Thickness(14, 4, 14, 4), Margin = new Thickness(8, 0, 0, 0) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        buttons.Children.Add(download);
        buttons.Children.Add(later);
        var root = new StackPanel { Margin = new Thickness(16) };
        root.Children.Add(message);
        root.Children.Add(hint);
        root.Children.Add(buttons);
        window.Content = root;
        window.ShowDialog();
    }

    public static void OpenDownloadPage()
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = DownloadPage, UseShellExecute = true });
        }
        catch (Win32Exception)
        {
        }
    }
}
