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
            exact: "1.1.0"
        ),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "BetterMeetingApp",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/BetterMeetingApp",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "BetterMeetingTests", dependencies: ["BetterMeetingApp"]),
    ],
    swiftLanguageModes: [.v5]
)
