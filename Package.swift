// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BtrVoice",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "BtrVoice",
            path: "Sources/BtrVoice",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
