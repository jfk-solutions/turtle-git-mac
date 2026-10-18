// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum RebaseHistoryToolsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2200 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Rebase history tools did not settle at \(line)")
    }
    static func views(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(views)}
    static func click(_ item:NSMenuItem) throws {guard let selector=item.action else {throw Failure(description:"Missing action "+item.title)};_ = NSApp.sendAction(selector,to:item.target,from:item)}
    static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for(key,value) in [("user.name","History Tools QA"),("user.email","tools@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"Base")
        _ = try await repo.run(["commit","--allow-empty","-m","Repeated Needle"]);let repeated=try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["commit","--allow-empty","-m","Other row"]);let other=try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["tag","needle",repeated.hash])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.RebaseHistoryTools.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let owner=RebaseWindowController(repository:repo,access:nil,preferences:prefs),model=owner.model,window=owner.window!
        var export:ExportWindowController?
        var heldFind:CheckedContinuation<[String],Never>?,heldReferences:CheckedContinuation<CommitContainingReferences,Never>?
        var referenceSnapshot:CommitContainingReferences?
        func drained()->Bool { RevisionGraphFindController.activeOperations==0 && CommitContainingReferencesWindowController.activeOperations==0 && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0 && ExportWindowModel.activeReads==0 && ReferenceBrowserWindowModel.activeReads==0 }
        func cleanup() async throws {
            owner.close();export?.close();export=nil
            heldFind?.resume(returning:[]);heldFind=nil
            if let referenceSnapshot {heldReferences?.resume(returning:referenceSnapshot);heldReferences=nil}
            try await wait {drained()}
            try require(!window.isVisible && owner.revisionFind==nil && owner.containingWindows.isEmpty,"Owned history tool windows survived cleanup")
        }
        do {
        window.alphaValue=0;window.orderFront(nil)
        model.load(cherryPick:[other.hash,repeated.hash])
        try await wait {!model.busy && !model.loadingPlan && model.plan != nil && RebaseWindowModel.activePreparationReads==0}
        model.plan=try await repo.addingRebaseCommits(model.plan!,revisions:[repeated.hash])
        var table:RebaseReplayNativeTable?
        try await wait {table=views(window.contentView!).compactMap{$0 as? RebaseReplayNativeTable}.first;return table?.numberOfRows==3 && RebaseWindowModel.activePreparationReads==0}
        let native=table!,coordinator=native.owner!,top=model.entries[0].id,bottom=model.entries[2].id
        try require(top != bottom && model.entries[0].commit.hash==model.entries[2].commit.hash,"Fixture needs repeated occurrences")
        func select(_ ids:Set<String>) async throws {
            model.selection=ids
            try await wait {
                native.window===window && model.revisionMenuAvailable && !model.revisionFiles.busy &&
                RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0 && !model.loadingColumnMetadata && owner.revisionFind?.loadingReferences != true &&
                Set(native.selectedRowIndexes.compactMap {model.entries.indices.contains($0) ? model.entries[$0].id:nil})==ids
            }
        }
        func italic(_ row:Int)->Bool {
            guard let column=native.tableColumns.firstIndex(where:{$0.identifier.rawValue=="Message"}),
                  let cell=native.view(atColumn:column,row:row,makeIfNecessary:true) as? NSTableCellView,
                  let font=cell.textField?.font else {return false}
            return NSFontManager.shared.traits(of:font).contains(.italicFontMask)
        }
        try await select([top])
        let findItem=coordinator.menu(ids:[top],alternate:false).item(withTitle:"Find…")!
        try require(findItem.isEnabled && findItem.image != nil,"Source Find menu missing")
        try click(findItem);let find=owner.revisionFind!,findWindow=find.window!
        try await wait {!find.loadingReferences}
        try require(findWindow.parent===window && findWindow.alphaValue==0 && find.references.contains("refs/tags/needle"),"Owned Find scope/artwork references missing")
        find.searchBox.stringValue="Repeated Needle";find.findNext();try await wait {!find.busy}
        try require(model.revisionFindIndex==2 && model.selection==[bottom] && model.scrollRevisionOccurrence==bottom,"Find collapsed later occurrence to first matching hash")
        find.findNext();try await wait {!find.busy}
        try require(model.revisionFindIndex==0 && model.selection==[top] && find.status.stringValue.contains("beginning"),"Repeated Find did not wrap by occurrence")
        let shift=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:findWindow.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        findWindow.sendEvent(shift);try await wait {!find.busy}
        try require(model.revisionFindIndex==2 && model.selection==[top] && model.scrollRevisionOccurrence==bottom,"Shift Find changed selection or collapsed occurrence")
        try await wait {model.revisionFindHighlightHash==repeated.hash && italic(0) && italic(2)}
        try await wait {native.numberOfRows==3}
        find.searchReference("refs/tags/needle",select:false);try await wait {!find.busy}
        try require(model.revisionFindIndex==0 && model.selection==[top],"Reference navigation lost first displayed occurrence")
        _ = try await repo.run(["tag","-d","needle"])
        find.searchReference("refs/tags/needle");try await wait {findWindow.attachedSheet != nil}
        try require(model.revisionFindBlocked && !model.editable && !owner.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Find failure did not own parent/Quit")
        let sheet=findWindow.attachedSheet!,ok=views(sheet.contentView!).compactMap{$0 as? NSButton}.first{$0.title=="OK"}!
        ok.performClick(nil);try await wait {!find.acknowledgingFailure && findWindow.attachedSheet==nil && !model.revisionFindBlocked}
        try require(findWindow.alphaValue==0,"Find error presentation became visible")
        find.cancelButton.performClick(nil);try await wait {owner.revisionFind==nil}
        try require(find.closed && findWindow.parent==nil && prefs.stringArray(forKey:"History.Find.Search")?.first=="Repeated Needle","Find close/history persistence missing")
        // A normal native selection must move the source Find cursor without
        // first constructing a context menu (which separately sets that cursor).
        try await wait {native.selectedRowIndexes==IndexSet(integer:0) && !model.revisionFiles.busy}
        native.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        try await wait {model.selection==[model.entries[1].id] && model.revisionFindIndex==1 && model.revisionFindHighlightHash==nil && !italic(1) && !italic(2) && RebaseWindowModel.activePreparationReads==0}
        let f=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"f",charactersIgnoringModifiers:"f",isARepeat:false,keyCode:3)!
        native.keyDown(with:f);let reopened=owner.revisionFind!
        try await wait {!reopened.loadingReferences}
        try require(reopened.searchIndex()==1 && reopened.searchBox.stringValue=="Repeated Needle","Command F did not reuse native selection cursor/persisted Find inputs")
        reopened.findNext();try await wait {!reopened.busy}
        try require(model.revisionFindIndex==2 && model.selection==[bottom],"Command F searched from the old cursor instead of the ordinary native selection")
        // Retire the deliberately deleted tag from the real owned metadata
        // before asserting the source's no-tag hash fallback.
        model.refreshColumnMetadata(force:true)
        try await wait {!model.loadingColumnMetadata && RebaseWindowModel.activeColumnReads==0 && !(model.revisionReferenceNames[repeated.hash] ?? []).contains(where:{$0=="refs/tags/needle" || $0=="refs/tags/needle^{}"})}
        // Canonical Export handoff builds the actual existing native Export page.
        model.revisionMenuLog.onExportRevision={hash in export=ExportWindowController(repository:repo,access:nil,revision:hash,preferences:prefs);export?.window?.alphaValue=0}
        try await select([bottom])
        try click(coordinator.menu(ids:[bottom],alternate:false).item(withTitle:"Export this version…")!)
        try await wait {export != nil && export?.model.busy==false}
        try require(export?.model.commitRevision==repeated.hash && export?.model.presentationPreferences === prefs,"Export lost captured hash/preferences")
        export?.close();export=nil
        // The source prefers an actual tag label over the hash for Export.
        // Refresh the production-owned metadata; do not inject decorations into
        // an otherwise undecorated replay commit.
        _ = try await repo.run(["tag","-a","export-needle","-m","Export label",repeated.hash])
        model.refreshColumnMetadata(force:true)
        try await wait {!model.loadingColumnMetadata && RebaseWindowModel.activeColumnReads==0 && (model.revisionReferenceNames[repeated.hash] ?? []).contains(where:{$0=="refs/tags/export-needle" || $0=="refs/tags/export-needle^{}"})}
        try await select([bottom])
        try click(coordinator.menu(ids:[bottom],alternate:false).item(withTitle:"Export this version…")!)
        try await wait {export != nil && export?.model.busy==false}
        try require(export?.model.target == .tag && export?.model.tag=="refs/tags/export-needle" && export?.model.presentationPreferences === prefs,"Export did not preserve the real canonical tag label/preferences")
        export?.close();export=nil
        var ranges:[HistoryRevisionRange]=[]
        model.revisionMenuLog.onShowHistoryRange={ranges.append($0)}
        let pair:Set<String>=[bottom,model.entries[1].id];try await select(pair)
        let expected=model.revisionMenuRanges(pair)
        for number in 0..<3 {
            let items=coordinator.menu(ids:pair,alternate:false).items.filter{$0.title.hasPrefix("Show log of ")}
            try require(items.count==3 && items[number].isEnabled,"Range Log family missing")
            try click(items[number]);try require(ranges.last==expected[number],"Range callback lost canonical direction/kind")
            try click(items[number]);try require(ranges.count==number+1,"Range receipt was reused")
        }
        var logs:[String?]=[];model.revisionMenuLog.onContainingLog={name,_,_ in logs.append(name)}
        try await select([bottom])
        try click(coordinator.menu(ids:[bottom],alternate:false).item(withTitle:"Show branches this commit is on")!)
        try await wait {owner.containingWindows.values.first?.snapshot != nil && owner.containingWindows.values.first?.busy==false}
        let containing=owner.containingWindows.values.first!
        try require(containing.preferences === prefs && containing.window?.parent===window && containing.window?.alphaValue==0 && containing.snapshot?.hash==repeated.hash,"Containing references lost owner/scope/preferences")
        containing.showLog.performClick(nil);try require(logs.count==1 && logs[0] == repeated.hash,"Containing references Show log lost captured target")
        let browse=containing.chooser.itemArray.first{$0.title=="Browse References"}!
        try click(browse)
        try await wait {(containing.picker as? ReferenceBrowserWindowController)?.model.busy==false && containing.window?.attachedSheet != nil && containing.hasBlockingChild && model.containingReferenceBlocked && ReferenceBrowserWindowModel.activeReads==0}
        let browser=containing.picker as! ReferenceBrowserWindowController
        try require(browser.window?.alphaValue==0 && !model.revisionMenuAvailable && !model.editable && !owner.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Containing child picker did not retain invisible parent/action/Close/Quit ownership")
        let priorFind=owner.revisionFind
        model.performRevisionMenu(.find,ids:[bottom])
        try require(owner.revisionFind===priorFind && model.selection==[bottom],"Parent action dispatched behind containing child picker")
        browser.model.finish(nil)
        try await wait {containing.picker==nil && containing.window?.attachedSheet==nil && !model.containingReferenceBlocked && model.revisionMenuAvailable && containing.showLog.isEnabled}
        containing.close();try await wait {owner.containingWindows.isEmpty}
        // Both helpers keep their actual cancelled reads through forced parent retirement.
        let snapshot=try await repo.commitContainingReferences(repeated.hash,includeCompletion:false,useMailmap:false)
        referenceSnapshot=snapshot
        reopened.readReferences={_ in await withCheckedContinuation {heldFind=$0}}
        reopened.loadReferences();try await wait {heldFind != nil}
        owner.configureContainingReferences={child in child.readCompletion={_ in []};child.read={_,_ in await withCheckedContinuation {heldReferences=$0}}}
        owner.showRevisionContainingReferences(repeated.hash);try await wait {heldReferences != nil}
        owner.close()
        try require(reopened.closed && owner.containingWindows.isEmpty && RevisionGraphFindController.activeOperations>0 && CommitContainingReferencesWindowController.activeOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed helpers released owned read accounting too early")
        heldFind?.resume(returning:[]);heldFind=nil;heldReferences?.resume(returning:snapshot);heldReferences=nil
        try await wait {RevisionGraphFindController.activeOperations==0 && CommitContainingReferencesWindowController.activeOperations==0 && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0 && ExportWindowModel.activeReads==0}
        try require(model.retired && model.selection==[bottom],"Late helper reply revived or navigated a retired owner")
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout,finalIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(head==finalHead && index==finalIndex,"History tools changed HEAD/index")
        try await cleanup()
        print("PASS: Rebase Find duplicate occurrences/Shift/highlight/wrap/references/error/history, canonical hash/tag Export and range logs, containing refs/picker ownership, inherited prefs/icons and hidden read/close/Quit/retirement drain; HEAD/index preserved")
        } catch {
            let original=error
            do {try await cleanup()} catch {throw Failure(description:"\(original); cleanup failed: \(error)")}
            throw original
        }
    }
}
