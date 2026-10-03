// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dikte",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // WhisperKit artık Argmax Open-Source SDK içinde
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "Dikte",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/Dikte"
        )
    ]
)
