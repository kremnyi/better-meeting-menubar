// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BetterMeetingMac",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "BetterMeeting", targets: ["BetterMeetingApp"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.1.1"
        ),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "BetterMeetingApp",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/BetterMeetingApp",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                // Drop unreferenced code from the static speech libraries (TTS, streaming ASR, diarization).
                .unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release)),
            ]
        ),
        .testTarget(
            name: "BetterMeetingTests",
            dependencies: [
                "BetterMeetingApp",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
