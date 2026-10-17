// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct LogFileIdentitiesVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func views(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { views($0) } }
    @MainActor static func wait(_ window: NSWindow?, line: Int = #line, _ ready: () -> Bool) async throws {
        var settled = 0
        for _ in 0..<2000 {
            try await Task.sleep(nanoseconds: 10_000_000); window?.contentView?.layoutSubtreeIfNeeded()
            settled = ready() ? settled + 1 : 0; if settled == 2 { return }
        }
        throw Failure(description: "Log identities timeout at \(line)")
    }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do { try await verify(); print("PASS Log file identities: exact native selections and parent groups, copy/compare/mark targets, consumed and stale menu ownership, stale preview/flags, owned chooser cancellation/reuse/retirement; HEAD/index unchanged") }
        catch { fputs("Log file identities failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Log Identity QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","true")] { _ = try await repo.run(["config",key,value]) }
        let a = "café.txt", b = "cafe\u{301}.txt", paths = [a,b]
        func tree(_ text: String) async throws -> String {
            let blob = try await repo.run(["hash-object","-w","--stdin"],input:Data(text.utf8)).text.trimmingCharacters(in:.newlines)
            _ = try await repo.run(["update-index","-z","--index-info"],input:Data(paths.map { "100644 \(blob)\t\($0)\0" }.joined().utf8))
            return try await repo.run(["write-tree"]).text.trimmingCharacters(in:.newlines)
        }
        func commit(_ tree: String, _ parents: [String], _ message: String) async throws -> String {
            try await repo.run(["commit-tree",tree]+parents.flatMap { ["-p",$0] },input:Data((message+"\n").utf8)).text.trimmingCharacters(in:.newlines)
        }
        let base = try await commit(tree("base\n"),[],"base")
        let left = try await commit(tree("left\n"),[base],"left")
        let right = try await commit(tree("right\n"),[base],"right")
        let merge = try await commit(tree("merged\n"),[left,right],"merge pairs")
        _ = try await repo.run(["update-ref","HEAD",merge])
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.LogIdentities."+UUID().uuidString, prefs = UserDefaults(suiteName:suite)!, clipboard = NSPasteboard.withUniqueName()
        defer { prefs.removePersistentDomain(forName:suite); clipboard.releaseGlobally() }
        for key in ["EnableLogCache","EnableGravatar","LogIncludeWorkingTreeChanges"] { prefs.set(false,forKey:key) }
        let owner = LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false), model = owner.model
        defer { owner.close() }; owner.window!.alphaValue = 0; owner.window!.orderFront(nil); model.clipboard = clipboard
        try await wait(owner.window) { !model.busy && model.entries.contains { $0.hash == merge } }
        model.select([merge]); try await wait(owner.window) { model.files.count == 4 && model.fileGroups.count == 2 }
        guard let probe = views(owner.window?.contentView).compactMap({ $0 as? CommitFileInteraction.Probe }).first else { throw Failure(description:"Missing native Log file probe") }
        try await wait(owner.window) { probe.groupHeaders?.headings.count == 2 }
        let table = probe.groupHeaders!.table!
        let files = model.fileTableRows.compactMap(\.file), ids = GitPathSet(files.map(\.id))
        try require(ids.count == 4 && Set(model.fileTableRows.map(\.id)).count == 6,"Native Unicode or parent identities collapsed")
        try require(probe.itemIDs!.map { GitReferenceName($0) } == model.fileTableRows.map { GitReferenceName($0.rawID) },"Probe received encoded rather than Git IDs")
        let first = files.first { GitReferenceName.equal($0.path,a) && $0.parentIndex == 0 }!, second = files.first { GitReferenceName.equal($0.path,b) && $0.parentIndex == 0 }!
        func selectNative(_ chosen: GitPathSet, line: Int = #line) async throws {
            try await wait(owner.window) {
                let rows = model.fileTableRows
                guard table.numberOfRows == rows.count,
                      probe.itemIDs?.map({ GitReferenceName($0) }) == rows.map({ GitReferenceName($0.rawID) }) else { return false }
                let native = GitPathSet(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].file?.id:nil })
                return native == model.selectedFiles
            }
            let indexes = IndexSet(model.fileTableRows.enumerated().compactMap { chosen.contains($0.element.rawID) ? $0.offset:nil })
            CommitFileInteraction.replaceSelection(in:table,with:indexes)
            do { try await wait(owner.window) { model.selectedFiles == chosen && table.selectedRowIndexes == indexes } }
            catch { throw Failure(description:"Native selection at caller \(line): wanted \(chosen.map(GitPathRowIdentity.encode)), model \(model.nativeFileSelection), native indexes \(table.selectedRowIndexes), wanted indexes \(indexes)") }
        }
        try await selectNative([first.id]); try require(GitReferenceName.equal(model.markedFile(model.selectedFiles)!.id,first.id),"First native mark wrong")
        let stale = model.fileMenuSnapshot([first.id])
        try await selectNative([second.id]); try require(GitReferenceName.equal(model.fileSelectionMark!,second.id),"Canonical-only native mark did not change")
        var callbacks = 0; model.withFileMenu(stale) { callbacks += 1 }
        try require(callbacks == 0,"Menu retargeted after canonical selection change")
        try await selectNative(ids); try require(model.information.selectedFileCount == 4,"Information count collapsed exact parent occurrences")
        model.copyFiles(ids,information:.relativePaths)
        try require(Data((clipboard.string(forType:.string) ?? "").utf8) == Data(files.map { $0.path+"\n" }.joined().utf8),"Copy lost Unicode bytes or parent occurrence ordering")
        model.copyChangedFileIDs([second.id],column:.path)
        try require(Data((clipboard.string(forType:.string) ?? "").utf8) == Data(b.utf8),"Single column copy retargeted to canonical peer")
        var comparisons: [[(ComparisonRevision,ComparisonRevision,[String])]] = []
        model.onFileComparisons = { comparisons.append($0) }; model.compareFiles(ids)
        try require(comparisons.count == 1 && comparisons[0].count == 2 && comparisons[0].map { $0.0 } == [.revision(left),.revision(right)],"Parent comparison scopes changed")
        try require(comparisons[0].allSatisfy { GitPathSet($0.2) == GitPathSet(paths) },"Parent comparison lost canonical peer")
        try require(model.canCompareFilePair([first.id,second.id]),"Distinct UTF-8 historical paths cannot compare")
        let pair = try await repo.historicalFilePairComparison(revision:merge,files:[first,second])
        let pairFile = try await repo.comparisonFile(pair,path:b)
        try require(GitReferenceName.equal(pairFile.base.path,a) && GitReferenceName.equal(pairFile.destination.path,b),"Historical pair names changed")
        model.markForComparison([first.id]); var prepared: (PreparedFileComparisonMark,PreparedFileComparisonMark)?
        model.onPreparedFileCompare = { prepared = ($0,$1) }; model.compareWithMarkedFile([second.id])
        try require(prepared.map { GitReferenceName.equal($0.0.path,a) && GitReferenceName.equal($0.1.path,b) } == true,"Prepared comparison retargeted")
        // Each receipt shares the original target with nested leaves and can run once.
        let once = model.fileMenuSnapshot([second.id]); model.withFileMenu(once) { callbacks += 1; model.copyFiles([second.id],information:.relativePaths) }; model.withFileMenu(once) { callbacks += 100 }
        try require(callbacks == 1,"Captured menu accepted duplicate callback")
        let focus = model.fileMenuSnapshot(ids); model.focusedChangedFile = first.id; model.withFileMenu(focus) { callbacks += 100 }
        let changedMark = model.fileMenuSnapshot(ids); model.markForComparison([second.id]); model.withFileMenu(changedMark) { callbacks += 100 }
        let sorted = model.fileMenuSnapshot(ids); model.setChangedFileSort([LogChangedFileSort(column:.path,order:.reverse)]); model.withFileMenu(sorted) { callbacks += 100 }
        let filtered = model.fileMenuSnapshot(ids); model.filterPaths = "missing"; model.filterPaths = ""; model.withFileMenu(filtered) { callbacks += 100 }
        let busy = model.fileMenuSnapshot(ids); model.busy = true; model.busy = false; model.withFileMenu(busy) { callbacks += 100 }
        try require(callbacks == 1,"Old focus/mark/sort/filter/busy menu became usable again")
        try await selectNative([first.id])
        model.setPatchPreview(true); try await wait(owner.window) { !model.patchPreviewLoading }
        var held: CheckedContinuation<Data,Error>?
        model.readPatchPreview = { _,_,_ in try await withCheckedThrowingContinuation { held = $0 } }
        model.refreshPatchPreview(); try await wait(owner.window) { held != nil }
        model.readPatchPreview = nil; model.selectedFiles = [second.id]
        held!.resume(returning:Data("stale canonical preview".utf8)); held = nil
        try await wait(owner.window) { !model.patchPreviewLoading }
        let expected = try await repo.logPatchPreviewData(model.revision!,files:[second])
        try require(model.patchPreviewData == expected,"Stale canonical preview published")
        model.setPatchPreview(false); try await wait(owner.window) { !model.busy }
        // Real sheets remain owned through release, repeated cancellation and reuse.
        model.saveHistoricalFile([second.id]); try await wait(owner.window) { owner.filePanels.currentPanel?.sheetParent === owner.window }
        let picker = owner.filePanels.currentPanel!
        try require(model.busy && !owner.windowShouldClose(owner.window!),"Log Save chooser did not block duplicate actions/close")
        owner.filePanels.receive(picker,response:.cancel); owner.filePanels.receive(picker,response:.OK)
        try await wait(owner.window) { !model.busy && owner.window?.attachedSheet == nil && owner.filePanels.currentPanel == nil }
        try require(model.error == nil,"Cancelled chooser published error")
        model.chooseHistoricalExport([first.id,second.id]); try await wait(owner.window) { owner.filePanels.currentPanel?.sheetParent === owner.window }
        let pending = owner.filePanels.currentPanel!, retired = model.fileMenuSnapshot(ids)
        owner.close(); owner.filePanels.receive(pending,response:.OK)
        try await wait(nil) { !model.busy && owner.filePanels.currentPanel == nil }
        model.withFileMenu(retired) { callbacks += 100 }; try require(callbacks == 1 && model.isInvalidated && model.error == nil,"Retired menu/chooser escaped owner")
        // Working flag confirmation must not mutate after an exact target changed away/back.
        prefs.set(true,forKey:"LogIncludeWorkingTreeChanges")
        let working = LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false), w = working.model
        defer { working.close() }; working.window!.alphaValue = 0; working.window!.orderFront(nil)
        try await wait(working.window) { !w.busy && w.entries.contains { $0.hash.isEmpty } }
        w.select([""]); try await wait(working.window) { w.files.count == 2 }
        w.selectedFiles = [a]; var answer: CheckedContinuation<Bool,Never>?
        w.confirmWorkingFlags = { _ in await withCheckedContinuation { answer = $0 } }
        w.setWorkingFlag(.skipWorktree,ids:[a]); try await wait(working.window) { answer != nil }
        w.selectedFiles = [b]; w.selectedFiles = [a]; answer!.resume(returning:true); answer = nil
        try await wait(working.window) { !w.busy }
        try require(w.error == nil,"Cancelled stale flags produced an error")
        working.close()
        try require(try await repo.run(["rev-parse","HEAD"]).stdout == head,"Read-only Log changed HEAD")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"Cancelled/stale Log operation changed index")
    }
}
