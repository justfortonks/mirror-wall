using MirrorWall.Core;

namespace MirrorWall.Core.Tests;

public class LatestReleaseTests
{
    private const string Answer = """
    {
      "tag_name": "v0.109",
      "body": "## What's new\n\n### October 14, 2026: Android app\n\n- Each release now includes\n  Mirror Wall Cast.\n- Second.\n\n## Install\n\n### Mac\n\nDownload it.",
      "assets": [
        {"name": "MirrorWall.dmg", "browser_download_url": "https://github.com/justfortonks/mirror-wall/releases/download/v0.109/MirrorWall.dmg"},
        {"name": "MirrorWall-Setup.exe", "browser_download_url": "https://github.com/justfortonks/mirror-wall/releases/download/v0.109/MirrorWall-Setup.exe"}
      ]
    }
    """;

    [Fact]
    public void ReadsGitHubsAnswer()
    {
        var release = LatestRelease.Parse(Answer, "MirrorWall-Setup.exe");
        Assert.NotNull(release);
        Assert.Equal(109, release.Build);
        Assert.Equal("0.109", release.Version);
        Assert.EndsWith("/MirrorWall-Setup.exe", release.DownloadUrl?.AbsoluteUri);
        Assert.Equal("October 14, 2026: Android app\n\n• Each release now includes Mirror Wall Cast.\n• Second.", release.Notes);
        Assert.Null(LatestRelease.Parse(Answer, "Other.zip")?.DownloadUrl);
    }

    [Fact]
    public void Tags()
    {
        Assert.Equal(new BuildNumber(109), BuildNumber.FromTag("v0.109"));
        Assert.Equal(new BuildNumber(7), BuildNumber.FromTag("0.7"));
        Assert.Equal(new BuildNumber(112, 7), BuildNumber.FromTag("v0.112-beta.7"));
        Assert.Equal(new BuildNumber(112, 7), BuildNumber.FromTag("0.112-beta.7"));
        Assert.Equal("0.112 beta 7", BuildNumber.FromTag("v0.112-beta.7")?.Version);
        Assert.Null(BuildNumber.FromTag("v1.2.3"));
        Assert.Null(BuildNumber.FromTag("v0.112-rc.1"));
        Assert.Null(BuildNumber.FromTag("nightly"));
        Assert.Null(BuildNumber.FromTag(""));
        Assert.Null(LatestRelease.Parse("{}", "MirrorWall-Setup.exe"));
        Assert.Null(LatestRelease.Parse("not json", "MirrorWall-Setup.exe"));
    }

    [Fact]
    public void BetasSortBeforeTheirRelease()
    {
        Assert.True(new BuildNumber(112, 7) < new BuildNumber(112));
        Assert.True(new BuildNumber(112, 7) < new BuildNumber(112, 8));
        Assert.True(new BuildNumber(111) < new BuildNumber(112, 1));
        Assert.True(new BuildNumber(112) >= new BuildNumber(112));
    }

    [Fact]
    public void TheBetaChannelPicksTheHighestNumber()
    {
        static string Release(string tag, bool draft = false, string asset = "MirrorWall-Setup.exe") =>
            $$"""{"tag_name": "{{tag}}", "draft": {{(draft ? "true" : "false")}}, "body": "", "assets": [{"name": "{{asset}}", "browser_download_url": "https://example.com/{{tag}}/{{asset}}"}]}""";
        string list = "[" + string.Join(",", Release("v0.111"), Release("v0.113-beta.9", draft: true), Release("v0.112-beta.7"),
            Release("v0.112-beta.8", asset: "MirrorWall.dmg"), Release("v0.110")) + "]";
        var newest = LatestRelease.Parse(list, "MirrorWall-Setup.exe", UpdateChannel.Beta);
        Assert.NotNull(newest);
        Assert.Equal(new BuildNumber(112, 7), newest.Number);
        Assert.Equal("https://example.com/v0.112-beta.7/MirrorWall-Setup.exe", newest.DownloadUrl?.AbsoluteUri);
        Assert.Null(LatestRelease.Parse(list, "MirrorWall-Setup.exe", UpdateChannel.Stable)); // Stable reads a single release
    }
}
