// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PathDeck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PathDeckCore", targets: ["PathDeckCore"]),
        .executable(name: "PathDeck", targets: ["PathDeck"]),
    ],
    targets: [
        .target(name: "PathDeckCore", path: "PathDeck/Core"),
        .executableTarget(
            name: "PathDeck",
            dependencies: ["PathDeckCore"],
            path: "PathDeck",
            exclude: ["Core", "Resources"]
        ),
        .testTarget(
            name: "PathDeckTests",
            dependencies: ["PathDeckCore"],
            path: "PathDeckTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)

