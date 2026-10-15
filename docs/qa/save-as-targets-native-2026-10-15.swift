import AppKit
import TurtleGitCore

@main struct SaveAsTargetsVerification {
    @MainActor static func wait(_ windows: [NSWindow], _ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<2000 { windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }; if ready() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        preconditionFailure("Save As target fixture did not settle at line \(line)")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func textView(_ window: NSWindow, label: String) -> NSTextView {
        descendants(window.contentView!).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == label }!
    }
    @MainActor static func type(_ view: NSTextView, _ value: String) {
        let history = view.undoManager!; history.groupsByEvent = false; history.beginUndoGrouping()
        view.insertText(value, replacementRange: NSRange(location: 0, length: (view.string as NSString).length)); history.endUndoGrouping()
    }
    @MainActor static func chooseSaveAs(_ view: NSTextView, prefs: UserDefaults, board: NSPasteboard) {
        let menu = (view as! ComparisonContextMenuProviding).comparisonContextMenu(defaults: prefs, pasteboard: board)
        let item = menu.item(withTitle: "Save As…")!
        precondition(item.isEnabled && item.image != nil && NSApp.sendAction(item.action!, to: item.target, from: item))
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.SaveAsTargets." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try await compare(root: root, prefs: prefs, board: board)
        try await sourceSnapshot(root: root, prefs: prefs, board: board)
        try await review(root: root, git: git, prefs: prefs, board: board)
        try await threePane(root: root, prefs: prefs, board: board)
        print("PASS: native source Save As target binding, later Save/Reload, Review routing, three-pane inputs and owned late replies; private files/preferences/clipboard only")
    }
    @MainActor static func compare(root: URL, prefs: UserDefaults, board: NSPasteboard) async throws {
        let folder = root.appendingPathComponent("compare"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let left = folder.appendingPathComponent("left"), right = folder.appendingPathComponent("right"), chosen = folder.appendingPathComponent("chosen.txt")
        try Data("left\n".utf8).write(to: left); try Data("right\n".utf8).write(to: right)
        let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: left, destination: right), permissions: [])
        defer { controller.close() }
        let model = controller.model, window = controller.window!
        model.comparisonDefaults = prefs; model.editorConfigEnabled = [true: false, false: false]; model.load()
        try await wait([window]) { !model.busy && !model.filtering && model.document != nil }
        let view = textView(window, label: "Destination file")
        type(view, "saved 🐢\nlast"); try await wait([window]) { model.canTransfer(toBase: false) }
        model.changeEncoding(.utf16LEBOM, base: false)
        var pending: CheckedContinuation<URL?, Never>?, prompts = 0
        model.chooseExportLocation = { owner, name, directory in
            precondition(owner === window && name == "right" && directory.path == folder.path); prompts += 1
            return await withCheckedContinuation { pending = $0 }
        }
        chooseSaveAs(view, prefs: prefs, board: board); try await wait([window]) { pending != nil }
        precondition(model.exporting && !controller.windowShouldClose(window))
        precondition(TurtleGitApplicationDelegate().applicationShouldTerminate(.shared) == .terminateCancel)
        model.saveAs(base: true); model.updateDraft("blocked", base: false); model.load()
        precondition(prompts == 1 && model.draftText(base: false) == "saved 🐢\nlast")
        pending!.resume(returning: chosen); pending = nil
        try await wait([window]) { !model.busy && !model.filtering }
        precondition(model.savedPaneURL(base: false) == chosen && model.document!.destination.path == chosen.path && !model.dirty)
        let first = try Data(contentsOf: chosen), untouched = try Data(contentsOf: right)
        let expectedFirst = try ComparisonTextEncoding.utf16LEBOM.encode("saved 🐢\nlast")
        precondition(first == expectedFirst && untouched == Data("right\n".utf8))
        precondition(textView(window, label: "Destination file") === view, "Retarget must retain native history/editor")
        type(view, "later\nno final newline"); try await wait([window]) { !model.filtering }
        var saved: Bool?; model.save { saved = $0 }; try await wait([window]) { saved != nil && !model.filtering }
        let second = try Data(contentsOf: chosen)
        let expectedSecond = try ComparisonTextEncoding.utf16LEBOM.encode("later\nno final newline")
        precondition(saved == true && !model.dirty && second == expectedSecond)
        let stillUntouched = try Data(contentsOf: right); precondition(stillUntouched == untouched)
        type(view, "quit-approved pane\n"); try await wait([window]) { !model.filtering }
        model.confirmingQuit = true; saved = nil; model.saveAllForQuit { saved = $0 }
        try await wait([window]) { saved != nil && !model.filtering }; model.confirmingQuit = false
        let quitPane = try Data(contentsOf: chosen), expectedQuitPane = try ComparisonTextEncoding.utf16LEBOM.encode("quit-approved pane\n")
        precondition(saved == true && !model.dirty && quitPane == expectedQuitPane)
        try await wait([window]) { view.isEditable && model.canTransfer(toBase: false) }
        type(view, "later\nno final newline"); try await wait([window]) { !model.filtering }
        saved = nil; model.save { saved = $0 }; try await wait([window]) { saved != nil && !model.filtering }
        let restored = try Data(contentsOf: chosen); precondition(saved == true && restored == expectedSecond)

        try Data("external\n".utf8).write(to: chosen)
        type(view, "must refuse"); try await wait([window]) { !model.filtering }
        saved = nil; model.save { saved = $0 }; try await wait([window]) { saved != nil }
        let external = try Data(contentsOf: chosen); precondition(saved == false && model.dirty && model.error != nil && external == Data("external\n".utf8))
        model.error = nil; type(view, "later\nno final newline"); try await wait([window]) { !model.filtering && !model.dirty }
        try FileManager.default.removeItem(at: right)
        model.load(); try await wait([window]) { !model.busy && !model.filtering }
        precondition(model.document!.destination.bytes == external && model.document!.destination.path == chosen.path)
        let chosenLeft = folder.appendingPathComponent("chosen-left")
        model.chooseExportLocation = { _, _, _ in chosenLeft }; model.saveAs(base: true)
        try await wait([window]) { !model.busy && !model.filtering }
        try FileManager.default.removeItem(at: left)
        model.load(); try await wait([window]) { !model.busy && !model.filtering }
        precondition(model.document!.base.path == chosenLeft.path && model.document!.destination.path == chosen.path)
        let late = folder.appendingPathComponent("late")
        model.chooseExportLocation = { _, _, _ in await withCheckedContinuation { pending = $0 } }
        model.saveAs(base: false); try await wait([window]) { pending != nil }
        let count = FileComparisonWindowModel.activePaneExports
        controller.close(); precondition(FileComparisonWindowModel.activePaneExports == count)
        pending!.resume(returning: late); pending = nil
        try await wait([]) { FileComparisonWindowModel.activePaneExports == count - 1 }
        precondition(!FileManager.default.fileExists(atPath: late.path) && model.savedPaneURL(base: false) == chosen)
        // A later ordinary Save must also reject a held empty-file answer after
        // forced retirement, keeping its own grant/operation lifetime bounded.
        let other = FileComparisonWindowController(comparison: try WorkingFileComparison(base: chosenLeft, destination: chosen), permissions: [])
        defer { other.close() }; let secondModel = other.model, secondWindow = other.window!
        secondModel.editorConfigEnabled = [true: false, false: false]; secondModel.load()
        try await wait([secondWindow]) { !secondModel.busy && !secondModel.filtering }
        type(textView(secondWindow, label: "Destination file"), "")
        try await wait([secondWindow]) { !secondModel.filtering }
        var empty: CheckedContinuation<MergeEmptyResult, Never>?
        secondModel.chooseEmptyResult = { _ in await withCheckedContinuation { empty = $0 } }
        let prior = try Data(contentsOf: chosen); saved = nil
        secondModel.save { saved = $0 }; try await wait([secondWindow]) { empty != nil }
        other.close(); empty!.resume(returning: .delete); empty = nil
        try await wait([]) { saved != nil }
        let retained = try Data(contentsOf: chosen); precondition(saved == false && retained == prior)
        print("PASS: actual two-pane Save As menu rebinds cleanly; Unicode/encoding, later Save, stale refusal, independent Reload without old paths, Cancel/retired target and held ordinary Save refusal")
    }
    @MainActor static func sourceSnapshot(root: URL, prefs: UserDefaults, board: NSPasteboard) async throws {
        let controller = try MergeSourceComparisonWindows.open(base: Data("base\n".utf8), side: Data("mine\n".utf8), name: "file", sideName: "Mine", preferences: prefs)
        defer { controller.close() }
        let window = controller.window!, model = controller.model
        window.alphaValue = 0; window.orderOut(nil)
        try await wait([window]) { !model.busy && !model.filtering && model.document != nil }
        let temporary = URL(fileURLWithPath: model.document!.destination.path).deletingLastPathComponent()
        precondition(!model.canEdit(base: true) && !model.canEdit(base: false))
        let chosen = root.appendingPathComponent("snapshot-chosen")
        model.chooseExportLocation = { _, _, _ in chosen }
        chooseSaveAs(textView(window, label: "Destination file"), prefs: prefs, board: board)
        try await wait([window]) { !model.busy && !model.filtering }
        precondition(model.savedPaneURL(base: false) == chosen && model.canEdit(base: false) && !model.canEdit(base: true))
        model.activatePane(base: false); model.editingEnabled = true
        type(textView(window, label: "Destination file"), "edited snapshot copy\n")
        try await wait([window]) { !model.filtering }
        var saved: Bool?; model.save { saved = $0 }; try await wait([window]) { saved != nil && !model.filtering }
        let bytes = try Data(contentsOf: chosen)
        precondition(saved == true && bytes == Data("edited snapshot copy\n".utf8))
        controller.close()
        precondition(!FileManager.default.fileExists(atPath: temporary.path) && FileManager.default.fileExists(atPath: chosen.path))
        print("PASS: captured read-only source becomes editable only through explicit Save As; later Save retains chosen file and Close removes private snapshots")
    }
    @MainActor static func review(root: URL, git: URL, prefs: UserDefaults, board: NSPasteboard) async throws {
        let folder = root.appendingPathComponent("review"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let repo = GitRepository(root: folder, executable: git), file = folder.appendingPathComponent("file"), target = root.appendingPathComponent("review-chosen")
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Save As QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: file); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        try Data("proposal\n".utf8).write(to: file); let patch = try await repo.run(["diff", "--binary", "HEAD", "--", "file"]).stdout
        _ = try await repo.run(["restore", "--", "file"])
        let controller = WorkingTreePatchWindowController(repository: repo, access: nil, fileAccess: nil, bytes: patch, title: "review.patch", preferences: prefs)
        defer { controller.close() }; let model = controller.model, window = controller.window!
        try await wait([window]) { !model.busy && model.editor?.filtering == false && model.afterScroll != nil }
        let index = try Data(contentsOf: folder.appendingPathComponent(".git/index"))
        model.setEditing(true); try await wait([window]) { model.editor?.canTransfer(toBase: false) == true }
        let editor = model.editor!, view = model.afterScroll!.documentView as! NSTextView
        type(view, "manual copy\n"); try await wait([window]) { editor.canTransfer(toBase: false) }
        editor.chooseExportLocation = { _, _, _ in target }; chooseSaveAs(view, prefs: prefs, board: board)
        try await wait([window]) { !editor.busy && !editor.filtering }
        precondition(editor.savedPaneURL(base: false) == target && !model.dirty && model.appliedPaths.isEmpty)
        type(view, "saved to chosen file\n"); try await wait([window]) { !editor.filtering }
        var saved: Bool?; model.saveDraft { saved = $0 }; try await wait([window]) { saved != nil && !model.busy && !editor.filtering }
        let selected = try Data(contentsOf: target), original = try Data(contentsOf: file)
        precondition(saved == true && selected == Data("saved to chosen file\n".utf8) && original == Data("base\n".utf8) && model.appliedPaths.isEmpty)
        type(view, "quit saves chosen\n"); try await wait([window]) { !editor.filtering && MergeRegexOperations.activeRequests == 0 }
        model.chooseDraft = { .save }
        let app = TurtleGitApplicationDelegate(); var reply: Bool?
        app.replyToTermination = { _, value in reply = value }
        precondition(app.applicationShouldTerminate(.shared) == .terminateLater)
        try await wait([window]) { reply != nil && !model.busy }
        let quitBytes = try Data(contentsOf: target), finalOriginal = try Data(contentsOf: file), finalIndex = try Data(contentsOf: folder.appendingPathComponent(".git/index"))
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        precondition(reply == true, "Quit Save refused: " + (editor.error ?? "no editor error") + "; dirty=" + String(model.dirty))
        precondition(quitBytes == Data("quit saves chosen\n".utf8), "Quit Save did not write chosen bytes")
        precondition(finalOriginal == original, "Quit Save mutated original file")
        precondition(finalIndex == index, "Quit Save mutated original index")
        precondition(finalHead == head && model.appliedPaths.isEmpty, "Quit Save changed HEAD or applied proposal")
        print("PASS: prepared Review Save As routes subsequent Save and owned Quit Save only to the chosen file; original proposal path, HEAD/index/applied flags unchanged")
    }
    @MainActor static func threePane(root: URL, prefs: UserDefaults, board: NSPasteboard) async throws {
        let folder = root.appendingPathComponent("three"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = folder.appendingPathComponent("base"), mine = folder.appendingPathComponent("mine"), theirs = folder.appendingPathComponent("theirs"), chosen = folder.appendingPathComponent("chosen-source"), output = folder.appendingPathComponent("merged")
        let originals = ["head\nbase\nend\n", "head\nmine\nend\n", "head\nbase\ntheirs\nend\n"]
        for (file, value) in zip([base, mine, theirs], originals) { try Data(value.utf8).write(to: file) }
        let controller = TextConflictWindowController(repository: GitRepository(root: folder), access: nil, path: "merge.txt", workingMerge: try WorkingTextMerge(base: base, theirs: theirs, mine: mine), preferences: prefs)
        defer { controller.close() }; let model = controller.model, window = controller.window!
        model.load(); try await wait([window]) { !model.busy && model.document != nil }
        var answer: ((NSApplication.ModalResponse) -> Void)?
        model.sourceExporter.present = { _, owner, completion in precondition(owner === window); answer = completion }
        model.sourceExporter.selectedURL = { _ in chosen }
        let bytes = try MergePaneSaveAs.sourceBytes(rows: model.sourceComparison!.rows, mine: true, encoding: model.document!.mineEncoding ?? model.document!.encoding)
        let beforeResult = model.result, beforeDirty = model.dirty
        model.exportSource(mine: true); precondition(model.exportingSource)
        answer?(.OK); try await wait([window]) { !model.exportingSource }
        let captured = try Data(contentsOf: chosen), untouched = try Data(contentsOf: mine)
        precondition(captured == bytes && untouched == Data(originals[1].utf8) && model.sourceTargetURL(mine: true) == chosen && model.result == beforeResult && model.dirty == beforeDirty)
        model.result = "<<<<<<< ours\nours\n=======\ntheirs\n>>>>>>> theirs\n"
        window.contentView?.layoutSubtreeIfNeeded(); model.continueResolving()
        precondition(model.selectedConflict == 0 && (model.selectionRequest == model.blocks.first?.range || descendants(window.contentView!).compactMap { $0 as? NSTextView }.contains { $0.selectedRange() == model.blocks.first?.range }) && model.sourceExporter.panel == nil)
        model.result = model.document!.workingContents.flatMap { model.document!.encoding.decode($0) } ?? model.document!.mine
        try Data("changed bound source\n".utf8).write(to: chosen); try FileManager.default.removeItem(at: mine)
        precondition(!model.dirty); model.load(); try await wait([window]) { !model.busy }
        precondition(model.document!.mine == "changed bound source\n" && model.sourceTargetURL(mine: true) == chosen)
        model.result = "merged chosen\n"; model.encoding = .utf16LEBOM
        model.chooseStandaloneOutput = { _, _ in output }; var saved: Bool?
        model.save(markResolved: false, completion: { saved = $0 }); try await wait([window]) { saved != nil }
        let merged = try Data(contentsOf: output)
        let expectedMerged = try ComparisonTextEncoding.utf16LEBOM.encode("merged chosen\n")
        precondition(saved == true && merged == expectedMerged)
        model.result = "quit-approved merge\n"; model.confirmingQuit = true; saved = nil
        model.saveForQuit { saved = $0 }; try await wait([window]) { saved != nil }; model.confirmingQuit = false
        let quitMerged = try Data(contentsOf: output), expectedQuitMerged = try ComparisonTextEncoding.utf16LEBOM.encode("quit-approved merge\n")
        precondition(saved == true && !model.dirty && quitMerged == expectedQuitMerged)

        precondition(!FileManager.default.fileExists(atPath: mine.path))
        let late = folder.appendingPathComponent("late")
        model.sourceExporter.selectedURL = { _ in late }; model.exportSource(mine: false); controller.close(); answer?(.OK)
        try await wait([]) { MergeSourceExport.activeExports == 0 }
        precondition(!FileManager.default.fileExists(atPath: late.path))
        let unchangedBase = try Data(contentsOf: base), unchangedTheirs = try Data(contentsOf: theirs)
        precondition(unchangedBase == Data(originals[0].utf8) && unchangedTheirs == Data(originals[2].utf8))
        print("PASS: three-pane source Save As binds source identity/Reload, retains result draft and original inputs, continues resolving, validates bound sources and fences retired destination replies")
    }
}
