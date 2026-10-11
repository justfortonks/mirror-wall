// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MirrorWall",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MirrorWall", targets: ["MirrorWall"]),
    ],
    targets: [
        // Platform-independent pieces: RTP parsing, H.264 reassembly, slot settings.
        .target(name: "MirrorCore"),
        // The macOS app: runs one uxplay receiver per slot and shows each phone in a tile.
        .executableTarget(name: "MirrorWall", dependencies: ["MirrorCore"]),
        .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore"]),
    ]
)
