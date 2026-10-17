// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Talk2Me",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Talk2Me", targets: ["Talk2Me"]),
        .executable(name: "talk2me-bench", targets: ["Talk2MeBench"]),
    ],
    targets: [
        // Platform logic with no UI: hotkey state, transcription, Claude cleanup.
        .target(name: "Talk2MeCore"),
        // The menu-bar app. AppKit and event-tap callbacks are simpler in the Swift 5 language mode.
        .executableTarget(
            name: "Talk2Me",
            dependencies: ["Talk2MeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Command-line harness to time the cleanup backends and transcribe audio files.
        .executableTarget(name: "Talk2MeBench", dependencies: ["Talk2MeCore"]),
        .testTarget(name: "Talk2MeCoreTests", dependencies: ["Talk2MeCore"]),
    ]
)
