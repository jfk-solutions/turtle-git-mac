import AppKit
import TurtleGitCore

struct MergeGeneralVerification {
    @MainActor static func verify() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMergeGeneral-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "TurtleGit.MergeGeneralNative." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("before.cpp"), mine = folder.appendingPathComponent("after.cpp")
        var a = (0..<250).map { "unchanged row \($0)\n" }; a[150] = "stable prefix value 1 suffix constant\n"
        var b = a; b[150] = "stable prefix value 2 suffix constant\n"
        let baseBytes = Data(a.joined().utf8), mineBytes = Data(b.joined().utf8)
        try baseBytes.write(to: base); try mineBytes.write(to: mine)
        var preferences = MergeGeneralPreferences(fontName: "Missing source family", fontSize: 10)
        preferences.save(to: defaults)
        let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [])
        defer { controller.window?.close() }
        let model = controller.model; model.comparisonDefaults = defaults; model.commentProfileURL = folder.appendingPathComponent("ignorecomments.txt")
        model.load(); try await TwoPaneEngineVerification.settled(model)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try await TwoPaneEngineVerification.wait { TwoPaneEngineVerification.editors(controller.window?.contentView).count == 2 }
        precondition(model.difference == 0 && !model.dirty)
        let views = TwoPaneEngineVerification.editors(controller.window?.contentView)
        try await TwoPaneEngineVerification.wait { views.allSatisfy { $0.font?.pointSize == 10 && $0.font?.isFixedPitch == true } }
        let selected = views.map { $0.selectedRange() }, generation = model.alignmentGeneration
        model.showInlineDiff = true; model.inlineWordDiff = false
        precondition(model.inlineDifference(150) != nil)
        preferences.fontName = "Menlo"; preferences.fontSize = 16; preferences.maximumInlineLength = 2
        preferences.save(to: defaults); model.refreshPreferences()
        try await TwoPaneEngineVerification.wait { views.allSatisfy { $0.font?.pointSize == 16 } }
        precondition(model.inlineDifference(150) == nil && views.map { $0.selectedRange() } == selected)
        precondition(model.alignmentGeneration == generation && !model.dirty && !model.canUndo)
        preferences.firstDifference = false; preferences.firstConflict = false; preferences.save(to: defaults)
        model.load(); try await TwoPaneEngineVerification.settled(model)
        precondition(!model.generalPreferences.firstDifference && views.map { $0.selectedRange() } == selected)
        preferences.firstDifference = true; preferences.save(to: defaults)
        model.load(); try await TwoPaneEngineVerification.settled(model)
        precondition(model.difference == 0 && !model.canUndo && !model.dirty)
        let finalBase = try Data(contentsOf: base), finalMine = try Data(contentsOf: mine)
        precondition(finalBase == baseBytes && finalMine == mineBytes)
        controller.window?.close(); try await TwoPaneEngineVerification.wait { MergeRegexOperations.activeRequests == 0 }
        print("Merge General: native fixed-pitch fallback/live font sizes, selection and history preservation, actual inline-length gating, first-difference enabled/disabled reload and unchanged input bytes passed. Owned window closed.")
    }
}
