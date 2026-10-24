// swift-tools-version:5.9
import Foundation
import PackageDescription

// The OBS feed (Syphon) is built in when Vendor/Syphon.xcframework exists; scripts/build-syphon.sh
// makes it. Without it the app builds and runs as before, minus that one menu item.
let syphonPath = "Vendor/Syphon.xcframework"
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasSyphon = FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent(syphonPath).path)

var targets: [Target] = [
    // Platform-independent pieces: RTP parsing, H.264 reassembly, slot settings.
    .target(name: "MirrorCore"),
    // The macOS app: runs one uxplay receiver per slot and shows each phone in a tile.
    .executableTarget(
        name: "MirrorWall",
        dependencies: ["MirrorCore"] + (hasSyphon ? ["Syphon"] : []),
        resources: [.copy("Resources/AppIcon.png"), .copy("Resources/Brand"), .copy("Resources/Bezels")],
        linkerSettings: hasSyphon ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])] : []
    ),
    .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore"]),
    .testTarget(name: "MirrorWallTests", dependencies: ["MirrorWall"]),
]
if hasSyphon {
    targets.append(.binaryTarget(name: "Syphon", path: syphonPath))
}

let package = Package(
    name: "MirrorWall",
    // iOS for MirrorCore only: the iPhone app (ios/) links it for the Cast protocol and ConnectLink.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "MirrorWall", targets: ["MirrorWall"]),
        .library(name: "MirrorCore", targets: ["MirrorCore"]),
    ],
    targets: targets
)
