using System.ComponentModel;
using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// Help › Check for Update…: compares this copy with the newest release on GitHub and, when asked,
/// downloads its installer and runs it quietly; Mirror Wall closes, and opens again once the
/// installer is done.
///
/// Nothing needs signing for this: SmartScreen only asks about files a browser marks as
/// downloaded from the internet, and a download the app makes itself has no such mark. Windows
/// still asks once to let the installer make changes, as it needs an administrator for the
/// firewall rules.
/// </summary>
internal static class Updater
{
    private static bool busy;

    /// <summary>98 for build 0.98; null for a build made outside the workflow (version 0.0).</summary>
    private static int? CurrentBuild
    {
        get
        {
            var version = Assembly.GetExecutingAssembly().GetName().Version;
            return version is { Major: 0, Minor: > 0 } ? version.Minor : null;
        }
    }

    public static async void Check(Window? owner)
    {
        if (busy) return;
        busy = true;
        try
        {
            LatestRelease? release;
            try
            {
                using var client = Client();
                release = LatestRelease.Parse(await client.GetStringAsync(LatestRelease.ApiUrl), "MirrorWall-Setup.exe");
            }
            catch (Exception error) when (error is HttpRequestException or TaskCanceledException)
            {
                Problem(owner, "Mirror Wall couldn't check for an update.", error.Message, offerPage: false);
                return;
            }
            if (release == null)
            {
                Problem(owner, "Mirror Wall couldn't check for an update.", "GitHub didn't list a release Mirror Wall could read.", offerPage: false);
                return;
            }
            if (Offer(owner, release)) await Install(owner, release);
        }
        finally
        {
            busy = false;
        }
    }

    /// <summary>Says what's available; true when the user chose to install it.</summary>
    private static bool Offer(Window? owner, LatestRelease release)
    {
        bool installable = CurrentBuild != null && release.DownloadUrl != null;
        if (CurrentBuild is int current && current >= release.Build)
        {
            string have = current == release.Build
                ? $"You have {release.Version}, the newest release."
                : $"You have 0.{current}, newer than the newest release ({release.Version}).";
            if (!installable)
            {
                Message(owner, have, MessageBoxButton.OK);
                return false;
            }
            // Puts a fresh copy of the release back, e.g. after trying a test build.
            return Message(owner, $"Mirror Wall is up to date. {have}\n\nInstall {release.Version} anyway?", MessageBoxButton.YesNo, MessageBoxResult.No) == MessageBoxResult.Yes;
        }

        string notes = release.Notes.Length > 0 ? $"\n\n{release.Notes}" : "";
        if (!installable)
        {
            if (Message(owner, $"Mirror Wall {release.Version} is available.{notes}\n\nOpen its download page?", MessageBoxButton.YesNo) == MessageBoxResult.Yes)
                OpenPage();
            return false;
        }
        return Message(owner,
            $"Mirror Wall {release.Version} is available. You have 0.{CurrentBuild}.{notes}\n\n" +
            "Install it now? Mirror Wall will close, Windows will ask to let the installer make changes, and Mirror Wall opens again when it's done. Phones reconnect by themselves.",
            MessageBoxButton.YesNo) == MessageBoxResult.Yes;
    }

    private static async Task Install(Window? owner, LatestRelease release)
    {
        var progress = new ProgressWindow($"Downloading Mirror Wall {release.Version}…") { Owner = owner?.IsVisible == true ? owner : null };
        progress.Show();
        string folder = Path.Combine(Path.GetTempPath(), "Mirror Wall update");
        string setup = Path.Combine(folder, "MirrorWall-Setup.exe");
        try
        {
            Directory.CreateDirectory(folder);
            using (var client = Client())
            using (var response = await client.GetAsync(release.DownloadUrl!, HttpCompletionOption.ResponseHeadersRead))
            {
                response.EnsureSuccessStatusCode();
                long? total = response.Content.Headers.ContentLength;
                await using var source = await response.Content.ReadAsStreamAsync();
                await using var file = File.Create(setup);
                var buffer = new byte[81920];
                long done = 0;
                int read;
                while ((read = await source.ReadAsync(buffer)) > 0)
                {
                    await file.WriteAsync(buffer.AsMemory(0, read));
                    done += read;
                    if (total > 0) progress.Fraction = (double)done / total.Value;
                }
            }
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or IOException or UnauthorizedAccessException)
        {
            progress.Close();
            Problem(owner, $"Mirror Wall couldn't download {release.Version}.", error.Message, offerPage: true);
            return;
        }
        progress.Close();

        Process? installer;
        try
        {
            // Asks Windows' permission now, while Mirror Wall is still open to say if it's refused.
            installer = Process.Start(new ProcessStartInfo
            {
                FileName = setup,
                Arguments = "/SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS",
                UseShellExecute = true,
                Verb = "runas",
            });
        }
        catch (Win32Exception error)
        {
            // 1223: "No" to Windows' prompt.
            if (error.NativeErrorCode != 1223) Problem(owner, $"Mirror Wall couldn't install {release.Version}.", error.Message, offerPage: true);
            return;
        }
        if (installer != null) ReopenAfter(installer);
        App.Current.Quit();
    }

    /// <summary>Opens Mirror Wall again once the installer has finished, as the signed-in user
    /// rather than as the administrator the installer runs as. If the install failed, that's the
    /// copy that was already there.</summary>
    private static void ReopenAfter(Process installer)
    {
        if (Environment.ProcessPath is not string app) return;
        string quoted = app.Replace("'", "''");
        string script = $"while (Get-Process -Id {installer.Id} -ErrorAction SilentlyContinue) {{ Start-Sleep -Milliseconds 500 }}; Start-Process '{quoted}'";
        try
        {
            Process.Start(new ProcessStartInfo("powershell.exe")
            {
                ArgumentList = { "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", script },
                UseShellExecute = false,
                CreateNoWindow = true,
            });
        }
        catch (Win32Exception)
        {
            // Mirror Wall is still updated; it just doesn't reopen by itself.
        }
    }

    private static HttpClient Client()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("MirrorWall");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    private static MessageBoxResult Message(Window? owner, string text, MessageBoxButton buttons, MessageBoxResult otherwise = MessageBoxResult.None) =>
        owner?.IsVisible == true
            ? MessageBox.Show(owner, text, "Check for Update", buttons, MessageBoxImage.Information, otherwise)
            : MessageBox.Show(text, "Check for Update", buttons, MessageBoxImage.Information, otherwise);

    private static void Problem(Window? owner, string message, string detail, bool offerPage)
    {
        string text = $"{message}\n\n{detail}";
        if (!offerPage)
        {
            Message(owner, text, MessageBoxButton.OK);
            return;
        }
        if (Message(owner, $"{text}\n\nOpen the download page instead?", MessageBoxButton.YesNo) == MessageBoxResult.Yes) OpenPage();
    }

    private static void OpenPage()
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = LatestRelease.PageUrl.AbsoluteUri, UseShellExecute = true });
        }
        catch (Win32Exception)
        {
        }
    }

    /// <summary>A small window with a progress bar while the installer downloads.</summary>
    private sealed class ProgressWindow : Window
    {
        private readonly ProgressBar bar = new() { Height = 16, IsIndeterminate = true, Margin = new Thickness(0, 10, 0, 0) };

        public ProgressWindow(string text)
        {
            Title = "Check for Update";
            Width = 360;
            SizeToContent = SizeToContent.Height;
            ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            ShowInTaskbar = false;
            var panel = new StackPanel { Margin = new Thickness(20) };
            panel.Children.Add(new TextBlock { Text = text });
            panel.Children.Add(bar);
            Content = panel;
        }

        public double Fraction
        {
            set
            {
                bar.IsIndeterminate = false;
                bar.Maximum = 1;
                bar.Value = value;
            }
        }
    }
}
