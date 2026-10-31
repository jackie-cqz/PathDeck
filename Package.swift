// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PathDeck", platforms: [.macOS(.v14)], products: [.library(name: "PathDeckCore", targets: ["PathDeckCore"])], targets: [.target(name: "PathDeckCore", path: "PathDeck/Core"), .testTarget(name: "PathDeckTests", dependencies: ["PathDeckCore"], path: "PathDeckTests")], swiftLanguageModes: [.v6])
