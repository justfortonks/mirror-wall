# Mirror Wall

View up to eight iPhone and Android phone screens together on a Mac or Windows PC. Keep them in a tiled wall, focus on one phone, or open individual screens in separate windows.

iPhones connect through built-in AirPlay Screen Mirroring. Android phones use the Mirror Wall Cast companion app. Mirror Wall supports screenshots and video recording; it does not control phones or capture audio.

## Download

| Platform | Download | Requirements |
|---|---|---|
| macOS | [MirrorWall.dmg](https://github.com/justfortonks/mirror-wall/releases/latest/download/MirrorWall.dmg) | Apple Silicon, macOS 26 or later |
| Windows | [MirrorWall-Setup.exe](https://github.com/justfortonks/mirror-wall/releases/latest/download/MirrorWall-Setup.exe) | Windows 10 version 1809 or later, or Windows 11; x64 build |
| Android (Mirror Wall Cast) | [MirrorWallCast.apk](https://github.com/justfortonks/mirror-wall/releases/latest/download/MirrorWallCast.apk) | Android 10 or later |

These requirements apply to the packaged releases.

**Mac:** Open the DMG and drag Mirror Wall to Applications. The app is ad-hoc signed and not notarized. If macOS blocks opening it, use System Settings → Privacy & Security → **Open Anyway**. Allow local-network access when prompted.

**Windows:** Run the installer. It is unsigned, so SmartScreen may show a warning. Installation requires administrator access to add firewall rules. It works on Private and Public networks. See the [Windows guide](windows/README.md) for details.

**Updating:** Mirror Wall › Check for Update… on a Mac, or Help › Check for Update… on Windows (also in the menu bar or notification area icon's menu), downloads the newest release, installs it and reopens Mirror Wall. It only checks when you ask. Settings › General › Updates can switch it to Beta, which also offers test builds (published as pre-releases). A Mac doesn't need Open Anyway again for an update installed this way; Windows asks once to let the installer make changes.

## Connect your phones

Keep the computer and phones on the same local network, with device-to-device communication allowed.

### iPhone

1. Open Mirror Wall.
2. On the iPhone, open **Control Center → Screen Mirroring**.
3. Choose an available Mirror Wall slot.
4. Repeat with a different slot for each phone.

Nothing needs to be installed on the iPhone.

### Android

Requires Android 10 or later.

1. Install [MirrorWallCast.apk](https://github.com/justfortonks/mirror-wall/releases/latest/download/MirrorWallCast.apk) from the latest release (allow installing from your browser or file manager when asked), or deploy it with your device management.
2. Open the app and choose an available slot.
3. Approve Android’s screen-sharing prompt.

If no slots appear, enter the computer’s address manually. Slot 1 uses port `7350`, slot 2 uses `7450`, and each following slot adds `100`.

Android builds use a public test signing key unless a separate signing key is configured, so each new version installs over the last one. Test builds between releases are under the **MirrorWallCast** artifact of an [Android workflow run](https://github.com/justfortonks/mirror-wall/actions/workflows/android.yml) (needs a GitHub sign-in; artifacts expire after 90 days).

iPhones and Android phones can share the wall at the same time, with one phone per slot.

## Using Mirror Wall

- **Add a slot:** Click **+** or right-click an empty area of the wall. The app starts with two slots and supports up to eight.
- **Focus on one phone:** Double-click its picture; double-click again to return to the wall.
- **Open a separate window:** Click the arrow on a tile or choose **Open in Own Window** from its **⋯** menu. Adjust sizing under **View → Pop-out Window Size**.
- **Take a screenshot or record:** Use the camera and record buttons, or the tile’s menu. Files go to `Documents/MirrorWall/Screenshots` and `Documents/MirrorWall/Recordings` by default; change these in Settings.
- **Customize a slot:** Rename it or choose a standby picture from the **⋯** menu; its **Troubleshooting** submenu shows the log and restarts the receiver.
- **Phone bezels:** Draw a phone-shaped frame around every slot from Settings → **Wall** → **Phone bezels**, or around one slot from its **⋯** menu → **Phone Bezel** → **On the Wall and Own Window**. **Phone Bezel** → **In the OBS Feed** sends OBS the framed phone, with see-through corners, whether or not the wall shows it. Recordings and screenshots stay unframed.
- **Menu bar or tray icon:** Lists every slot and its status. While it's shown, closing the wall leaves Mirror Wall running; quit from the icon's menu. Turn it off in Settings.
- **Staying awake:** The computer and its screen stay awake while a phone is mirroring or a slot is recording. Turn this off in Settings.
- **Adjust the picture:** The View menu includes frame-rate limits, **Smoother Motion**, **Sharper Picture (H.265)**, and **Stats for Nerds**.

Recordings contain video only. Rotation or reconnection can start a new recording file.

For how each feature behaves in detail, see [Mirror Wall in detail](docs/details.md).

## Optional OBS output

Each slot can publish video directly through **Syphon on macOS** or **Spout on Windows**, without opening a separate window.

Enable **Send to OBS** in the tile’s menu. In OBS, add a **Syphon Client** source on Mac or a **Spout2 Capture** source on Windows. Windows requires the [Spout2 plugin](https://github.com/Off-World-Live/obs-spout2-plugin).

## Limitations

- No remote control, audio, or USB mirroring.
- Protected content may appear black or be unavailable.
- iOS ends Screen Mirroring about a minute after the iPhone's screen turns off, and only the phone can start it again. To keep an iPhone on the wall, set **Settings → Display & Brightness → Auto-Lock** to **Never** and keep it charging. Otherwise, reconnect from Screen Mirroring.
- Performance depends on the network, computer, phone, and number of active streams. Selecting 60 fps requests a maximum, not a guaranteed frame rate.
- Smoother Motion adds some delay; higher picture quality can increase bandwidth and processing requirements.

## Development

The macOS app uses SwiftUI/AppKit, the Windows app uses C#/WPF, and Mirror Wall Cast uses Kotlin. iPhone mirroring uses [UxPlay](https://github.com/FDH2/UxPlay) with GStreamer; Android uses the [Mirror Wall Cast protocol](docs/mirror-wall-cast.md).

Build and test configuration:

- [Building the Mac app](docs/building-mac.md): how it works, the UxPlay patches, and the build scripts
- [macOS release workflow](.github/workflows/release.yml) and [build scripts](scripts/)
- [Windows development guide](windows/README.md)
- [Android build workflow](.github/workflows/android.yml)

Add an entry to [CHANGELOG.md](CHANGELOG.md) for any change people will notice; the About box and each release's notes come from it.

To publish a release, open **Actions → Release → Run workflow** with **Publish** ticked. It builds the Mac DMG, the Windows installer and the Android APK on GitHub's machines and publishes them as release `v0.<build number>`, with the exact UxPlay source attached.

## License

Mirror Wall is licensed under [GNU GPL v3](LICENSE). See [Third-party notices](THIRD_PARTY_NOTICES.md) for bundled components and source information.

Mirror Wall is not affiliated with Apple. AirPlay and iPhone are Apple trademarks.
