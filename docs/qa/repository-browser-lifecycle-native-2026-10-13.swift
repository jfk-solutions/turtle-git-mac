import AppKit
import TurtleGitCore

@main struct RepositoryBrowserLifecycleVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ condition:Bool,_ message:String) throws { if !condition { throw Failure(description:message) } }
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<1500 { if ready() { return };try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Browser timeout at \(line)")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Browser lifecycle failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Browser QA"),("user.email","browser@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        for path in ["a/b/one","a/b/two","other/leaf"] {
            try FileManager.default.createDirectory(at:root.appendingPathComponent(path).deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data((path+" baseline\n").utf8).write(to:root.appendingPathComponent(path))
        }
        try await repo.stage(["a","other"]);_ = try await repo.commit(message:"Browser baseline")
        let original=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-index","--add","--cacheinfo","160000,"+original+",module"])
        _ = try await repo.commit(message:"Missing child")
        let pinned=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let owner=RepositoryBrowserWindowController(repository:repo,access:nil,revision:pinned)
        defer { owner.close() }
        let model=owner.model
        try await wait { !model.busy && model.snapshot != nil }
        model.expanded.formUnion(["a","a/b"]);model.loadDirectory("a/b",select:true)
        try await wait { model.snapshot?.directory=="a/b" }
        model.selection=[RepositoryBrowserPathIdentity.id("a/b/one")]
        model.refresh();try await wait { !model.busy && model.snapshot?.directory=="a/b" }
        try require(model.expanded.isSuperset(of:["","a","a/b"]) && model.directories["a"] != nil && model.selection==[RepositoryBrowserPathIdentity.id("a/b/one")],"Refresh lost loaded ancestors/selection")
        let board=NSPasteboard(name:NSPasteboard.Name("TurtleGit.Browser.QA."+UUID().uuidString));defer { board.clearContents() }
        model.copy(pasteboard:board);try require(board.string(forType:.string)=="one\r\n","Private names copy")
        model.copy(hashes:true,pasteboard:board);try require(board.string(forType:.string)==model.selected.first?.objectID,"Private hash copy")
        let entries=model.entries
        // Real partial-success Continue then Cancel, keeping the captured revision.
        for value in entries { try Data("edited\n".utf8).write(to:root.appendingPathComponent(value.path)) }
        let lock=root.appendingPathComponent(".git/index.lock");try Data().write(to:lock)
        var questions=0,changed=0,result=""
        model.handleRevertFailure={ _ in questions += 1;try? FileManager.default.removeItem(at:lock);return true }
        model.onChanged={ changed += 1 };model.showRevertResult={ result=$0 }
        model.revert(entries);model.revert(entries);try await wait { !model.mutating }
        try require(questions==1 && changed==1 && result.contains("1 file(s) reverted") && result.contains("1 file(s) failed"),"Continue/duplicate/summary")
        try require(try Data(contentsOf:root.appendingPathComponent(entries[0].path))==Data("edited\n".utf8),"Failed file changed")
        try require(try Data(contentsOf:root.appendingPathComponent(entries[1].path))==Data((entries[1].path+" baseline\n").utf8),"Following file not restored")
        try Data().write(to:lock);questions=0;result=""
        model.handleRevertFailure={ _ in questions += 1;return false }
        model.revert(entries);try await wait { !model.mutating }
        try require(questions==1 && result.contains("1 file(s) were not attempted"),"Cancel did not stop restore sequence")
        try FileManager.default.removeItem(at:lock)
        _ = try await repo.run(["reset","--hard",pinned])
        // A removed current folder falls back to its nearest surviving ancestor.
        _ = try await repo.run(["rm","-r","a/b"]);_ = try await repo.commit(message:"Remove nested folder")
        model.revision="HEAD";model.refresh();try await wait { !model.busy }
        try require(model.snapshot?.directory=="" && !model.expanded.contains("a/b") && model.selection.isEmpty,"Removed ancestor fallback")
        model.revision=pinned;model.refresh();try await wait { !model.busy }
        let module=model.entries.first { $0.kind == .submodule }!
        var childReply=0
        model.onSubmodule={ comparison,entry,log in childReply += 1;precondition(comparison.checkout==nil && entry==module && log) }
        model.showSubmoduleLog(module);try await wait { !model.busy }
        try require(childReply==1,"Captured unavailable child result")
        owner.close();try await wait { RepositoryBrowserWindowModel.activeOperations==0 }
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        for phase in ["rev-parse","ls-tree","cat-file","checkout"] {
            let helper=root.appendingPathComponent("slow-browser-"+phase),marker=URL(fileURLWithPath:helper.path+".started"),pause=URL(fileURLWithPath:helper.path+".pause")
            let quoted="'"+repo.executable.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
            let script="""
            #!/bin/sh
            task_match=false
            for task_argument in "$@"; do
              if [ "$task_argument" = '\(phase)' ]; then task_match=true; fi
            done
            if [ "$task_match" = true ] && [ -f "$0.pause" ]; then
              /bin/rm "$0.pause"
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.started.tmp"
              /bin/mv "$0.started.tmp" "$0.started"
              wait "$task_child"
            fi
            exec \(quoted) "$@"
            """
            try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
            let slow=GitRepository(root:root,executable:helper),host=RepositoryBrowserWindowController(repository:slow,access:nil,revision:pinned)
            var replies=0;host.model.presentFile={ _,_ in replies += 1 };host.model.onChanged={ replies += 1 };host.model.showRevertResult={ _ in replies += 1 }
            do {
                try await wait { !host.model.busy && host.model.snapshot != nil }
                if ["cat-file","checkout"].contains(phase) { host.model.loadDirectory("a/b",select:true);try await wait { host.model.snapshot?.directory=="a/b" } }
                try Data().write(to:pause)
                if phase=="cat-file" { host.model.open(host.model.entries[0]) }
                else if phase=="checkout" { host.model.revert(host.model.entries) }
                else { host.model.refresh() }
                try await wait { FileManager.default.fileExists(atPath:marker.path) }
                let pids=try String(contentsOf:marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
                try require(pids.count==2 && pids.allSatisfy { kill($0,0)==0 },"Missing live owned \(phase) processes: \(pids)")
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Quit escaped active browser \(phase)")
                host.close();try await wait { RepositoryBrowserWindowModel.activeOperations==0 && pids.allSatisfy { kill($0,0) != 0 } }
                try require(!host.model.active && replies==0 && host.model.error==nil,"Retired \(phase) published")
            } catch { host.close();try? await wait { RepositoryBrowserWindowModel.activeOperations==0 };throw error }
        }
        // Forced close retires actual Save/Open With and per-file failure sheets.
        for action in [RepositoryBrowserWindowModel.FileAction.save,.openWith] {
            let host=RepositoryBrowserWindowController(repository:repo,access:nil,revision:pinned)
            try await wait { !host.model.busy };host.model.loadDirectory("a/b",select:true);try await wait { host.model.snapshot?.directory=="a/b" }
            host.model.open(host.model.entries[0],action:action);try await wait { host.window?.attachedSheet != nil }
            host.close();try await wait { host.window?.attachedSheet==nil && RepositoryBrowserWindowModel.activeOperations==0 }
            try require(!host.model.active && host.model.error==nil,"Retired file sheet result")
        }
        let host=RepositoryBrowserWindowController(repository:repo,access:nil,revision:pinned)
        try await wait { !host.model.busy };host.model.loadDirectory("a/b",select:true);try await wait { host.model.snapshot?.directory=="a/b" }
        try Data().write(to:lock);host.model.revert(host.model.entries);try await wait { host.window?.attachedSheet != nil }
        host.close();try await wait { host.window?.attachedSheet==nil && RepositoryBrowserWindowModel.activeOperations==0 }
        try FileManager.default.removeItem(at:lock)
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(head==afterHead && index==afterIndex,"Retirement checks changed HEAD/index")
        // Tree-object handoffs keep the exact snapshot rather than requiring a commit.
        let tree = try await repo.run(["rev-parse", pinned + "^{tree}"]).text.trimmingCharacters(in: .newlines)
        let treeOwner = RepositoryBrowserWindowController(repository:repo,access:nil,revision:tree)
        defer { treeOwner.close() }
        let treeModel = treeOwner.model
        try await wait { !treeModel.busy && treeModel.snapshot != nil }
        treeModel.loadDirectory("a/b",select:true)
        try await wait { treeModel.snapshot?.directory == "a/b" }
        let treeEntry = treeModel.entries.first { $0.name == "one" }!
        var workingHandoff:(String,String)?, markedHandoff:(PreparedFileComparisonMark,PreparedFileComparisonMark)?
        var historyCalls = 0
        treeModel.onCompare = { workingHandoff = ($0,$1) }
        treeModel.onPreparedFileCompare = { markedHandoff = ($0,$1) }
        treeModel.onLog = { _,_ in historyCalls += 1 }; treeModel.onBlame = { _,_ in historyCalls += 1 }
        treeModel.compareEntryToWorkingTree(treeEntry)
        try await wait { !treeModel.busy && workingHandoff != nil }
        try require(workingHandoff?.0 == treeEntry.path && workingHandoff?.1 == tree,"Tree working handoff lost identity")
        let comparison = try await repo.revisionFileComparison(from:.revision(workingHandoff!.1),to:.workingTree,paths:[workingHandoff!.0])
        let treeDocument = try await repo.comparisonFile(comparison,path:treeEntry.path)
        let treeSnapshot = try await repo.repositoryBrowserFile(treeModel.snapshot!,entry:treeEntry)
        try require(treeDocument.base.bytes == treeSnapshot.bytes,"Tree comparison changed historical bytes")
        treeModel.markForComparison(treeEntry);treeModel.compareWithMarkedFile(treeEntry)
        try require(markedHandoff?.0.revision == tree && markedHandoff?.1.revision == tree,"Tree mark lost identity")
        let marked = try await repo.preparedPathComparison(from:.revision(markedHandoff!.0.revision),fromPath:markedHandoff!.0.path,to:.revision(markedHandoff!.1.revision),toPath:markedHandoff!.1.path)
        let markedDocument = try await repo.comparisonFile(marked,path:treeEntry.path)
        try require(markedDocument.base.bytes == treeSnapshot.bytes && markedDocument.destination.bytes == treeSnapshot.bytes,"Tree marked comparison failed")
        treeModel.showEntryLog(treeEntry);try require(treeModel.error?.contains("no commit history") == true,"Tree Log explanation missing")
        treeModel.error=nil;treeModel.showEntryBlame(treeEntry)
        try require(historyCalls == 0 && treeModel.error?.contains("no commit history") == true,"Tree Blame fabricated history")
        let treeCompare = RevisionComparisonWindowController(repository:repo,access:nil,from:.revision(pinned),to:.revision(tree))
        defer { treeCompare.close() }
        treeCompare.model.load();try await wait { !treeCompare.model.busy && treeCompare.model.snapshot != nil }
        try require(treeCompare.model.snapshot?.toDetails?.isTree == true,"Tree revision metadata missing")
        try require(treeCompare.model.revisionDescription(base:false).contains("Tree") && treeCompare.model.revisionTooltip(base:false).contains("no commit metadata"),"Tree details show commit metadata")
        treeCompare.model.onLog = { _ in historyCalls += 1 };treeCompare.model.onFileLog = { _,_ in historyCalls += 1 }
        treeCompare.model.log();treeCompare.model.logFiles([treeEntry.path])
        try require(historyCalls == 0 && treeCompare.model.error?.contains("no commit history") == true,"Changed Files launched tree history")
        for appearance in [NSAppearance.Name.aqua,.darkAqua] { treeCompare.window?.appearance=NSAppearance(named:appearance);treeOwner.window?.appearance=NSAppearance(named:appearance) }
        treeOwner.close();treeCompare.close()
        print("Tree-object browser: working and marked comparison handoffs, exact blob content, commit/tree details, history explanations, light/dark native hosts and owned close passed.")
        print("Repository Browser: retained ancestor/selection refresh, removed-folder fallback, pinned child lookup, private Copy, multi-file Continue/Cancel and duplicate guards, root/tree/blob/checkout cancellation with owned process reaping, Quit lifetime, Save/Open With/failure sheet retirement passed. Owned windows closed.")
    }
}
