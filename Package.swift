// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "QuotaBar", targets: ["QuotaBar"])
    ],
    targets: [
        .executableTarget(
            name: "QuotaBar",
            path: "Sources/QuotaBar",
            resources: [
                .copy("Resources/CodexProvider.png"),
                .copy("Resources/GrokProvider.icns"),
                .copy("Resources/AgyProvider.png")
            ]
        ),
        .testTarget(
            name: "QuotaBarTests",
            dependencies: ["QuotaBar"]
        )
    ]
)
