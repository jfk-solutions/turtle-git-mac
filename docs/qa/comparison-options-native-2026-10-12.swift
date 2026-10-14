import AppKit
import TurtleGitCore

@main struct ComparisonOptionsVerification {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if CommandLine.arguments.contains("--source-tools-only") {
            try await MergeSourceToolsNativeVerification.verify()
            try await TwoPaneEngineVerification.verify()
            try await ThreePaneEngineVerification.verify(configuration: SubversionMergeConfiguration.bundled())
            return
        }
        if CommandLine.arguments.contains("--patch-open-only") {
            try await MergePatchOpenNativeVerification.verify()
            try await ReviewPatchNativeVerification.verify()
            try await MergeEditorOpenNativeVerification.verify()
            try await MergeOpenNativeVerification.verify()
            return
        }
        if CommandLine.arguments.contains("--editor-open-only") {
            try await MergeEditorOpenNativeVerification.verify()
            try await MergeOpenNativeVerification.verify()
            try await TwoPaneEngineVerification.verify()
            try await ThreePaneEngineVerification.verify(configuration: SubversionMergeConfiguration.bundled())
            return
        }
        if CommandLine.arguments.contains("--folding-only") {
            try await MergeFoldingNativeVerification.verify()
            try await MergeWrappingVerification.verify()
            try await TwoPaneEngineVerification.verify()
            try await ThreePaneEngineVerification.verify(configuration: SubversionMergeConfiguration.bundled())
            return
        }
        if CommandLine.arguments.contains("--inline-only") { try await MergeInlineNativeVerification.verify(); return }
        if CommandLine.arguments.contains("--wrapping-only") { try await MergeWrappingVerification.verify(); return }
        if CommandLine.arguments.contains("--default-encoding-only") { try await MergeDefaultEncodingVerification.verify(); return }
        if CommandLine.arguments.contains("--one-pane-context-only") { try await MergeOnePaneContextVerification.verify(); return }
        if CommandLine.arguments.contains("--one-pane-only") { try await MergeOnePaneNativeVerification.verify(); return }
        if CommandLine.arguments.contains("--colors-only") { try await MergeColorsNativeVerification.verify(); return }
        if CommandLine.arguments.contains("--patch-only") { try await MergePatchNativeVerification.verify(); return }
        if CommandLine.arguments.contains("--format-only") { try await MergeFormatNativeVerification.verify(); return }
        if CommandLine.arguments.contains("--open-only") { try await MergeOpenNativeVerification.verify(); return }
        if CommandLine.arguments.contains("--find-only") { try await MergeFindNativeVerification.verify(); return }
        if CommandLine.arguments.contains("--about-only") { try await AboutNativeVerification.verify(); return }
        if CommandLine.arguments.contains("--general-only") { try await MergeGeneralVerification.verify(); return }
        if CommandLine.arguments.contains("--whitespace-only") { try await MergeWhitespaceDisplayVerification.verify(); return }
        if !CommandLine.arguments.contains("--resume-from-line-diff") {
            if !CommandLine.arguments.contains("--resume-after-engines") {
                try await ThreePaneEngineVerification.verify(configuration: SubversionMergeConfiguration.bundled())
                try await TwoPaneEngineVerification.verify()
            }
            try await MergeSourceToolsNativeVerification.verify()
            try await MergePatchOpenNativeVerification.verify()
            try await MergeEditorOpenNativeVerification.verify()
            try await MergeFoldingNativeVerification.verify()
            try await MergeInlineNativeVerification.verify()
            try await MergeLocatorVerification.verify()
            try await MergeWhitespaceDisplayVerification.verify()
            try await MergeGeneralVerification.verify()
            try await AboutNativeVerification.verify()
            try await MergeFindNativeVerification.verify()
            try await MergeOpenNativeVerification.verify()
            try await MergeFormatNativeVerification.verify()
        }
        try await MergeLineDiffNativeVerification.verify()
        try await MergePatchNativeVerification.verify()
        try await MergeColorsNativeVerification.verify()
        try await MergeOnePaneNativeVerification.verify()
        try await MergeOnePaneContextVerification.verify()
        try await MergeDefaultEncodingVerification.verify()
        try await MergeWrappingVerification.verify()
        print("Comparison option receivers passed together: three-pane dirty Cancel/persistence, two-pane preference choices, existing Undo/save/cancellation paths; one frontend compilation and one process.")
    }
}
