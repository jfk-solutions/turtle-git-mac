import AppKit
import TurtleGitCore

@main struct ComparisonOptionsVerification {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await ThreePaneEngineVerification.verify(configuration: SubversionMergeConfiguration.bundled())
        try await TwoPaneEngineVerification.verify()
        try await MergeLocatorVerification.verify()
        print("Comparison option receivers passed together: three-pane dirty Cancel/persistence, two-pane preference choices, existing Undo/save/cancellation paths; one frontend compilation and one process.")
    }
}
