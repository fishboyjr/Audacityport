// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AudioCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AudioCore", targets: ["AudioCore"]),
        .library(name: "AudioDSP", targets: ["AudioDSP"]),
    ],
    targets: [
        // Portable C signal-processing core (effects, analysis, generators, WAV I/O).
        .target(
            name: "AudioDSP",
            path: "Sources/AudioDSP"
        ),
        // Platform-independent editing model: project, tracks, clips, undo, effects, mixing.
        .target(
            name: "AudioCore",
            dependencies: ["AudioDSP"],
            path: "Sources/AudioCore"
        ),
        .testTarget(
            name: "AudioCoreTests",
            dependencies: ["AudioCore"],
            path: "Tests/AudioCoreTests"
        ),
    ]
)
