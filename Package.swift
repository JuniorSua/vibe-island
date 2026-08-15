// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VibeIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VibeIsland",
            path: "Sources/VibeIsland",
            resources: [.copy("Resources/pets")]
        )
    ]
)
