// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mpd-virt",
    // macOS-only orchestrator. The binary drives Parallels Desktop Pro on the
    // user's Mac to create + manage mpd VMs.
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "mpd-virt",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "mpd-virt",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
