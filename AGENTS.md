# Mirror Wall agent guidance

Instructions for coding agents (and people using them) working in this repository.

## Project context

This is a fork of justfortonks/mirror-wall, developed with its author. Work happens on **`cody-changes`**.
`main` mirrors upstream and must not be committed to. Read [PRODUCT.md](PRODUCT.md) and
[DESIGN.md](DESIGN.md) before UI work, and [docs/CURRENT_FOCUS.md](docs/CURRENT_FOCUS.md) before
starting anything new.

- Mac app: Swift 5.9+, SwiftUI/AppKit, Swift Package (`Package.swift`), macOS 14 minimum in the
  package.
- Android app: Kotlin, `android/`, app ID `com.justfortonks.mirrorwall.cast` (upstream's: one
  Mirror Wall Cast on every device, whichever repo built it).
- Windows app: C#/WPF in `windows/`, upstream only.

## Repository structure

- `Sources/MirrorCore` is platform-free and fully unit-tested: put logic here (layout, bezel
  geometry, presets, protocol parsing, session policy).
- `Sources/MirrorWall` is the app: views, windows, receivers, recording, Syphon.
- `Tests/MirrorCoreTests`, `Tests/MirrorWallTests`.
- `patches/` and `scripts/build-uxplay.sh`: the patched UxPlay receiver.

## Building and testing

Swift only builds on macOS. From a Linux container, push a branch and build on the Mac.

```sh
swift build && swift test
scripts/build-app.sh
```

Android builds anywhere with Java 17 and the Android SDK:

```sh
cd android && MIRROR_WALL_BUILD=$(git rev-list --count HEAD) ./gradlew --no-daemon assembleRelease
```

Android unit tests need `org.json` on the test classpath and may not resolve offline; build
`assembleRelease` at minimum.

Testing on a handheld over USB: adb 37.0.1 crashes on macOS 27 as soon as a phone is attached
("libunwind: stepWithCompactEncoding"); platform-tools 36.0.0 works
(`~/Library/Android/adb-older/platform-tools/adb` on the Mac mini). Zebra HC50s need USB
debugging on and the USB mode set to File transfer.

## Installing a local build on the Mac

`scripts/build-app.sh` without a built `Vendor/` receiver produces an app without its receiver.
Copy it from the installed app, re-sign, and replace:

```sh
cp -R ~/Applications/"Mirror Wall.app"/Contents/Resources/receiver MirrorWall.app/Contents/Resources/
codesign --force --sign - MirrorWall.app
osascript -e 'tell application "Mirror Wall" to quit'
rm -rf ~/Applications/"Mirror Wall.app" && ditto MirrorWall.app ~/Applications/"Mirror Wall.app"
open ~/Applications/"Mirror Wall.app"
```

## Bringing in upstream changes

1. `git fetch upstream` and branch from `cody-changes` (for example `merge-upstream`).
2. Merge `upstream/main`. Expect conflicts in bezels, `Slot.swift`, `SyphonFeed.swift`,
   `LatestRelease.swift`, `Package.swift` and `CHANGELOG.md`.
3. Keep both sides where possible. Never take upstream's release URLs.
4. Build, test and install on the Mac; have Cody check it on screen.
5. Fast-forward `cody-changes` only after that.

## Do not break

- Release URLs in `Sources/MirrorCore/LatestRelease.swift` point at `yurtbeer/mirror-wall`.
- Android `applicationId` is `com.justfortonks.mirrorwall.cast`.
- No company branding or marks: the look is Mirror Wall's own (DESIGN.md, the design system).
- `Package.swift` resources: `AppIcon.png`, `Brand`, `Bezels`. `scripts/build-app.sh` copies Brand
  and Bezels into the app; keep both in step.
- Presenter intent (hidden, frozen) must survive reconnects.

## Conventions

- Add a `CHANGELOG.md` entry for anything a user will notice; newest first, dated headings.
- Update [docs/DELIVERY_LOG.md](docs/DELIVERY_LOG.md) and
  [docs/CURRENT_FOCUS.md](docs/CURRENT_FOCUS.md) when a piece of work lands.
- Record lasting decisions as ADRs in `docs/adr/`.
- Keep commits narrow: branding, behavior, Android and docs in separate commits where possible.
- Plain, user-facing wording in UI copy and docs (see DESIGN.md copy rules).
