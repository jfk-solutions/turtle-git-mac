// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TurtleGitMac",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TurtleGitCore", targets: ["TurtleGitCore"]), .executable(name: "TurtleGitMac", targets: ["TurtleGitMac"])],
    targets: [
        .target(name: "TurtleGitCore", resources: [.copy("Resources/Icons")]),
        .executableTarget(name: "TurtleGitMac", dependencies: ["TurtleGitCore"]),
        .testTarget(name: "TurtleGitCoreTests", dependencies: ["TurtleGitCore"])
    ],
    swiftLanguageModes: [.v5]
)
