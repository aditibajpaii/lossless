// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lossless",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LosslessEngine", targets: ["LosslessEngine"]),
        .library(name: "LosslessIntent", targets: ["LosslessIntent"]),
        .executable(name: "lossless-cli", targets: ["LosslessCLI"]),
        .executable(name: "Lossless", targets: ["LosslessApp"]),
    ],
    targets: [
        .target(
            name: "LosslessEngine",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LosslessIntent",
            dependencies: ["LosslessEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LosslessCLI",
            dependencies: ["LosslessEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LosslessKit",
            dependencies: ["LosslessEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LosslessApp",
            dependencies: ["LosslessEngine", "LosslessKit", "LosslessIntent"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LosslessKitTests",
            dependencies: ["LosslessKit", "LosslessEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LosslessIntentTests",
            dependencies: ["LosslessIntent"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
