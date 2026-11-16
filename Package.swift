// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnkiAudioCapture",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AnkiAudioCapture"),
        .testTarget(name: "AnkiAudioCaptureTests", dependencies: ["AnkiAudioCapture"])
    ]
)
