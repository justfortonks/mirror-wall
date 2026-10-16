using System.ComponentModel;
using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>
/// Help › Check for Update…: compares this copy with the newest release on GitHub (or, on the Beta
/// channel, lets you choose a test build or the newest release) and, when asked, downloads its
/// installer and runs it quietly; Mirror Wall closes, and opens again once the
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

    /// <summary>This copy's number, from the version the Windows workflow gives it
    /// ("0.112-beta.7+commit.date"); null for a build made outside the workflow (version 0.0).</summary>
    internal static BuildNumber? Current
    {
        get
        {
            string full = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "";
            return BuildNumber.FromTag(full.Split('+')[0]) is { Build: > 0 } number ? number : null;
        }
    }

    private static UpdateChannel Channel => Settings.Current.BetaUpdates ? UpdateChannel.Beta : UpdateChannel.Stable;

    public static async void Check(Window? owner)
    {
        if (busy) return;
        busy = true;
        try
        {
            var channel = Channel;
            string json;
            try
            {
                using var client = Client();
                json = await client.GetStringAsync(LatestRelease.UrlFor(channel));
            }
            catch (Exception error) when (error is HttpRequestException or TaskCanceledException)
            {
                Problem(owner, "Mirror Wall couldn't check for an update.", error.Message, offerPage: false);
                return;
            }
            if (channel == UpdateChannel.Beta)
            {
                var choices = LatestRelease.Choices(json, "MirrorWall-Setup.exe");
                if (choices.Count == 0)
                {
                    Problem(owner, "Mirror Wall couldn't check for an update.", "GitHub didn't list a release or test build Mirror Wall could read.", offerPage: false);
                    return;
                }
                if (Choose(owner, choices) is { } chosen) await Install(owner, chosen);
                return;
            }
            if (LatestRelease.Parse(json, "MirrorWall-Setup.exe") is not { } release)
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
        bool installable = Current != null && release.DownloadUrl != null;
        string newest = "the newest release";
        if (Current is BuildNumber current && current >= release.Number)
        {
            string have = current == release.Number
                ? $"You have {release.Version}, {newest}."
                : $"You have {current.Version}, newer than {newest} ({release.Version}).";
            // Only when this copy is newer, e.g. a beta: offers to go back to the release.
            if (!installable || current == release.Number)
            {
                Message(owner, $"Mirror Wall is up to date. {have}", MessageBoxButton.OK);
                return false;
            }
            return Message(owner, $"Mirror Wall is up to date. {have}\n\nGo back to {release.Version}?", MessageBoxButton.YesNo, MessageBoxResult.No) == MessageBoxResult.Yes;
        }

        string notes = release.Notes.Length > 0 ? $"\n\n{release.Notes}" : "";
        if (!installable)
        {
            if (Message(owner, $"Mirror Wall {release.Version} is available.{notes}\n\nOpen its download page?", MessageBoxButton.YesNo) == MessageBoxResult.Yes)
                OpenPage();
            return false;
        }
        return Message(owner,
            $"Mirror Wall {release.Version} is available. You have {Current?.Version}.{notes}\n\n" +
            "Install it now? Mirror Wall will close, Windows will ask to let the installer make changes, and Mirror Wall opens again when it's done. Phones reconnect by themselves.",
            MessageBoxButton.YesNo) == MessageBoxResult.Yes;
    }

    /// <summary>The Beta channel: a list of every test build on offer and the newest release, to
    /// install any one of them. Null when nothing was chosen.</summary>
    private static LatestRelease? Choose(Window? owner, List<LatestRelease> choices)
    {
        var picker = new BuildPicker(choices, Current) { Owner = owner?.IsVisible == true ? owner : null };
        if (picker.ShowDialog() != true || picker.Selected is not { } chosen) return null;
        if (Current == null)
        {
            OpenPage();
            return null;
        }
        return chosen;
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

    /// <summary>The Beta channel's list of builds, with what the chosen one is below it.</summary>
    private sealed class BuildPicker : Window
    {
        private readonly ListBox list = new() { Height = 150 };
        private readonly TextBox details = new()
        {
            IsReadOnly = true,
            Height = 170,
            TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Margin = new Thickness(0, 10, 0, 0),
        };
        private readonly Button install;
        private readonly List<LatestRelease> choices;
        private readonly BuildNumber? current;

        public LatestRelease? Selected => list.SelectedIndex >= 0 ? choices[list.SelectedIndex] : null;

        public BuildPicker(List<LatestRelease> choices, BuildNumber? current)
        {
            this.choices = choices;
            this.current = current;
            Title = "Check for Update";
            Width = 520;
            SizeToContent = SizeToContent.Height;
            ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            ShowInTaskbar = false;

            string have = current is BuildNumber number ? $"You have {number.Version}." : "This copy wasn't installed by the Mirror Wall installer, so it can't replace itself.";
            var intro = new TextBlock
            {
                Text = $"Choose a Mirror Wall build. {have} Test builds are listed most recent first, then the newest release."
                    + (current != null ? " Mirror Wall will close, Windows will ask to let the installer make changes, and Mirror Wall opens again when it's done. Phones reconnect by themselves." : ""),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 10),
            };
            foreach (var release in choices) list.Items.Add(Label(release));
            list.SelectionChanged += (_, _) => ShowSelection();

            install = new Button { Content = current != null ? "Install" : "Open Download Page", IsDefault = true, Padding = new Thickness(14, 4, 14, 4) };
            install.Click += (_, _) => DialogResult = true;
            var cancel = new Button { Content = "Cancel", IsCancel = true, Padding = new Thickness(14, 4, 14, 4), Margin = new Thickness(8, 0, 0, 0) };
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
            buttons.Children.Add(install);
            buttons.Children.Add(cancel);

            var panel = new StackPanel { Margin = new Thickness(16) };
            panel.Children.Add(intro);
            panel.Children.Add(list);
            panel.Children.Add(details);
            panel.Children.Add(buttons);
            Content = panel;

            // The first one that isn't this copy.
            int first = choices.FindIndex(release => release.Number != current);
            list.SelectedIndex = first >= 0 ? first : 0;
            ShowSelection();
        }

        private string Label(LatestRelease release)
        {
            string label = release.Version;
            if (release.Number.Beta == null) label += " · newest release";
            else if (release.Title.Length > 0) label += " · " + release.Title;
            return label + (release.Number == current ? " (installed)" : "");
        }

        private void ShowSelection()
        {
            if (Selected is not { } release) return;
            var lines = new List<string> { (release.Number.Beta == null ? "Release " : "Test build ") + release.Version + (release.Title.Length > 0 ? $": {release.Title}" : "") };
            if (release.Published is DateTimeOffset published) lines.Add($"Published {published.ToLocalTime():g}");
            if (release.Number == current) lines.Add("This is the copy you have.");
            if (release.Notes.Length > 0) lines.Add(Environment.NewLine + release.Notes.Replace("\n", Environment.NewLine));
            details.Text = string.Join(Environment.NewLine, lines);
            install.IsEnabled = release.Number != current;
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
