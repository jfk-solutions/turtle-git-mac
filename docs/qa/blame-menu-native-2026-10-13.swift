import AppKit
import TurtleGitCore

@main struct BlameMenuVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(line:Int = #line,_ condition:@escaping ()->Bool) async throws {
        for _ in 0..<1000 { if condition() { return };try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Blame menu did not settle at \(line)")
    }
    @MainActor static func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch {
        for _ in 0..<500 { if BlameWindowModel.activeHistoryOperations==0 { break };try? await Task.sleep(nanoseconds:10_000_000) }
        fputs("Blame menus failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let regexExecutable=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Menus QA"),("user.email","menus@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
        let text="int value = 42;\n// needle 雪\n",file=root.appendingPathComponent("menus.cpp")
        try Data(text.utf8).write(to:file);try await repo.stage(["menus.cpp"]);_ = try await repo.commit(message:"Menu baseline")
        try Data(text.replacingOccurrences(of:"42",with:"43").utf8).write(to:file);try await repo.stage(["menus.cpp"]);_ = try await repo.commit(message:"Second revision")
        try Data(text.utf8).write(to:file);try Data("unrelated diff must be excluded\n".utf8).write(to:root.appendingPathComponent("unrelated.txt"));try await repo.stage(["menus.cpp","unrelated.txt"]);_ = try await repo.commit(message:"Restore display #10 #2 #10")
        _ = try await repo.run(["config","bugtraq.url","https://example.invalid/issues/%BUGID%"]);_ = try await repo.run(["config","bugtraq.logregex","#([0-9]+)"])
        let svnMarker=root.appendingPathComponent(".git/svn/.metadata");try FileManager.default.createDirectory(at:svnMarker.deletingLastPathComponent(),withIntermediateDirectories:true);try Data().write(to:svnMarker)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let name="TurtleGit.BlameMenus.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:name)!
        defer { prefs.removePersistentDomain(forName:name) }
        try Data("Mapped Menus <mapped@example.invalid> Menus QA <menus@example.invalid>\n".utf8).write(to:root.appendingPathComponent(".mailmap"))
        let globals=GitBlamePreferences.load(),findGlobals=GitBlameFindPreferences.load()
        let owner=BlameWindowController(repository:repo,access:nil,path:"menus.cpp",revision:"HEAD",options:GitBlameOptions(),preferences:prefs,regexExecutable:regexExecutable)
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
        try require(model.issueProperties.showsBugIDColumn && model.hasGitSVN && historyCoordinator.text("bugs",0)=="2 10","Project metadata not applied to Blame rows")
        try require(history.tableColumns.first { $0.identifier.rawValue=="bugs" }?.isHidden==false && history.tableColumns.first { $0.identifier.rawValue=="svn" }?.isHidden==false,"Conditional columns unavailable")
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
        var ready=false,previousRoute:(String,String,Int)?,comparison:RevisionComparisonSnapshot?,comparisonAlternate:Bool?
        model.onPrevious={ path,hash,line,_ in previousRoute=(path,hash,line) };model.onChanges={ comparison=$0;comparisonAlternate=ComparisonToolInvocation.capture }
        model.prepareHistoryParents(parentTarget) { _ in ready=true };try await wait { ready && BlameWindowModel.activeHistoryOperations==0 }
        historyCoordinator.menuNeedsUpdate(historyMenu)
        let previous=historyMenu.items.first { $0.title=="Blame previous revision" }!,compare=historyMenu.items.first { $0.title=="Compare with previous revision" }!,unified=historyMenu.items.first { $0.title=="Show changes as unified diff" }!
        history.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        _ = NSApp.sendAction(previous.action!,to:previous.target,from:previous);_ = NSApp.sendAction(compare.action!,to:compare.target,from:compare)
        try require(previousRoute?.0=="menus.cpp" && previousRoute?.1==model.historyEntries[1].hash && previousRoute?.2==1,"Previous Blame lost captured parent")
        let capturedParents=try await repo.blameHistoryParentComparisons(model.snapshot!,revision:parentTarget.entries[0].hash)
        model.performHistoryParent(parentTarget,choices:capturedParents,action:.compare,alternate:true)
        try require(comparisonAlternate==true && ComparisonToolInvocation.alternate==nil,"Blame compare lost or leaked Shift choice")
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
        _ = try await repo.run(["config","--unset","bugtraq.url"]);_ = try await repo.run(["config","--unset","bugtraq.logregex"]);try FileManager.default.removeItem(at:svnMarker)
        model.reload();try await wait { !model.busy && !model.syntaxWorking && !model.hasGitSVN }
        try require(!model.issueProperties.showsBugIDColumn && history.tableColumns.first { $0.identifier.rawValue=="bugs" }?.isHidden==true && history.tableColumns.first { $0.identifier.rawValue=="svn" }?.isHidden==true,"Stale conditional columns survived reload")
        _ = try await repo.run(["config","bugtraq.url","https://example.invalid/issues/%BUGID%"]);_ = try await repo.run(["config","bugtraq.logregex","#([0-9]+)"]);try Data().write(to:svnMarker)
        model.reload();try await wait { !model.busy && !model.syntaxWorking }
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
        try await paneWorkflows(owner:owner,prefs:prefs,regexExecutable:regexExecutable)
        // A second owner receives its own routing and restores persisted pane choices.
        model.showToolbar=false;model.showLog=false;model.showProperties=false;model.showStatusBar=false
        let reopened=BlameWindowController(repository:repo,access:nil,path:"menus.cpp",revision:"HEAD",options:GitBlameOptions(),preferences:prefs,regexExecutable:regexExecutable)
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
    @MainActor static func paneWorkflows(owner:BlameWindowController,prefs:UserDefaults,regexExecutable:URL) async throws {
        NSApp.setActivationPolicy(.accessory);NSApp.activate(ignoringOtherApps:true)
        let model=owner.model,annotations=model.lines.map{($0.hash,$0.originalLine)},selection=model.selection
        let root=owner.window!;owner.showWindow(nil);root.makeKeyAndOrderFront(nil)
        model.restorePaneLayout()
        func sideSplit(_ window:NSWindow)->NSSplitView? {
            let container=descendants(window.contentView!).compactMap{$0 as? NSSplitView}.first{String(describing:type(of:$0)).contains("BlameDockRootSplit")}
            return container?.arrangedSubviews.compactMap{$0 as? NSSplitView}.first { split in descendants(split).compactMap{$0 as? NSTextView}.contains{$0.accessibilityLabel()=="Blame source text"} }
        }
        try await wait { root.contentView?.layoutSubtreeIfNeeded();return sideSplit(root)?.arrangedSubviews.count==2 }
        let sides=sideSplit(root)!;sides.setPosition(sides.bounds.width-316-sides.dividerThickness,ofDividerAt:0)
        try await wait { abs(prefs.double(forKey:"Blame.Pane.Dock.right.Extent")-316)<1 }
        // Native tab containers preserve pane/model identity and the selected tab.
        model.tabPane(.log,joined:true)
        func paneTabs()->NSTabView? { descendants(root.contentView!).compactMap{$0 as? NSTabView}.first{$0.tabViewItems.compactMap{$0.identifier as? String} == ["log","properties"]} }
        try await wait { root.contentView?.layoutSubtreeIfNeeded();return paneTabs() != nil }
        try require(model.panesAreTabbed && model.paneLayout.log == .right && paneTabs()?.selectedTabViewItem?.identifier as? String == "log","Tab group placement/initial selection failed")
        paneTabs()?.selectTabViewItem(withIdentifier:"properties")
        try await wait {model.paneLayout.activeTab == .properties}
        try require(BlamePaneLayout.load(prefs)==model.paneLayout,"Native tab selection did not persist")
        try await wait { descendants(root.contentView!).compactMap{$0 as? NSSegmentedControl}.contains{$0.segmentCount==2 && $0.label(forSegment:0)=="Git Revision List" && $0.selectedSegment==1 && $0.frame.width>200} }
        let selector=descendants(root.contentView!).compactMap{$0 as? NSSegmentedControl}.first{$0.segmentCount==2 && $0.label(forSegment:0)=="Git Revision List"}!
        selector.selectedSegment=0;try require(selector.sendAction(selector.action!,to:selector.target),"Native tab selector action missing")
        try await wait {model.paneLayout.activeTab == .log && paneTabs()?.selectedTabViewItem?.identifier as? String == "log"}
        selector.selectedSegment=1;_=selector.sendAction(selector.action!,to:selector.target)
        try await wait {model.paneLayout.activeTab == .properties && paneTabs()?.selectedTabViewItem?.identifier as? String == "properties"}

        model.busy=true;paneTabs()?.selectTabViewItem(withIdentifier:"log")
        try require(paneTabs()?.selectedTabViewItem?.identifier as? String == "properties" && model.paneLayout.activeTab == .properties,"Busy native tab selection changed layout");model.busy=false
        model.setPaneAutoHidden(.log,true)
        try require(model.paneAutoHidden(.log) && model.paneAutoHidden(.properties),"Group auto-hide split its state")
        model.setPaneAutoHidden(.properties,false)
        try await wait { root.contentView?.layoutSubtreeIfNeeded();return paneTabs()?.selectedTabViewItem?.identifier as? String == "properties" }
        model.setPaneVisible(.properties,false)
        try require(!model.finishPaneDrag(model.paneDragData(.properties),at:.zero,outsideWorkspace:true,cancelled:false,operation:[]),"Hidden pane accepted outside drag")
        try await wait { root.contentView?.layoutSubtreeIfNeeded();return paneTabs()==nil }
        model.setPaneVisible(.properties,true)
        try await wait { root.contentView?.layoutSubtreeIfNeeded();return paneTabs() != nil }
        // Older saved layouts contain neither new optional field.
        let profile=prefs.data(forKey:"Blame.PaneLayout")!
        var oldProfile=try JSONSerialization.jsonObject(with:profile) as! [String:Any];oldProfile.removeValue(forKey:"tabbed");oldProfile.removeValue(forKey:"activeTab")
        prefs.set(try JSONSerialization.data(withJSONObject:oldProfile),forKey:"Blame.PaneLayout")
        try require(BlamePaneLayout.load(prefs).log == .right && BlamePaneLayout.load(prefs).tabbed==nil,"Legacy layout did not migrate")
        prefs.set(profile,forKey:"Blame.PaneLayout")
        model.setPanePlacement(.log,.bottom)
        try require(!model.panesAreTabbed && model.paneLayout.properties == .right,"Moving a tab did not separate its group")
        try await wait { root.contentView?.layoutSubtreeIfNeeded();return descendants(root.contentView!).contains{$0 is BlamePaneCaptionButton} }
        let caption=descendants(root.contentView!).compactMap{$0 as? BlamePaneCaptionButton}.first{$0.pane == .log}!
        try require(caption.model === model && caption.accessibilityPerformPress(),"Native pane caption accessibility action unavailable")
        try require(model.paneLayout.log == .floating && owner.floatingPaneWindow(.log) != nil,"Native caption failed to float")
        try await wait { owner.floatingPaneWindow(.log)?.titlebarAccessoryViewControllers.forEach{$0.view.layoutSubtreeIfNeeded()};return owner.floatingPaneWindow(.log)?.titlebarAccessoryViewControllers.flatMap{descendants($0.view)}.contains{$0 is BlamePaneCaptionButton} == true }
        let accessory=owner.floatingPaneWindow(.log)!.titlebarAccessoryViewControllers.flatMap{descendants($0.view)}.compactMap{$0 as? BlamePaneCaptionButton}.first!
        try require(accessory.accessibilityPerformPress() && model.paneLayout.log == .bottom,"Floating titlebar caption did not dock")
        let payload=model.paneDragData(.log),point=NSPoint(x:root.frame.minX-40,y:root.frame.maxY-40),layout=model.paneLayout
        try require(!model.finishPaneDrag(payload,at:point,outsideWorkspace:true,cancelled:true,operation:[]) && !model.finishPaneDrag(payload,at:point,outsideWorkspace:false,cancelled:false,operation:[]) && !model.finishPaneDrag(payload,at:point,outsideWorkspace:true,cancelled:false,operation:.move) && model.paneLayout==layout,"Cancelled/inside/handled drag floated pane")
        model.busy=true;try require(!model.finishPaneDrag(payload,at:point,outsideWorkspace:true,cancelled:false,operation:[]),"Busy pane accepted outside drag");model.busy=false
        try require(model.finishPaneDrag(payload,at:point,outsideWorkspace:true,cancelled:false,operation:[]),"Outside drag did not float")
        let dragged=owner.floatingPaneWindow(.log)!,screen=dragged.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        try require(screen.contains(dragged.frame) && prefs.string(forKey:"Blame.Pane.log.FloatingFrame") != nil,"Drag floating frame was not clamped/saved")
        model.setPanePlacement(.log,.bottom)
        for edge in [BlamePanePlacement.left,.top,.right,.bottom] {
            model.setPanePlacement(.log,edge);root.contentView?.layoutSubtreeIfNeeded()
            try require(model.paneLayout.placement(.log)==edge && BlamePaneLayout.load(prefs)==model.paneLayout,"Dock edge not persisted")
        }
        model.setPanePlacement(.log,.floating);model.setPanePlacement(.properties,.floating)
        try await wait { owner.floatingPaneWindow(.log)?.isVisible == true && owner.floatingPaneWindow(.properties)?.isVisible == true }
        let log=owner.floatingPaneWindow(.log)!,properties=owner.floatingPaneWindow(.properties)!
        try await wait { descendants(log.contentView!).compactMap{$0 as? BlameHistoryNativeTable}.first?.numberOfRows == model.historyEntries.count }
        let context=BlameMenuContext(keyWindow:{log});context.refresh()
        try require(context.owner === owner && context.available,"Floating pane lost focused owner")
        owner.setDarkMode(true);try require(log.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua && properties.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua,"Floating appearance did not follow owner")
        owner.followSystemAppearance()
        log.setFrameOrigin(NSPoint(x:log.frame.minX+18,y:log.frame.minY+12))
        try await wait { prefs.string(forKey:"Blame.Pane.log.FloatingFrame") != nil }
        properties.performClose(nil)
        try require(!model.showProperties && !model.retired && model.showLog && owner.floatingPaneWindow(.properties)==nil,"Closing Properties retired owner or Log")
        model.setPaneVisible(.properties,true)
        // Same-window drag uses the actual item provider. A foreign document cannot apply it.
        let provider=model.paneDragProvider(.log)
        try require(model.receivePaneDrop([provider],placement:.top),"Own pane drop refused")
        try await wait { model.paneLayout.log == .top && owner.floatingPaneWindow(.log)==nil }
        model.setPanePlacement(.log,.floating)
        let restored=owner.floatingPaneWindow(.log)!
        try require(abs(restored.frame.minX-log.frame.minX)<1 && abs(restored.frame.minY-log.frame.minY)<1,"Floating frame did not restore")
        let second=BlameWindowController(repository:model.repository,access:nil,path:model.path,revision:"HEAD",preferences:prefs,regexExecutable:regexExecutable)
        defer { second.close() }
        second.showWindow(nil);second.window?.makeKeyAndOrderFront(nil)
        try await wait { !second.model.busy && second.floatingPaneWindow(.log) != nil }
        second.model.setPanePlacement(.properties,.right)
        try await wait { second.window?.contentView?.layoutSubtreeIfNeeded();return sideSplit(second.window!)?.arrangedSubviews.last.map{abs($0.frame.width-316)<1} == true }
        second.model.setPanePlacement(.properties,.floating)
        let foreign=second.model.paneDragProvider(.log)
        let foreignData:Data=try await withCheckedThrowingContinuation { reply in foreign.loadDataRepresentation(forTypeIdentifier:BlamePane.dragType) { bytes,error in if let bytes { reply.resume(returning:bytes) } else { reply.resume(throwing:error ?? Failure(description:"Missing pane payload")) } } }
        try require(!model.applyPaneDropData(foreignData,placement:.left) && !model.finishPaneDrag(foreignData,at:point,outsideWorkspace:true,cancelled:false,operation:[]) && model.paneLayout.log == .floating,"Foreign pane payload changed layout")
        // File Open replaces the model and retires floating views before rebinding.
        let old=second.model,oldLog=second.floatingPaneWindow(.log)!
        second.chooseFile={ _,_,reply in reply(model.repository.root.appendingPathComponent("unrelated.txt")) }
        second.openDocument()
        try await wait { second.model !== old && !second.model.openingDocument && !second.model.busy && second.floatingPaneWindow(.log) != nil }
        let rebound=second.floatingPaneWindow(.log)!
        try require(old.retired && !oldLog.isVisible && oldLog.parent==nil && rebound !== oldLog && second.model.path=="unrelated.txt","Document replacement retained old floating content")
        try await wait { descendants(rebound.contentView!).compactMap{$0 as? BlameHistoryNativeTable}.contains { ($0.delegate as? BlameHistoryTable.Coordinator)?.model === second.model } }
        let visibleBeforeClose=BlamePane.allCases.compactMap{second.floatingPaneWindow($0)}
        second.close()
        try require(visibleBeforeClose.allSatisfy{!$0.isVisible && $0.parent==nil} && prefs.bool(forKey:"Blame.ShowLog") && prefs.bool(forKey:"Blame.ShowProperties"),"Owner close leaked panels or discarded saved visibility")
        try require(!old.applyPaneDropData(foreignData,placement:.bottom) && !old.finishPaneDrag(foreignData,at:point,outsideWorkspace:true,cancelled:false,operation:[]),"Retired document applied pane drop/float")
        model.setPanePlacement(.properties,.right);model.setPanePlacement(.log,.bottom);model.setPaneAutoHidden(.log,true)
        root.makeKeyAndOrderFront(nil)
        try require(model.paneAutoHidden(.log) && model.showLog && model.canFind,"Auto-hide state did not install: \(model.paneLayout), retired=\(model.retired), busy=\(model.busy)")
        try await wait { root.contentView?.layoutSubtreeIfNeeded();return descendants(root.contentView!).compactMap{$0 as? NSButton}.contains{$0.accessibilityLabel()=="Show auto-hidden Log"} }
        let tab=descendants(root.contentView!).compactMap{$0 as? NSButton}.first{$0.accessibilityLabel()=="Show auto-hidden Log"}!
        try require(tab.isEnabled && tab.target != nil && tab.action != nil,"Auto-hide native tab lost enabled target/action")
        try require(tab.accessibilityPerformPress(),"Auto-hide tab did not execute its native accessibility press action")
        try await wait { NSApp.windows.filter{$0.isVisible && $0 !== root}.contains { window in window.contentView.map { descendants($0).compactMap{$0 as? BlameHistoryNativeTable}.contains{($0.delegate as? BlameHistoryTable.Coordinator)?.model === model} } == true } }
        model.setPaneAutoHidden(.log,false)
        try await wait { !NSApp.windows.filter{$0.isVisible && $0 !== root}.contains { window in window.contentView.map { descendants($0).compactMap{$0 as? BlameHistoryNativeTable}.contains{($0.delegate as? BlameHistoryTable.Coordinator)?.model === model} } == true } }
        model.restorePaneLayout();root.contentView?.layoutSubtreeIfNeeded()
        try require(model.paneLayout==BlamePaneLayout() && model.selection==selection && model.lines.count==annotations.count && zip(model.lines,annotations).allSatisfy{$0.0.hash==$0.1.0 && $0.0.originalLine==$0.1.1},"Pane docking changed annotations or selected line")
        try require(owner.floatingPaneWindow(.log)==nil && owner.floatingPaneWindow(.properties)==nil,"Restore layout retained floating panes")
        try await wait { root.contentView?.layoutSubtreeIfNeeded();return descendants(root.contentView!).compactMap{$0 as? BlameHistoryNativeTable}.contains{$0.frame.width>root.contentView!.bounds.width*0.8} }
        try require(sideSplit(root)?.arrangedSubviews.last.map{abs($0.frame.width-280)<1} == true,"Restore layout did not reset native divider extent")
        if let directory=ProcessInfo.processInfo.environment["TURTLEGIT_BLAME_PANE_CAPTURES"],model.repository.executable.path=="/usr/bin/git" {
            let output=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            let selected=model.selectedLogHashes
            defer { model.selectedLogHashes=selected }
            if let entry=model.historyEntries.first { model.selectedLogHashes=[entry.hash] }
            NSApp.setActivationPolicy(.accessory)
            for (dark,name) in [(false,"light"),(true,"dark")] {
                model.restorePaneLayout();owner.setDarkMode(dark);root.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                try await capturePane(root,to:output.appendingPathComponent("blame-panes-"+name+".png"))
                model.setPanePlacement(.properties,.bottom);model.tabPane(.log,joined:true)
                try await capturePane(root,to:output.appendingPathComponent("blame-tabs-log-"+name+".png"))
                model.selectPaneTab(.properties)
                try await capturePane(root,to:output.appendingPathComponent("blame-tabs-properties-"+name+".png"))
                model.setPanePlacement(.log,.floating);model.setPanePlacement(.properties,.floating)
                try await wait { owner.floatingPaneWindow(.log)?.isVisible==true && owner.floatingPaneWindow(.properties)?.isVisible==true }
                for pane in BlamePane.allCases { try await capturePane(owner.floatingPaneWindow(pane)!,to:output.appendingPathComponent("blame-floating-"+pane.rawValue+"-"+name+".png")) }
            }
            model.restorePaneLayout();owner.followSystemAppearance()
        }
        print("Blame panes: four dock edges, owned float/close, focused menu routing, appearance/frame restoration, own/foreign/retired drag payloads, saved layout, File Open rebinding, actual auto-hide tab/popover and annotation selection preservation passed.")
    }

    @MainActor static func capturePane(_ window:NSWindow,to output:URL) async throws {
        window.contentView?.layoutSubtreeIfNeeded();window.orderFront(nil)
        try await Task.sleep(nanoseconds:400_000_000)
        let capture=Process();capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
        capture.arguments=["-x","-o","-l",String(window.windowNumber),output.path]
        try capture.run();capture.waitUntilExit()
        try require(capture.terminationStatus==0,"Owned Blame pane compositor capture failed")
    }

}
