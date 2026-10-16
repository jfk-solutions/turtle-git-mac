import AppKit
import TurtleGitCore

@main struct LogPopupVariantsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value{throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool,line:Int = #line) async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Popup variants timeout at \(line)")
    }
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func leaves(_ menu:NSMenu)->[NSMenuItem] {menu.items.flatMap{$0.submenu.map{leaves($0)} ?? ($0.action == nil ? []:[$0])}}
    @MainActor static func main() async {do{try await verify()}catch{fputs("Log popup variants failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),root=folder.appendingPathComponent("Harbor"),git=URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for(key,value) in [("user.name","Popup QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"Root")
        let base=try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["switch","-c","side"]);try Data("side\n".utf8).write(to:root.appendingPathComponent("side"));try await repo.stage(["side"]);_ = try await repo.commit(message:"Side")
        _ = try await repo.run(["switch","main"])
        for name in ["first","second"] {try Data((name+"\n").utf8).write(to:root.appendingPathComponent(name));try await repo.stage([name]);_ = try await repo.commit(message:name)}
        _ = try await repo.run(["merge","--no-ff","side","-m","Merge side"])
        try Data("modified working contents\n".utf8).write(to:root.appendingPathComponent("file"))
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try await repo.run(["write-tree"]).stdout,status=try await repo.run(["status","--porcelain=v1","-z"]).stdout
        let suite="TurtleGit.LogPopupVariants."+UUID().uuidString
        guard let prefs=UserDefaults(suiteName:suite) else{throw Failure(description:"Private preferences unavailable")}
        prefs.set(true,forKey:"LogIncludeWorkingTreeChanges");prefs.set(false,forKey:"EnableGravatar");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        defer{prefs.removePersistentDomain(forName:suite)}
        let regex=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let owner=LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false,historyRegexExecutable:regex),model=owner.model
        defer{owner.close()};owner.window?.alphaValue=0;owner.window?.orderFront(nil);model.reload()
        try await wait{!model.busy && !model.loadingHistory && model.entries.count>=6 && views(owner.window?.contentView).contains{$0 is HistoryTableView}}
        guard let table=views(owner.window?.contentView).compactMap({$0 as? HistoryTableView}).first,let coordinator=table.delegate as? RevisionTable.Coordinator,let menu=table.menu else{throw Failure(description:"Native Log menu missing")}
        let clipboard=NSPasteboard.withUniqueName();model.clipboard=clipboard;defer{clipboard.releaseGlobally()}
        var comparisons:[(ComparisonRevision,ComparisonRevision)]=[],reverted:[String]=[]
        model.onCompare={comparisons.append(($0,$1))};model.onBrowseRepository={_ in};model.onShowHistoryRange={_ in};model.onCommitChangeSets={_ in};model.onRevertRevisions={rows,_ in reverted=rows.map(\.hash)}
        func item(_ selector:String)->NSMenuItem? {leaves(menu).first{ $0.action.map(NSStringFromSelector)==selector }}
        func choose(_ ids:Set<String>) {
            let indices=IndexSet(model.entries.indices.filter{ids.contains(model.entries[$0].hash)});table.selectRowIndexes(indices,byExtendingSelection:false);model.select(ids);coordinator.menuNeedsUpdate(menu)
        }
        func send(_ item:NSMenuItem?) throws {
            guard let item,let action=item.action,item.isEnabled else{throw Failure(description:"Enabled menu item missing")}
            _ = NSApp.sendAction(action,to:item.target,from:item)
        }
        func clean(_ value:NSMenu) throws {
            try require(value.items.first?.isSeparatorItem != true && value.items.last?.isSeparatorItem != true,"Leading/trailing separator")
            for pair in zip(value.items,value.items.dropFirst()){try require(!pair.0.isSeparatorItem || !pair.1.isSeparatorItem,"Duplicate separators")}
            for item in value.items {if let sub=item.submenu{try clean(sub)}}
        }
        choose([]);try require(menu.items.isEmpty,"Empty selection exposed revision commands")
        let commits=model.entries.filter{!$0.hash.isEmpty};guard let ordinary=commits.first(where:{$0.parents.count==1}),let merge=commits.first(where:{$0.parents.count>1}) else{throw Failure(description:"Fixture revisions missing")}
        choose([ordinary.hash]);try clean(menu)
        let normalSelectors=menu.items.compactMap{$0.action.map(NSStringFromSelector)}
        try require(Array(normalSelectors.prefix(3))==["workingDiff","showDiff","compare"] && item("findEntry:")?.image != nil,"Single-commit source command order/Find differs")
        choose([base.hash]);try clean(menu)
        try require(item("workingDiff") != nil && item("compare")==nil && item("showDiff")==nil,"Root menu invents a previous revision")
        choose([merge.hash]);try clean(menu)
        try require(item("showParentDiff:") != nil && menu.items.first(where:{$0.title=="Compare with previous revision"})?.submenu?.items.count==merge.parents.count,"Merge parent menu differs")
        choose(Set(commits.prefix(2).map(\.hash)));try clean(menu)
        try require(item("workingDiff")==nil && item("browseRepository")==nil && item("compare") != nil && item("showDiff") != nil && leaves(menu).filter{$0.action.map(NSStringFromSelector)=="showHistoryRange:"}.count==3,"Two-row menu contains single-only actions or lost ranges")
        choose(Set(commits.prefix(3).map(\.hash)));try clean(menu)
        try require(item("compare") != nil && item("showDiff")==nil && item("browseRepository")==nil,"Continuous multi-row comparison mask differs")
        choose([commits[0].hash,commits[2].hash,commits[4].hash]);try clean(menu)
        try require(item("compare")==nil && item("showDiff")==nil && item("formatPatch")==nil,"Discontinuous multi-row menu exposes endpoint/patch commands")
        choose([""]);try clean(menu)
        try require(item("copyDetails") != nil && item("findEntry:")?.isEnabled==true && item("browseRepository")==nil,"Working-tree common menu tail missing")
        try send(item("copyDetails"));try await wait{!model.copyingDetails}
        try require(clipboard.string(forType:.string)?.contains("Working tree changes")==true && clipboard.string(forType:.string)?.contains("Modified: file")==true,"Working-tree full clipboard tried to resolve empty commit")
        choose([""]);try send(item("copyDetailsWithoutPaths"));try await wait{!model.copyingDetails}
        try require(clipboard.string(forType:.string)?.contains("Working tree changes")==true && clipboard.string(forType:.string)?.contains("Modified: file")==false,"Working-tree no-path copy includes file details")
        let mixed=Set(model.entries.prefix(3).map(\.hash)),oldest=model.entries[2].hash
        choose(mixed);try send(item("copyDetailsWithoutPaths"));try await wait{!model.copyingDetails}
        try require(clipboard.string(forType:.string)?.contains("Working tree changes")==true && clipboard.string(forType:.string)?.contains(oldest)==true,"Mixed clipboard omitted working/commit entries")
        choose(mixed);try clean(menu);try require(model.continuousHistorySelection && item("compare") != nil,"Working-tree contiguous endpoint comparison missing")
        try send(item("compare"));try require(comparisons.last?.0 == .revision(oldest) && comparisons.last?.1 == .workingTree,"Working-tree comparison used newest commit")
        choose(mixed);try send(item("revertCaptured:"));try require(reverted.count==2 && !reverted.contains(""),"Synthetic working-tree row became a Revert commit")
        choose([ordinary.hash]);let findRow=model.entries.firstIndex{$0.hash==ordinary.hash}!
        table.contextRow=findRow;coordinator.menuNeedsUpdate(menu);let find=item("findEntry:");coordinator.menuDidClose(menu)
        try send(find);try await wait{owner.find != nil}
        try require(model.findSearchIndex==findRow && owner.find?.searchIndex()==findRow,"Find did not retain clicked selection mark after menu close")
        owner.find?.close();try await wait{owner.find==nil}
        try send(find);try require(owner.find==nil,"Find popup action replayed")
        choose([ordinary.hash]);let stale=item("findEntry:");choose([base.hash]);choose([ordinary.hash]);try send(stale);try require(owner.find==nil,"Selection-away/return revived Find")
        // A real bare consumer keeps revision comparison but omits working/unified actions.
        let bareRoot=folder.appendingPathComponent("Bare.git");_ = try await repo.run(["clone","--bare",root.path,bareRoot.path])
        let bareRepo=GitRepository(root:bareRoot,executable:git),bareOwner=LogWindowController(repository:bareRepo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false),bareModel=bareOwner.model
        defer{bareOwner.close()};bareOwner.window?.alphaValue=0;bareOwner.window?.orderFront(nil);bareModel.reload()
        try await wait{!bareModel.busy && bareModel.bare && !bareModel.entries.isEmpty && views(bareOwner.window?.contentView).contains{$0 is HistoryTableView}}
        guard let bareTable=views(bareOwner.window?.contentView).compactMap({$0 as? HistoryTableView}).first,let bareCoordinator=bareTable.delegate as? RevisionTable.Coordinator,let bareMenu=bareTable.menu else{throw Failure(description:"Bare menu missing")}
        bareModel.selected=[ordinary.hash];bareCoordinator.menuNeedsUpdate(bareMenu);try clean(bareMenu)
        let bareActions=leaves(bareMenu).compactMap{$0.action.map(NSStringFromSelector)}
        try require(bareActions.contains("compare") && !bareActions.contains("workingDiff") && !bareActions.contains("showDiff"),"Bare menu has worktree-only commands")
        bareOwner.close()
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["write-tree"]).stdout,afterStatus=try await repo.run(["status","--porcelain=v1","-z"]).stdout
        try require(afterHead==head && afterIndex==index && afterStatus==status,"Menu/clipboard/Find preparation changed repository")
        print("PASS: native Log single/root/merge/two/continuous/discontinuous/working/bare popup variants, source order and separators, working clipboard, contiguous working endpoints, synthetic-row Revert exclusion, captured one-use Find/selection mark and stale callbacks; HEAD/index/worktree preserved; owned windows closed.")
    }
}
