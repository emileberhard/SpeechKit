// swift-tools-version: 6.4
import PackageDescription

let swiftSettings: [SwiftSetting] = [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]

let package = Package(
    name: "SpeechKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "SpeechKit",
            targets: ["SpeechKit"]
        ),
        .library(name: "DictationLibrary", targets: ["DictationLibrary"]),
        .library(name: "SpeakerRecognition", targets: ["SpeakerRecognition"])
    ],
    targets: [
        .target(name: "SpeakerRecognition", dependencies: ["SpeechKit"], path: "SpeakerRecognition/Sources", resources: [.copy("Resources/SpeakerModel.mlmodelc"), .copy("Resources/CC-BY-4.0.txt"), .copy("Resources/NOTICE.md")], swiftSettings: swiftSettings),
        .testTarget(name: "SpeakerRecognitionTests", dependencies: ["SpeakerRecognition"], path: "SpeakerRecognition/Tests", resources: [.process("Fixtures")], swiftSettings: swiftSettings),
        .target(name: "DictationLibrary", dependencies: ["SpeechKit"], path: "DictationLibrary/Sources", swiftSettings: swiftSettings),
        .testTarget(name: "DictationLibraryTests", dependencies: ["DictationLibrary"], path: "DictationLibrary/Tests", swiftSettings: swiftSettings),
        .target(
            name: "SpeechKit",
            path: "SpeechKit/Sources",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SpeechKitTests",
            dependencies: ["SpeechKit"],
            path: "SpeechKit/Tests",
            resources: [
                .process("Transcription/Fixtures")
            ],
            swiftSettings: swiftSettings
        )
    ]
)
