// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Core test jobs build the application separately with Xcode. Avoid compiling
// its SwiftUI executable a second time through SwiftPM. Normal package use keeps it.
let coreOnly = ProcessInfo.processInfo.environment["TURTLEGIT_CORE_ONLY"] == "1"
let package = Package(
    name: "TurtleGitMac",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TurtleGitCore", targets: ["TurtleGitCore"]), .executable(name: "TurtleGitWCRev", targets: ["TurtleGitWCRev"])] + (coreOnly ? [] : [.executable(name: "TurtleGitMac", targets: ["TurtleGitMac"])]),
    targets: [
        .target(name: "TurtleGitSMTP", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "TurtleGitCore", dependencies: ["TurtleGitSMTP"], resources: [.copy("Resources/Icons"), .copy("Resources/Completion")]),
        .executableTarget(name: "TurtleGitWCRev", dependencies: ["TurtleGitCore"]),
        .testTarget(name: "TurtleGitCoreTests", dependencies: ["TurtleGitCore"], exclude: ["Fixtures/WorkingCopyRevision"], resources: [.copy("Fixtures/GitOutput"), .copy("Fixtures/Certificates"), .copy("Fixtures/WaterEffect"), .copy("Fixtures/smtp_server.py")])
    ] + (coreOnly ? [] : [.executableTarget(name: "TurtleGitMac", dependencies: ["TurtleGitCore"], exclude: ["Resources/ApplicationAssets.xcassets"], resources: [.copy("Resources/TurtleGitHelp.help"), .copy("Resources/Branding")])]),
    swiftLanguageModes: [.v5]
)
