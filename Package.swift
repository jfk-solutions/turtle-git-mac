// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TurtleGitMac",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TurtleGitCore", targets: ["TurtleGitCore"]), .executable(name: "TurtleGitMac", targets: ["TurtleGitMac"]), .executable(name: "TurtleGitWCRev", targets: ["TurtleGitWCRev"])],
    targets: [
        .target(name: "TurtleGitSMTP", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "TurtleGitCore", dependencies: ["TurtleGitSMTP"], resources: [.copy("Resources/Icons"), .copy("Resources/Completion")]),
        .executableTarget(name: "TurtleGitWCRev", dependencies: ["TurtleGitCore"]),
        .executableTarget(name: "TurtleGitMac", dependencies: ["TurtleGitCore"]),
        .testTarget(name: "TurtleGitCoreTests", dependencies: ["TurtleGitCore"], exclude: ["Fixtures/WorkingCopyRevision"], resources: [.copy("Fixtures/GitOutput"), .copy("Fixtures/smtp_server.py")])
    ],
    swiftLanguageModes: [.v5]
)
