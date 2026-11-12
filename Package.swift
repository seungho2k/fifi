// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Fifi",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "Fifi",
            path: "Sources/Fifi",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
