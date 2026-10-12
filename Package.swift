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
        resources: [.copy("Resources/AppIcon.png")],
        linkerSettings: hasSyphon ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])] : []
    ),
    .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore"]),
]
if hasSyphon {
    targets.append(.binaryTarget(name: "Syphon", path: syphonPath))
}

let package = Package(
    name: "MirrorWall",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MirrorWall", targets: ["MirrorWall"]),
    ],
    targets: targets
)
