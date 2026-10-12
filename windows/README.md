# Mirror Wall for Windows

The Windows version of Mirror Wall: the same tile wall of mirrored iPhones, each slot's own
window for OBS, and an OBS feed per slot (Spout instead of the Mac's Syphon). It's a separate
app from the Mac one, written in C# with WPF, and it uses the same receiver (UxPlay with Mirror
Wall's patches) built for Windows.

## Install

**[Download MirrorWall-Setup.exe](https://github.com/justfortonks/mirror-wall/releases/latest/download/MirrorWall-Setup.exe)**
(the newest release; all of them are on the [Releases](https://github.com/justfortonks/mirror-wall/releases)
page) and run it. Test builds from pull requests are on the Actions tab: open a **Windows** run
and download **MirrorWall-Setup** from the bottom of the page.

1. Windows SmartScreen may say it protected your PC, because the installer isn't signed. Click
   **More info**, then **Run anyway**. This is needed once per installer.
2. The installer asks for administrator rights to add a Windows Firewall rule that lets iPhones
   reach the receiver on home and work networks.
3. The PC's network must be set to **Private** (Settings › Network & internet › Wi-Fi or
   Ethernet › the network › Network profile type). On a Public network, Windows blocks phones
   from finding Mirror Wall.

Then on the iPhone: Control Center › Screen Mirroring › **Mirror Wall 1 · &lt;PC name&gt;**.

## OBS

Each slot can feed OBS two ways:

- **Its own window.** Click the arrow at a tile's top right. Add a **Window Capture** source in
  OBS and pick `[MirrorWall.exe]: MacMirror-<phone>`. Set its Capture Method to **Windows 10
  (1903 and up)**.
- **Spout**, which works with Mirror Wall minimized. Install the
  [Spout2 plugin for OBS](https://github.com/Off-World-Live/obs-spout2-plugin), tick **Send to
  OBS (Spout)** in the tile's ⋯ menu, then add a **Spout2 Capture** source and pick
  `MacMirror-<phone>`. While no phone is mirroring, the feed shows the slot's standby picture.
  Mirror Wall looks for the plugin the first time it opens, and again when a feed is turned on,
  and offers its download page if it's missing.

## How it's built

Releases come from `.github/workflows/release.yml` (Actions › **Release** › Run workflow, with
Publish ticked), which builds the Mac DMG and, through this workflow, the installer, and attaches
both to one release.

`.github/workflows/windows.yml` runs on every change under `windows/` or `patches/`:

1. **receiver**: builds uxplay in MSYS2 (UCRT64) with the patches in `patches/` and
   `windows/receiver/uxplay-windows.patch`, then packages it with the GStreamer plugins and the
   libraries it needs (`windows/receiver/build-uxplay.sh`), and starts two receivers to check they
   come up (`smoke-test.ps1`).
2. **app**: runs the stream logic's tests, builds `MirrorSpout.dll` (Spout2's SpoutDX, wrapped in
   `windows/MirrorSpout`), publishes the app with .NET's runtime included, puts the receiver in
   its `receiver` folder, and makes `MirrorWall-Setup.exe` with Inno Setup.

The app decodes and records with the FFmpeg libraries that come with the receiver. Builds are
numbered 0.&lt;commit count&gt;, like the Mac's; Help › About shows the commit and date.

| Folder | What |
|--------|------|
| `MirrorCore` | Stream logic shared with the tests: RTP, reassembling frames, timing, receiver output, slot settings |
| `MirrorCore.Tests` | Its tests (`dotnet test windows/MirrorCore.Tests`, runs on any OS) |
| `MirrorWall` | The app (WPF). Builds on Linux or a Mac for checking, runs only on Windows |
| `MirrorSpout` | The Spout sender DLL |
| `receiver` | uxplay's Windows build and its Windows patch |
| `installer` | The Inno Setup script |

Settings are in `%APPDATA%\Mirror Wall\settings.json`. Logs (`slot-N.log`, and `crash.log` if
something went wrong) are in `%LOCALAPPDATA%\Mirror Wall\Logs`.
