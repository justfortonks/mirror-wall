using System.Text;
using System.Text.Json;

namespace MirrorWall.Core;

/// <summary>
/// The newest Mirror Wall release on GitHub, as Check for Update sees it: its build number (the
/// commit count, as in the app's own version "0.N"), its "What's new" notes and the download for
/// this computer. The same as the Mac app's LatestRelease.
/// </summary>
public sealed record LatestRelease(int Build, string Notes, Uri? DownloadUrl)
{
    /// <summary>The release's page, for when the app can't install it itself.</summary>
    public static readonly Uri PageUrl = new("https://github.com/justfortonks/mirror-wall/releases/latest");
    /// <summary>GitHub's description of the newest release (not a pre-release or draft).</summary>
    public static readonly Uri ApiUrl = new("https://api.github.com/repos/justfortonks/mirror-wall/releases/latest");

    public string Version => $"0.{Build}";

    /// <summary>Reads GitHub's answer for the newest release; <paramref name="asset"/> is the
    /// download wanted, e.g. "MirrorWall-Setup.exe". Null if it isn't a release this app can
    /// compare itself with.</summary>
    public static LatestRelease? Parse(string json, string asset)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (!root.TryGetProperty("tag_name", out var tag) || BuildFromTag(tag.GetString() ?? "") is not int build) return null;
            string body = root.TryGetProperty("body", out var text) && text.ValueKind == JsonValueKind.String ? text.GetString()! : "";
            Uri? download = null;
            if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in assets.EnumerateArray())
                {
                    if (item.TryGetProperty("name", out var name) && name.GetString() == asset
                        && item.TryGetProperty("browser_download_url", out var url)
                        && Uri.TryCreate(url.GetString(), UriKind.Absolute, out var parsed))
                    {
                        download = parsed;
                        break;
                    }
                }
            }
            return new LatestRelease(build, WhatsNew(body), download);
        }
        catch (JsonException)
        {
            return null;
        }
        catch (InvalidOperationException)
        {
            return null; // a field of the wrong kind
        }
    }

    /// <summary>"v0.109" → 109.</summary>
    public static int? BuildFromTag(string tag)
    {
        string[] parts = tag.TrimStart('v').Split('.');
        return parts.Length == 2 && parts[0] == "0" && int.TryParse(parts[1], out int build) ? build : null;
    }

    /// <summary>The release notes' "What's new" section (what .github/workflows/release.yml
    /// writes before "## Install"), with markdown headings and bullets turned into plain text.</summary>
    public static string WhatsNew(string body)
    {
        var lines = new List<string>();
        foreach (string line in body.Replace("\r\n", "\n").Split('\n'))
        {
            string text = line.Trim();
            if (text.StartsWith("## "))
            {
                if (text == "## What's new") continue;
                break;
            }
            if (text.StartsWith("### ")) lines.Add(text[4..]);
            else if (text.StartsWith("- ")) lines.Add("• " + text[2..]);
            else if (text.Length > 0 && lines.Count > 0 && lines[^1].Length > 0) lines[^1] += " " + text;
            else lines.Add(text);
        }
        return string.Join("\n", lines).Replace("\n\n\n", "\n\n").Trim();
    }
}
