# Results ledger

**Verified (local command evidence), 2026-10-16:** G0 run 0 only. No capture, radio, pairing, performance or integrated acceptance runs exist. Future runs append rows with links to sanitized evidence; private device IDs, keys, tokens and screen content stay outside Git.

| Run / date | Revision / branch / config | Devices / OS / SDK / signing | Topology / radio / accounts | Media / steps / duration | Expected | Actual / metrics / status | Evidence / limitations |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 / 2026-10-16 | `70e2f1a1d48ca65ea26fc2a0592760eb543795b3`; `feat/ios-direct-poc`; root SwiftPM default debug; initial clean tree | User-supplied MacBook Air M5; local macOS 27.0.1 (26A434), Xcode 27.1 (27A9275), Swift 6.4; Mac SDK 27.0, iPhoneOS SDK 27.1; no signing reached | Local shell only; radios/accounts not exercised | No media; requested status/build/test pipeline once; tool elapsed 3.69 s (per-command timing not captured) | Build completes, tests execute, baseline recorded | **Blocked** at manifest sandbox evaluation for build and test; 0 tests executed, pass/fail counts unavailable; no product build or tests passed | Verbatim fatal diagnostics below; pipeline exit 0 belongs to tail. No alternate cache/sandbox flags, fixes or retries. |

## Run 0 command and output

Working directory: `/Users/thomas/Documents/Claude Code/Mirror-wall POC`.

```sh
git status --porcelain && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30
```

Initial status output was empty. Both commands emitted the same three cache warnings:

```text
warning: /Users/thomas/Library/org.swift.swiftpm/configuration is not accessible or not writable, disabling user-level cache features.
warning: /Users/thomas/Library/org.swift.swiftpm/security is not accessible or not writable, disabling user-level cache features.
warning: /Users/thomas/Library/Caches/org.swift.swiftpm is not accessible or not writable, disabling user-level cache features.
```

Build diagnostic (verbatim):

```text
error: 'mirror-wall poc': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vn/w0gkmgxn1g7gspgm_n1dp_540000gn/T/TemporaryDirectory.CPODkx/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "5", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-package-description-version", "5.9.0", "/Users/thomas/Documents/Claude Code/Mirror-wall POC/Package.swift", "-o", "/var/folders/vn/w0gkmgxn1g7gspgm_n1dp_540000gn/T/TemporaryDirectory.G0xQPP/mirror-wall poc-manifest"])
sandbox-exec: sandbox_apply: Operation not permitted
```

Test diagnostic (verbatim):

```text
error: 'mirror-wall poc': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vn/w0gkmgxn1g7gspgm_n1dp_540000gn/T/TemporaryDirectory.YO2hFM/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "5", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-package-description-version", "5.9.0", "/Users/thomas/Documents/Claude Code/Mirror-wall POC/Package.swift", "-o", "/var/folders/vn/w0gkmgxn1g7gspgm_n1dp_540000gn/T/TemporaryDirectory.3I1qOr/mirror-wall poc-manifest"])
sandbox-exec: sandbox_apply: Operation not permitted
```

The requested pipeline returned **0** because it did not enable pipefail and both `tail` processes succeeded. Individual Swift command exit codes were not preserved by that command; their diagnostics establish failure before target build/test execution. Static source has 80 test method declarations, which is not an executed test result. This environment failure was not repaired or classified as a product defect.

Final scope check: `git status --porcelain --untracked-files=all` lists exactly the six new Markdown files under `docs/ios-direct/`; no tracked changes elsewhere. No prototype directory was created. SDK/device command outputs are recorded in feasibility.md; they are not fabricated hardware-result rows.

## Run 0b — baseline rerun outside the Codex sandbox (Claude, 2026-10-16)

Same revision `70e2f1a`, same worktree, run by Claude in a normal shell.

| Command | Result |
| --- | --- |
| `swift build` | **Pass** — `Build complete!` |
| `swift test` | **Pass** — XCTest: 80 tests executed, 0 failures. (Swift Testing: 0 tests, as expected.) |

Run 0's failure was the Codex sandbox, not the project. This is the accepted G0 baseline.
