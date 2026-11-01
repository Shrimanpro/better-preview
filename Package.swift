// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetterPreview",
    platforms: [.macOS("27.0")],
    targets: [
        // Pure Swift, no AppKit. Everything here is unit-tested.
        .target(
            name: "BPCore",
            path: "Sources/BPCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BetterPreview",
            dependencies: ["BPCore"],
            path: "Sources/BetterPreview",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
