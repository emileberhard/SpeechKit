// swift-tools-version: 6.4
import PackageDescription

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
        .library(name: "DictationLibrary", targets: ["DictationLibrary"])
    ],
    targets: [
        .target(name: "DictationLibrary", dependencies: ["SpeechKit"], path: "DictationLibrary/Sources"),
        .testTarget(name: "DictationLibraryTests", dependencies: ["DictationLibrary"], path: "DictationLibrary/Tests"),
        .target(
            name: "SpeechKit",
            path: "SpeechKit/Sources"
        ),
        .testTarget(
            name: "SpeechKitTests",
            dependencies: ["SpeechKit"],
            path: "SpeechKit/Tests",
            resources: [
                .process("Transcription/Fixtures")
            ]
        )
    ]
)
