// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Parrot",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // Vendored SpeexDSP for acoustic echo cancellation. Kept in sync with
        // project.yml (the xcodegen source of truth) so `swift build` works too.
        .package(path: "Vendor/CSpeexDSP"),
    ],
    targets: [
        .executableTarget(
            name: "Parrot",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "CSpeexDSP", package: "CSpeexDSP"),
            ],
            path: "Parrot"
        ),
    ]
)
