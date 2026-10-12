import AppKit
import TurtleGitCore

@main struct ComparisonOptionsVerification {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if CommandLine.arguments.contains("--about-only") { try await AboutNativeVerification.verify(); return }
        if CommandLine.arguments.contains("--general-only") { try await MergeGeneralVerification.verify(); return }
        if CommandLine.arguments.contains("--whitespace-only") { try await MergeWhitespaceDisplayVerification.verify(); return }
        try await ThreePaneEngineVerification.verify(configuration: SubversionMergeConfiguration.bundled())
        try await TwoPaneEngineVerification.verify()
        try await MergeLocatorVerification.verify()
        try await MergeWhitespaceDisplayVerification.verify()
        try await MergeGeneralVerification.verify()
        try await AboutNativeVerification.verify()
        print("Comparison option receivers passed together: three-pane dirty Cancel/persistence, two-pane preference choices, existing Undo/save/cancellation paths; one frontend compilation and one process.")
    }
}
