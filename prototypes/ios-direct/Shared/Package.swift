// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IOSDirectShared",
    platforms: [.iOS("27.0"), .macOS(.v14)],
    products: [.library(name: "IOSDirectShared", targets: ["IOSDirectShared"])],
    targets: [
        .target(name: "IOSDirectShared"),
        .testTarget(name: "IOSDirectSharedTests", dependencies: ["IOSDirectShared"])
    ]
)
