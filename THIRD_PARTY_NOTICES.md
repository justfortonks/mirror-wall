# Mirror Wall: licences and source code

Mirror Wall is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License, version 3 (the `LICENSE` file, also inside the app at
`Mirror Wall.app/Contents/Resources/LICENSE`, and `LICENSE.txt` in the Windows version's
install folder). It comes with no warranty.

Mirror Wall's source code, including the changes it makes to UxPlay, is at
<https://github.com/justfortonks/mirror-wall>. Each release on that page also carries the exact
UxPlay source its receiver was built from (`UxPlay-source-<commit>.tar.gz`; the Windows
receiver also has `uxplay-windows.patch`, included in that archive, applied on top). If you were given
the app some other way and can't reach that page, ask whoever gave it to you for the source:
under the GPL they must provide it.

The app icon was made for Mirror Wall by its author and is covered by the same licence.

Mirror Wall is not affiliated with or endorsed by Apple. AirPlay and iPhone are trademarks of
Apple Inc.

The phone frames for the Zebra HC50, Honeywell CT37 and Spectralink Versity 95/96 and 97
(`Sources/MirrorWall/Resources/Bezels`) are cut from the makers' own product photographs, with
the printed brand names removed; those photographs remain their owners'. Mirror Wall is not
affiliated with or endorsed by Zebra Technologies, Honeywell or Spectralink, whose names and
product names are their trademarks.

## What the app includes

### Barlow typeface (SIL Open Font License 1.1)

The Barlow font files in `Contents/Resources/Brand` are Copyright 2017 The Barlow Project
Authors (<https://github.com/jpt/barlow>), licensed under the SIL Open Font License 1.1; the full
licence is `Contents/Resources/Brand/OFL.txt`.

### UxPlay (GNU GPL v3)

The AirPlay receiver inside the app (`Contents/Resources/receiver/bin/uxplay`) is
[UxPlay](https://github.com/FDH2/UxPlay) by the UxPlay developers, built from commit
`ec203121355220dd90278a369eeabb0b8ba4f14a` with the three patches in this repository's
`patches/` folder applied (`scripts/build-uxplay.sh` does exactly that). UxPlay is licensed
under the GNU GPL v3 and includes code from RPiPlay (GPL v3), ShairPlay and AirplayServer
(LGPL v2.1 or later), PlayFair (GPL) and llhttp (MIT); see UxPlay's README for details.

Because the app ships UxPlay, Mirror Wall as a whole is distributed under the GPL v3.

### GStreamer and the libraries it loads (mostly LGPL)

The receiver carries the parts of [GStreamer](https://gstreamer.freedesktop.org) (LGPL v2.1 or
later) it needs, and the libraries those load, among them GLib (LGPL v2.1 or later), FFmpeg
(through GStreamer's libav plugin), OpenSSL 3 (Apache 2.0) and libplist (LGPL v2.1 or later).
They are the unmodified builds from [Homebrew](https://brew.sh). The exact list, with each
library's version and licence, and the licence files themselves, are inside the app in
`Contents/Resources/receiver/licenses/`. Their source is available from each project's homepage
(listed there) and from Homebrew.

They are separate dynamic libraries: you can replace any of them in
`Contents/Resources/receiver/lib/` with your own build.

### Syphon (BSD licence)

The OBS feed uses the [Syphon framework](https://github.com/Syphon/Syphon-Framework),
`Contents/Frameworks/Syphon.framework`, built from commit
`f4761677a45b8034a3c2069ec0f3d2553da81fba`. Its licence:

```
Copyright 2010 bangnoise (Tom Butterworth) & vade (Anton Marini).
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

* Neither the name of the Syphon Project nor the names of its contributors
may be used to endorse or promote products derived from this software
without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## The Windows version

The Windows version (`MirrorWall-Setup.exe`, installed to `C:\Program Files\Mirror Wall`) is
covered by the same licence and carries the same UxPlay, built for Windows with
`windows/receiver/build-uxplay.sh`, which applies `windows/receiver/uxplay-windows.patch` on top
of the patches above.

- **GStreamer, FFmpeg and the libraries they load** (mostly LGPL v2.1 or later) are the
  unmodified builds from [MSYS2](https://www.msys2.org) (UCRT64). `receiver\licenses\packages.txt`
  lists the MSYS2 package and version each one came from, with each package's licence files
  beside it; their source is on MSYS2's package pages. They are separate DLLs in the `receiver`
  folder that you can replace with your own builds. The app itself decodes and records with the
  same FFmpeg DLLs, through [FFmpeg.AutoGen](https://github.com/Ruslan-B/FFmpeg.AutoGen) (LGPL v3).
- **Spout2** (BSD 2-clause licence, `Spout2-LICENSE.txt` in the install folder): the OBS feed's
  `MirrorSpout.dll` is built from [Spout2](https://github.com/leadedge/Spout2) release 2.007.018.
- **.NET** (MIT licence): the app includes Microsoft's .NET runtime and WPF.
