// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DukascopyClient",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DukascopyClient", targets: ["DukascopyClient"]),
        .executable(name: "dukascopy-cli", targets: ["dukascopy-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/attaswift/BigInt", from: "5.3.0"),
    ],
    targets: [
        .target(
            name: "DukascopyClient",
            dependencies: [
                .product(name: "BigInt", package: "BigInt"),
            ]
        ),
        .executableTarget(
            name: "dukascopy-cli",
            dependencies: [
                "DukascopyClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "DukascopyClientTests", dependencies: ["DukascopyClient"]),
    ]
)
