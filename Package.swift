// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BtrVoice",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        )
    ],
    targets: [
        .executableTarget(
            name: "BtrVoice",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/BtrVoice",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
