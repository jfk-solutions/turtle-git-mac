import AppKit
import TurtleGitCore

@main struct BlameMenuVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(_ condition:@escaping ()->Bool) async throws {
        for _ in 0..<1000 { if condition() { return };try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Blame menu did not settle")
    }
    @MainActor static func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch {
        for _ in 0..<500 { if BlameWindowModel.activeHistoryOperations==0 { break };try? await Task.sleep(nanoseconds:10_000_000) }
        fputs("Blame menus failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Menus QA"),("user.email","menus@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
        let text="int value = 42;\n// needle 雪\n",file=root.appendingPathComponent("menus.cpp")
        try Data(text.utf8).write(to:file);try await repo.stage(["menus.cpp"]);_ = try await repo.commit(message:"Menu baseline")
        try Data(text.replacingOccurrences(of:"42",with:"43").utf8).write(to:file);try await repo.stage(["menus.cpp"]);_ = try await repo.commit(message:"Second revision")
        try Data(text.utf8).write(to:file);try Data("unrelated diff must be excluded\n".utf8).write(to:root.appendingPathComponent("unrelated.txt"));try await repo.stage(["menus.cpp","unrelated.txt"]);_ = try await repo.commit(message:"Restore display")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let name="TurtleGit.BlameMenus.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:name)!
        defer { prefs.removePersistentDomain(forName:name) }
        try Data("Mapped Menus <mapped@example.invalid> Menus QA <menus@example.invalid>\n".utf8).write(to:root.appendingPathComponent(".mailmap"))
        let globals=GitBlamePreferences.load(),findGlobals=GitBlameFindPreferences.load()
        let owner=BlameWindowController(repository:repo,access:nil,path:"menus.cpp",revision:"HEAD",options:GitBlameOptions(),preferences:prefs)
        defer { owner.close() }
        let window=owner.window!,model=owner.model
        window.contentView?.layoutSubtreeIfNeeded()
        func source()->NSTextView? { descendants(window.contentView!).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel()=="Blame source text" } }
        try await wait { !model.busy && !model.syntaxWorking && source()?.string==text }
        func historyTable()->BlameHistoryNativeTable? { descendants(window.contentView!).compactMap { $0 as? BlameHistoryNativeTable }.first }
        try await wait { historyTable()?.numberOfRows==3 }
        let history=historyTable()!,historyCoordinator=history.delegate as! BlameHistoryTable.Coordinator
        try require(history.tableColumns.map { $0.identifier.rawValue }==BlameHistoryColumns.names,"Source Blame column inventory")
        try require(historyCoordinator.text("id",0)=="3" && historyCoordinator.text("id",2)=="1","Blame Log ID numbering")
        let header=history.headerView as! BlameHistoryColumnHeader,columns=header.buildMenu()!,email=columns.items.first { $0.title=="Email" }!
        _ = NSApp.sendAction(email.action!,to:email.target,from:email)
        try await wait { history.tableColumns.first { $0.identifier.rawValue=="email" }?.isHidden==false }
        history.moveColumn(6,toColumn:1);history.tableColumns[1].width=217;historyCoordinator.saveLayout()
        try require(model.historyColumns.order[1]=="email" && model.historyColumns.widths["email"]==217,"History width/order persistence")
        try require(BlameHistoryColumns.load(prefs)==model.historyColumns,"History layout private restoration")
        var routed:[String]=[],historyCopied=""
        model.onHistoryExport={ routed.append("export:"+$0) };model.onHistoryReference={ routed.append(($0 ? "tag:" : "branch:")+$1) }
        model.onHistorySwitch={ routed.append("switch:"+$0) };model.onHistoryBrowse={ routed.append("browse:"+$0) };model.onContainingReferences={ routed.append("refs:"+$0) }
        model.writeClipboard={ historyCopied=$0 }
        history.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let historyMenu=history.menu!;historyCoordinator.menuNeedsUpdate(historyMenu)
        let pinned=model.selectedHistoryEntry!.hash,export=historyMenu.items.first { $0.title=="Export this version…" }!
        history.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        for title in ["Export this version…","Create branch at this version…","Create tag at this version…","Switch/Checkout to this…","Browse repository","Show branches this commit is on"] {
            let item=historyMenu.items.first { $0.title==title }!;try require(item.image != nil && item.isEnabled,"Missing enabled source revision command")
            _ = NSApp.sendAction(item.action!,to:item.target,from:item)
        }
        try require(routed==["export:","branch:","tag:","switch:","browse:","refs:"].map { $0+pinned },"Retained history menu followed new selection")
        history.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let parentTarget=model.historyTarget([model.historyEntries[0]])!
        var ready=false,previousRoute:(String,String,Int)?,comparison:RevisionComparisonSnapshot?
        model.onPrevious={ path,hash,line,_ in previousRoute=(path,hash,line) };model.onChanges={ comparison=$0 }
        model.prepareHistoryParents(parentTarget) { _ in ready=true };try await wait { ready && BlameWindowModel.activeHistoryOperations==0 }
        historyCoordinator.menuNeedsUpdate(historyMenu)
        let previous=historyMenu.items.first { $0.title=="Blame previous revision" }!,compare=historyMenu.items.first { $0.title=="Compare with previous revision" }!,unified=historyMenu.items.first { $0.title=="Show changes as unified diff" }!
        history.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        _ = NSApp.sendAction(previous.action!,to:previous.target,from:previous);_ = NSApp.sendAction(compare.action!,to:compare.target,from:compare)
        try require(previousRoute?.0=="menus.cpp" && previousRoute?.1==model.historyEntries[1].hash && previousRoute?.2==1,"Previous Blame lost captured parent")
        let compared=try await repo.comparisonFile(comparison!,path:"menus.cpp")
        try require(compared.base.text?.contains("43")==true && compared.destination.text?.contains("42")==true,"Parent comparison changed pinned file sides")
        _ = NSApp.sendAction(unified.action!,to:unified.target,from:unified)
        try await wait { owner.historyUnifiedWindows.count==1 && BlameWindowModel.activeHistoryOperations==0 }
        let diff=owner.historyUnifiedWindows.values.first!,patch=String(decoding:diff.model.exportDocument.bytes,as:UTF8.self)
        try require(diff.model.readOnly && patch.contains("menus.cpp") && !patch.contains("unrelated.txt"),"Unified parent patch included unrelated file or was editable")
        diff.model.busy=true
        var requestedOpen=false;let oldChoose=owner.chooseFile;owner.chooseFile={ _,_,_ in requestedOpen=true };owner.openDocument()
        try require(!owner.windowShouldClose(window) && !requestedOpen,"Blocking unified child allowed owner Close/Open")
        owner.chooseFile=oldChoose;diff.model.busy=false
        diff.close();try await wait { owner.historyUnifiedWindows.isEmpty }
        history.selectRowIndexes(IndexSet([0,1,2]),byExtendingSelection:false);historyCoordinator.menuNeedsUpdate(historyMenu)
        let hashes=historyMenu.items.first { $0.title=="Copy SHA-1 to clipboard" }!;_ = NSApp.sendAction(hashes.action!,to:hashes.target,from:hashes)
        try require(historyCopied==model.historyEntries.map(\.hash).joined(separator:"\n"),"Multi-revision hash clipboard")
        let clipboard=historyMenu.items.first { $0.title=="Copy to clipboard" }!.submenu!,subjects=clipboard.items.first { $0.title=="Subjects" }!
        _ = NSApp.sendAction(subjects.action!,to:subjects.target,from:subjects)
        try require(historyCopied==LogEntry.historyClipboard(model.historyEntries,subjectsOnly:true),"Multi-revision subject clipboard")
        let details=clipboard.items.first { $0.title=="Full log messages without changed paths" }!;_ = NSApp.sendAction(details.action!,to:details.target,from:details)
        try await wait { !model.copyingLog && BlameWindowModel.activeHistoryOperations==0 }
        try require(historyCopied.components(separatedBy:"Revision: ").count==4,"Multi-revision complete clipboard")
        model.confirmHistoryReset={ false };let savedColumns=model.historyColumns;model.resetHistoryColumns();try await wait { !model.resettingHistoryColumns }
        try require(model.historyColumns==savedColumns,"No reset changed layout")
        model.confirmHistoryReset={ true };model.resetHistoryColumns();try await wait { !model.resettingHistoryColumns }
        try require(model.historyColumns==BlameHistoryColumns(),"Yes reset did not restore layout")
        model.reload();try await wait { !model.busy && !model.syntaxWorking }
        let beforeRoutes=routed;_ = NSApp.sendAction(export.action!,to:export.target,from:export)
        try require(routed==beforeRoutes,"Old menu survived Blame reload")
        previousRoute=nil;_ = NSApp.sendAction(previous.action!,to:previous.target,from:previous);try require(previousRoute==nil,"Old parent menu survived reload")
        model.selectedLogHashes=[]
        let layout = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/GraphLayout/graph-layout")
        let graph = RevisionGraphWindowModel(repository: repo, access: nil, preferences: prefs, layoutExecutable: layout)
        defer { graph.invalidate() }
        var copied = ""; model.writeClipboard = { copied = $0 }
        for enabled in [false, true] {
            prefs.set(enabled, forKey: "UseMailmap")
            let author = enabled ? "Mapped Menus" : "Menus QA"
            model.reload(); graph.load()
            try await wait { !model.busy && !graph.busy }
            try require(model.lines.first?.author == author, "Annotation identity disagrees with history mailmap policy")
            try require(model.historyEntries.first?.author == author, "Blame history ignored private mailmap policy")
            try require(graph.nodes.first?.author == author, "Graph ignored private mailmap policy")
            model.copyLogMessage(model.historyEntries.first!.hash)
            try await wait { !model.copyingLog }
            try require(copied.contains("Author: " + author + " <"), "Copied Blame Log ignored mailmap policy")
        }
        var focus:NSWindow?=window
        let context=BlameMenuContext(keyWindow:{ focus });context.refresh()
        try require(context.focused && context.available && !context.allowed(.nextChange),"Initial focus/next-change menu gates")
        let selected=(text as NSString).range(of:"雪");source()!.setSelectedRange(selected)
        context.perform(.toolbar);context.perform(.log);context.perform(.properties);context.perform(.statusBar)
        try await wait { !model.showToolbar && !model.showLog && !model.showProperties && !model.showStatusBar }
        try require(context.available && source()?.string==text && source()?.selectedRange()==selected,"Hidden panes disabled menus or lost source selection")
        try require(prefs.object(forKey:"Blame.ShowToolbar") as? Bool==false && prefs.object(forKey:"Blame.ShowLog") as? Bool==false,"Pane visibility not persisted")
        context.perform(.toolbar);context.perform(.log);context.perform(.properties);context.perform(.statusBar)
        try await wait { model.showToolbar && model.showLog && model.showProperties && model.showStatusBar }
        context.perform(.dark);context.refresh()
        let dark=context.checked(.dark)
        try require(model.darkOverride==dark && window.appearance != nil,"Dark mode did not apply/persist window override")
        context.perform(.find);try await wait { owner.findWindow != nil }
        let panel=owner.findWindow!
        try require(panel.window?.appearance?.name==window.appearance?.name,"Find panel did not follow owner appearance")
        focus=panel.window;context.refresh();try require(context.owner===owner && context.available,"Find focus lost active owner")
        panel.window?.performClose(nil);focus=window;context.refresh()
        context.followSystemAppearance();try require(model.darkOverride==nil && window.appearance==nil && prefs.object(forKey:"Blame.DarkMode")==nil,"Follow-system reset did not clear override")
        context.perform(.colorAge);try require(!model.colorAge && !context.checked(.colorAge) && prefs.object(forKey:"Blame.ColorAge") as? Bool==false,"Color Age check/persistence")
        context.perform(.colorAge);context.perform(.wrap);context.perform(.author)
        try await wait { model.wrapLongLines && !model.marginFields.contains(.author) }
        context.perform(.wrap);context.perform(.author)
        // Exercise actual menu routing through both supplemental codecs and a
        // platform legacy codec. ASCII remains byte-identical in all three.
        for page: UInt32 in [720, 858, 28606] {
            let codec = GitBlameEncoding.available.first { $0.windowsCodePage == page }!
            context.setEncoding(codec)
            try await wait { !model.busy && model.snapshot?.encoding.id == codec.id }
            context.refresh()
            try require(context.encoding?.id == codec.id, "Encoding check state did not follow selected codec")
        }
        context.setEncoding(nil); try await wait { !model.busy }; context.refresh()
        try require(source()?.string == text, "Automatic encoding did not restore Unicode text")
        model.openingDocument=true;context.refresh();let before=model.showToolbar
        context.perform(.toolbar);context.setEncoding(.utf16LE);try require(model.sourceEncoding == nil && !context.available && model.showToolbar==before,"Busy menu mutated a blocked owner")
        model.openingDocument=false
        let other=NSWindow(contentRect:NSRect(x:0,y:0,width:50,height:50),styleMask:.titled,backing:.buffered,defer:false);other.isReleasedWhenClosed=false
        defer { other.close() }
        focus=other;context.refresh();context.perform(.properties)
        try require(!context.focused && model.showProperties,"Unrelated focus changed a background Blame")
        focus=window;context.refresh();context.setDetection(.modifiedFiles)
        try await wait { !model.busy && model.detectionMode == .modifiedFiles }
        context.refresh();try require(!context.allowed(.completeLog) && !context.allowed(.followRenames),"Detection mode did not update source Log gates")
        context.setDetection(.disabled);try await wait { !model.busy };context.refresh()
        context.perform(.ignoreWhitespace);try await wait { !model.busy && model.ignoreWhitespace }
        try require(GitBlamePreferences.load(from:prefs).ignoreWhitespace && GitBlamePreferences.load()==globals,"Option menu wrote outside injected preferences")
        // A second owner receives its own routing and restores persisted pane choices.
        model.showToolbar=false;model.showLog=false;model.showProperties=false;model.showStatusBar=false
        let reopened=BlameWindowController(repository:repo,access:nil,path:"menus.cpp",revision:"HEAD",options:GitBlameOptions(),preferences:prefs)
        defer { reopened.close() }
        try await wait { !reopened.model.busy && !reopened.model.syntaxWorking }
        try require(!reopened.model.showToolbar && !reopened.model.showLog && !reopened.model.showProperties && !reopened.model.showStatusBar,"New viewer did not restore pane layout")
        focus=reopened.window;context.refresh();context.perform(.toolbar)
        try require(reopened.model.showToolbar && !model.showToolbar,"Menus targeted a background viewer")
        reopened.close();context.refresh();context.setEncoding(.utf16BE);try require(reopened.model.sourceEncoding == nil, "Retired owner accepted encoding");try require(!context.focused && !context.available,"Retired owner stayed in menu context")
        try require(GitBlameFindPreferences.load()==findGlobals,"Find menu wrote global query preferences")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),afterFile=try Data(contentsOf:file)
        try require(afterHead==head && afterIndex==index && afterFile==Data(text.utf8),"Menu operations changed repository state")
        print("Blame menus: current/Find/unrelated/second/retired window routing, busy/detection gates, persistent pane restoration, source selection retention, window/panel appearance/reset, private option defaults and exact HEAD/index/file preservation passed. Owned windows closed; full physical menu/VoiceOver acceptance remains open.")
    }
}
