// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum ReferenceFilterVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func wait(_ message: String, _ ready: () -> Bool) async throws {
        for _ in 0..<2500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Reference filter timeout: " + message)
    }
    static func views(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { views($0) } }
    static func key(_ window: NSWindow, _ code: UInt16, _ text: String = "", _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    /// Deliberately ignore cancellation: the real owner/counter must survive
    /// until the underlying delay returns, and stale replies must be harmless.
    final class Delays {
        var replies: [CheckedContinuation<Void, Error>?] = []
        var count: Int { replies.count }
        func wait() async throws { try await withCheckedThrowingContinuation { replies.append($0) } }
        func release(_ index: Int) { guard replies.indices.contains(index), let reply = replies[index] else { return }; replies[index] = nil; reply.resume() }
        func releaseAll() { for index in replies.indices { release(index) } }
    }
    static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (name,value) in [("user.name","Filter Author"),("user.email","filter@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",name,value]) }
        let file = root.appendingPathComponent("file")
        try Data("reference filter fixture\n".utf8).write(to: file); try await repo.stage(["file"]); _ = try await repo.commit(message: "Filter subject fixture")
        let hash = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines)
        let names = (0..<48).map { "refs/heads/topic-" + String(format: "%02d", $0) } + ["refs/heads/team/alpha","refs/heads/team/beta","refs/heads/café","refs/heads/雪","refs/tags/release"]
        _ = try await repo.run(["update-ref","--stdin"], input: Data((names.map { "create \($0) \(hash)" }.joined(separator: "\n") + "\n").utf8))
        let beforeHead = try await repo.run(["rev-parse","HEAD"]).stdout
        let beforeRefs = try await repo.run(["for-each-ref","--format=%(refname)%00%(objectname)"]).stdout
        let beforeIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), beforeFile = try Data(contentsOf: file)
        let suite = "TurtleGit.ReferenceFilter.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "RelativeTimes"); preferences.set(true, forKey: "RefBrowserIncludeNestedRefs")
        let owner = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs/heads/team/alpha", preferences: preferences, picking: false) { _ in }
        let model = owner.model, window = owner.window!, delays = Delays()
        owner.commandKeyWindow = { window }; window.alphaValue = 0; window.setFrameOrigin(.init(x: -24000, y: -24000)); window.orderFront(nil)
        model.waitForFilterDelay = { try await delays.wait() }
        var detached: ReferenceBrowserWindowModel?, detachedDelays: Delays?, dirtyDocument: PatchWindowController?
        var pendingDocumentQuestion: ((PatchDocumentSession.Decision) -> Void)?
        do {
            model.load()
            try await wait("initial reference read") { !model.busy && model.snapshot != nil }
            model.setFolder("refs/heads")
            try await wait("initial native catalog") {
                window.contentView?.layoutSubtreeIfNeeded()
                return !model.busy && model.rows.count > 48 && views(window.contentView).compactMap { $0 as? NSTableView }.contains { $0.identifier?.rawValue == "BrowseRefs.References" && $0.numberOfRows == model.rows.count }
            }
            let table = views(window.contentView).compactMap { $0 as? NSTableView }.first { $0.identifier?.rawValue == "BrowseRefs.References" }!
            let field = views(window.contentView).compactMap { $0 as? NSSearchField }.first { $0.identifier?.rawValue == "BrowseRefs.Filter" }!
            let native = NativeListSelection.originalDelegate(of: table) as! ReferenceBrowserNativeView.Coordinator
            try await wait("positioned native catalog") { native.positioned }
            func input(_ text: String) throws {
                field.stringValue = text
                (field.currentEditor() as? NSTextView)?.string = text
                guard let action = field.action else { throw Failure(description: "Native filter action missing") }
                try require(NSApp.sendAction(action, to: field.target, from: field), "Native filter action refused")
            }
            func settled(_ message: String) async throws {
                try await wait(message) { window.contentView?.layoutSubtreeIfNeeded(); return table.numberOfRows == model.rows.count }
            }
            func releaseAll(_ message: String) async throws {
                try await wait(message) { delays.releaseAll(); return !model.hasPendingWork && ReferenceBrowserWindowModel.activeFilters == 0 }
            }
            let baseline = model.rows.map(\.reference.name)
            model.select(["refs/heads/team/alpha"], last: "refs/heads/team/alpha"); native.update()
            let priorMenu = model.menuContext()!, priorSelection = model.selection
            let builds = model.rowProjectionBuilds, signatures = native.rowSignatureBuilds, selections = native.selectionProjectionBuilds
            try input("topic-0"); try await wait("first held typing delay") { delays.count == 1 }
            try require(model.query == "topic-0" && model.filterPending && model.rows.map(\.reference.name) == baseline && model.selection == priorSelection, "Draft typing replaced accepted rows/selection")
            for _ in 0..<6 { native.update(); _ = model.rows }
            try require(model.rowProjectionBuilds == builds && native.rowSignatureBuilds == signatures && native.selectionProjectionBuilds == selections, "Draft repaint rebuilt/scanned the complete catalog or selection")
            let dateColumn = table.tableColumn(withIdentifier: .init("authorDate"))!
            let absoluteDate = model.text(model.rows[0], column: "authorDate")
            preferences.set(true, forKey: "RelativeTimes"); native.update()
            let relativeDate = model.text(model.rows[0], column: "authorDate")
            let renderedDate = native.tableView(table, viewFor: dateColumn, row: 0) as? NSTextField
            try require(!relativeDate.isEmpty && relativeDate != absoluteDate && renderedDate?.stringValue == relativeDate, "Date preference change did not reach actual native date cell")
            try require(model.rowProjectionBuilds == builds && native.rowSignatureBuilds == signatures + 1 && native.selectionProjectionBuilds == selections && model.filterPending, "Date repaint refiltered/reselected catalog or failed its signature invalidation")
            native.update(); try require(native.rowSignatureBuilds == signatures + 1 && native.selectionProjectionBuilds == selections, "Unchanged date presentation rescanned catalog or selection")
            preferences.set(false, forKey: "RelativeTimes"); native.update()
            var oldMenuRan = false; model.performMenu(priorMenu) { oldMenuRan = true }
            try require(!oldMenuRan, "Draft query revived a captured revision popup")
            model.select(["refs/heads/team/beta"], last: "refs/heads/team/beta")
            try require(model.chosen?.name == "refs/heads/team/beta", "Pending query stopped selection of accepted rows")
            try input("café"); try await wait("replacement held delay") { delays.count == 2 }
            delays.release(0); try await wait("cancelled old delay drains") { ReferenceBrowserWindowModel.activeFilters == 1 }
            try require(model.filterPending && model.rows.map(\.reference.name) == baseline, "Superseded typing delay published")
            delays.release(1); try await wait("accepted Unicode filter") { !model.filterPending && model.rows.count == 1 && model.rows[0].reference.name == "refs/heads/café" }
            try await settled("Unicode native rows"); try require(model.selection.isEmpty && model.lastSelected == nil, "Applied filter retained hidden selection mark")

            var start = delays.count
            model.fields = [.authors]; try await wait("field-mask delay") { delays.count > start }
            try require(model.rows.count == 1 && model.filterCue.contains("Authors"), "Field choices immediately changed accepted rows or lost cue")
            delays.releaseAll(); try await wait("author-only accepted filter") { !model.filterPending && model.rows.isEmpty }
            start = delays.count; model.toggleSearchFields(context: model.formContext)
            try await wait("toggle-fields delay") { delays.count > start }; delays.releaseAll()
            try await wait("complement mask accepted") { !model.filterPending && model.rows.count == 1 }
            try require(model.fields == ReferenceBrowserWindowModel.allFields.subtracting(.authors) && !model.filterCue.contains("Authors"), "Toggle filters did not use the exact four-field complement")
            model.fields = ReferenceBrowserWindowModel.allFields; model.clearFilter(); try await releaseAll("clear mask leftovers")
            try require(model.query.isEmpty && model.rows.map(\.reference.name) == baseline, "Clear did not immediately restore current fields/catalog")

            start = delays.count; try input("team/"); try await wait("sort-held draft") { delays.count > start }
            model.descending.toggle(); native.update()
            try require(model.filterPending && model.rows.count == baseline.count, "Sort prematurely applied draft query")
            delays.releaseAll(); try await wait("sorted accepted draft") { !model.filterPending && model.rows.count == 2 }
            model.clearFilter(); try await releaseAll("sort clear"); model.descending = false

            start = delays.count; try input("alpha"); try await wait("namespace-held draft") { delays.count > start }
            model.setFolder("refs/heads/team")
            try require(!model.filterPending && model.rows.count == 1 && model.rows[0].name == "alpha", "Namespace change did not flush captured draft using relative ref names")
            let namespaceRevision = model.acceptedFilterRevision; try await releaseAll("namespace stale delay drains")
            try require(model.acceptedFilterRevision == namespaceRevision, "Old namespace timer refiltered after explicit navigation")
            model.clearFilter(); model.setFolder("refs/heads"); try await releaseAll("namespace reset")

            start = delays.count; try input("topic-1"); try await wait("F5-held draft") { delays.count > start }
            try require(window.performKeyEquivalent(with: key(window, 96)), "Actual native F5 did not dispatch")
            try require(model.busy && !model.filterPending, "F5 did not cancel timer before real catalog read")
            try await wait("real F5 catalog") { !model.busy && model.rows.count == 10 }
            let refreshed = model.rows.map(\.reference.name); try await releaseAll("F5 stale delay drains")
            try require(model.rows.map(\.reference.name) == refreshed, "Cancelled F5 timer replaced fresh catalog")
            model.clearFilter(); try await releaseAll("F5 clear")

            start = delays.count; try input("alpha"); try await wait("nested-held draft") { delays.count > start }
            model.nestedBinding(context: model.formContext).wrappedValue = false
            try require(model.busy && !model.filterPending, "Nested toggle did not replace timer with source refresh")
            try await wait("non-nested catalog") { !model.busy && model.rows.isEmpty }
            try await releaseAll("nested stale delay drains")
            model.clearFilter(); model.nestedBinding(context: model.formContext).wrappedValue = true
            try await wait("nested catalog restored") { !model.busy && model.rows.contains { $0.reference.name == "refs/heads/team/alpha" } }

            for quit in [false,true] {
                start = delays.count; try input(quit ? "topic-2" : "topic-3"); try await wait("blocked owner held delay") { delays.count > start }
                let accepted = model.rows.map(\.reference.name), oldBinding = model.queryBinding(context: model.formContext)
                if quit { model.confirmingQuit = true } else { model.hasChild = true }
                oldBinding.wrappedValue = "foreign"
                try require(!model.filterPending && model.query != "foreign", "Blocked owner accepted retained filter setter")
                try await releaseAll("blocked old delay returns")
                try require(model.rows.map(\.reference.name) == accepted, "Child/Quit timer changed accepted rows")
                start = delays.count
                if quit { model.confirmingQuit = false } else { model.hasChild = false }
                try await wait("resumed owner delay") { delays.count > start }; delays.releaseAll()
                try await wait("resumed owner accepted rows") { !model.filterPending && model.rows.count == 10 }
                model.clearFilter(); try await releaseAll("blocked cycle clear")
            }

            // Escape must clear the active native filter rather than closing
            // the browser or waiting for another timer.
            start = delays.count; try input("雪"); try await wait("Escape-held delay") { delays.count > start }
            _ = window.makeFirstResponder(field)
            try require(window.performKeyEquivalent(with: key(window,53)), "Active native Escape not consumed")
            try require(model.query.isEmpty && field.stringValue.isEmpty && !model.filterPending && !model.closed, "Escape did not clear immediately on the same owner")
            try await releaseAll("Escape stale delay drains")

            // A cosmetic typing delay cannot silently reject Quit. Drain its
            // actual return first, then keep the normal dirty-document decision.
            let dirty = PatchWindowController(documentDirectory: root, preferences: preferences)
            dirtyDocument = dirty; dirty.window?.alphaValue = 0; dirty.window?.setFrameOrigin(.init(x: -24000,y: -24000)); dirty.showWindow(nil)
            dirty.presentDocument(Data("--- a/file\n+++ b/file\n@@ -1 +1 @@\n-before\n+after\n".utf8), title: "Private filter Quit document", comparison: "Private filter Quit", information: "")
            try await wait("dirty-document admission") { PatchDocumentSession.activeOperations == 0 && dirty.model.canEditText }
            dirty.model.editDocument(dirty.model.document.text + "retained draft\n")
            try require(dirty.model.documentDirty, "Quit fixture failed to create a real dirty document")
            var questions = 0, quitReplies: [Bool] = []
            dirty.documentSession.askChanges = { _, reply in questions += 1;pendingDocumentQuestion = reply }
            let quitDelegate = TurtleGitApplicationDelegate(); quitDelegate.replyToTermination = { _, allowed in quitReplies.append(allowed) }
            start = delays.count; try input("topic-2"); try await wait("real Quit held filter") { delays.count > start }
            let beforeQuit = model.rows.map(\.reference.name), quitDraft = model.query
            try require(quitDelegate.applicationShouldTerminate(NSApp) == .terminateLater && quitDelegate.applicationShouldTerminate(NSApp) == .terminateLater, "Pending filter did not use one deferred Quit drain")
            try require(quitReplies.isEmpty && pendingDocumentQuestion == nil && ReferenceBrowserWindowModel.activeFilters > 0 && !model.filterPending && model.query == quitDraft, "Quit replied, asked or released draft before actual filter return")
            delays.releaseAll()
            try await wait("real dirty question after filter drain") { ReferenceBrowserWindowModel.activeFilters == 0 && pendingDocumentQuestion != nil }
            try require(quitReplies.isEmpty && questions == 1 && model.rows.map(\.reference.name) == beforeQuit, "Deferred Quit duplicated question or published cancelled filter")
            start = delays.count; let decline = pendingDocumentQuestion; pendingDocumentQuestion = nil; decline?(.cancel)
            try await wait("declined Quit restores draft timer") { quitReplies == [false] && delays.count > start && model.filterPending }
            try require(model.query == quitDraft && dirty.model.documentDirty && !model.closed, "Declined Quit lost live filter/document drafts")
            delays.releaseAll(); try await wait("declined Quit filter accepted") { !model.filterPending && model.rows.count == 10 }
            try require(quitReplies == [false] && questions == 1, "Deferred Quit replied more than once")
            dirty.documentSession.askChanges = { _, reply in reply(.discard) }; dirty.close(); dirtyDocument = nil
            try await wait("dirty fixture retirement") { dirty.model.retired && PatchDocumentSession.activeOperations == 0 }
            model.clearFilter(); try await releaseAll("declined Quit clear")

            start = delays.count; try input("topic-4"); try await wait("close-held delay") { delays.count > start }
            let closedRows = model.rows.map(\.reference.name), retired = model.queryBinding(context: model.formContext)
            owner.close(); retired.wrappedValue = "after close"
            try require(model.closed && model.hasPendingWork && ReferenceBrowserWindowModel.activeFilters > 0 && !model.filterPending && model.query == "topic-4", "Close released held filter or accepted stale setter")
            try await releaseAll("closed owner actual delay drain")
            try await wait("closed controller release") { !owner.hasPendingWork }
            try require(model.rows.map(\.reference.name) == closedRows && window.isVisible == false, "Retired delayed filter published or left window open")

            let isolated = ReferenceBrowserWindowModel(repository: repo, access: nil, initial: "HEAD", preferences: preferences), isolatedDelay = Delays()
            detached = isolated; detachedDelays = isolatedDelay; isolated.waitForFilterDelay = { try await isolatedDelay.wait() }
            isolated.query = "sole owned delay"; try await wait("detached held delay") { isolatedDelay.count == 1 }
            isolated.invalidate()
            let delegate = TurtleGitApplicationDelegate(); var detachedReplies: [Bool] = []
            delegate.replyToTermination = { _, allowed in detachedReplies.append(allowed) }
            try require(ReferenceBrowserWindowModel.activeReads == 0 && ReferenceBrowserWindowModel.activeFilters == 1 && isolated.hasPendingWork && delegate.applicationShouldTerminate(NSApp) == .terminateLater && delegate.applicationShouldTerminate(NSApp) == .terminateLater, "Quit did not defer for the detached filter's actual return")
            try require(detachedReplies.isEmpty, "Detached Quit replied before cancellation drained")
            isolatedDelay.releaseAll(); try await wait("detached cancellation actual drainage and reply") { !isolated.hasPendingWork && ReferenceBrowserWindowModel.activeFilters == 0 && detachedReplies == [true] }
            try require(!isolated.filterPending && model.closed, "Approved Quit resumed a retired filter owner")

            let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout, afterRefs = try await repo.run(["for-each-ref","--format=%(refname)%00%(objectname)"]).stdout
            try require(afterHead == beforeHead && afterRefs == beforeRefs && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == beforeIndex && (try Data(contentsOf: file)) == beforeFile, "Reference filtering changed repository bytes/refs")
            print("PASS: Reference filter accepted/draft projections, native input and catalog/selection cache, captured menu refusal, fields/Unicode/clear/Escape/F5/namespace/nesting/sort, child/close, deferred Quit actual drainage/once-only reply and dirty-decline draft resumption; unchanged refs/HEAD/index/files")
        } catch {
            pendingDocumentQuestion?(.cancel); pendingDocumentQuestion = nil
            owner.close(); detached?.invalidate(); dirtyDocument?.documentSession.askChanges = { _, reply in reply(.discard) }; dirtyDocument?.close()
            var drained = false
            for _ in 0..<2500 {
                delays.releaseAll(); detachedDelays?.releaseAll()
                if !owner.hasPendingWork && detached?.hasPendingWork != true && ReferenceBrowserWindowModel.activeFilters == 0 && ReferenceBrowserWindowModel.activeReads == 0 && PatchDocumentSession.activeOperations == 0 { drained = true; break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            if !drained { throw Failure(description: "\(error); owned reference filter/window cleanup did not drain") }
            throw error
        }
    }
}
