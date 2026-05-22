// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mpd-virt",
    // macOS-only orchestrator. The binary drives Parallels Desktop Pro on the
    // user's Mac to create + manage mpd-machine VMs.
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
        // swift-crypto powers Curve25519 keypair generation for WireGuard
        // static keys. On Apple platforms it re-exports CryptoKit at zero cost.
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "mpd-virt",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "mpd-virt",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
