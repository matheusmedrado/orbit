// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Orbit",
            path: "Sources/Orbit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
