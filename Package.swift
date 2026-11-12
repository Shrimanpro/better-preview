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
        // Vendored SyncTeX parser (MIT, github.com/jlaurens/synctex). Reads
        // .synctex(.gz) files; links the system zlib.
        .target(
            name: "CSyncTeX",
            path: "Sources/CSyncTeX",
            exclude: ["LICENSE"],
            cSettings: [.headerSearchPath(".")],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "BetterPreview",
            dependencies: ["BPCore", "CSyncTeX"],
            path: "Sources/BetterPreview",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BPCoreTests",
            dependencies: ["BPCore"],
            path: "Tests/BPCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
