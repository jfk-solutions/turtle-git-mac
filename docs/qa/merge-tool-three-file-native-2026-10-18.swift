import AppKit
import TurtleGitCore

enum ThreeFileMergeToolVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Three-file merge tool did not settle at \(line)")
    }
    @MainActor static func editors(_ view: NSView?) -> [NSTextView] {
        guard let view else { return [] }; return (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { editors($0) }
    }
    final class HeldExport: @unchecked Sendable {
        private let condition = NSCondition()
        private var entered = false, released = false
        private var token: OperationCancellation?
        var started: Bool { condition.lock(); defer { condition.unlock() }; return entered }
        var cancelled: Bool { condition.lock(); defer { condition.unlock() }; return token?.isCancelled == true }
        func hold(_ token: OperationCancellation) {
            condition.lock(); entered = true; self.token = token; condition.broadcast()
            let deadline = Date().addingTimeInterval(30)
            while !released && condition.wait(until: deadline) {}
            condition.unlock()
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.MergeToolThreeFile." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(false, forKey: "TurtleGitMerge.Backup")
        var controllers: [TextConflictWindowController] = []
        var unexpectedOutputChoices = 0
        defer { prefs.removePersistentDomain(forName: suite); for controller in controllers { controller.close() } }
        func make(_ name: String, base: String, theirs: String, mine: String, output: String?, missingInputs: [Int] = [], flags: [String] = []) throws -> (TextConflictWindowController, [URL]) {
            let directory = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = ["base.txt", "theirs.txt", "mine.txt", "merged.txt"].map { directory.appendingPathComponent($0) }
            for (file, text) in zip(files, [base, theirs, mine]) { try Data(text.utf8).write(to: file) }
            if let output { try Data(output.utf8).write(to: files[3]) }
            for index in missingInputs { try FileManager.default.removeItem(at: files[index]) }
            let args = ["--base", files[0].path, "--theirs", files[1].path, "--mine", files[2].path, "--merged", files[3].path] + flags
            let invocation = try requireInvocation(args, directory: directory)
            let merge = try WorkingTextMerge(base: files[0], theirs: files[1], mine: files[2], merged: files[3], allowMissingInputs: true)
            let controller = TextConflictWindowController(repository: GitRepository(root: directory, executable: git), access: nil, path: files[2].lastPathComponent, workingMerge: merge, permissions: [RepositoryAccessLease(url: directory)], preferences: prefs, deferInitialLoad: true)
            controller.model.commentProfileURL = directory.appendingPathComponent("private-ignorecomments.txt")
            controller.model.regexDefaults = prefs
            try controller.model.configureMergeTool(invocation)
            controller.window?.alphaValue = 0; controllers.append(controller); controller.showWindow(nil); controller.model.beginTransferredDocument()
            return (controller, files)
        }
        func ready(_ controller: TextConflictWindowController) -> Bool { !controller.model.busy && !controller.model.preparing && controller.model.document != nil && controller.model.nativeEditorReady }
        func save(_ controller: TextConflictWindowController) async throws -> Bool {
            var answer: Bool?
            controller.model.save(markResolved: false) { answer = $0 }
            try await wait { answer != nil && !controller.model.mergeToolHasPendingWork }
            return answer!
        }
        let text = "head\nsecond\nthird\n"
        let (required, files) = try make("required", base: text, theirs: text, mine: text, output: text, flags: ["--saverequired", "--basename=Ancestor label", "--theirsname=Incoming label", "--minename=Mine label", "--mergedname=Release result", "--basereflectedname=/shown/ancestor", "--theirsreflectedname=/shown/incoming", "--minereflectedname=/shown/mine", "--mergedreflectedname=/shown/result", "--line=3"])
        try await wait { ready(required) }
        let requiredModel = required.model
        try require(requiredModel.mergeToolRequiresSave && requiredModel.dirty && !requiredModel.mergeToolSaved, "Clean mandatory-save launch did not require a real Save")
        try require(requiredModel.workingMergeOutput?.path == files[3].path && requiredModel.resultPath == files[3].path, "Explicit merged output did not become Save target")
        try require(requiredModel.mergeToolPaneTitle("Base") == "Ancestor label" && requiredModel.mergeToolPaneTitle("Mine", mine: true) == "Mine label" && requiredModel.mergeToolPaneTitle("Theirs", mine: false) == "Incoming label" && requiredModel.mergeToolPaneTitle("Merged", result: true) == "Release result", "Captured source/result names were lost")
        try require(requiredModel.mergeToolPaneLocation(mine: true) == "/shown/mine" && requiredModel.mergeToolPaneLocation(result: true) == "/shown/result" && required.window?.title == "Release result – TurtleGitMerge", "Reflected display names retargeted or disappeared")
        try await wait { editors(required.window?.contentView).first { $0.accessibilityLabel() == "Mine label" }?.selectedRange().location == "head\nsecond\n".utf16.count }
        try require(editors(required.window?.contentView).contains { $0.accessibilityLabel() == "Release result" && $0.isEditable }, "Native merged pane was not editable or lost its label")
        let originalInputs = try files.prefix(3).map { try Data(contentsOf: $0) }
        requiredModel.chooseStandaloneOutput = { _, _ in unexpectedOutputChoices += 1; return nil }
        try require(try await save(required), "Mandatory Save failed: " + String(describing: requiredModel.error))
        try require(unexpectedOutputChoices == 0, "Explicit output unexpectedly opened Save As")
        try require(requiredModel.mergeToolSaved && !requiredModel.mergeToolRequiresSave && !requiredModel.dirty, "Successful Save did not clear required-save state")
        try require(try Data(contentsOf: files[3]) == Data(text.utf8), "Save did not preserve the generated result bytes")
        try require(try files.prefix(3).map { try Data(contentsOf: $0) } == originalInputs, "Explicit output Save changed an input")
        requiredModel.result = text + "later unsaved\n"
        try require(!requiredModel.mergeToolSaved && requiredModel.dirty, "A later unsaved edit still reported a successful completed merge")
        required.close()

        let (absent, absentFiles) = try make("absent", base: text, theirs: text, mine: text, output: nil, flags: ["--saverequired"])
        try await wait { ready(absent) }
        absent.model.chooseStandaloneOutput = { _, _ in unexpectedOutputChoices += 1; return nil }
        try require(try await save(absent), "Absent explicit output did not save directly: " + String(describing: absent.model.error))
        try require(unexpectedOutputChoices == 0, "Absent explicit output unexpectedly opened Save As")
        try require(try Data(contentsOf: absentFiles[3]) == Data(text.utf8) && absent.model.mergeToolSaved, "Absent merged output bytes/status wrong")
        absent.close()

        let (missingBase, missingFiles) = try make("missing-base", base: text, theirs: text, mine: text, output: nil, missingInputs: [0], flags: ["--saverequired"])
        try await wait { ready(missingBase) }
        try require(missingBase.model.document?.base == "" && !FileManager.default.fileExists(atPath: missingFiles[0].path), "Absent named Base did not load as an empty source")
        try require(try await save(missingBase), "Absent named Base blocked standalone output: " + String(describing: missingBase.model.error))
        try require(try Data(contentsOf: missingFiles[3]) == Data(text.utf8) && !FileManager.default.fileExists(atPath: missingFiles[0].path), "Saving absent-input merge created or rewrote its source")
        missingBase.close()

        let (stale, staleFiles) = try make("stale", base: text, theirs: text, mine: text, output: text, flags: ["--saverequired"])
        try await wait { ready(stale) }
        try Data("external replacement\n".utf8).write(to: staleFiles[3])
        try require(try await !save(stale), "Changed explicit output was overwritten")
        try require(stale.model.error != nil && stale.model.mergeToolRequiresSave && !stale.model.mergeToolSaved && stale.model.dirty, "Failed output save lost reviewed mandatory state")
        try require(try Data(contentsOf: staleFiles[3]) == Data("external replacement\n".utf8), "Stale output failure wrote bytes")
        stale.close()

        let conflictBase = "head\nbase\ntail\n", conflictTheirs = "head\ntheirs\ntail\n", conflictMine = "head\nmine\ntail\n"
        let (conflicted, _) = try make("conflicts-default", base: conflictBase, theirs: conflictTheirs, mine: conflictMine, output: conflictMine, flags: ["--saverequired"])
        try await wait { ready(conflicted) }
        try require(conflicted.model.hasUnresolvedConflicts && !conflicted.model.mergeToolRequiresSave, "Source conflict condition did not suppress plain saverequired")
        conflicted.close()
        let (retained, _) = try make("conflicts-required", base: conflictBase, theirs: conflictTheirs, mine: conflictMine, output: conflictMine, flags: ["--saverequired", "--saverequiredonconflicts"])
        try await wait { ready(retained) }
        try require(retained.model.hasUnresolvedConflicts && retained.model.mergeToolRequiresSave, "saverequiredonconflicts did not preserve pending Save")
        retained.model.confirmUnresolvedSave = { _ in false }
        try require(try await !save(retained), "Refused unresolved save unexpectedly succeeded")
        try require(retained.model.mergeToolRequiresSave && !retained.model.mergeToolSaved, "Cancelled unresolved Save lost required state")
        retained.close()

        for flag in ["--readonly", "--blame"] {
            let (locked, lockedFiles) = try make(flag, base: conflictBase, theirs: conflictTheirs, mine: conflictMine, output: conflictMine, flags: [flag, "--saverequired", "--saverequiredonconflicts"])
            try await wait { ready(locked) }
            let model = locked.model, before = model.result, encoding = model.encoding
            try require(model.mergeToolReadOnly && !model.dirty && model.sourceToolsAllowed && !model.sourceMutationsAllowed && !model.canChooseConflict, "Readonly launch lost navigation or allowed a mutation")
            try require(editors(locked.window?.contentView).allSatisfy { !$0.isEditable }, "Readonly native pane remained editable")
            let snapshot = try lockedFiles.map { try Data(contentsOf: $0) }
            model.choose(.mine); model.changeEncoding(.utf16LE); model.changeLineEnding(.crlf); model.exportSource(mine: true)
            try require(try await !save(locked), "Readonly Save was accepted")
            try require(model.result == before && model.encoding == encoding && !model.mergeToolSaved && model.sourceTargets.isEmpty, "Readonly handlers changed editor state or rebound an input")
            try require(try lockedFiles.map { try Data(contentsOf: $0) } == snapshot, "Readonly handlers wrote a file")
            try require(locked.editorToolbar?.commandState(.save)?.enabled == false && locked.editorToolbar?.commandState(.saveMerged)?.enabled == false && locked.editorToolbar?.commandState(.find)?.enabled == true, "Readonly toolbar mutation/navigation gates wrong")
            locked.close()
        }
        // Retired export presentation flags may stay set; ownership follows
        // the actual picker/writer, including a non-cooperative writer drain.
        let (exporting, exportFiles) = try make("export-drain", base: text, theirs: text, mine: text, output: text)
        try await wait { ready(exporting) }
        let held = HeldExport(), exportTarget = root.appendingPathComponent("held-source-export.txt")
        defer { held.release() }
        exporting.model.sourceExporter.present = { _, _, reply in reply(.OK) }
        exporting.model.sourceExporter.selectedURL = { _ in exportTarget }
        exporting.model.sourceExporter.saveFolderAccess.requireScope = false
        exporting.model.sourceExporter.write = { _, _, token in held.hold(token); try token.check() }
        exporting.model.exportSource(mine: true)
        try await wait { held.started && exporting.model.sourceExporter.hasPendingWork && MergeSourceExport.activeExports > 0 }
        exporting.close()
        try require(exporting.model.retired && held.cancelled && exporting.model.mergeToolHasPendingWork, "Forced export owner closure lost actual pending write ownership")
        held.release()
        try await wait { !exporting.model.sourceExporter.hasPendingWork && !exporting.model.mergeToolHasPendingWork && MergeSourceExport.activeExports == 0 }
        try require(exporting.model.sourceTargets.isEmpty && !FileManager.default.fileExists(atPath: exportTarget.path) && exporting.model.error == nil, "Retired source export published a late file/rebinding/error")
        try require(try Data(contentsOf: exportFiles[2]) == Data(text.utf8), "Retired source export changed Mine")

        let (picking, _) = try make("export-picker", base: text, theirs: text, mine: text, output: text)
        try await wait { ready(picking) }
        var lateReply: ((NSApplication.ModalResponse) -> Void)?
        picking.model.sourceExporter.present = { _, _, reply in lateReply = reply }
        picking.model.exportSource(mine: false)
        try require(picking.model.sourceExporter.hasPendingWork && picking.model.mergeToolHasPendingWork, "Open source export chooser had no owner")
        picking.close()
        try require(!picking.model.sourceExporter.hasPendingWork && !picking.model.mergeToolHasPendingWork, "Retired source export chooser kept a stale pending flag")
        lateReply?(.OK)
        try require(picking.model.sourceTargets.isEmpty && !picking.model.mergeToolHasPendingWork, "Retired source export picker accepted a late reply")

        for controller in controllers { controller.close() }
        try await wait { controllers.allSatisfy { !$0.model.mergeToolHasPendingWork } && MergeRegexOperations.activeRequests == 0 && MergeSourceExport.activeExports == 0 }
        print("PASS: three-file merge-tool native: labels/reflected paths and source line, explicit existing/absent output, real mandatory Save, changed-output refusal, post-save edits, source conflict flags/cancel, readonly/blame actual native mutation/toolbar gates, unchanged inputs, retired source export picker/write drain and owned cleanup")
    }
    static func requireInvocation(_ arguments: [String], directory: URL) throws -> MergeToolInvocation {
        guard let invocation = try MergeToolInvocation.parse(arguments: arguments, currentDirectory: directory.path) else { throw Failure(description: "Missing merge-tool invocation") }; return invocation
    }
}
