import AppKit
import TurtleGitCore

@main struct RebaseConflictMenusVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Replay file menu timeout at line \(line)")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Replay file menu failed: \(error)\n",stderr);exit(1) } }
    struct PrivateBookmarks:RepositoryBookmarkProvider {
        func create(for url:URL) throws -> Data {Data(url.path.utf8)}
        func resolve(_ data:Data) throws -> ResolvedBookmark {ResolvedBookmark(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool {true}
        func stopAccessing(_ url:URL) {}
    }
    @MainActor static func verifyComparisons(owner:RebaseWindowController,repo:GitRepository,root:URL,path:String,clean:String,prefs:UserDefaults) async throws {
        let model=owner.model,window=owner.window!,git=URL(fileURLWithPath:CommandLine.arguments[2])
        let all=model.conflictFileMenu([path,clean]);var externalChoice:Bool?
        owner.openConflictUnifiedExternal={_,alternate,_ in externalChoice=alternate;return false}
        model.showConflictUnified(all,alternate:true)
        try await wait {!model.busy && RebaseWindowModel.activePreparationReads==0 && owner.conflictUnifiedWindows.count==1}
        var expected=Data()
        for row in all.rows {expected.append(try await repo.run(["diff","--no-ext-diff","--no-textconv","--no-color",all.head,"--",row.path]+(row.originalPath.map {[$0]} ?? [])).stdout)}
        let viewer=owner.conflictUnifiedWindows.values.first!
        try require(externalChoice==true && viewer.model.readOnly && viewer.model.exportDocument.bytes==expected,"Unified diff lost selected order/raw bytes/Shift")
        viewer.model.busy=true;try require(!owner.windowShouldClose(window),"Parent closed while unified child was busy");viewer.model.busy=false
        viewer.close();try await wait {owner.conflictUnifiedWindows.isEmpty}
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false);workspace.fileComparisonPreferences=prefs
        var opened:[String]=[],choices:[Bool]=[]
        workspace.fileComparisonPresentation={_,file in opened.append(file.path);choices.append(ComparisonToolInvocation.capture)}
        var mixed:([String],Bool)?
        model.onConflictWorkingComparison={paths,amend in mixed=(paths,amend);workspace.showWorkingFiles(repository:repo,access:nil,paths:paths,amendToParent:amend,owner:window)}
        ComparisonToolInvocation.$alternate.withValue(true) {model.compareConflictMenu(all)}
        model.selectedConflicts=[clean]
        try await wait {!model.busy && !workspace.busy && RebaseWindowModel.activePreparationReads==0 && FileListComparisonSession.activeOperations==0}
        try require(mixed?.0==all.paths && mixed?.1==false && Set(opened)==Set([path,clean]) && choices.allSatisfy {$0},"Mixed comparison dropped rows or Shift")
        model.markConflictForComparison(model.conflictFileMenu([clean]));try await wait {!model.busy}
        let captured=model.conflictFileMenu([path]);try require(captured.comparisonMark?.path==clean,"Local comparison mark was not captured")
        model.markConflictForComparison(model.conflictFileMenu([path]));try await wait {!model.busy}
        opened=[];choices=[];var prepared:(PreparedFileComparisonMark,PreparedFileComparisonMark,Bool)?
        model.onConflictPreparedComparison={marked,current in
            prepared=(marked,current,ComparisonToolInvocation.capture)
            if marked.workingAccess==nil {workspace.showPreparedFileComparison(repository:repo,access:nil,marked:marked,current:current,owner:window)}
        }
        model.compareConflictWithMarked(captured,alternate:true)
        try await wait {!model.busy && !workspace.busy && RebaseWindowModel.activePreparationReads==0 && FileListComparisonSession.activeOperations==0}
        try require(prepared?.0.path==clean && prepared?.1.path==path && prepared?.2==true && opened==[path] && choices==[true],"Captured local mark comparison followed a new mark")
        let external=root.appendingPathComponent("external-mark.txt");try Data("external marked bytes\n".utf8).write(to:external)
        let bookmarks=PrivateBookmarks(),grant=RepositoryAccessLease(url:root,provider:bookmarks)
        let store=WorkingComparisonMarkStore(storageURL:root.appendingPathComponent("private-mark.json"),provider:bookmarks)
        _ = try store.remember(file:external,permission:grant);let access=try store.acquire()
        model.importConflictComparisonMark(access);let imported=model.conflictFileMenu([path])
        model.markConflictForComparison(model.conflictFileMenu([clean]));try await wait {!model.busy};model.importConflictComparisonMark(access)
        try require(model.conflictComparisonMark?.path==clean,"Repeated Finder mark overwrote local choice")
        model.compareConflictWithMarked(imported,alternate:false);try await wait {!model.busy}
        try require(prepared?.0.workingAccess?.mark.id==access.mark.id && prepared?.1.path==path && prepared?.2==false,"Imported mark lost captured permission/endpoint")
        // Real initialized working gitlink history, without advancing the parent.
        let index=root.appendingPathComponent(".git/index"),savedIndex=try Data(contentsOf:index),mode=try FileManager.default.attributesOfItem(atPath:index.path)[.posixPermissions]!
        let modulePath="module",moduleRoot=root.appendingPathComponent(modulePath),modules=root.appendingPathComponent(".gitmodules")
        try require(!FileManager.default.fileExists(atPath:moduleRoot.path) && !FileManager.default.fileExists(atPath:modules.path),"Submodule fixture target already exists")
        try FileManager.default.createDirectory(at:moduleRoot,withIntermediateDirectories:true)
        defer {try? savedIndex.write(to:index,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:mode],ofItemAtPath:index.path);try? FileManager.default.removeItem(at:moduleRoot);try? FileManager.default.removeItem(at:modules)}
        let child=GitRepository(root:moduleRoot,executable:git);_ = try await child.run(["init","-b","main"])
        for (key,value) in [("user.name","Module QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await child.run(["config",key,value])}
        try Data("module bytes\n".utf8).write(to:moduleRoot.appendingPathComponent("module.txt"));try await child.stage(["module.txt"]);_ = try await child.commit(message:"Module history")
        let childHead=try await child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("[submodule \"module\"]\n\tpath = module\n\turl = ./module\n".utf8).write(to:modules)
        _ = try await repo.run(["update-index","--add","--cacheinfo","160000",childHead,modulePath])
        model.refreshState();try await wait {!model.busy && model.conflictRows.contains {$0.path==modulePath}}
        let moduleMenu=model.conflictFileMenu([modulePath]);try require(model.canConflictFileCommand(.submoduleLog,menu:moduleMenu) && !model.canMarkConflictComparison(moduleMenu),"Gitlink history/mark gates wrong")
        var loaded:GitRepository?;model.onConflictSubmoduleLog={loaded=$0};model.conflictFileCommand(.submoduleLog,menu:moduleMenu)
        try await wait {!model.busy && SubmoduleWorkingLogSession.activeReads==0}
        guard let loaded else {throw Failure(description:"Submodule Log callback missing: "+(model.error ?? ""))}
        let childRows=try await loaded.history();try require(loaded.root.resolvingSymlinksInPath().path==moduleRoot.resolvingSymlinksInPath().path && childRows.first?.hash==childHead,"Submodule Log endpoint mismatch: \(loaded.root.path), expected \(moduleRoot.path); HEAD \(childRows.first?.hash ?? "nil"), expected \(childHead)")
        // Stale generation and retired async preparation cannot publish a viewer.
        let stale=model.conflictFileMenu([path]);model.refreshState();try await wait {!model.busy}
        model.showConflictUnified(stale);try require(!model.busy && owner.conflictUnifiedWindows.isEmpty,"Stale unified popup launched")
        let late=RebaseWindowModel(repository:repo,access:nil,messageDefaults:prefs);late.load();try await wait {!late.busy && late.fileRecovery}
        let snapshot=try await repo.rebaseSessionSnapshot();var reply:CheckedContinuation<RebaseSessionSnapshot,Never>?,delivered=0
        late.readSession={_,_ in await withCheckedContinuation {reply=$0}};late.onConflictUnified={_,_,_,_ in delivered += 1}
        late.showConflictUnified(late.conflictFileMenu([path]));try await wait {reply != nil};late.retire();reply?.resume(returning:snapshot)
        try await wait {RebaseWindowModel.activePreparationReads==0}
        try require(delivered==0 && late.error==nil && late.conflictComparisonMark==nil,"Retired comparison preparation published")
    }
    @MainActor static func verifyMutations(root:URL,git:URL,prefs:UserDefaults) async throws {
        let root=root.appendingPathComponent("mutations");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git),path="normal 雪.txt",conflict="conflict.txt"
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Replay mutation QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        for name in [path,conflict] {try Data("base\n".utf8).write(to:root.appendingPathComponent(name))};try await repo.stage([path,conflict]);_ = try await repo.commit(message:"base")
        let base=try await repo.rebaseCommit("HEAD");_ = try await repo.run(["switch","-c","upstream"])
        try Data("upstream\n".utf8).write(to:root.appendingPathComponent(conflict));try await repo.stage([conflict]);_ = try await repo.commit(message:"upstream")
        _ = try await repo.run(["switch","-c","topic",base.hash])
        for name in [path,conflict] {try Data("topic\n".utf8).write(to:root.appendingPathComponent(name))};try await repo.stage([path,conflict]);_ = try await repo.commit(message:"topic")
        var options=RebaseOptions();options.branch="topic";options.upstream="upstream"
        let editor=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac")
        _ = try await repo.startRebase(try await repo.rebasePlan(options),editorExecutable:editor)
        let owner=RebaseWindowController(repository:repo,access:nil,preferences:prefs),model=owner.model
        defer {owner.close()};model.load();try await wait {!model.busy && model.fileRecovery}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,stages=try await repo.run(["ls-files","--unmerged","-z"]).stdout
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),working=try Data(contentsOf:root.appendingPathComponent(path))
        model.focusedConflictPath=path
        let selected=model.conflictFileMenu([path]),bad=model.conflictFileMenu([conflict])
        try require(model.canSetConflictFlags(.assumeUnchanged,menu:selected) && !model.canSetConflictFlags(.clear,menu:selected) && !model.canSetConflictFlags(.skipWorktree,menu:bad),"Index flag source gates wrong")
        model.setConflictFlags(.assumeUnchanged,menu:selected)
        try await wait {owner.window?.attachedSheet != nil && model.hasReplayQuestion}
        let question=owner.window!.attachedSheet!
        try require(question.defaultButtonCell?.title=="No","Index flags must default to No")
        owner.window!.endSheet(question,returnCode:.alertSecondButtonReturn);question.orderOut(nil)
        try await wait {!model.busy && RebaseWindowModel.activePreparationReads==0}
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"No changed index flags")
        model.confirmConflictMutation={_,_ in true}
        model.setConflictFlags(.assumeUnchanged,menu:model.conflictFileMenu([path,conflict]));try await wait {!model.busy && RebaseWindowModel.activePreparationReads==0}
        try require(model.error != nil,"Mixed stage-zero/unmerged selection lost its partial failure")
        model.error=nil;try await wait {owner.window?.attachedSheet == nil}
        try require(model.conflictIndexFlags[path]?.assumeUnchanged==true && model.conflictColumnText(model.conflictRows.first {$0.path==path}!, .status)=="Assume unchanged","Index flag result/status not refreshed")
        let stale=model.conflictFileMenu([path])
        model.setConflictFlags(.skipWorktree,menu:stale);try await wait {!model.busy && RebaseWindowModel.activePreparationReads==0}
        try require(model.conflictIndexFlags[path]?.skipWorktree==true && model.conflictIndexFlags[path]?.assumeUnchanged==true,"Skip overwrote other index flag")
        let beforeStale=try Data(contentsOf:root.appendingPathComponent(".git/index"));model.setConflictFlags(.clear,menu:stale)
        try require(!model.busy && Data(contentsOf:root.appendingPathComponent(".git/index"))==beforeStale,"Stale flag popup mutated index")
        model.setConflictFlags(.clear,menu:model.conflictFileMenu([path]));try await wait {!model.busy && RebaseWindowModel.activePreparationReads==0}
        try require(model.conflictIndexFlags[path]==nil && Data(contentsOf:root.appendingPathComponent(path))==working,"Clear flags changed working bytes")
        var progress:RevertProgressWindowModel?
        owner.configureConflictRevert={progress=$0};model.confirmConflictMutation={_,_ in false}
        let revertIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        model.revertConflictFiles(model.conflictFileMenu([path]));try await wait {!model.busy && RebaseWindowModel.activePreparationReads==0}
        try require(progress==nil && Data(contentsOf:root.appendingPathComponent(".git/index"))==revertIndex,"Declined Revert opened operation or changed index")
        model.confirmConflictMutation={_,_ in true};model.revertConflictFiles(model.conflictFileMenu([path]))
        try await wait {progress != nil && progress?.busy==false && RevertProgressWindowModel.activeOperations==0}
        guard let progress else {throw Failure(description:"Owned Revert progress missing")}
        defer {for copy in progress.trashedFiles {try? FileManager.default.removeItem(at:copy)}}
        try require(!progress.failed && !progress.cancelled,"Owned Revert failed: "+progress.information)
        try await wait {!model.busy && RebaseWindowModel.activePreparationReads==0}
        try require(progress.retired && !progress.failed && !progress.cancelled && owner.conflictRevertWindow==nil,"Owned Revert did not finish/close")
        try require(try Data(contentsOf:root.appendingPathComponent(path))==Data("base\n".utf8) && !model.conflictRows.contains {$0.path==path},"Revert did not restore HEAD or refresh list")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterStages=try await repo.run(["ls-files","--unmerged","-z"]).stdout
        try require(afterHead==head && afterStages==stages && model.active,"Revert advanced replay or changed unrelated conflict")
        try require(progress.trashedFiles.count==1 && Data(contentsOf:progress.trashedFiles[0])==working,"Revert lost recoverable working bytes")
        owner.close()
        // A captured Yes after retirement cannot resume a pending flag command.
        try Data("later\n".utf8).write(to:root.appendingPathComponent(path))
        let late=RebaseWindowController(repository:repo,access:nil,preferences:prefs);defer {late.close()};late.model.load();try await wait {!late.model.busy && late.model.fileRecovery}
        var reply:CheckedContinuation<Bool,Never>?
        late.model.confirmConflictMutation={_,_ in await withCheckedContinuation {reply=$0}}
        let lateIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        late.model.setConflictFlags(.assumeUnchanged,menu:late.model.conflictFileMenu([path]));try await wait {reply != nil}
        late.close();reply?.resume(returning:true);try await wait {RebaseWindowModel.activePreparationReads==0}
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==lateIndex,"Retired confirmation changed index")
        _ = try await repo.abortRebase()
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Replay file QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let path="-conflict 雪\n[*].txt",file=root.appendingPathComponent(path),clean="added.txt"
        try Data("base\n".utf8).write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"base")
        let base=try await repo.rebaseCommit("HEAD");_ = try await repo.run(["switch","-c","upstream"]);try Data("upstream\n".utf8).write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"upstream")
        _ = try await repo.run(["switch","-c","topic",base.hash]);try Data("topic\n".utf8).write(to:file);try Data("clean applied\n".utf8).write(to:root.appendingPathComponent(clean));try await repo.stage([path,clean]);_ = try await repo.commit(message:"topic")
        var options=RebaseOptions();options.branch="topic";options.upstream="upstream"
        let editor=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac")
        _ = try await repo.startRebase(try await repo.rebasePlan(options),editorExecutable:editor)
        let suite="TurtleGit.ReplayFileMenus."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar");defer { prefs.removePersistentDomain(forName:suite) }
        let owner=RebaseWindowController(repository:repo,access:nil,preferences:prefs),model=owner.model
        defer { owner.close() }
        let pasteboard=NSPasteboard.withUniqueName();model.conflictPasteboard=pasteboard
        defer { pasteboard.releaseGlobally() }
        owner.configureConflictBaseViewer={ $0.openExternalComparison={ _,_,_,_ in false } }
        model.load();try await wait { !model.busy && model.fileRecovery && model.conflictRows.count == 2 }
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
        let menu=model.conflictFileMenu(Set([path])),all=model.conflictFileMenu(Set([path,clean]))
        try require(model.canConflictFileCommand(.open,menu:menu) && !model.canConflictFileCommand(.open,menu:all) && model.canConflictFileCommand(.compareTwo,menu:all),"Source selection gates incorrect")
        model.copyConflictFiles(menu,copy:.relativePaths);try require(pasteboard.string(forType:.string) == path+"\n","Literal path copy changed newline/Unicode")
        model.copyConflictFiles(all,copy:.all);let copied=pasteboard.string(forType:.string) ?? ""
        try require(copied.hasPrefix("Path\tExtension\tStatus\tLines added\tLines removed\n") && copied.contains("Conflicted") && copied.contains(".txt"),"Five displayed-column copy missing")
        model.copyConflictFiles(menu,copy:.column(.status));try require(pasteboard.string(forType:.string) == "Conflicted\n","Per-column status copy differs from table")
        var logged="",blame:(String,String)?,pair:[String]=[],opened:[URL]=[],reveal:[URL]=[],edited:[URL]=[]
        model.onConflictFileLog={logged=$0};model.onConflictFileBlame={blame=($0,$1)};model.onConflictWorkingPair={pair=$0}
        model.openConflictWorkingFile={url,_ in opened.append(url)};model.openConflictAlternativeEditor={edited.append($0)};model.revealConflictFiles={reveal=$0}
        model.conflictFileCommand(.log,menu:menu);try await wait { !model.busy };try require(logged == path,"File Log lost captured path")
        model.conflictFileCommand(.blame,menu:menu);try await wait { !model.busy };try require(blame?.0 == path && blame?.1 == String(decoding:head,as:UTF8.self).trimmingCharacters(in:.newlines),"Blame lost captured HEAD/path")
        model.conflictFileCommand(.compareTwo,menu:all);try await wait { !model.busy };try require(pair == all.paths,"Pair comparison changed selected order")
        model.conflictFileCommand(.editor,menu:menu);try await wait { !model.busy };try require(edited.map(\.path) == [file.path],"Alternative editor lost path")
        try require(!model.canConflictFileCommand(.blame,menu:model.conflictFileMenu(Set([clean]))) && !model.canConflictFileCommand(.reveal,menu:all),"Added Blame/multiple Explore gates differ from source")
        model.conflictFileCommand(.reveal,menu:menu);try await wait { !model.busy };try require(reveal.map(\.path) == [file.path],"Reveal did not preserve selected file")
        // Open With retains menu selection even when highlight changes while its
        // picker awaits a reply, then revalidates the stopped replay.
        var release:(()->Void)?
        model.chooseConflictApplication={ await withCheckedContinuation { continuation in release={continuation.resume(returning:root.appendingPathComponent("Fake.app"))} } }
        model.conflictFileCommand(.openWith,menu:menu);try await wait { release != nil }
        model.selectedConflicts=Set([clean]);release?();try await wait { !model.busy }
        try require(opened.map(\.path) == [file.path],"Open With redirected to later highlight")
        let exported=root.appendingPathComponent("export");try FileManager.default.createDirectory(at:exported,withIntermediateDirectories:true)
        model.chooseConflictExport={exported};model.conflictFileCommand(.export,menu:all);try await wait { !model.busy }
        try require(try Data(contentsOf:exported.appendingPathComponent(path)) == working && Data(contentsOf:exported.appendingPathComponent(clean)) == Data("clean applied\n".utf8),"Export did not preserve selected working bytes")
        // New front-end snapshot invalidates a stale popup without changing its
        // selection, contents, index or HEAD.
        model.refreshState();try await wait { !model.busy };model.conflictFileCommand(.open,menu:menu)
        try require(opened.count == 1,"Old popup survived refresh generation")
        model.compareConflicts(Set([path]));try await wait { owner.conflictBaseViewer != nil }
        let viewer=owner.conflictBaseViewer!;viewer.model.load();try await wait { !viewer.model.busy && !viewer.model.filtering && (viewer.model.alignment != nil || viewer.model.error != nil) }
        try require(viewer.model.error == nil && viewer.model.document?.base.text == "base\n" && viewer.model.canEdit(base:false),"Replay base viewer does not use stage 1/editable current bytes")
        try require(model.busy && model.viewingConflictBase && !owner.windowShouldClose(owner.window!),"Replay remains actionable while base child owns review")
        viewer.close();try await wait { !model.busy && !model.viewingConflictBase }
        owner.window?.contentView?.layoutSubtreeIfNeeded();model.tab=0
        try await wait { descendants(owner.window!.contentView!).contains { $0 is RebaseConflictFileKeys.Probe } }
        let probes=descendants(owner.window!.contentView!).compactMap { $0 as? RebaseConflictFileKeys.Probe }
        try await wait { probes.first?.table()?.numberOfRows == model.conflictRows.count }
        let probe=probes[0],table=probe.table()!,row=model.conflictRows.firstIndex(where:{$0.path == path})!
        table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);owner.window?.makeFirstResponder(table)
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:"c",charactersIgnoringModifiers:"c",isARepeat:false,keyCode:8)!
        try require(probe.handle(event) == nil && pasteboard.string(forType:.string) == path+"\n","Scoped native Command-C failed")
        let checked=model.checkedConflicts;let space=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49)!
        try require(probe.handle(space) == nil && model.checkedConflicts.contains(path) != checked.contains(path) && model.checkedConflicts.contains(clean) == checked.contains(clean),"Space changed highlight/unchecked other paths")
        // The lower replay list shares native column visibility/order/width,
        // numeric metadata sorting, reset ownership and keyboard coordinates.
        try await wait { table.tableColumns.count==6 && table.headerView?.menu != nil }
        let fileProbe=descendants(owner.window!.contentView!).compactMap { $0 as? CommitFileInteraction.Probe }.first!
        try await wait {fileProbe.enabled && model.conflictColumnsAvailable && table.headerView?.menu?.items.first(where:{$0.title=="Lines added"})?.isEnabled == true}
        let header=table.headerView!.menu!;header.delegate?.menuNeedsUpdate?(header)
        let addedColumn=header.items.first { $0.title=="Lines added" }!
        try require(addedColumn.isEnabled && !header.items.contains { $0.title=="File size" || $0.title=="Last modified" || $0.title=="Filename" || $0.title=="LFS Lock" },"Header does not honor source allowed-column mask; enabled=\(fileProbe.enabled), busy=\(model.busy), items=\(header.items.map { $0.title })")
        _ = NSApp.sendAction(addedColumn.action!,to:addedColumn.target,from:addedColumn)
        try await wait { !model.conflictFileColumns.visible.contains(.added) && !fileProbe.visibleColumns.contains(.added) }
        _ = NSApp.sendAction(addedColumn.action!,to:addedColumn.target,from:addedColumn)
        try await wait { model.conflictFileColumns.visible.contains(.added) && fileProbe.visibleColumns.contains(.added) }
        var layout=model.conflictFileColumns.order;layout.removeAll { $0 == .added };layout.insert(.added,at:0)
        try require(model.saveConflictColumnLayout(order:layout,widths:[.path:310,.added:143]),"Replay layout rejected")
        // Use distinct multi-digit counts to distinguish numeric sorting from
        // lexical sorting without assuming Git omits conflict-marker statistics.
        let liveStatistics=model.conflictStatistics
        for (name,count) in [(path,2),(clean,10)] {
            model.conflictStatistics[name]=CommitFile(path:name,oldPath:nil,action:"M",added:count,removed:0,hasStatistics:true,isSubmodule:false)
        }
        model.setConflictSort([RebaseConflictSort(column:.added,order:.reverse)])
        owner.window!.contentView!.layoutSubtreeIfNeeded()
        try await wait { table.tableColumns.first(where:{$0.headerCell.stringValue=="Lines added"})?.isHidden == false }
        let sorted=model.conflictTableRows.map(\.id)
        try require(sorted.first==clean,"Lines added did not order numeric 10 ahead of 2")
        let selected=Set(sorted),captured=model.conflictFileMenu(selected)
        model.copyConflictFiles(captured,copy:.all)
        try require((pasteboard.string(forType:.string) ?? "").hasPrefix("Lines added\tPath\tExtension\tStatus\tLines removed\n"),"Clipboard ignored saved visible column order")
        model.copyConflictFiles(captured,copy:.column(.added))
        try require(pasteboard.string(forType:.string)==sorted.map { model.conflictStatistics[$0]?.added.map(String.init) ?? "–" }.joined(separator:"\n")+"\n","Clipboard ignored sorted metadata rows")
        model.conflictStatistics=liveStatistics
        let reopened=RebaseWindowModel(repository:repo,access:nil,messageDefaults:prefs)
        try require(reopened.conflictFileColumns.widths[.path]==310 && reopened.conflictFileColumns.widths[.added]==143 && reopened.conflictFileColumns.order.first == .added && reopened.conflictSortOrder.first?.column == .added && reopened.conflictSortOrder.first?.order == .reverse,"Replay file layout/sort did not survive reopening")
        reopened.retire()
        let beforeHide=model.conflictFileColumns
        model.setConflictColumn(.path,visible:false);model.setConflictColumn(.lfsOwner,visible:true)
        try require(model.conflictFileColumns==beforeHide,"Unavailable/path column visibility changed")
        var resetReply:CheckedContinuation<Bool,Never>?,accepted=0
        model.resetConflictColumns(choose:{await withCheckedContinuation {resetReply=$0}},onAccepted:{accepted += 1})
        try await wait { resetReply != nil }
        try require(model.busy && RebaseWindowModel.activePreparationReads>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Reset lost owner/Quit guard")
        resetReply?.resume(returning:false);resetReply=nil;try await wait {!model.busy}
        try require(model.conflictFileColumns==beforeHide && accepted==0,"Declined Reset changed layout")
        model.resetConflictColumns(choose:{true},onAccepted:{accepted += 1});try await wait {!model.busy}
        try require(model.conflictFileColumns==StatusListColumnSettings() && accepted==1,"Accepted Reset did not restore source defaults")
        // A sorted native row routes Copy and Space to its stable path identity.
        model.setConflictSort([RebaseConflictSort(column:.path,order:.reverse)])
        owner.window!.contentView!.layoutSubtreeIfNeeded();try await wait { fileProbe.rows.compactMap(\.entry).map(\.id)==model.conflictTableRows.map(\.id) }
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);owner.window!.makeFirstResponder(table)
        let sortedFirst=model.conflictTableRows[0].id,checks=model.checkedConflicts
        try require(probe.handle(event)==nil && pasteboard.string(forType:.string)==sortedFirst+"\n","Sorted Copy targeted old index")
        try require(probe.handle(space)==nil && model.checkedConflicts.contains(sortedFirst) != checks.contains(sortedFirst),"Sorted Space targeted old index")
        try await verifyComparisons(owner:owner,repo:repo,root:root,path:path,clean:clean,prefs:prefs)
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;try require(after == head && Data(contentsOf:root.appendingPathComponent(".git/index")) == index && Data(contentsOf:file) == working,"Review/menu actions changed repository baseline")
        owner.close()
        // Forced-close settles an owned actual native export picker once; late OK
        // cannot create files. The lifetime persists until its task settles.
        let pending=RebaseWindowController(repository:repo,access:nil,preferences:prefs);defer { pending.close() }
        pending.model.load();try await wait { !pending.model.busy && pending.model.fileRecovery }
        var answer:((NSApplication.ModalResponse)->Void)?;pending.presentConflictPanel={_,_,reply in answer=reply;return true}
        pending.model.conflictFileCommand(.export,menu:pending.model.conflictFileMenu(Set([clean])));try await wait { answer != nil }
        pending.close();answer?(.OK);answer?(.OK);try await wait { RebaseWindowModel.activePreparationReads == 0 }
        try require(pending.model.retired && pending.model.error == nil,"Late export picker revived retired owner")
        let retired=RebaseWindowModel(repository:repo,access:nil,messageDefaults:prefs)
        retired.load();try await wait { !retired.busy && retired.fileRecovery }
        let savedColumns=retired.conflictFileColumns
        var lateReset:CheckedContinuation<Bool,Never>?
        retired.resetConflictColumns(choose:{await withCheckedContinuation {lateReset=$0}},onAccepted:{accepted += 100})
        try await wait {lateReset != nil};retired.retire();lateReset?.resume(returning:true)
        try await wait {RebaseWindowModel.activePreparationReads==0}
        try require(retired.conflictFileColumns==savedColumns && accepted==1,"Retired Reset wrote settings or callback")
        _ = try await repo.abortRebase()
        try await verifyMutations(root:root,git:git,prefs:prefs)
        print("Replay file menus: captured Log/Blame/Open With/Editor/Reveal/pair callbacks, exact multi-file export and private clipboard, stale-popup rejection, native stage-1 viewer/parent blocking, scoped native copy/check keys and owned picker retirement passed. HEAD/raw index/working bytes preserved; all owned windows closed.")
    }
}
