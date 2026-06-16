// swift-tools-version: 5.9
import PackageDescription

// Vendored SpeexDSP (xiph/speexdsp), echo-cancellation + preprocess only.
// Built in floating-point mode with the bundled KISS FFT so it compiles cleanly
// with no autotools/config.h. EXPORT is defined empty (it normally comes from the
// generated config). Used for acoustic echo cancellation: the ScreenCaptureKit
// system audio is fed as the reference, the mic as near-end.
let package = Package(
    name: "CSpeexDSP",
    products: [
        .library(name: "CSpeexDSP", targets: ["CSpeexDSP"]),
    ],
    targets: [
        .target(
            name: "CSpeexDSP",
            cSettings: [
                .define("FLOATING_POINT"),
                .define("USE_KISS_FFT"),
                .define("EXPORT", to: ""),
                // SpeexDSP is old C with many benign warnings; keep the build quiet.
                .unsafeFlags(["-w"]),
            ]
        ),
    ]
)
