import AppKit
import Foundation
import TurtleGitCore

@main struct TwoPaneEngineVerification {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        preconditionFailure("Timed out waiting for two-pane comparison")
    }
    @MainActor static func editors(_ view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        return (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { editors($0) }
    }
    @MainActor static func settled(_ model: FileComparisonWindowModel) async throws {
        try await wait { !model.busy && !model.filtering && model.alignmentSelections.isEmpty }
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await verify()
    }
    @MainActor static func verify() async throws {
        UserDefaults.standard.setVolatileDomain(["TurtleGit.DiffTools": try JSONEncoder().encode(DiffToolPreferences())], forName: "NSArgumentDomain")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitTwoPaneEngine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "TurtleGit.TwoPaneEngine." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("base.txt"), destination = folder.appendingPathComponent("destination.txt")
        let baseText = "stamp 12\r\nkeep\r\nold\r\nsame\r\n", destinationText = "stamp 81\r\nkeep\r\nnew\r\nsame\r\n"
        let baseBytes = try ComparisonTextEncoding.utf16LEBOM.encode(baseText), destinationBytes = try ComparisonTextEncoding.utf8BOM.encode(destinationText)
        try baseBytes.write(to: base); try destinationBytes.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path)
        let filter = MergeRegexFilter(name: "Versions", expression: "[0-9]+", replacement: "")
        try MergeRegexFilters.save([filter], defaults: defaults)
        let comparison = try WorkingFileComparison(base: base, destination: destination)
        let controller = FileComparisonWindowController(comparison: comparison, permissions: []), model = controller.model
        model.comparisonDefaults = defaults; model.regexDefaults = defaults; model.load(); try await settled(model)
        precondition(model.error == nil && model.alignment?.differences == [0..<1, 2..<3])
        let requestedOptions = MergeComparisonOptions(whitespace: .ignoreChanges, ignoreCase: true, ignoreEndings: false)
        model.setComparisonOptions(requestedOptions); try await settled(model)
        precondition(model.comparisonOptions == requestedOptions && MergeComparisonOptions.load(from: defaults) == requestedOptions)
        model.setComparisonOptions(.exact); try await settled(model)
        model.refreshRegexFilters(); model.selectRegexFilter(filter.name); try await settled(model)
        precondition(model.alignment?.rows[0].base.state == .filtered && model.alignment?.differences == [2..<3])
        model.selectRegexFilter(nil); model.selectRegexFilter(filter.name); model.selectRegexFilter(nil)
        try await wait { MergeRegexOperations.activeRequests == 0 }; try await settled(model)
        precondition(model.regexFilterName == nil && model.alignment?.rows[0].base.state != .filtered)
        model.activatePane(base: false); model.editingEnabled = true
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait { editors(controller.window?.contentView).contains { $0.isEditable && $0.string.contains("new") } }
        guard let text = editors(controller.window?.contentView).first(where: { $0.isEditable && $0.string.contains("new") }) else { preconditionFailure("Missing production editable destination pane") }
        text.insertText("🦎!", replacementRange: (text.string as NSString).range(of: "new"))
        precondition(model.filtering && !model.canTransfer && model.draftText(base: false).contains("🦎!"))
        let retained = model.draftText(base: false)
        model.selectedRows = 2..<3; model.useOtherBlock()
        precondition(model.draftText(base: false) == retained)
        let selection = (text.string as NSString).range(of: "🦎!")
        text.setSelectedRange(selection)
        try await settled(model)
        try await wait { model.canUndo }
        let selected = (text.string as NSString).substring(with: text.selectedRange())
        let viewStates = editors(controller.window?.contentView).map { "editable=\($0.isEditable), range=\($0.selectedRange())" }.joined(separator: "; ")
        if selected != "🦎!" {
            let detail = "QA selection mismatch: actual=\(text.selectedRange()), selected=\(selected.debugDescription), caret=\(String(describing: model.selectionRequest)), activeBase=\(model.activeBase), views=[\(viewStates)]\n"
            FileHandle.standardError.write(Data(detail.utf8))
        }
        precondition((text.string as NSString).substring(with: text.selectedRange()) == "🦎!")
        precondition(model.draftText(base: false) == "stamp 81\r\nkeep\r\n🦎!\r\nsame\r\n")
        model.undo(); try await settled(model)
        precondition(model.draftText(base: false) == destinationText && !model.dirty)
        model.redo(); try await settled(model)
        precondition(model.dirty && model.draftText(base: false).contains("🦎!"))
        model.selectedRows = 2..<3; model.markBlock(true); try await settled(model)
        precondition(model.annotations(base: false).marked.contains(2))
        model.chooseMarkedSave = { .include }
        model.save(); try await settled(model)
        // Include keeps marked/manual rows and takes the source for unmarked
        // differences, including the untouched stamp change.
        let expected = try ComparisonTextEncoding.utf8BOM.encode("stamp 12\r\nkeep\r\n🦎!\r\nsame\r\n")
        let saved = try Data(contentsOf: destination), retainedBase = try Data(contentsOf: base)
        precondition(saved == expected && retainedBase == baseBytes && !model.dirty)
        let mode = try FileManager.default.attributesOfItem(atPath: base.path)[.posixPermissions] as? NSNumber
        precondition(mode?.intValue == 0o755)
        controller.window?.close(); try await wait { MergeRegexOperations.activeRequests == 0 }
        let commentBase = folder.appendingPathComponent("base.cpp"), commentMine = folder.appendingPathComponent("mine.cpp")
        let commentBaseBytes = Data("value; // base\r\n".utf8), commentMineBytes = Data("value; // mine\r\n".utf8)
        try commentBaseBytes.write(to: commentBase); try commentMineBytes.write(to: commentMine)
        let comments = FileComparisonWindowModel(comparison: try WorkingFileComparison(base: commentBase, destination: commentMine), permissions: [])
        comments.comparisonDefaults = defaults; comments.load(); try await settled(comments)
        precondition(comments.supportsComments && comments.alignment?.differences.isEmpty == false)
        var commentOptions = MergeComparisonOptions.exact; commentOptions.ignoreComments = true
        comments.setComparisonOptions(commentOptions); try await settled(comments)
        precondition(comments.alignment?.differences.isEmpty == true && comments.alignment?.rows[0].base.state == .filtered)
        let originalComments = try Data(contentsOf: commentBase), retainedComments = try Data(contentsOf: commentMine)
        precondition(originalComments == commentBaseBytes && retainedComments == commentMineBytes)
        comments.retireImageLoader(); try await wait { MergeRegexOperations.activeRequests == 0 }
        // A missing engine must show a failure, never an apparently completed
        // Swift comparison. No hosted window is needed for this error path.
        let failed = FileComparisonWindowModel(comparison: comparison, permissions: [])
        var configuration = try SubversionMergeConfiguration.bundled()
        configuration.executable = folder.appendingPathComponent("missing-adapter")
        failed.engineConfiguration = configuration; failed.load(); try await settled(failed)
        precondition(failed.error != nil && failed.alignment == nil); failed.retireImageLoader()
        let slow = folder.appendingPathComponent("slow-adapter")
        try Data("#!/bin/sh\nprintf started > \"$0.started\"\n/bin/sleep 2\nexit 1\n".utf8).write(to: slow)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slow.path)
        configuration.executable = slow
        let retired = FileComparisonWindowModel(comparison: comparison, permissions: [])
        retired.engineConfiguration = configuration; retired.load()
        try await wait { FileManager.default.fileExists(atPath: slow.appendingPathExtension("started").path) }
        retired.retireImageLoader(); try await wait { MergeRegexOperations.activeRequests == 0 }
        precondition(retired.error == nil)
        print("Two-pane Subversion: ordinary/filtered ranges, stale selection fencing, native Unicode typing and selection retention, pending transfer gate, Undo/Redo, marks, exact BOM/CRLF Save, untouched UTF-16 executable Base, explicit missing-engine error and retired cleanup passed. Owned hidden windows/helpers closed.")
    }
}
