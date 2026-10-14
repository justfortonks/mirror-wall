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
        Assert.Equal(109, LatestRelease.BuildFromTag("v0.109"));
        Assert.Equal(7, LatestRelease.BuildFromTag("0.7"));
        Assert.Null(LatestRelease.BuildFromTag("v1.2.3"));
        Assert.Null(LatestRelease.BuildFromTag("nightly"));
        Assert.Null(LatestRelease.Parse("{}", "MirrorWall-Setup.exe"));
        Assert.Null(LatestRelease.Parse("not json", "MirrorWall-Setup.exe"));
    }
}
