import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class PreviewCloseGuard: NSObject, NSWindowDelegate {
    var requests = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool { requests += 1; return false }
}

@main struct ImportPatchVerification {
    @MainActor static func settle(_ model: ImportPatchWindowModel) async throws {
        for _ in 0..<1000 {
            if !model.receivingDrop && !model.busy && !model.closing && !model.openingViewer && !model.composingMail { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Import did not finish")
    }
    @MainActor static func fixture(_ directory: URL, _ git: URL, conflict: Bool = false) async throws -> (GitRepository, [URL]) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repo = GitRepository(root: directory, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Importer"]); _ = try await repo.run(["config", "user.email", "importer@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base\n".utf8).write(to: directory.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["switch", "-c", "feature"])
        var patches: [URL] = []
        for (index, file) in ["file", "other"].enumerated() {
            try Data("feature\n".utf8).write(to: directory.appendingPathComponent(file)); try await repo.stage([file])
            _ = try await repo.run(["-c", "user.name=Author 雪", "-c", "user.email=author@example.invalid", "commit", "-m", "Feature \(index)"])
            let patch = directory.appendingPathComponent("--mail 雪 \(index).patch")
            try await repo.run(["format-patch", "-1", "--stdout", "HEAD"]).stdout.write(to: patch); patches.append(patch)
        }
        _ = try await repo.run(["switch", "main"])
        if conflict { try Data("ours\n".utf8).write(to: directory.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "ours") }
        return (repo, patches)
    }
    @MainActor static func nativeTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.compactMap { nativeTable($0) }.first
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let (repo, patches) = try await fixture(root.appendingPathComponent("batch"), git)
        let suite = "TurtleGit.ImportPatch.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        let controller = ImportPatchWindowController(repository: repo, access: nil, preferences: prefs), model = controller.model
        // Prevent production error sheets. The layout host remains hidden and
        // uses its own preferences; no main app or user preference store runs.
        controller.window?.contentViewController = nil
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize(); model.invalidate(); controller.close() }
        let host = NSHostingView(rootView: AnyView(ImportPatchDialog(model: model).defaultAppStorage(prefs).environment(\.colorScheme, .light)))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        let (identityRepo, identityFiles) = try await fixture(root.appendingPathComponent("identity"), git)
        for key in ["user.name", "user.email", "author.name", "author.email", "committer.name", "committer.email"] { _ = try await identityRepo.run(["config", "--local", key, ""]) }
        _ = try await identityRepo.run(["config", "user.useConfigOnly", "true"])
        let identity = ImportPatchWindowModel(repository: identityRepo, access: nil, preferences: prefs)
        identity.add(identityFiles)
        let identityHead = try await identityRepo.run(["rev-parse", "HEAD"]).stdout
        var identityPrompts = 0
        identity.configureIdentity = { identityPrompts += 1; return false }
        identity.apply(); try await settle(identity)
        let cancelledHead = try await identityRepo.run(["rev-parse", "HEAD"]).stdout
        precondition(identityPrompts == 1 && cancelledHead == identityHead && identity.items.allSatisfy { $0.state == .pending } && identity.error == nil)
        identity.configureIdentity = {
            identityPrompts += 1
            precondition(identity.busy && !identity.editable)
            identity.add([identityFiles[0]]); identity.remove(); identity.apply()
            if identityPrompts == 2 { _ = try await identityRepo.run(["config", "--local", "user.name", "Native Importer 雪"]) }
            else { _ = try await identityRepo.run(["config", "--local", "user.email", "native@example.invalid"]) }
            return true
        }
        identity.apply(); try await settle(identity)
        precondition(identityPrompts == 3 && identity.finished && identity.items.count == 2)
        let identities = try await identityRepo.run(["log", "-2", "--format=%an <%ae>|%cn <%ce>"]).text
        precondition(identities.components(separatedBy: "Native Importer 雪 <native@example.invalid>").count == 3 && identities.contains("Author 雪 <author@example.invalid>"))
        identity.invalidate()
        print("PASS: missing identity Cancel preserves HEAD/pending rows; configuration callback retries after name-only change, locks mutations, then imports two real patches with original author and configured committer; no global settings changed or physical sheets invoked.")
        let (reviewRepo, reviewFiles) = try await fixture(root.appendingPathComponent("review-window"), git)
        let reviewBytes = try Data(contentsOf: reviewFiles[0]) + Data(contentsOf: reviewFiles[1])
        let reviewController = WorkingTreePatchWindowController(repository: reviewRepo, access: nil, fileAccess: nil, bytes: reviewBytes, title: "series.patch", preferences: prefs)
        defer { reviewController.close() }
        let reviewer = reviewController.model
        func waitReview() async throws {
            for _ in 0..<1000 { if !reviewer.busy { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            fatalError("Review did not settle")
        }
        try await waitReview()
        reviewController.window?.contentView?.layoutSubtreeIfNeeded()
        precondition(nativeTable(reviewController.window!.contentView!)?.numberOfRows == 2 && reviewer.canApply && reviewer.previewDocument.readOnly && reviewer.previewDocument.exportDocument.bytes == reviewBytes)
        let reviewIndex = try Data(contentsOf: reviewRepo.root.appendingPathComponent(".git/index")), reviewHead = try await reviewRepo.run(["rev-parse", "HEAD"]).stdout
        precondition(reviewer.comparison?.document.base.bytes == Data("base\n".utf8) && reviewer.comparison?.document.destination.bytes == Data("feature\n".utf8))
        for _ in 0..<100 {
            reviewController.window?.contentView?.layoutSubtreeIfNeeded()
            if reviewer.beforeScroll != nil && reviewer.afterScroll != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let beforeEditor = reviewer.beforeScroll!.documentView as! NSTextView, afterEditor = reviewer.afterScroll!.documentView as! NSTextView
        precondition(!beforeEditor.isEditable && !afterEditor.isEditable && beforeEditor.string == "base\n" && afterEditor.string == "feature\n")
        precondition(reviewer.beforeScroll!.rulersVisible && (reviewer.beforeScroll!.verticalRulerView as! MergeLineRuler).sourceNumbers == [1])
        for (editor, state) in [(beforeEditor, MergeSourceState.removed), (afterEditor, .added)] {
            let actual = (editor.textStorage!.attribute(.backgroundColor, at: 0, effectiveRange: nil) as! NSColor).usingColorSpace(.deviceRGB)!
            let expected = MergePalette.color(state).usingColorSpace(.deviceRGB)!
            precondition(abs(actual.redComponent - expected.redComponent) < 0.001 && abs(actual.greenComponent - expected.greenComponent) < 0.001 && abs(actual.blueComponent - expected.blueComponent) < 0.001)
        }
        reviewer.navigate(1); precondition(reviewer.difference == 0 && afterEditor.selectedRange().location == 0)
        reviewer.findComparison(); precondition(reviewer.afterScroll!.isFindBarVisible)
        reviewer.afterScroll!.isFindBarVisible = false
        let additionID = reviewer.review!.files.first { $0.path == "other" }!.id
        reviewer.focusFile(additionID); precondition(reviewer.busy); try await waitReview()
        precondition(reviewer.comparison?.document.base.mode == nil && reviewer.comparison?.document.destination.bytes == Data("feature\n".utf8))
        reviewer.focusFile(reviewer.review!.files.first { $0.path == "file" }!.id); try await waitReview()
        let previewHead = try await reviewRepo.run(["rev-parse", "HEAD"]).stdout
        let previewIndex = try Data(contentsOf: reviewRepo.root.appendingPathComponent(".git/index"))
        precondition(previewIndex == reviewIndex && previewHead == reviewHead)
        var reviewChanges = 0; reviewer.onChanged = { _ in reviewChanges += 1 }
        let firstFile = reviewer.review!.files.first { $0.path == "file" }!
        reviewer.check(firstFile.id, false); try await waitReview(); precondition(reviewer.canApply && reviewer.selected.count == 1)
        var parentBusy = true; reviewer.parentActive = { parentBusy }
        reviewer.apply(); reviewer.refresh(); reviewer.check(firstFile.id, true); precondition(!reviewer.busy && reviewer.selected.count == 1)
        parentBusy = false
        reviewController.setQuitConfirmation(true); reviewer.apply(); precondition(!reviewer.busy && reviewer.previewDocument.confirmingQuit); reviewController.setQuitConfirmation(false)
        reviewer.apply(); precondition(reviewer.busy && !reviewController.windowShouldClose(reviewController.window!))
        precondition(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        reviewer.refresh(); reviewer.check(firstFile.id, true); reviewer.setReversed(true); reviewer.setStripCount(0)
        precondition(!reviewer.reversed && reviewer.stripCount == 1)
        try await waitReview()
        let unselectedReviewFile = try Data(contentsOf: reviewRepo.root.appendingPathComponent("file")), appliedReviewFile = try Data(contentsOf: reviewRepo.root.appendingPathComponent("other"))
        precondition(unselectedReviewFile == Data("base\n".utf8) && appliedReviewFile == Data("feature\n".utf8))
        precondition(reviewChanges == 1 && reviewer.appliedPaths == [Data("other".utf8)] && reviewer.canApply)
        reviewer.apply(); try await waitReview(); precondition(reviewChanges == 2 && !reviewer.canApply && reviewer.selected.isEmpty)
        reviewer.setStripCount(0); precondition(reviewer.requiresRefresh && !reviewer.canApply)
        reviewer.check(firstFile.id, true); reviewer.apply(); precondition(!reviewer.busy && !reviewer.canApply)
        reviewer.setStripCount(1); reviewer.setReversed(true); precondition(reviewer.requiresRefresh && !reviewer.canApply)
        reviewer.check(firstFile.id, true); precondition(!reviewer.busy && !reviewer.canApply)
        reviewer.refresh(); try await waitReview(); precondition(reviewer.canApply && !reviewer.requiresRefresh)
        reviewer.apply(); try await waitReview()
        let reviewFinalHead = try await reviewRepo.run(["rev-parse", "HEAD"]).stdout
        let finalReviewFile = try Data(contentsOf: reviewRepo.root.appendingPathComponent("file")), finalReviewIndex = try Data(contentsOf: reviewRepo.root.appendingPathComponent(".git/index"))
        precondition(finalReviewFile == Data("base\n".utf8) && !FileManager.default.fileExists(atPath: reviewRepo.root.appendingPathComponent("other").path) && reviewIndex == finalReviewIndex && reviewHead == reviewFinalHead && reviewChanges == 3)
        precondition(reviewer.previewDocument.exportDocument.bytes == reviewBytes)
        print("PASS: actual hidden native Review Patch table/preview, checked-file application, remaining-file continuation and reverse; original bytes/HEAD/index retained, busy close/Quit/options/reentry guards; no main app or physical context gestures.")
        let longBefore = (0..<120).map { "line \($0)\n" }.joined()
        let longAfter = longBefore.replacingOccurrences(of: "line 75\n", with: "changed 75\n")
        let longPath = reviewRepo.root.appendingPathComponent("long")
        try Data(longBefore.utf8).write(to: longPath); try await reviewRepo.stage(["long"]); _ = try await reviewRepo.commit(message: "long preview")
        try Data(longAfter.utf8).write(to: longPath)
        let longBytes = try await reviewRepo.run(["diff", "--no-ext-diff", "--no-color", "--", "long"]).stdout
        _ = try await reviewRepo.run(["restore", "--", "long"])
        let scrollController = WorkingTreePatchWindowController(repository: reviewRepo, access: nil, fileAccess: nil, bytes: longBytes, title: "long.patch", preferences: prefs)
        defer { scrollController.close() }
        let scrollModel = scrollController.model
        for _ in 0..<1000 {
            scrollController.window?.contentView?.layoutSubtreeIfNeeded()
            if !scrollModel.busy && scrollModel.beforeScroll != nil && scrollModel.afterScroll != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(!scrollModel.busy && scrollModel.alignment?.rows.count == 120)
        let leftScroll = scrollModel.beforeScroll!, rightScroll = scrollModel.afterScroll!
        leftScroll.contentView.scroll(to: NSPoint(x: 0, y: 220)); leftScroll.reflectScrolledClipView(leftScroll.contentView)
        precondition(leftScroll.contentView.bounds.minY > 0 && abs(leftScroll.contentView.bounds.minY - rightScroll.contentView.bounds.minY) < 1)
        scrollModel.navigate(1)
        precondition(scrollModel.difference == 0 && (rightScroll.documentView as! NSTextView).selectedRange().location > 0)
        let unchangedLong = try Data(contentsOf: longPath)
        precondition(unchangedLong == Data(longBefore.utf8))
        print("PASS: actual hidden aligned before/after text, source Merge colors, line ruler, addition absence, Find bar, linked vertical scrolling and next-difference navigation; real worktree/HEAD/index unchanged by preview. No physical input/screenshot acceptance.")
        let (editRepo, editFiles) = try await fixture(root.appendingPathComponent("edited-review"), git)
        let editBytes = try Data(contentsOf: editFiles[0]) + Data(contentsOf: editFiles[1])
        let editController = WorkingTreePatchWindowController(repository: editRepo, access: nil, fileAccess: nil, bytes: editBytes, title: "edit.patch", preferences: prefs)
        defer { editController.close() }
        let edit = editController.model
        func waitEdit(_ condition: () -> Bool) async throws {
            for _ in 0..<1000 {
                editController.window?.contentView?.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            fatalError("Edited review did not settle")
        }
        try await waitEdit { !edit.busy && edit.afterScroll != nil }
        let editIndex = try Data(contentsOf: editRepo.root.appendingPathComponent(".git/index")), editHead = try await editRepo.run(["rev-parse", "HEAD"]).stdout
        var mergePreferences = MergeEditorPreferences.load(from: prefs); precondition(mergePreferences.autoAdd)
        mergePreferences.autoAdd = false; mergePreferences.save(to: prefs)
        precondition(!MergeEditorPreferences.load(from: prefs).autoAdd)
        edit.setEditing(true)
        try await waitEdit { (edit.afterScroll?.documentView as? NSTextView)?.isEditable == true }
        let editedView = edit.afterScroll!.documentView as! NSTextView
        precondition((edit.beforeScroll!.documentView as! NSTextView).isEditable == false)
        let menuClipboard = NSPasteboard.withUniqueName()
        defer { menuClipboard.releaseGlobally() }
        menuClipboard.declareTypes([.string], owner: nil); menuClipboard.setString("private paste", forType: .string)
        editedView.setSelectedRange(NSRange(location: 0, length: 4))
        let comparisonMenus = editedView as! ComparisonContextMenuProviding
        let menu = comparisonMenus.comparisonContextMenu(defaults: prefs, pasteboard: menuClipboard)
        precondition(["Copy", "Cut", "Paste"].allSatisfy { menu.item(withTitle: $0)?.image != nil && menu.item(withTitle: $0)?.isEnabled == true })
        precondition(["Copy", "Cut", "Paste"].allSatisfy { (menu.item(withTitle: $0)?.target as? NSTextView) === editedView })
        prefs.set(false, forKey: "ShowAppContextMenuIcons")
        precondition(comparisonMenus.comparisonContextMenu(defaults: prefs, pasteboard: menuClipboard).items.allSatisfy { $0.image == nil })
        prefs.removeObject(forKey: "ShowAppContextMenuIcons")
        for quit in [false, true] {
            edit.editor!.busy = !quit; edit.editor!.confirmingQuit = quit
            let lockedMenu = comparisonMenus.comparisonContextMenu(defaults: prefs, pasteboard: menuClipboard)
            precondition(!lockedMenu.item(withTitle: "Cut")!.isEnabled && !lockedMenu.item(withTitle: "Paste")!.isEnabled && lockedMenu.item(withTitle: "Copy")!.isEnabled)
        }
        edit.editor!.busy = false; edit.editor!.confirmingQuit = false
        menuClipboard.clearContents()
        precondition(!comparisonMenus.comparisonContextMenu(defaults: prefs, pasteboard: menuClipboard).item(withTitle: "Paste")!.isEnabled)
        let beforeView = edit.beforeScroll!.documentView as! NSTextView
        beforeView.setSelectedRange(NSRange(location: 0, length: min(1, (beforeView.string as NSString).length)))
        let beforeMenu = (beforeView as! ComparisonContextMenuProviding).comparisonContextMenu(defaults: prefs, pasteboard: menuClipboard)
        precondition(!beforeMenu.item(withTitle: "Cut")!.isEnabled && !beforeMenu.item(withTitle: "Paste")!.isEnabled)
        beforeView.setSelectedRange(NSRange(location: 0, length: 0)); editedView.setSelectedRange(NSRange(location: 0, length: 0)); edit.editor!.selectedRows = nil
        print("PASS: actual aligned comparison menu clipboard targets/artwork, icon-off policy without standard-selector glyph fallback, private Paste availability, read-only and busy/Quit editing metadata. No synthetic context events or general clipboard writes.")
        editedView.undoManager!.groupsByEvent = false
        editedView.undoManager!.beginUndoGrouping()
        editedView.insertText("custom\nno final newline", replacementRange: NSRange(location: 0, length: (editedView.string as NSString).length))
        editedView.undoManager!.endUndoGrouping()
        precondition(edit.dirty && edit.editor!.draftText(base: false) == "custom\nno final newline")
        edit.editor!.undo(); precondition(!edit.dirty && edit.editor!.draftText(base: false) == "feature\n")
        edit.editor!.redo(); precondition(edit.dirty && edit.editor!.draftText(base: false) == "custom\nno final newline")
        let pendingID = edit.focusedFile, pendingSelection = edit.selected
        edit.refresh(); edit.focusFile(nil); edit.setReversed(true); edit.setStripCount(0); edit.apply()
        precondition(edit.focusedFile == pendingID && edit.selected == pendingSelection && !edit.reversed && edit.stripCount == 1 && !edit.busy)
        var choices = 0; edit.chooseDraft = { choices += 1; return .cancel }
        precondition(!editController.windowShouldClose(editController.window!))
        try await waitEdit { choices == 1 && !edit.draftDecisionPending }
        precondition(edit.dirty && edit.editor!.draftText(base: false) == "custom\nno final newline")
        let quitEdit = TurtleGitApplicationDelegate(); var editReply: Bool?
        quitEdit.replyToTermination = { _, value in editReply = value }
        precondition(quitEdit.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await waitEdit { editReply != nil }
        precondition(editReply == false && edit.dirty && !edit.confirmingQuit)
        edit.chooseDraft = { choices += 1; return .save }; editReply = nil
        precondition(quitEdit.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await waitEdit { editReply != nil }
        let editedDisk = try Data(contentsOf: editRepo.root.appendingPathComponent("file")), afterEditedIndex = try Data(contentsOf: editRepo.root.appendingPathComponent(".git/index"))
        precondition(editReply == true && editedDisk == Data("custom\nno final newline".utf8) && editIndex == afterEditedIndex && !edit.dirty)
        // The receiver captures the reply; it never terminates NSApplication.
        try await waitEdit { !edit.busy && edit.afterScroll != nil && edit.comparison?.document.destination.path == "other" }
        mergePreferences.autoAdd = true; mergePreferences.save(to: prefs)
        edit.setEditing(true); try await waitEdit { (edit.afterScroll?.documentView as? NSTextView)?.isEditable == true }
        let newEditor = edit.afterScroll!.documentView as! NSTextView
        newEditor.insertText("new edited file\n", replacementRange: NSRange(location: 0, length: (newEditor.string as NSString).length))
        precondition(edit.dirty); edit.saveDraft(); precondition(edit.busy)
        precondition(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        try await waitEdit { !edit.busy }
        let stagedNew = try await editRepo.run(["show", ":other"]).stdout, stagedOriginal = try await editRepo.run(["show", ":file"]).stdout
        let finalEditHead = try await editRepo.run(["rev-parse", "HEAD"]).stdout
        precondition(stagedNew == Data("new edited file\n".utf8) && stagedOriginal == Data("base\n".utf8) && finalEditHead == editHead && !edit.dirty)
        _ = try await editRepo.run(["reset", "--hard", "HEAD"])
        edit.refresh(); try await waitEdit { !edit.busy && edit.afterScroll != nil }
        edit.setEditing(true); try await waitEdit { (edit.afterScroll?.documentView as? NSTextView)?.isEditable == true }
        let staleEditor = edit.afterScroll!.documentView as! NSTextView
        staleEditor.insertText("retained draft\n", replacementRange: NSRange(location: 0, length: (staleEditor.string as NSString).length))
        try Data("external change\n".utf8).write(to: editRepo.root.appendingPathComponent("file"))
        editReply = nil
        precondition(quitEdit.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await waitEdit { editReply != nil }
        precondition(editReply == false && edit.dirty && edit.editor!.draftText(base: false) == "retained draft\n")
        let externalFile = try Data(contentsOf: editRepo.root.appendingPathComponent("file")); precondition(externalFile == Data("external change\n".utf8))
        edit.chooseDraft = { choices += 1; return .discard }; editReply = nil
        precondition(quitEdit.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await waitEdit { editReply != nil }
        precondition(editReply == true && edit.dirty) // Don’t Save retains draft if another document cancels Quit.
        edit.discardDraft(); precondition(!edit.dirty && !edit.editingEnabled)
        print("PASS: real aligned native editing/Undo/Redo, draft transition locks and Close/Quit Cancel/Save/Don’t Save; edited bytes/no-final-newline saved, existing index/HEAD retained, default Auto Add stages only new result; stale save keeps draft and cancels Quit. Captured replies/injected choices, no physical sheets or app termination.")
        // Exercise ordinary FileSave separately from automatic PatchSave.
        let markRoot = root.appendingPathComponent("marked-save")
        try FileManager.default.createDirectory(at: markRoot, withIntermediateDirectories: true)
        let markBase = markRoot.appendingPathComponent("base"), markMine = markRoot.appendingPathComponent("mine")
        let baseText = "base one\ncommon\nbase two\nend", mineText = "local one\r\ncommon\r\nlocal two\r\nend"
        try Data(baseText.utf8).write(to: markBase)
        func markedTextView(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.compactMap { markedTextView($0) }.first
        }
        for ending in MergeLineEnding.allCases {
            let eol = ending.rawValue
            try Data("base\ntail".utf8).write(to: markBase)
            try Data(("mine" + eol + "tail").utf8).write(to: markMine)
            let endingModel = FileComparisonWindowModel(comparison: try WorkingFileComparison(base: markBase, destination: markMine), permissions: [])
            endingModel.editorPreferences = .load(from: prefs); endingModel.load()
            for _ in 0..<1000 { if !endingModel.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(endingModel.error == nil && endingModel.alignment!.rows.count == 2)
            let endingHost = NSHostingView(rootView: FileComparisonEditor(model: endingModel, cells: endingModel.alignment!.rows.map(\.destination), base: false))
            endingHost.frame = NSRect(x: 0, y: 0, width: 500, height: 300); endingHost.layoutSubtreeIfNeeded()
            let endingView = markedTextView(endingHost)!
            for _ in 0..<1000 { if endingView.isEditable { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(endingView.string == "mine\ntail\n")
            let endingHistory = endingView.undoManager!; endingHistory.groupsByEvent = false
            endingHistory.beginUndoGrouping(); endingView.insertText("typed\n", replacementRange: NSRange(location: 0, length: 0)); endingHistory.endUndoGrouping()
            precondition(endingModel.draftText(base: false) == "typed" + eol + "mine" + eol + "tail")
            endingModel.undo(); precondition(endingModel.draftText(base: false) == "mine" + eol + "tail")
            endingModel.redo(); precondition(endingModel.draftText(base: false) == "typed" + eol + "mine" + eol + "tail")
            var endingSaved: Bool?
            endingModel.save { endingSaved = $0 }
            for _ in 0..<1000 { if endingSaved != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            let endingBytes = try Data(contentsOf: markMine)
            precondition(endingSaved == true && endingBytes == Data(("typed" + eol + "mine" + eol + "tail").utf8))
            endingModel.selectedRows = 0..<1
            endingHistory.beginUndoGrouping(); endingModel.useOtherBlock(targetBase: false); endingHistory.endUndoGrouping()
            precondition(endingModel.draftText(base: false) == "base" + eol + "mine" + eol + "tail")
            endingSaved = nil; endingModel.save { endingSaved = $0 }
            for _ in 0..<1000 { if endingSaved != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            let transferredBytes = try Data(contentsOf: markMine), unchangedBase = try Data(contentsOf: markBase)
            precondition(endingSaved == true && transferredBytes == Data(("base" + eol + "mine" + eol + "tail").utf8))
            precondition(unchangedBase == Data("base\ntail".utf8))
            endingModel.resetHistory(); withExtendedLifetime(endingHost) {}
        }
        try Data(baseText.utf8).write(to: markBase)
        print("PASS: all nine line endings through actual native aligned display, insertText, private Undo/Redo, ordinary Save and other-block transfer; exact bytes and unterminated EOF, Base retained. No synthetic input or physical format-menu acceptance.")
        let markCases: [(FileComparisonEditing.MarkedSaveChoice?, Bool)] = [(nil, false), (.include, false), (.exclude, false), (.manualEditsOnly, false), (.include, true)]
        for (choice, stale) in markCases {
            try Data(mineText.utf8).write(to: markMine)
            let comparison = try WorkingFileComparison(base: markBase, destination: markMine)
            let markedModel = FileComparisonWindowModel(comparison: comparison, permissions: [])
            markedModel.editorPreferences = .load(from: prefs)
            markedModel.load()
            for _ in 0..<1000 { if !markedModel.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(markedModel.error == nil && markedModel.alignment != nil)
            let markedHost = NSHostingView(rootView: FileComparisonEditor(model: markedModel, cells: markedModel.alignment!.rows.map(\.destination), base: false))
            markedHost.frame = NSRect(x: 0, y: 0, width: 500, height: 300); markedHost.layoutSubtreeIfNeeded()
            markedModel.updateAnnotations(.init(marked: [0]), base: false)
            var prompts = 0, savedReply: Bool?
            markedModel.chooseMarkedSave = {
                prompts += 1; precondition(markedModel.busy)
                markedModel.load(); markedModel.save(); precondition(prompts == 1)
                if stale { try! Data("external writer".utf8).write(to: markMine) }
                return choice
            }
            let markHistory = markedTextView(markedHost)!.undoManager!
            markHistory.groupsByEvent = false; markHistory.beginUndoGrouping()
            markedModel.save { savedReply = $0 }
            for _ in 0..<1000 { if savedReply != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            markHistory.endUndoGrouping()
            precondition(prompts == 1 && !markedModel.busy)
            let expected: String
            switch choice {
            case .include: expected = "local one\r\ncommon\r\nbase two\r\nend"
            case .exclude: expected = "base one\r\ncommon\r\nlocal two\r\nend"
            case .manualEditsOnly: expected = "base one\r\ncommon\r\nbase two\r\nend"
            case nil: expected = mineText
            }
            let savedMine = try Data(contentsOf: markMine), retainedBase = try Data(contentsOf: markBase)
            precondition(savedMine == Data((stale ? "external writer" : expected).utf8))
            precondition(retainedBase == Data(baseText.utf8))
            precondition(savedReply == (choice != nil && !stale))
            if stale {
                precondition(markedModel.error != nil && markedModel.dirty)
                markedModel.undo()
                precondition(markedModel.draftText(base: false) == mineText && markedModel.annotations(base: false).marked == [0])
                let external = try Data(contentsOf: markMine); precondition(external == Data("external writer".utf8))
            } else if choice == nil { precondition(markedModel.dirty && markedModel.annotations(base: false).marked == [0]) }
            else {
                precondition(!markedModel.dirty && markedModel.annotations(base: false).marked.isEmpty)
                markedModel.undo()
                precondition(markedModel.dirty && markedModel.draftText(base: false) == mineText && markedModel.annotations(base: false).marked == [0])
                markedModel.redo(); precondition(!markedModel.dirty && markedModel.draftText(base: false) == expected)
            }
            markedModel.resetHistory()
            withExtendedLifetime(markedHost) {}
        }
        print("PASS: ordinary native FileSave marked-block Include/Exclude/Manual-only/Cancel; exact CRLF/no-final-newline bytes, Base retained, Cancel retains marks/draft, Undo/Redo restores policy text and marks, stale writes refused with draft/Undo retained, prompt locks prevent reentry. Injected sheet choices; physical sheets pending.")
        let dropped = ImportPatchWindowModel(repository: repo, access: nil, preferences: prefs)
        func provider(_ url: URL) -> NSItemProvider {
            let item = NSItemProvider()
            item.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in
                done(url.dataRepresentation, nil); return nil
            }
            return item
        }
        dropped.add([patches[0]])
        precondition(!dropped.receiveDrop([NSItemProvider(object: "text" as NSString)]))
        precondition(dropped.receiveDrop([provider(repo.root), provider(patches[1]), provider(patches[0]), provider(patches[1])]))
        precondition(dropped.receivingDrop && !dropped.editable)
        dropped.add([patches[0]]); dropped.apply(); dropped.remove(); dropped.requestClose()
        precondition(dropped.items.count == 1 && !dropped.busy && !dropped.closing)
        precondition(!dropped.receiveDrop([provider(patches[0])]))
        try await settle(dropped)
        precondition(dropped.items.map(\.file) == patches && dropped.items.allSatisfy { $0.checked && $0.state == .pending })
        let broken = NSItemProvider()
        broken.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in done(nil, MailPatchFailure.file); return nil }
        precondition(dropped.receiveDrop([broken, provider(patches[0])]))
        try await settle(dropped); precondition(dropped.editable && dropped.error != nil && dropped.items.count == 2)
        dropped.invalidate()
        print("PASS: native file URL providers preserve order, skip directories/duplicates, reject non-file providers; pending drops block edits/import/close/reentry, failed providers unlock controls; no pointer drag simulation.")
        model.add(patches + [patches[0]])
        let ids = model.items.map(\.id)
        model.selection = [ids[1]]; model.move(-1); precondition(model.items.map(\.id) == [ids[1], ids[0], ids[2]])
        model.move(1); precondition(model.items.map(\.id) == ids)
        model.selection = [ids[0], ids[1]]; model.move(-1); precondition(model.items.map(\.id) == ids)
        model.check(ids[2], false); precondition(!model.items[2].checked)
        model.selection = [ids[0]]
        for _ in 0..<30 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(nativeTable(host)?.numberOfRows == 3 && model.preview.contains("Feature 0"))
        func patchText(_ view: NSView) -> NSTextView? {
            if let text = view as? PatchTextView.PatchText { return text }
            return view.subviews.compactMap { patchText($0) }.first
        }
        func settleLayout() async throws {
            for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
        }
        func rgb(_ color: NSColor) -> UInt32 {
            let c = color.usingColorSpace(.sRGB)!
            return UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 | UInt32((c.blueComponent * 255).rounded())
        }
        func split(_ view: NSView) -> NSSplitView? {
            if let divider = view as? NSSplitView, divider.accessibilityLabel() == "Patch list and preview divider" { return divider }
            return view.subviews.compactMap { split($0) }.first
        }
        let nativeSplit = split(host)!
        let splitOwner = nativeSplit.delegate as! ImportPatchSplitController
        precondition(!nativeSplit.isVertical && splitOwner.upper.view.superview === nativeSplit && splitOwner.lower.view.superview === nativeSplit)
        nativeSplit.setPosition(270, ofDividerAt: 0); try await settleLayout()
        let savedHeight = splitOwner.upper.view.frame.height
        print("DIVIDER DIAGNOSTIC", nativeSplit.bounds, savedHeight, prefs.object(forKey: ImportPatchSplitController.positionKey) as Any); fflush(stdout)
        precondition(abs(savedHeight - 270) < 2 && abs(prefs.double(forKey: ImportPatchSplitController.positionKey) - savedHeight) < 1)
        let restored = ImportPatchSplitController(upper: AnyView(Text("List")), lower: AnyView(Text("Preview")), preferences: prefs)
        let restoredWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        restoredWindow.isReleasedWhenClosed = false; restoredWindow.contentViewController = restored
        restoredWindow.setContentSize(.init(width: 800, height: 440))
        defer { restoredWindow.contentViewController = nil; restoredWindow.close() }
        for _ in 0..<20 { restored.view.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(abs(restored.upper.view.frame.height - savedHeight) < 2)
        restoredWindow.setContentSize(.init(width: 800, height: 400))
        for _ in 0..<20 { restored.view.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(restored.upper.view.frame.height >= 219 && restored.lower.view.frame.height >= 159)
        SavedDataStore(preferences: prefs).clear(.dialogGeometry)
        precondition(prefs.object(forKey: ImportPatchSplitController.positionKey) == nil)
        precondition(!SavedDataStore(preferences: prefs).summary(.dialogGeometry).available)
        print("PASS: actual hidden horizontal NSSplitView, divider move persistence, new-controller restoration, smaller-window pane constraints and Saved Data geometry clearing; no pointer drag simulation.")
        let editor = patchText(host)!, added = (editor.string as NSString).range(of: "\n+feature\n").location + 1
        precondition(added > 0 && added < editor.string.utf16.count && !editor.isEditable && (editor.textStorage!.attribute(.font, at: added, effectiveRange: nil) as? NSFont)?.pointSize == 10)
        precondition(model.previewDocument.readOnly && !model.previewDocument.refreshAvailable)
        let originalPreview = try Data(contentsOf: patches[0]); precondition(model.previewDocument.exportDocument.bytes == originalPreview)
        let palette = UnifiedDiffAppearance()
        precondition(rgb(editor.textStorage!.attribute(.backgroundColor, at: added, effectiveRange: nil) as! NSColor) == palette.colors(.added, dark: false).background)
        host.rootView = AnyView(ImportPatchDialog(model: model).defaultAppStorage(prefs).environment(\.colorScheme, .dark))
        try await settleLayout()
        let darkEditor = patchText(host)!, darkAdded = (darkEditor.string as NSString).range(of: "\n+feature\n").location + 1
        precondition(rgb(darkEditor.textStorage!.attribute(.backgroundColor, at: darkAdded, effectiveRange: nil) as! NSColor) == palette.colors(.added, dark: true).background)
        var custom = palette; custom.fontSize = 17; custom.light[.added] = .init(0x123456, 0xabcdef); custom.save(to: prefs)
        host.rootView = AnyView(ImportPatchDialog(model: model).defaultAppStorage(prefs).environment(\.colorScheme, .light))
        try await settleLayout()
        let customEditor = patchText(host)!, customAdded = (customEditor.string as NSString).range(of: "\n+feature\n").location + 1
        precondition((customEditor.textStorage!.attribute(.font, at: customAdded, effectiveRange: nil) as? NSFont)?.pointSize == 17 && rgb(customEditor.textStorage!.attribute(.backgroundColor, at: customAdded, effectiveRange: nil) as! NSColor) == 0xabcdef)
        print("PASS: actual hidden Import Patch styled preview, source default font, light/dark added-line palettes, custom shared color/font and original export bytes; no physical screenshot acceptance.")
        let markerBytes = Data("+a b\tc\n+ \t雪😀 tail \n".utf8)
        model.previewDocument.setReadOnlyDiff(markerBytes); try await settleLayout()
        let markerEditor = patchText(host) as! PatchTextView.PatchText
        markerEditor.layoutManager?.ensureLayout(for: markerEditor.textContainer!)
        let beforeMarkers = markerEditor.string, marks = markerEditor.whitespaceMarks(in: markerEditor.bounds)
        precondition(marks.filter { $0.kind == .space }.count == 4 && marks.filter { $0.kind == .tab }.count == 2)
        precondition(marks.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 && $0.rect.intersects(markerEditor.bounds) })
        precondition(markerEditor.whitespaceMarks(in: NSRect(x: 100000, y: 100000, width: 10, height: 10)).isEmpty)
        markerEditor.setSelectedRange(NSRange(location: 0, length: (markerEditor.string as NSString).length))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let wroteMarkers = markerEditor.writeSelection(to: board, types: markerEditor.writablePasteboardTypes)
        print("COPY DIAGNOSTIC", wroteMarkers, markerEditor.selectedRange(), String(reflecting: beforeMarkers), String(reflecting: board.string(forType: .string))); fflush(stdout)
        precondition(wroteMarkers && board.string(forType: .string) == beforeMarkers)
        precondition(markerEditor.string == beforeMarkers && model.previewDocument.exportDocument.bytes == markerBytes)
        host.rootView = AnyView(ImportPatchDialog(model: model).defaultAppStorage(prefs).environment(\.colorScheme, .dark)); try await settleLayout()
        let darkMarks = patchText(host) as! PatchTextView.PatchText
        precondition(rgb(darkMarks.whitespaceColor) == 0xb4b4b4 && darkMarks.whitespaceMarks(in: darkMarks.bounds).count == 6)
        print("PASS: actual native glyph layout supplies four space/two tab markers including Unicode-adjacent whitespace; offscreen marks excluded; private-pasteboard copy, backing text and original export bytes unchanged; dark marker palette. Physical rendered appearance unverified.")
        darkMarks.setSelectedRange(NSRange(location: 0, length: 0))
        precondition(window.makeFirstResponder(darkMarks))
        darkMarks.showFind(nil); try await settleLayout()
        precondition(darkMarks.enclosingScrollView?.isFindBarVisible == true)
        let closeGuard = PreviewCloseGuard(); window.delegate = closeGuard; window.styleMask.insert(.closable)
        darkMarks.cancelOperation(nil); try await settleLayout()
        precondition(darkMarks.enclosingScrollView?.isFindBarVisible == false && window.firstResponder === darkMarks && closeGuard.requests == 0)
        darkMarks.find(.showFindInterface); try await settleLayout()
        precondition(darkMarks.enclosingScrollView?.isFindBarVisible == true)
        darkMarks.find(.hideFindInterface); try await settleLayout()
        darkMarks.cancelOperation(nil)
        precondition(closeGuard.requests == 1 && model.previewDocument.exportDocument.bytes == markerBytes)
        window.delegate = nil
        print("PASS: embedded ordinary NSWindow preview Find action shows native find bar; Cancel hides it and returns text focus before requesting guarded window close. No key events or shared Find pasteboard writes; search matching/physical keyboard unverified.")
        precondition(model.options.threeWay && model.options.ignoreSpaceChange && model.options.keepCR && !model.options.signOff)
        model.options.signOff = true; var refreshes = 0; model.onChanged = { _ in refreshes += 1 }
        model.apply(); precondition(model.busy)
        model.remove(); model.add(patches); model.check(ids[0], false); model.move(1)
        precondition(model.items.map(\.id) == ids && model.items[0].checked)
        try await settle(model)
        precondition(model.error == nil && model.finished && model.items.map(\.state) == [.success, .success, .skipped] && refreshes >= 2)
        let message = try await repo.run(["show", "-s", "--format=%an%n%B", "HEAD"]).text
        precondition(message.contains("Author 雪") && message.contains("Signed-off-by: Importer <importer@example.invalid>"))
        let count = try await repo.run(["rev-list", "--count", "HEAD"]).text; precondition(count.trimmingCharacters(in: .whitespacesAndNewlines) == "3")
        host.layoutSubtreeIfNeeded(); precondition(model.tab == 1)
        for action in MailPatchRecovery.allCases {
            let (conflicted, files) = try await fixture(root.appendingPathComponent(action.rawValue), git, conflict: true)
            let m = ImportPatchWindowModel(repository: conflicted, access: nil); defer { m.invalidate() }
            m.add(files); m.apply(); try await settle(m)
            precondition(m.items[0].state == .failed && m.items[1].state == .pending)
            let active = try await conflicted.mailPatchSession(); precondition(active == .applying)
            if action == .resolved { try Data("resolved\n".utf8).write(to: conflicted.root.appendingPathComponent("file")); try await conflicted.stage(["file"]) }
            m.chooseRecovery = { action }
            if action == .abort { m.onChanged = { _ in m.requestStop() } }
            m.apply(); try await settle(m)
            let session = try await conflicted.mailPatchSession(); precondition(session == .none)
            if action == .abort { precondition(m.items.map(\.state) == [.pending, .pending] && m.stopRequested) }
            else { precondition(m.finished && m.items[0].state == (action == .skip ? .skipped : .success) && m.items[1].state == .success) }
        }
        let (closingRepo, closeFiles) = try await fixture(root.appendingPathComponent("close"), git, conflict: true)
        let closing = ImportPatchWindowModel(repository: closingRepo, access: nil); defer { closing.invalidate() }
        closing.add(closeFiles); closing.apply(); try await settle(closing)
        var closes = 0; closing.close = { closes += 1 }
        closing.chooseClose = { .cancel }; closing.requestClose(); try await settle(closing); precondition(closes == 0)
        closing.chooseClose = { .keep }; closing.requestClose(); try await settle(closing); precondition(closes == 1)
        let retained = try await closingRepo.mailPatchSession(); precondition(retained == .applying)
        closing.chooseClose = { .abort }; closing.requestClose(); try await settle(closing); precondition(closes == 2)
        let cleared = try await closingRepo.mailPatchSession(); precondition(cleared == .none)

        // Make a real active am session temporarily unavailable without deleting it.
        let beforeUnavailableHead = try await closingRepo.run(["rev-parse", "HEAD"]).stdout
        closing.apply(); try await settle(closing)
        let gitDirectory = closingRepo.root.appendingPathComponent(".git"), heldDirectory = closingRepo.root.appendingPathComponent("held-git")
        let indexBefore = try Data(contentsOf: gitDirectory.appendingPathComponent("index"))
        let fileBefore = try Data(contentsOf: closingRepo.root.appendingPathComponent("file"))
        try FileManager.default.moveItem(at: gitDirectory, to: heldDirectory)
        var unknownPrompts = 0
        closing.chooseUnavailableClose = { reason in unknownPrompts += 1; precondition(!reason.isEmpty); return false }
        closing.requestClose(); try await settle(closing); precondition(closes == 2 && unknownPrompts == 1 && closing.editable)
        closing.chooseUnavailableClose = { _ in unknownPrompts += 1; return true }
        closing.requestClose(); try await settle(closing); precondition(closes == 3 && unknownPrompts == 2)
        let unknownIndex = try Data(contentsOf: heldDirectory.appendingPathComponent("index")), unknownFile = try Data(contentsOf: closingRepo.root.appendingPathComponent("file"))
        precondition(unknownIndex == indexBefore && unknownFile == fileBefore)
        try FileManager.default.moveItem(at: heldDirectory, to: gitDirectory)
        let retainedUnknown = try await closingRepo.mailPatchSession(), headAfterUnknown = try await closingRepo.run(["rev-parse", "HEAD"]).stdout
        precondition(retainedUnknown == .applying && headAfterUnknown == beforeUnavailableHead)
        _ = try await closingRepo.recoverMailPatch(.abort)
        print("PASS: unavailable Git directory during real active am: Cancel retains window, explicit close keeps HEAD/index/file/session intact, controls recover; no automatic abort.")
        let (quitRepo, quitFiles) = try await fixture(root.appendingPathComponent("quit"), git, conflict: true)
        let quitController = ImportPatchWindowController(repository: quitRepo, access: nil, preferences: prefs)
        quitController.window?.contentViewController = nil
        let quitModel = quitController.model
        defer { quitModel.invalidate(); quitController.close() }
        quitModel.add(quitFiles); quitModel.apply(); try await settle(quitModel)
        let quitHead = try await quitRepo.run(["rev-parse", "HEAD"]).stdout
        let application = TurtleGitApplicationDelegate()
        var replies: [Bool] = [], quitPrompts = 0, quitCloses = 0
        application.replyToTermination = { _, allow in replies.append(allow) }
        quitModel.close = { quitCloses += 1 }
        func waitReply(_ count: Int) async throws {
            for _ in 0..<1000 { if replies.count == count { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            fatalError("Missing deferred termination reply")
        }
        quitModel.chooseClose = {
            quitPrompts += 1
            precondition(quitModel.confirmingQuit && quitModel.closing && !quitModel.editable)
            quitModel.add([quitFiles[0]]); quitModel.remove(); quitModel.apply(); quitModel.requestClose()
            return .cancel
        }
        precondition(application.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        precondition(application.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await waitReply(1)
        let quitRetained = try await quitRepo.mailPatchSession(), cancelQuitHead = try await quitRepo.run(["rev-parse", "HEAD"]).stdout
        precondition(replies == [false] && quitPrompts == 1 && quitCloses == 0 && quitModel.editable && quitModel.items.count == 2 && quitRetained == .applying && cancelQuitHead == quitHead)
        quitModel.chooseClose = { quitPrompts += 1; return .keep }
        precondition(application.applicationShouldTerminate(NSApplication.shared) == .terminateLater); try await waitReply(2)
        let keepQuitSession = try await quitRepo.mailPatchSession()
        precondition(replies == [false, true] && quitCloses == 0 && keepQuitSession == .applying && quitModel.editable)
        quitModel.chooseClose = { quitPrompts += 1; return .abort }
        precondition(application.applicationShouldTerminate(NSApplication.shared) == .terminateLater); try await waitReply(3)
        let abortQuitSession = try await quitRepo.mailPatchSession()
        precondition(replies == [false, true, true] && quitPrompts == 3 && quitCloses == 0 && abortQuitSession == .none && quitModel.editable)
        print("PASS: actual application delegate defers Quit for idle real am conflict: Cancel/Keep/Abort replies, retained/aborted sessions, one pending quit, mutation locks reset; no premature window close or actual application termination.")
        let (slow, slowFiles) = try await fixture(root.appendingPathComponent("stop"), git)
        let hooks = slow.root.appendingPathComponent("hooks"); try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("applypatch-msg")
        try Data("#!/bin/sh\ntouch hook-started\nsleep 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = try await slow.run(["config", "core.hooksPath", hooks.path])
        let stopping = ImportPatchWindowModel(repository: slow, access: nil); defer { stopping.invalidate() }
        stopping.add(slowFiles); var stoppedClose = false; stopping.close = { stoppedClose = true }; stopping.apply()
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: slow.root.appendingPathComponent("hook-started").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(FileManager.default.fileExists(atPath: slow.root.appendingPathComponent("hook-started").path))
        stopping.requestClose(); precondition(stopping.busy && stopping.stopRequested && !stoppedClose)
        stopping.options.signOff = true // The active batch retains its option snapshot.
        try await settle(stopping)
        precondition(stopping.items.map(\.state) == [.success, .pending] && !stoppedClose)
        let stoppedMessage = try await slow.run(["show", "-s", "--format=%B", "HEAD"]).text
        precondition(!stoppedMessage.contains("Signed-off-by"))
        let context = ImportPatchWindowModel(repository: repo, access: nil); defer { context.invalidate() }
        let utf16 = root.appendingPathComponent("UTF16 雪.patch")
        let bytes = Data([0xff, 0xfe]) + "diff --git a/雪 b/雪\n+Unicode\n".data(using: .utf16LittleEndian)!
        try bytes.write(to: utf16)
        context.add(patches + [utf16]); let contextIDs = context.items.map(\.id)
        precondition(context.contextActions([]).isEmpty && context.contextActions([UUID()]).isEmpty)
        precondition(context.contextActions([contextIDs[0]]) == [.viewPatch, .reviewPatch, .sendMail])
        precondition(context.contextActions([contextIDs[0], contextIDs[1]]) == [.sendMail])
        var viewed: Data?, viewedTitle = "", usedAlternate = false
        context.showPatch = { data, title, alternate in
            viewed = data; viewedTitle = title; usedAlternate = alternate
            let readOnly = PatchWindowModel(repository: repo, access: nil); readOnly.setReadOnlyDiff(data)
            precondition(readOnly.readOnly && readOnly.exportDocument.bytes == bytes && !readOnly.canApplyHunks && !readOnly.canApplyLines)
        }
        context.viewPatch([contextIDs[2]], alternate: true)
        precondition(context.openingViewer && !context.editable && context.contextActions([contextIDs[0]]).isEmpty)
        context.selection = [contextIDs[0]]; context.remove(); context.add(patches)
        precondition(context.items.count == 3)
        try await settle(context); precondition(viewed == bytes && viewedTitle == utf16.lastPathComponent && usedAlternate)
        var attachments: [URL] = [], completeMail: ((String?) -> Void)?
        context.composeMail = { files, completion in attachments = files; completeMail = completion }
        context.sendMail([contextIDs[2], contextIDs[0]])
        precondition(context.composingMail && attachments == [patches[0], utf16] && !context.editable)
        context.requestClose(); context.apply(); context.remove(); precondition(!context.busy && !context.closing && context.items.count == 3)
        completeMail?("Mail fixture failed"); completeMail = nil
        precondition(!context.composingMail && context.error == "Mail fixture failed")
        context.error = nil
        var reviewHandoffs = 0
        context.showReview = { data, title, lease in
            reviewHandoffs += 1
            precondition(data == bytes && title == utf16.lastPathComponent && lease === context.items[2].access)
        }
        context.reviewPatch([contextIDs[2]])
        precondition(context.openingViewer && !context.editable)
        try await settle(context); precondition(reviewHandoffs == 1)
        context.reviewPatch([contextIDs[0], contextIDs[1]]); precondition(!context.openingViewer)
        context.showReview = { _, _, _ in throw MailPatchFailure.file }
        context.reviewPatch([contextIDs[0]]); try await settle(context)
        precondition(context.error != nil && context.editable); context.error = nil
        context.showPatch = { _, _, _ in throw MailPatchFailure.file }
        context.viewPatch([contextIDs[0]], alternate: false); try await settle(context)
        precondition(!context.openingViewer && context.error != nil && context.editable)
        context.viewPatch([contextIDs[0], contextIDs[1]], alternate: false); precondition(!context.openingViewer)
        print("PASS: source context selection policy; exact UTF-16 viewer bytes/title/Shift handoff and read-only export; review exact-byte/title/lease handoff and failures; viewer/mail mutation guards; ordered composition attachments; failure recovery. Injected handoffs, no external app or mail service invoked; native menu gestures remain unverified.")
        let large = root.appendingPathComponent("large.patch")
        FileManager.default.createFile(atPath: large.path, contents: Data())
        let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: 250 * 1024 * 1024); try handle.close()
        context.add([large]); context.selection = [context.items.last!.id]
        for _ in 0..<100 { if context.preview.contains("too large") { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(context.preview.contains("too large") && context.previewNotice != nil && context.previewDocument.exportDocument.bytes.isEmpty && context.items.last!.checked)
        context.selection = [contextIDs[2]]
        for _ in 0..<100 { if context.preview.contains("Unicode") { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(context.preview.contains("Unicode") && !context.preview.contains("�") && context.previewDocument.exportDocument.bytes == bytes)
        context.selection = [contextIDs[0], contextIDs[2]]; precondition(context.preview.isEmpty && context.previewDocument.exportDocument.bytes.isEmpty)
        print("PASS: source 250 MiB preview guard using sparse file; UTF-16 BOM preview decoded with original bytes retained; multiple-selection clear.")
        precondition(RepositoryAction.importPatch.icon == .patch && RepositoryAction.importPatch.requiresWorkingTree)
        print("PASS: hidden native patch table/preview; order, check, fixed batch options and mutation guards; two real mail commits/signoff; retained conflict cursor Abort/Skip/Resolved; close Cancel/Keep/Abort; real hook stop finishes current command without closing; original patch icon; no main app")
    }
}
