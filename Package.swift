// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Parrot",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // On-device speaker diarization (CoreML pyannote pipeline). Pinned to
        // the exact validated revision: clustering on borderline calls is
        // numerically chaotic across library changes, so bumps must re-run
        // --diarize-test on a real multi-party recording (see DiarizationEngine).
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "5390df9752c8fc583596018360c5fd70d6fa6c75"),
        // Vendored SpeexDSP for acoustic echo cancellation. Kept in sync with
        // project.yml (the xcodegen source of truth) so `swift build` works too.
        .package(path: "Vendor/CSpeexDSP"),
        // Self-updating. Sparkle is a binary XCFramework, so the Makefile has
        // to copy it into Contents/Frameworks itself — `swift build` links it
        // but never embeds it (see the bundle step).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
        // In-process LLM (Translation Local). Pinned to 2.29.x — later tags
        // need Swift 6.2. Same download-then-load pattern as WhisperKit.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "2.29.1")),
    ],
    targets: [
        .executableTarget(
            name: "Parrot",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "CSpeexDSP", package: "CSpeexDSP"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Parrot",
            linkerSettings: [
                // The framework lives next to the executable in the bundle.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
    ]
)
