using System.Text;
using System.Text.Json;

namespace MirrorWall.Core;

/// <summary>Which releases Check for Update offers: Stable only offers the newest regular release;
/// Beta lets you choose between it and every test build published as a GitHub pre-release (tagged
/// v0.N-beta.K). A test build withdrawn with .github/workflows/beta-builds.yml becomes a draft,
/// which GitHub doesn't list to the app.</summary>
public enum UpdateChannel { Stable, Beta }

/// <summary>A build's place in line: its build number (the commit count, as in the version "0.N")
/// and, for a beta, its beta number. A release outranks a beta with the same build number. The
/// same as the Mac app's BuildNumber.</summary>
public readonly record struct BuildNumber(int Build, int? Beta = null) : IComparable<BuildNumber>
{
    /// <summary>"0.112" or "0.112 beta 7".</summary>
    public string Version => Beta is int beta ? $"0.{Build} beta {beta}" : $"0.{Build}";

    /// <summary>"v0.109" → 0.109; "v0.112-beta.7" → 0.112 beta 7. Also reads the app's own
    /// version, "0.112-beta.7".</summary>
    public static BuildNumber? FromTag(string tag)
    {
        string[] parts = tag.TrimStart('v').Split('-', 2);
        string[] numbers = parts[0].Split('.');
        if (numbers.Length != 2 || numbers[0] != "0" || !int.TryParse(numbers[1], out int build)) return null;
        if (parts.Length == 1) return new BuildNumber(build);
        return parts[1].StartsWith("beta.") && int.TryParse(parts[1][5..], out int beta) ? new BuildNumber(build, beta) : null;
    }

    public int CompareTo(BuildNumber other) =>
        Build != other.Build ? Build.CompareTo(other.Build) : (Beta ?? int.MaxValue).CompareTo(other.Beta ?? int.MaxValue);

    public static bool operator <(BuildNumber a, BuildNumber b) => a.CompareTo(b) < 0;
    public static bool operator >(BuildNumber a, BuildNumber b) => a.CompareTo(b) > 0;
    public static bool operator <=(BuildNumber a, BuildNumber b) => a.CompareTo(b) <= 0;
    public static bool operator >=(BuildNumber a, BuildNumber b) => a.CompareTo(b) >= 0;
}

/// <summary>
/// The newest Mirror Wall release on GitHub, as Check for Update sees it: its number, its "What's
/// new" notes and the download for this computer. The same as the Mac app's LatestRelease.
/// </summary>
/// <param name="Title">For a test build, what it's for: the part of its GitHub title after
/// "Mirror Wall 0.N beta K: ".</param>
/// <param name="Published">When GitHub published it.</param>
public sealed record LatestRelease(BuildNumber Number, string Notes, Uri? DownloadUrl, string Title = "", DateTimeOffset? Published = null)
{
    /// <summary>The releases page, for when the app can't install it itself.</summary>
    public static readonly Uri PageUrl = new("https://github.com/justfortonks/mirror-wall/releases");
    /// <summary>GitHub's description of the newest regular release (not a pre-release or draft).</summary>
    public static readonly Uri ApiUrl = new("https://api.github.com/repos/justfortonks/mirror-wall/releases/latest");
    /// <summary>GitHub's recent releases, pre-releases (betas) included, newest first.</summary>
    public static readonly Uri ListUrl = new("https://api.github.com/repos/justfortonks/mirror-wall/releases?per_page=100");

    public static Uri UrlFor(UpdateChannel channel) => channel == UpdateChannel.Beta ? ListUrl : ApiUrl;

    public int Build => Number.Build;
    public string Version => Number.Version;

    /// <summary>What the Beta channel offers from GitHub's list (<see cref="ListUrl"/>): every test
    /// build that has <paramref name="asset"/>, most recently built first (by beta number, which
    /// counts up across branches, unlike the build number), then the newest regular release.
    /// Drafts are left out.</summary>
    public static List<LatestRelease> Choices(string json, string asset)
    {
        var releases = new List<LatestRelease>();
        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Array) return releases;
            foreach (var item in document.RootElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) continue;
                if (item.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True) continue;
                if (Read(item, asset) is { DownloadUrl: not null } release) releases.Add(release);
            }
        }
        catch (JsonException)
        {
            return new List<LatestRelease>();
        }
        var choices = releases.Where(release => release.Number.Beta != null).OrderByDescending(release => release.Number.Beta).ToList();
        if (releases.Where(release => release.Number.Beta == null).MaxBy(release => release.Number) is { } newest) choices.Add(newest);
        return choices;
    }

    /// <summary>"Mirror Wall 0.123 beta 48: Rename a slot's OBS feed" → "Rename a slot's OBS feed";
    /// "" for a title without that part.</summary>
    public static string TitleIn(string name)
    {
        int colon = name.IndexOf(": ", StringComparison.Ordinal);
        return name.StartsWith("Mirror Wall ", StringComparison.Ordinal) && colon >= 0 ? name[(colon + 2)..].Trim() : "";
    }

    /// <summary>Reads GitHub's answer for the newest release; <paramref name="asset"/> is the
    /// download wanted, e.g. "MirrorWall-Setup.exe". Null if it isn't a release this app can
    /// compare itself with.</summary>
    public static LatestRelease? Parse(string json, string asset)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            return document.RootElement.ValueKind == JsonValueKind.Object ? Read(document.RootElement, asset) : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static LatestRelease? Read(JsonElement root, string asset)
    {
        try
        {
            if (!root.TryGetProperty("tag_name", out var tag) || tag.ValueKind != JsonValueKind.String
                || BuildNumber.FromTag(tag.GetString()!) is not BuildNumber number) return null;
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
            string releaseName = root.TryGetProperty("name", out var title) && title.ValueKind == JsonValueKind.String ? title.GetString()! : "";
            DateTimeOffset? published = root.TryGetProperty("published_at", out var date) && date.ValueKind == JsonValueKind.String
                && DateTimeOffset.TryParse(date.GetString(), System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out var parsedDate)
                ? parsedDate : null;
            return new LatestRelease(number, WhatsNew(body), download, TitleIn(releaseName), published);
        }
        catch (InvalidOperationException)
        {
            return null; // a field of the wrong kind
        }
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
