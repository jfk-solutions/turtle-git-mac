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
    @MainActor static func settleComparisons() async throws {
        for _ in 0..<2000 {
            if MergeRegexOperations.activeRequests == 0 { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Comparison helpers must settle before testing dirty-window Quit prompts")
    }
    @MainActor static func nativeTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.compactMap { nativeTable($0) }.first
    }
    @MainActor static func verifySingleLineNavigation(root:URL,prefs:UserDefaults,board:NSPasteboard) async throws {
        let folder=root.appendingPathComponent("single-line-navigation");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let a=folder.appendingPathComponent("base"),b=folder.appendingPathComponent("mine")
        try Data("base".utf8).write(to:a);try Data("mine".utf8).write(to:b)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs,deferInitialLoad:true)
        defer {owner.close()}
        guard let window=owner.window else{throw NSError(domain:"Single-line navigation: native owner window missing",code:1)}
        let model=owner.model
        window.alphaValue=0;window.setFrameOrigin(NSPoint(x:-20000,y:-20000));window.orderFront(nil)
        model.beginTransferredDocument()
        func text(_ root:NSView?)->NSTextView? {
            guard let root else{return nil}
            if let text=root as? NSTextView,let scroll=text.enclosingScrollView,
               model.ownsEditor(scroll,base:false),model.ownsViewport(scroll,base:false) {return text}
            return root.subviews.compactMap{text($0)}.first
        }
        for _ in 0..<1000 {
            window.contentView?.layoutSubtreeIfNeeded()
            if !model.busy,!model.filtering,!model.initialNavigationPending,
               let view=text(window.contentView),let navigation=view as? MergeLineNavigationProviding,
               navigation.navigationAllowed {break}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        guard model.error==nil,model.alignment?.rows.count==1,
              !model.busy,!model.filtering,!model.initialNavigationPending,
              let view=text(window.contentView),view.window === window,
              let navigation=view as? MergeLineNavigationProviding,navigation.navigationAllowed,
              let provider=view as? ComparisonContextMenuProviding else {
            throw NSError(domain:"Single-line navigation native presentation: busy=\(model.busy), filtering=\(model.filtering), initial=\(model.initialNavigationPending), rows=\(String(describing:model.alignment?.rows.count)), visible=\(window.isVisible), text=\(text(window.contentView) != nil), error=\(String(describing:model.error))",code:1)
        }
        let menu=provider.comparisonContextMenu(defaults:prefs,pasteboard:board)
        guard let goToLine=menu.item(withTitle:"Go to Line…"),!goToLine.isEnabled else {
            throw NSError(domain:"Single-line navigation: actual Go to Line command missing or enabled",code:1)
        }
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        if ProcessInfo.processInfo.environment["TURTLEGIT_OUTPUT_OWNERSHIP_ONLY"] == "1" { try await ComparisonOutputOwnershipVerification.run(root: root, git: git); return }
        if ProcessInfo.processInfo.environment["TURTLEGIT_IMPORT_LIFECYCLE_ONLY"] == "1" { try await ImportPatchLifecycleVerification.run(root: root, git: git); return }
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
            let expected = reviewer.editor!.palette.color(state).usingColorSpace(.deviceRGB)!
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
        // Linked native scrolling requires a live presented editor owner, even
        // though this private receiver must not display a window to the user.
        let scrollWindow = scrollController.window!
        scrollWindow.alphaValue = 0
        scrollWindow.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        scrollWindow.orderFront(nil)
        let scrollModel = scrollController.model
        func currentScrollPanes() -> Bool {
            guard !scrollModel.busy, let editor = scrollModel.editor,
                  !editor.filtering, !editor.initialNavigationPending, editor.canScrollViewport,
                  let left = scrollModel.beforeScroll, let right = scrollModel.afterScroll,
                  editor.ownsEditor(left, base: true), editor.ownsEditor(right, base: false),
                  editor.ownsViewport(left, base: true), editor.ownsViewport(right, base: false),
                  left.window === scrollWindow, right.window === scrollWindow,
                  let a = left.documentView as? NSTextView,
                  let b = right.documentView as? NSTextView,
                  a.window === scrollWindow, b.window === scrollWindow,
                  !a.isHiddenOrHasHiddenAncestor, !b.isHiddenOrHasHiddenAncestor else { return false }
            // Check the actual mounted text against the current model projection
            // without naming the implementation-private native view subclass.
            for (view, base) in [(a, true), (b, false)] {
                let cells = editor.displayCells(base: base)
                let expected = cells.map(\.displayText).joined(separator: "\n") + (cells.isEmpty ? "" : "\n")
                guard view.string.utf8.elementsEqual(expected.utf8) else { return false }
            }
            return a.frame.height > left.contentView.bounds.height + 220 && b.frame.height > right.contentView.bounds.height + 220
        }
        func scrollDiagnostic() -> String {
            let editor = scrollModel.editor
            return "busy=\(scrollModel.busy), filtering=\(String(describing: editor?.filtering)), pendingInitial=\(String(describing: editor?.initialNavigationPending)), canScroll=\(String(describing: editor?.canScrollViewport)), visible=\(scrollWindow.isVisible), left=\(String(describing: scrollModel.beforeScroll?.contentView.bounds)), right=\(String(describing: scrollModel.afterScroll?.contentView.bounds)), current=\(currentScrollPanes())"
        }
        for _ in 0..<1000 {
            scrollWindow.contentView?.layoutSubtreeIfNeeded()
            if currentScrollPanes() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard currentScrollPanes() else { throw NSError(domain: "ImportPatchScrollQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native scroll owner did not become ready: " + scrollDiagnostic()]) }
        // Source two-pane EOF repair retains a final empty NoEnding record.
        precondition(!scrollModel.busy && scrollModel.alignment?.rows.count == 121)
        let terminal=scrollModel.alignment!.rows.last!
        precondition(terminal.base.text.isEmpty && terminal.destination.text.isEmpty && terminal.base.lineNumber==121 && terminal.destination.lineNumber==121)
        precondition(scrollModel.alignment!.rows.map(\.base.text).joined()==longBefore && scrollModel.alignment!.rows.map(\.destination.text).joined()==longAfter)
        let leftScroll = scrollModel.beforeScroll!, rightScroll = scrollModel.afterScroll!
        leftScroll.contentView.scroll(to: NSPoint(x: 0, y: 220)); leftScroll.reflectScrolledClipView(leftScroll.contentView)
        for _ in 0..<1000 {
            scrollController.window?.contentView?.layoutSubtreeIfNeeded()
            if leftScroll.contentView.bounds.minY > 0 && abs(leftScroll.contentView.bounds.minY - rightScroll.contentView.bounds.minY) < 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard currentScrollPanes(), scrollModel.beforeScroll === leftScroll, scrollModel.afterScroll === rightScroll,
              leftScroll.contentView.bounds.minY > 0 && abs(leftScroll.contentView.bounds.minY - rightScroll.contentView.bounds.minY) < 1 else {
            throw NSError(domain: "ImportPatchScrollQA", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native linked scrolling failed: " + scrollDiagnostic()])
        }
        scrollModel.navigate(1)
        precondition(scrollModel.difference == 0 && (rightScroll.documentView as! NSTextView).selectedRange().location > 0)
        let unchangedLong = try Data(contentsOf: longPath)
        precondition(unchangedLong == Data(longBefore.utf8))
        scrollController.close()
        print("PASS: actual hidden aligned before/after text, source Merge colors, line ruler, addition absence, Find bar, linked vertical scrolling and next-difference navigation; real worktree/HEAD/index unchanged by preview. No physical input/screenshot acceptance.")
        let (editRepo, editFiles) = try await fixture(root.appendingPathComponent("edited-review"), git)
        let editBytes = try Data(contentsOf: editFiles[0]) + Data(contentsOf: editFiles[1])
        let editController = WorkingTreePatchWindowController(repository: editRepo, access: nil, fileAccess: nil, bytes: editBytes, title: "edit.patch", preferences: prefs)
        defer { editController.close() }
        let edit = editController.model
        func waitEdit(_ condition: () -> Bool, line: UInt = #line) async throws {
            for _ in 0..<1000 {
                editController.window?.contentView?.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            fatalError("Edited review did not settle at \(line): busy=\(edit.busy), editable=\(edit.editable), editing=\(edit.editingEnabled), dirty=\(edit.dirty), filtering=\(String(describing: edit.editor?.filtering)), pending=\(String(describing: edit.editor?.hasPendingEditorChoice)), error=\(String(describing: edit.editor?.error)), notice=\(edit.notice)")
        }
        try await waitEdit { !edit.busy && edit.afterScroll != nil }
        let editIndex = try Data(contentsOf: editRepo.root.appendingPathComponent(".git/index")), editHead = try await editRepo.run(["rev-parse", "HEAD"]).stdout
        var mergePreferences = MergeEditorPreferences.load(from: prefs); precondition(mergePreferences.autoAdd)
        mergePreferences.autoAdd = false; mergePreferences.save(to: prefs)
        precondition(!MergeEditorPreferences.load(from: prefs).autoAdd)
        edit.setEditing(true)
        try await waitEdit { edit.editor?.canTransfer(toBase: false) == true && (edit.afterScroll?.documentView as? NSTextView)?.isEditable == true }
        let editedView = edit.afterScroll!.documentView as! NSTextView
        precondition((edit.beforeScroll!.documentView as! NSTextView).isEditable == false)
        let menuClipboard = NSPasteboard.withUniqueName()
        defer { menuClipboard.releaseGlobally() }
        menuClipboard.declareTypes([.string], owner: nil); menuClipboard.setString("private paste", forType: .string)
        editedView.setSelectedRange(NSRange(location: 0, length: 4))
        let prompt = MergeLineNumberPrompt(limit: 2); defer { prompt.close() }
        for input in ["", "0", "3", "-1", "1.5", " 1", "１", "9999999999999999999999"] {
            prompt.field.stringValue = input; prompt.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            precondition(!prompt.ok.isEnabled && MergeLineNumberPrompt.validated(input, limit: 2) == nil)
        }
        prompt.field.stringValue = "02"; prompt.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        precondition(prompt.ok.isEnabled && MergeLineNumberPrompt.validated("02", limit: 2) == 2)
        let comparisonMenus = editedView as! ComparisonContextMenuProviding
        let menu = comparisonMenus.comparisonContextMenu(defaults: prefs, pasteboard: menuClipboard)
        precondition(menu.item(withTitle: "Go to Line…")!.isEnabled && edit.alignment?.rows.count==2) // Text plus source final NoEnding record.
        precondition(["Copy", "Cut", "Paste"].allSatisfy { menu.item(withTitle: $0)?.image != nil && menu.item(withTitle: $0)?.isEnabled == true })
        // Clipboard commands now own the injected private pasteboard through a
        // retained adapter. Verify its actual route instead of requiring the
        // text view itself to be the Objective-C action target.
        let copyCommand = menu.item(withTitle: "Copy")!
        precondition(copyCommand.target != nil && ["Cut", "Paste"].allSatisfy { menu.item(withTitle: $0)?.target === copyCommand.target })
        let copiedSelection = (editedView.string as NSString).substring(with: editedView.selectedRange())
        precondition(NSApp.sendAction(copyCommand.action!, to: copyCommand.target, from: copyCommand))
        precondition(menuClipboard.string(forType: .string) == copiedSelection && copiedSelection.count == 4)
        menuClipboard.clearContents(); menuClipboard.setString("private paste", forType: .string)
        prefs.set(false, forKey: "ShowAppContextMenuIcons")
        precondition(comparisonMenus.comparisonContextMenu(defaults: prefs, pasteboard: menuClipboard).items.allSatisfy { $0.image == nil })
        prefs.removeObject(forKey: "ShowAppContextMenuIcons")
        for quit in [false, true] {
            edit.editor!.busy = !quit; edit.editor!.confirmingQuit = quit
            let lockedMenu = comparisonMenus.comparisonContextMenu(defaults: prefs, pasteboard: menuClipboard)
            let commandStates = ["Copy", "Cut", "Paste"].map { lockedMenu.item(withTitle: $0)!.isEnabled }
            precondition(commandStates == [true, false, false], "Clipboard gates quit=\(quit), Copy/Cut/Paste=\(commandStates)")
            menuClipboard.clearContents()
            let lockedCopy = lockedMenu.item(withTitle: "Copy")!
            precondition(NSApp.sendAction(lockedCopy.action!, to: lockedCopy.target, from: lockedCopy))
            precondition(menuClipboard.string(forType: .string) == copiedSelection)
            menuClipboard.clearContents(); menuClipboard.setString("private paste", forType: .string)
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
        try await verifySingleLineNavigation(root:root,prefs:prefs,board:menuClipboard)
        @MainActor func verifyRetiredCopy(_ editor: FileComparisonWindowModel) {
            editor.retireImageLoader()
            precondition(!editor.copyCommandsAllowed)
            menuClipboard.clearContents(); menuClipboard.setString("retired sentinel", forType: .string)
            precondition(NSApp.sendAction(copyCommand.action!, to: copyCommand.target, from: copyCommand))
            precondition(menuClipboard.string(forType: .string) == "retired sentinel", "Retained Copy must not publish after retirement")
        }
        if ProcessInfo.processInfo.environment["TURTLEGIT_IMPORT_CLIPBOARD_ONLY"] == "1" {
            verifyRetiredCopy(edit.editor!)
            print("PASS: two-pane Copy dispatch while busy/Quit, guarded Cut/Paste and retained retired-editor Copy refusal; private clipboard only")
            return
        }
        precondition(edit.editor!.window === editController.window)
        let exportEditor = edit.editor!
        let beforeExportEncoding = exportEditor.encoding(base: false)!
        let beforeExportText = exportEditor.draftText(base: false)
        let exportDraft = "exported edit\nno final newline"
        editedView.undoManager!.groupsByEvent = false; editedView.undoManager!.beginUndoGrouping()
        editedView.insertText(exportDraft, replacementRange: NSRange(location: 0, length: (editedView.string as NSString).length))
        editedView.undoManager!.endUndoGrouping()
        precondition(exportEditor.draftText(base: false) == exportDraft)
        // The authoritative comparison engine finishes asynchronously after
        // insertText. Change Encoding is correctly refused while filtering.
        try await waitEdit { exportEditor.canTransfer(toBase: false) }
        precondition((edit.afterScroll?.documentView as? NSTextView) === editedView && exportEditor.canUndo,
                     "Authoritative comparison must retain the native editor and its Undo history")
        exportEditor.changeEncoding(.utf16LEBOM, base: false)
        precondition(edit.dirty && exportEditor.encoding(base: false) == .utf16LEBOM)
        var exportPending: CheckedContinuation<URL?, Never>?, exportChoices = 0
        exportEditor.chooseExportLocation = { window, name, directory in
            exportChoices += 1
            precondition(window === editController.window && name == "file" && directory == editRepo.root)
            precondition(exportEditor.exporting && exportEditor.busy && editController.activeOperation && !edit.editable)
            let focus = edit.focusedFile, reverse = edit.reversed, strip = edit.stripCount
            edit.refresh(); edit.focusFile(nil); edit.setReversed(!reverse); edit.setStripCount(strip + 1); edit.apply()
            exportEditor.export(base: true); exportEditor.changeEncoding(.utf8, base: false)
            precondition(edit.focusedFile == focus && edit.reversed == reverse && edit.stripCount == strip && exportEditor.encoding(base: false) == .utf16LEBOM,
                         "Export lock: focus=\(String(describing: edit.focusedFile))/\(String(describing: focus)), reverse=\(edit.reversed)/\(reverse), strip=\(edit.stripCount)/\(strip), encoding=\(String(describing: exportEditor.encoding(base: false)))")
            precondition(!editController.windowShouldClose(editController.window!))
            precondition(TurtleGitApplicationDelegate().applicationShouldTerminate(.shared) == .terminateCancel)
            return await withCheckedContinuation { exportPending = $0 }
        }
        let exportedResult = root.appendingPathComponent("saved-result 雪.txt")
        // Save As legitimately creates missing parent directories. A regular
        // file in the parent position is a real structural write failure on all
        // hosts, independent of root privileges or a writable temporary folder.
        let blockedExportParent = root.appendingPathComponent("blocked-export-parent")
        let blockedExportBytes = Data("owned export parent sentinel\n".utf8)
        try blockedExportBytes.write(to: blockedExportParent)
        for target in [URL?.none, exportedResult, blockedExportParent.appendingPathComponent("result")] {
            exportEditor.export(base: false); precondition(exportEditor.exporting && exportEditor.busy)
            try await waitEdit { exportPending != nil }
            let pending = exportPending!; exportPending = nil; pending.resume(returning: target)
            try await waitEdit { !exportEditor.exporting && !exportEditor.busy }
            precondition(edit.dirty && exportEditor.encoding(base: false) == .utf16LEBOM)
        }
        let exportedBytes = try Data(contentsOf: exportedResult)
        let expectedExportBytes = try ComparisonTextEncoding.utf16LEBOM.encode(exportDraft)
        precondition(exportChoices == 3 && exportedBytes == expectedExportBytes)
        guard exportEditor.error != nil else {
            throw NSError(domain:"Import export structural failure did not report an error: choices=\(exportChoices), busy=\(exportEditor.busy), exporting=\(exportEditor.exporting), parentExists=\(FileManager.default.fileExists(atPath:blockedExportParent.path))",code:1)
        }
        guard edit.appliedPaths.isEmpty else {throw NSError(domain:"Export applied repository paths: \(edit.appliedPaths)",code:1)}
        let retainedExportParent = try Data(contentsOf:blockedExportParent)
        precondition(retainedExportParent == blockedExportBytes,"Failed export changed its regular-file parent")
        let unchangedExportIndex = try Data(contentsOf: editRepo.root.appendingPathComponent(".git/index"))
        let unchangedExportHead = try await editRepo.run(["rev-parse", "HEAD"]).stdout
        let unchangedExportWork = try Data(contentsOf: editRepo.root.appendingPathComponent("file"))
        precondition(unchangedExportIndex == editIndex && unchangedExportHead == editHead && unchangedExportWork == Data("base\n".utf8))
        exportEditor.error = nil
        func exportHistoryReady()->Bool {
            guard edit.editor === exportEditor,!exportEditor.filtering,!exportEditor.initialNavigationPending,
                  exportEditor.historyActionsAllowed,exportEditor.canTransfer(toBase:false),
                  let scroll=edit.afterScroll,exportEditor.ownsEditor(scroll,base:false),exportEditor.ownsViewport(scroll,base:false),
                  scroll.documentView === editedView,editedView.window === editController.window else{return false}
            let cells=exportEditor.displayCells(base:false)
            let expected=cells.map(\.displayText).joined(separator:"\n")+(cells.isEmpty ? "":"\n")
            return editedView.string.utf8.elementsEqual(expected.utf8)
        }
        try await waitEdit {exportHistoryReady() && exportEditor.canUndo}
        // Change Encoding is a real history entry. Export does not add one:
        // first Undo restores the format, then Undo restores the typed draft.
        // Restoring encoding by another command here would add another entry.
        exportEditor.undo()
        try await waitEdit {exportHistoryReady() && exportEditor.encoding(base:false)==beforeExportEncoding}
        precondition(exportEditor.draftText(base:false)==exportDraft && edit.dirty,"Export format Undo changed the typed draft or savepoint")
        precondition(exportEditor.canUndo,"Export format Undo lost the preceding text edit")
        exportEditor.undo()
        try await waitEdit {exportHistoryReady() && exportEditor.draftText(base:false)==beforeExportText && exportEditor.encoding(base:false)==beforeExportEncoding}
        precondition(exportEditor.draftText(base: false) == beforeExportText, "Export Undo: text=\(String(reflecting: exportEditor.draftText(base: false))) original=\(String(reflecting: beforeExportText)), canUndo=\(exportEditor.canUndo), busy=\(exportEditor.busy), quit=\(exportEditor.confirmingQuit)")
        precondition(!edit.dirty, "Export Undo: encoding=\(String(describing: exportEditor.encoding(base: false))) original=\(beforeExportEncoding), filtering=\(exportEditor.filtering)")
        exportEditor.resetHistory()
        try await waitEdit { editedView.isEditable }
        print("PASS: prepared editor Save As owns review window; injected Cancel/success/write-failure unlocks controls, exact UTF16 BOM export retains dirty draft and repository HEAD/index/worktree/applied paths, pending export blocks refresh/options/reentry/Close/Quit. No physical save panel or signed access.")
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
        try await settleComparisons()
        precondition(quitEdit.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await waitEdit { editReply != nil }
        precondition(editReply == false && edit.dirty && !edit.confirmingQuit)
        edit.chooseDraft = { choices += 1; return .save }; editReply = nil
        try await settleComparisons()
        precondition(quitEdit.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await waitEdit { editReply != nil }
        let editedDisk = try Data(contentsOf: editRepo.root.appendingPathComponent("file")), afterEditedIndex = try Data(contentsOf: editRepo.root.appendingPathComponent(".git/index"))
        precondition(editReply == true && editedDisk == Data("custom\nno final newline".utf8) && editIndex == afterEditedIndex && !edit.dirty,
                     "Quit Save outcome: reply=\(String(describing:editReply)),disk=\(String(reflecting:String(decoding:editedDisk,as:UTF8.self))),diskBytes=\(editedDisk as NSData),indexUnchanged=\(editIndex==afterEditedIndex),dirty=\(edit.dirty),busy=\(edit.busy),decision=\(edit.draftDecisionPending),confirmingQuit=\(edit.confirmingQuit),notice=\(String(reflecting:edit.notice)),output=\(String(reflecting:edit.output)),editorText=\(String(reflecting:edit.editor?.draftText(base:false))),editorEncoding=\(String(describing:edit.editor?.encoding(base:false))),editorError=\(String(reflecting:edit.editor?.error)),editorFiltering=\(String(describing:edit.editor?.filtering)),editorChoices=\(String(describing:edit.editor?.hasPendingEditorChoice)),ownerSheet=\(editController.window?.attachedSheet != nil)")
        // The receiver captures the reply; it never terminates NSApplication.
        try await waitEdit { !edit.busy && !edit.editor!.filtering && edit.afterScroll != nil }
        precondition(edit.editor === exportEditor && edit.editor!.draftText(base: false) == "custom\nno final newline" && !edit.dirty && !edit.canSaveDraft)
        precondition(edit.editor!.document!.destination.bytes == editedDisk && edit.editor!.document!.base.bytes == Data("base\n".utf8))
        precondition(edit.focusedFile == pendingID && edit.appliedPaths.contains(Data("file".utf8)))
        precondition((edit.afterScroll?.documentView as? NSTextView) === editedView, "Save must retain the completed native preview")
        let nextFile = edit.review!.files.first { $0.path == "other" }!
        edit.focusFile(nextFile.id)
        try await waitEdit { !edit.busy && edit.afterScroll != nil && edit.comparison?.document.destination.path == "other" }
        mergePreferences.autoAdd = true; mergePreferences.save(to: prefs)
        edit.setEditing(true); try await waitEdit { (edit.afterScroll?.documentView as? NSTextView)?.isEditable == true }
        let newEditor = edit.afterScroll!.documentView as! NSTextView
        newEditor.insertText("new edited file\n", replacementRange: NSRange(location: 0, length: (newEditor.string as NSString).length))
        // Native rows use LF display separators. Source-created files retain
        // their default CRLF serialization independently of that display.
        let newSerialized=edit.editor!.draftText(base:false),newEncoding=edit.editor!.encoding(base:false)!
        let expectedNewSerialized="new edited file\r\n"
        precondition(MergeLineEndings.boundaries(in:newSerialized).map(\.style)==[.crlf],"New file lost source default CRLF ending")
        let expectedNewBytes=try newEncoding.encode(expectedNewSerialized)
        precondition(edit.dirty && newEditor.string=="new edited file\n" && newSerialized==expectedNewSerialized,
                     "New-file edit receipt: path=\(String(describing:edit.comparison?.document.destination.path)),nativeText=\(String(reflecting:newEditor.string)),draft=\(String(reflecting:edit.editor?.draftText(base:false))),dirty=\(edit.dirty),encoding=\(String(describing:edit.editor?.encoding(base:false)))")
        edit.saveDraft(); precondition(edit.busy)
        precondition(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        try await waitEdit { !edit.busy }
        let stagedNew = try await editRepo.run(["show", ":other"]).stdout, stagedOriginal = try await editRepo.run(["show", ":file"]).stdout
        let finalEditHead = try await editRepo.run(["rev-parse", "HEAD"]).stdout
        let autoAddDisk=try Data(contentsOf:editRepo.root.appendingPathComponent("other"))
        precondition(stagedNew == expectedNewBytes && autoAddDisk == expectedNewBytes && stagedOriginal == Data("base\n".utf8) && finalEditHead == editHead && !edit.dirty,
                     "New-file Auto Add: stagedNew=\(stagedNew as NSData),stagedNewText=\(String(reflecting:String(decoding:stagedNew,as:UTF8.self))),stagedOriginal=\(stagedOriginal as NSData),HEADUnchanged=\(finalEditHead==editHead),disk=\(autoAddDisk as NSData),dirty=\(edit.dirty),busy=\(edit.busy),path=\(String(describing:edit.comparison?.document.destination.path)),encoding=\(String(describing:edit.editor?.encoding(base:false))),editorError=\(String(reflecting:edit.editor?.error)),notice=\(String(reflecting:edit.notice)),output=\(String(reflecting:edit.output)),requiresRefresh=\(edit.requiresRefresh),autoAddPreference=\(MergeEditorPreferences.load(from:prefs).autoAdd),draft=\(String(reflecting:edit.editor?.draftText(base:false))),ownerSheet=\(editController.window?.attachedSheet != nil)")
        _ = try await editRepo.run(["reset", "--hard", "HEAD"])
        edit.refresh(); try await waitEdit { !edit.busy && edit.afterScroll != nil }
        // Refresh preserves the explicitly viewed file. Select the file whose
        // bytes this stale-save case changes, rather than assuming a redirect.
        let staleFile = edit.review!.files.first { $0.path == "file" }!
        edit.focusFile(staleFile.id)
        try await waitEdit { !edit.busy && edit.focusedFile == staleFile.id && edit.afterScroll != nil }
        edit.setEditing(true); try await waitEdit { (edit.afterScroll?.documentView as? NSTextView)?.isEditable == true }
        let staleEditor = edit.afterScroll!.documentView as! NSTextView
        precondition(MergeLineEndings.boundaries(in:edit.editor!.draftText(base:false)).first?.style == .lf,"Existing source file lost its LF ending before stale-save edit")
        staleEditor.insertText("retained draft\n", replacementRange: NSRange(location: 0, length: (staleEditor.string as NSString).length))
        let retainedSerialized=edit.editor!.draftText(base:false)
        precondition(retainedSerialized=="retained draft\n" && MergeLineEndings.boundaries(in:retainedSerialized).map(\.style)==[.lf],"Existing-file native edit did not preserve source LF serialization")
        try Data("external change\n".utf8).write(to: editRepo.root.appendingPathComponent("file"))
        editReply = nil
        try await settleComparisons()
        precondition(quitEdit.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await waitEdit { editReply != nil }
        precondition(editReply == false && edit.dirty && edit.editor!.draftText(base: false) == retainedSerialized,
                     "Stale Quit Save: reply=\(String(describing:editReply)),dirty=\(edit.dirty),draft=\(String(reflecting:edit.editor?.draftText(base:false))),notice=\(String(reflecting:edit.notice)),output=\(String(reflecting:edit.output))")
        let externalFile = try Data(contentsOf: editRepo.root.appendingPathComponent("file")); precondition(externalFile == Data("external change\n".utf8))
        edit.chooseDraft = { choices += 1; return .discard }; editReply = nil
        try await settleComparisons()
        precondition(quitEdit.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await waitEdit { editReply != nil }
        precondition(editReply == true && edit.dirty) // Don’t Save retains draft if another document cancels Quit.
        edit.discardDraft(); precondition(!edit.dirty && !edit.editingEnabled)
        print("PASS: real aligned native editing/Undo/Redo, draft transition locks and Close/Quit Cancel/Save/Don’t Save; edited bytes/no-final-newline saved, existing index/HEAD retained, default Auto Add stages only new result; stale save keeps draft and cancels Quit. Captured replies/injected choices, no physical sheets or app termination.")
        // The real Quit continuation owns an empty-result sheet too. Ordinary
        // save admission remains blocked, and a retired owner's late reply
        // cannot publish the empty draft.
        @MainActor func emptyQuit(_ name:String,retireWhileQuestion:Bool)async throws {
            let (repo,files)=try await fixture(root.appendingPathComponent(name),git)
            let bytes=try Data(contentsOf:files[0])+Data(contentsOf:files[1])
            let owner=WorkingTreePatchWindowController(repository:repo,access:nil,fileAccess:nil,bytes:bytes,title:name+".patch",preferences:prefs)
            defer{owner.close()}
            let child=owner.model
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(NSPoint(x:-24000,y:-24000));owner.window?.orderFront(nil)
            func settled(_ condition:()->Bool)async throws {
                for _ in 0..<2000 {owner.window?.contentView?.layoutSubtreeIfNeeded();if condition(){return};try await Task.sleep(nanoseconds:5_000_000)}
                preconditionFailure("Empty Quit did not settle: busy=\(child.busy),dirty=\(child.dirty),quit=\(child.confirmingQuit),decision=\(child.draftDecisionPending),notice=\(child.notice),sheet=\(owner.window?.attachedSheet != nil)")
            }
            try await settled{!child.busy && child.editor != nil && !child.editor!.filtering && child.afterScroll != nil}
            child.setEditing(true)
            try await settled{(child.afterScroll?.documentView as? NSTextView)?.isEditable==true}
            let native=child.afterScroll!.documentView as! NSTextView
            native.insertText("",replacementRange:NSRange(location:0,length:native.string.utf16.count))
            try await settled{child.dirty && child.editor?.filtering==false}
            let file=repo.root.appendingPathComponent("file"),before=try Data(contentsOf:file),beforeIndex=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
            var question:NSAlert?,late:((NSApplication.ModalResponse)->Void)?
            child.presentSaveQuestion={alert,answer in question=alert;late=answer;alert.window.alphaValue=0;alert.window.setFrameOrigin(NSPoint(x:-24000,y:-24000));alert.beginSheetModal(for:owner.window!,completionHandler:answer)}
            child.chooseDraft={.save}
            let delegate=TurtleGitApplicationDelegate();var reply:Bool?
            delegate.replyToTermination={_,allow in reply=allow}
            try await settleComparisons()
            precondition(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
            try await settled{question?.window.sheetParent === owner.window && child.confirmingQuit && child.draftDecisionPending}
            precondition(child.busy && reply==nil)
            if retireWhileQuestion {
                owner.close();late?(.alertFirstButtonReturn);late?(.alertSecondButtonReturn)
                try await settled{reply != nil && !child.busy && question?.window.sheetParent==nil}
                precondition(reply==false,"Retired Quit Save accepted a late empty-result choice")
            } else {
                let keep=question!.buttons.first{$0.title=="Cancel — Keep Empty File"}!
                keep.performClick(nil)
                try await settled{reply != nil && !child.busy && question?.window.sheetParent==nil}
                precondition(reply==true && !child.dirty,"Owned Quit Save did not honor real keep-empty answer")
            }
            let finalIndex=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
            let disk=try Data(contentsOf:repo.root.appendingPathComponent("file"))
            precondition(disk==(retireWhileQuestion ? before:Data()),"Empty Quit Save changed the wrong bytes")
            precondition(finalIndex==beforeIndex && finalHead==head,"Empty Quit Save changed index or refs")
        }
        try await emptyQuit("empty-quit-save",retireWhileQuestion:false)
        try await emptyQuit("empty-quit-retired",retireWhileQuestion:true)

        // Exercise ordinary FileSave separately from automatic PatchSave.
        let markRoot = root.appendingPathComponent("marked-save")
        try FileManager.default.createDirectory(at: markRoot, withIntermediateDirectories: true)
        let markBase = markRoot.appendingPathComponent("base"), markMine = markRoot.appendingPathComponent("mine")
        let baseText = "base one\ncommon\nbase two\nend", mineText = "local one\r\ncommon\r\nlocal two\r\nend"
        try Data(baseText.utf8).write(to: markBase)
        func ownedDestination(_ owner:FileComparisonWindowController)->NSTextView? {
            guard let window=owner.window else{return nil}
            func find(_ root:NSView)->NSTextView? {
                if let view=root as? NSTextView,let scroll=view.enclosingScrollView,
                   view.window === window,!view.isHiddenOrHasHiddenAncestor,
                   owner.model.ownsEditor(scroll,base:false),owner.model.ownsViewport(scroll,base:false) {return view}
                return root.subviews.compactMap{find($0)}.first
            }
            return window.contentView.flatMap{find($0)}
        }
        func mountedComparison(_ comparison:WorkingFileComparison)async throws->(FileComparisonWindowController,NSTextView) {
            let owner=FileComparisonWindowController(comparison:comparison,permissions:[],preferences:prefs,deferInitialLoad:true)
            guard let window=owner.window else{throw NSError(domain:"Comparison native owner missing",code:1)}
            window.alphaValue=0;window.setFrameOrigin(NSPoint(x:-24000,y:-24000));window.orderFront(nil)
            let model=owner.model;model.beginTransferredDocument()
            for _ in 0..<2000 {
                window.contentView?.layoutSubtreeIfNeeded()
                if !model.busy,!model.filtering,!model.initialNavigationPending,!model.reloadPositionPending,
                   !model.lineWrapping.isGeometryPending,model.alignmentSelections.isEmpty,model.selectionRequest==nil,
                   let view=ownedDestination(owner),let navigation=view as? MergeLineNavigationProviding,navigation.navigationAllowed {
                    let cells=model.displayCells(base:false),expected=cells.map(\.displayText).joined(separator:"\n")+(cells.isEmpty ? "":"\n")
                    if model.error==nil,view.string.utf8.elementsEqual(expected.utf8) {
                        model.activatePane(base:false);model.editingEnabled=true
                        if view.isEditable,window.makeFirstResponder(view),window.firstResponder === view {return(owner,view)}
                    }
                }
                try await Task.sleep(nanoseconds:5_000_000)
            }
            owner.close()
            throw NSError(domain:"Comparison native presentation failed: busy=\(model.busy),filtering=\(model.filtering),initial=\(model.initialNavigationPending),geometry=\(model.lineWrapping.isGeometryPending),error=\(String(reflecting:model.error))",code:1)
        }
        func acknowledgeComparisonError(_ owner:FileComparisonWindowController)async throws {
            let message=owner.model.error ?? ""
            for _ in 0..<2000 {
                if let sheet=owner.window?.attachedSheet,let content=sheet.contentView {
                    func all(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap{all($0)}}
                    let children=all(content)
                    let labels=children.compactMap{$0 as? NSTextField}.map(\.stringValue)
                    if labels.contains(where:{$0.contains("Comparison failed") || !message.isEmpty && $0.contains(message)}),
                       let ok=children.compactMap({$0 as? NSButton}).first(where:{$0.title=="OK" && $0.isEnabled}) {
                        ok.performClick(nil)
                        for _ in 0..<2000 {
                            if owner.model.error==nil,sheet.sheetParent==nil,owner.window?.attachedSheet==nil {return}
                            try await Task.sleep(nanoseconds:5_000_000)
                        }
                        break
                    }
                }
                try await Task.sleep(nanoseconds:5_000_000)
            }
            throw NSError(domain:"Comparison error sheet did not drain: "+message,code:1)
        }
        for ending in MergeLineEnding.allCases {
            let eol = ending.rawValue
            try Data("base\ntail".utf8).write(to: markBase)
            try Data(("mine" + eol + "tail").utf8).write(to: markMine)
            let (endingOwner,endingView)=try await mountedComparison(WorkingFileComparison(base:markBase,destination:markMine))
            defer{endingOwner.close()}
            let endingModel=endingOwner.model,navigationWindow=endingOwner.window!
            precondition(endingModel.error==nil && endingModel.alignment!.rows.count==2)
            precondition(endingView.string == "mine\ntail\n")
            let navigation = endingView as! (NSTextView & MergeLineNavigationProviding)
            for _ in 0..<1000 { if navigation.canNavigateToSourceLine { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            if !navigation.canNavigateToSourceLine {print("Ending navigation readiness: filtering=\(endingModel.filtering), busy=\(endingModel.busy), allowed=\(navigation.navigationAllowed), limit=\(String(describing:navigation.navigationLimit))");fflush(stdout)}
            let goto = (endingView as! ComparisonContextMenuProviding).comparisonContextMenu(defaults: prefs, pasteboard: menuClipboard).item(withTitle: "Go to Line…")!
            precondition(goto.isEnabled)
            navigation.chooseNavigationLine = { owner, limit in precondition(owner === navigationWindow && limit == 2); return 2 }
            _ = NSApp.sendAction(goto.action!, to: goto.target, from: goto)
            while navigation.navigationPending { try await Task.sleep(nanoseconds: 1_000_000) }
            precondition(endingView.selectedRange() == NSRange(location: 5, length: 4) && !endingModel.dirty)
            for choice: Int? in [nil, 0, Int.max] {
                navigation.chooseNavigationLine = { _, _ in choice }
                _ = NSApp.sendAction(goto.action!, to: goto.target, from: goto)
                while navigation.navigationPending { try await Task.sleep(nanoseconds: 1_000_000) }
                precondition(endingView.selectedRange() == NSRange(location: 5, length: 4))
            }
            endingView.setSelectedRange(NSRange(location: 0, length: 0))
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
            try await settleComparisons()
            precondition(endingModel.canTransfer(toBase: false))
            endingModel.selectedRows = 0..<1
            endingHistory.beginUndoGrouping(); endingModel.useOtherBlock(targetBase: false); endingHistory.endUndoGrouping()
            precondition(endingModel.draftText(base: false) == "base" + eol + "mine" + eol + "tail")
            endingSaved = nil; endingModel.save { endingSaved = $0 }
            for _ in 0..<1000 { if endingSaved != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            let transferredBytes = try Data(contentsOf: markMine), unchangedBase = try Data(contentsOf: markBase)
            precondition(endingSaved == true && transferredBytes == Data(("base" + eol + "mine" + eol + "tail").utf8))
            precondition(unchangedBase == Data("base\ntail".utf8))
            endingModel.resetHistory();endingOwner.close()
        }
        try Data(baseText.utf8).write(to: markBase)
        print("PASS: all nine line endings through actual native aligned display, insertText, private Undo/Redo, ordinary Save and other-block transfer; exact bytes and unterminated EOF, Base retained. No synthetic input or physical format-menu acceptance.")
        let markCases: [(FileComparisonEditing.MarkedSaveChoice?, Bool)] = [(nil, false), (.include, false), (.exclude, false), (.manualEditsOnly, false), (.include, true)]
        for (choice, stale) in markCases {
            try Data(mineText.utf8).write(to: markMine)
            let comparison = try WorkingFileComparison(base: markBase, destination: markMine)
            let (markedOwner,markedView)=try await mountedComparison(comparison)
            defer{markedOwner.close()}
            let markedModel=markedOwner.model
            markedModel.updateAnnotations(.init(marked: [0]), base: false)
            var prompts = 0, savedReply: Bool?
            markedModel.chooseMarkedSave = {
                prompts += 1; precondition(markedModel.busy)
                markedModel.load(); markedModel.save(); precondition(prompts == 1)
                if stale { try! Data("external writer".utf8).write(to: markMine) }
                return choice
            }
            let markHistory = markedView.undoManager!
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
                try await acknowledgeComparisonError(markedOwner)
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
            markedOwner.close()
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
        try await settleComparisons()
        precondition(application.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await settleComparisons()
        precondition(application.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await waitReply(1)
        let quitRetained = try await quitRepo.mailPatchSession(), cancelQuitHead = try await quitRepo.run(["rev-parse", "HEAD"]).stdout
        precondition(replies == [false] && quitPrompts == 1 && quitCloses == 0 && quitModel.editable && quitModel.items.count == 2 && quitRetained == .applying && cancelQuitHead == quitHead)
        quitModel.chooseClose = { quitPrompts += 1; return .keep }
        try await settleComparisons()
        precondition(application.applicationShouldTerminate(NSApplication.shared) == .terminateLater); try await waitReply(2)
        let keepQuitSession = try await quitRepo.mailPatchSession()
        precondition(replies == [false, true] && quitCloses == 0 && keepQuitSession == .applying && quitModel.editable)
        quitModel.chooseClose = { quitPrompts += 1; return .abort }
        try await settleComparisons()
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
        verifyRetiredCopy(exportEditor)
        try await ImportPatchLifecycleVerification.run(root: root, git: git)
        try await ComparisonOutputOwnershipVerification.run(root: root, git: git)
        precondition(RepositoryAction.importPatch.icon == .patch && RepositoryAction.importPatch.requiresWorkingTree)
        print("PASS: hidden native patch table/preview; order, check, fixed batch options and mutation guards; two real mail commits/signoff; retained conflict cursor Abort/Skip/Resolved; close Cancel/Keep/Abort; real hook stop finishes current command without closing; original patch icon; no main app")
    }
}
