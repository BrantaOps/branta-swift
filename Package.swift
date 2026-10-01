// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Branta",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "Branta", targets: ["Branta"]),
    ],
    targets: [
        .target(name: "Branta"),
        .testTarget(name: "BrantaTests", dependencies: ["Branta"]),
    ]
)
