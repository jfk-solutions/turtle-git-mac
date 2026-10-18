import AppKit
import TurtleGitCore

@MainActor enum BlameHistoryPolicyVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    static func wait(_ condition:@escaping ()->Bool) async throws {
        for _ in 0..<1200 { if condition() { return };try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Blame history policy did not settle")
    }
    static func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    static func send(_ item:NSMenuItem) throws {
        guard let action=item.action else {throw Failure(description:"No action for \(item.title)")};_ = NSApp.sendAction(action,to:item.target,from:item)
    }
    static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","History QA"),("user.email","history@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let file=root.appendingPathComponent("history.cpp")
        for (value,message) in [("one\n","First"),("two\n","Second"),("three\n","Third")] {
            try Data(value.utf8).write(to:file);try await repo.stage(["history.cpp"]);_ = try await repo.commit(message:message)
        }
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),bytes=try Data(contentsOf:file)
        let domain="TurtleGit.BlameHistoryPolicy.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:domain)!
        defer {prefs.removePersistentDomain(forName:domain)}
        let helper=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let owner=BlameWindowController(repository:repo,access:nil,path:"history.cpp",revision:"HEAD",options:GitBlameOptions(),preferences:prefs,regexExecutable:helper)
        defer {owner.close()}
        let model=owner.model,window=owner.window!
        try await wait {!model.busy && !model.syntaxWorking && model.historyEntries.count==3}
        window.contentView?.layoutSubtreeIfNeeded()
        guard let table=descendants(window.contentView!).compactMap({$0 as? BlameHistoryNativeTable}).first,let coordinator=table.delegate as? BlameHistoryTable.Coordinator,let menu=table.menu else {throw Failure(description:"No native Blame history")}
        var comparisons=0,logs=0,exports:[String]=[]
        model.onChanges={_ in comparisons += 1};model.onLog={_,_ in logs += 1};model.onHistoryExport={exports.append($0)}
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);coordinator.menuNeedsUpdate(menu)
        try require(model.historyHasWorkingTree && model.historyHead==model.historyEntries[0].hash,"Owned metadata did not capture WC/HEAD")
        try require(!menu.items.contains{$0.title=="Switch/Checkout to this…"},"HEAD offered redundant checkout")
        table.openSelection();try require(comparisons==0 && logs==0,"Default disabled double-click unexpectedly acted")
        prefs.set(true,forKey:"DiffByDoubleClickInLog");table.openSelection()
        try await wait {comparisons==1 && BlameWindowModel.activeHistoryOperations==0}
        coordinator.menuNeedsUpdate(menu)
        guard let compare=menu.items.first(where:{$0.title=="Compare with previous revision"}) else {throw Failure(description:"Missing prepared compare")}
        let font=compare.attributedTitle?.attribute(.font,at:0,effectiveRange:nil) as? NSFont
        try require(font.map{NSFontManager.shared.traits(of:$0).contains(.boldFontMask)}==true,"Source default comparison not emphasized")
        let parents=menu.items.filter{["Blame previous revision","Show changes as unified diff","Compare with previous revision"].contains($0.title)}.map(\.title)
        try require(parents==["Blame previous revision","Show changes as unified diff","Compare with previous revision"],"Parent command source order differs")
        try require(!menu.items.contains{$0.title=="Copy SHA-1 to clipboard" || $0.title=="Copy log message"},"Extra non-source root clipboard commands")
        table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false);coordinator.menuNeedsUpdate(menu)
        try require(menu.items.contains{$0.title=="Switch/Checkout to this…"},"Non-HEAD checkout missing")
        let oldTarget=model.historyTarget([model.historyEntries[1]])!,oldExport=menu.items.first{$0.title=="Export this version…"}!
        model.historyContextMenuPolicy = .init(commands:[.copyClipboard]);model.historyContextMenuPolicy = .blame
        try send(oldExport);try require(exports.isEmpty && !model.acceptsHistory(oldTarget),"Mask change away/back revived old menu")
        coordinator.menuNeedsUpdate(menu);let export=menu.items.first{$0.title=="Export this version…"}!,pinned=model.historyEntries[1].hash
        table.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false);try send(export);try send(export)
        try require(exports==[pinned],"Captured export followed selection or replayed")
        model.historyContextMenuPolicy = .init(commands:[.copyClipboard]);coordinator.menuNeedsUpdate(menu)
        try require(menu.items.count==1 && menu.items[0].title=="Copy to clipboard","Actual Blame consumer did not apply mask/separator cleanup")
        table.openSelection();try require(comparisons==1,"Masked default action executed")
        model.historyContextMenuPolicy = .blame;coordinator.menuNeedsUpdate(menu)
        let retired=menu.items.first{$0.title=="Export this version…"}!
        owner.close();try send(retired);try require(exports==[pinned],"Closed Blame owner accepted action")
        try await wait {BlameWindowModel.activeHistoryOperations==0}
        // Bare snapshots retain historical comparison but have no WC unified or checkout action.
        let bareRoot=root.appendingPathComponent("bare.git");_ = try await repo.run(["clone","--bare","--no-hardlinks",root.path,bareRoot.path])
        let bare=GitRepository(root:bareRoot,executable:git),bareOwner=BlameWindowController(repository:bare,access:nil,path:"history.cpp",revision:"HEAD",options:GitBlameOptions(),preferences:prefs,regexExecutable:helper)
        defer {bareOwner.close()}
        try await wait {!bareOwner.model.busy && !bareOwner.model.syntaxWorking && bareOwner.model.historyEntries.count==3}
        bareOwner.window?.contentView?.layoutSubtreeIfNeeded()
        guard let bareTable=descendants(bareOwner.window!.contentView!).compactMap({$0 as? BlameHistoryNativeTable}).first,let bareCoordinator=bareTable.delegate as? BlameHistoryTable.Coordinator,let bareMenu=bareTable.menu else {throw Failure(description:"No bare history table")}
        bareTable.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        let target=bareOwner.model.historyTarget([bareOwner.model.historyEntries[1]])!;var ready=false
        bareOwner.model.prepareHistoryParents(target){_ in ready=true};try await wait {ready && BlameWindowModel.activeHistoryOperations==0};bareCoordinator.menuNeedsUpdate(bareMenu)
        try require(!bareOwner.model.historyHasWorkingTree && bareMenu.items.contains{$0.title=="Compare with previous revision"} && !bareMenu.items.contains{$0.title=="Switch/Checkout to this…" || $0.title=="Show changes as unified diff"},"Bare source action gating differs")
        bareOwner.close();try await wait {BlameWindowModel.activeHistoryOperations==0}
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"History actions changed HEAD")
        try require(try Data(contentsOf:file)==bytes && Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"History actions changed input/index")
        print("PASS: Blame source consumer mask, WC/HEAD menu gates, parent/default ordering, double-click preference, captured one-shot callbacks and retirement")
    }
}
