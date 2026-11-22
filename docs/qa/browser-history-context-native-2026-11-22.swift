// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum BrowserHistoryContextVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"Browser context \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func wait(_ message:String,window:NSWindow?=nil,_ ready:()->Bool)async throws {
        for _ in 0..<3500 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Browser context timeout: "+message)
    }
    static func send(_ item:NSMenuItem)throws {guard let action=item.action else{throw Failure(description:"Missing native action")};try require(NSApp.sendAction(action,to:item.target,from:item),"Native dispatch rejected "+item.title)}
    static func item(_ menu:NSMenu,_ key:String)throws->NSMenuItem {try unwrap(menu.items.first{$0.title==NSLocalizedString(key,comment:"")},"Missing Browser item "+key)}
    static func key(_ window:NSWindow,_ code:UInt16,_ flags:NSEvent.ModifierFlags=[])->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!}
    static func pointer(_ table:NSTableView,row:Int)->NSEvent {
        let point=table.convert(NSPoint(x:table.frameOfCell(atColumn:0,row:row).midX,y:table.rect(ofRow:row).midY),to:nil)
        return NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:table.window!.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:1)!
    }
    static func boldDefault(_ menu:NSMenu)throws {
        let value=try item(menu,"Open"),font=try unwrap(value.attributedTitle?.attribute(.font,at:0,effectiveRange:nil) as? NSFont,"Open default font missing")
        try require(NSFontManager.shared.traits(of:font).contains(.boldFontMask),"Open is not the native bold default")
    }
    final class Bookmarks:RepositoryBookmarkProvider {
        func create(for url:URL)throws->Data {Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)).standardizedFileURL,stale:false)}
        func startAccessing(_ url:URL)->Bool {true}
        func stopAccessing(_ url:URL) {}
    }
    struct LogPresentation {
        let owner:LogWindowController,root:URL,paths:[String],end:String?,selected:Set<String>,whole:Bool,pending:Int,active:Int
    }
    @MainActor final class Context {
        let base:URL,git:URL,suite="TurtleGit.BrowserContext."+UUID().uuidString,replacementSuite="TurtleGit.BrowserReplacement."+UUID().uuidString
        let preferences:UserDefaults,replacement:UserDefaults,clipboard=NSPasteboard.withUniqueName(),bookmarks=Bookmarks()
        let file="literal %@ 雪\n.txt",second="second.txt",folder="folder 雪",nested="folder 雪/child.txt"
        var repo:GitRepository!,child:GitRepository!,lease:RepositoryAccessLease!,workspace:RepositoryModel?,host:NSWindow?
        var browsers:[RepositoryBrowserWindowController]=[],logs:[LogWindowController]=[],blames:[BlameWindowController]=[],presentations:[LogPresentation]=[]
        var browsed="",childRevision="",head=Data(),index=Data(),childHead=Data(),childIndex=Data()
        var popup:NSMenu?,point:NSPoint?
        var noteReply:CheckedContinuation<(CommitNoteSnapshot,ProjectDialogSettings),Error>?,noteToken:OperationCancellation?
        init(base:URL,git:URL) {
            self.base=base.standardizedFileURL;self.git=git;preferences=UserDefaults(suiteName:suite)!;replacement=UserDefaults(suiteName:replacementSuite)!
            for prefs in [preferences,replacement] {for key in ["EnableLogCache","EnableGravatar","Blame.EnableLexer","LogIncludeWorkingTreeChanges"] {prefs.set(false,forKey:key)};prefs.set(true,forKey:"ShowAppContextMenuIcons")}
            preferences.set(false,forKey:"UseLibgit2");replacement.set(true,forKey:"UseLibgit2")
        }
        func repository(_ root:URL)async throws->GitRepository {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let directory=URL(fileURLWithPath:root.path,isDirectory:true).standardizedFileURL
            let value=GitRepository(root:directory,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await value.run(["init","--template=","-b","main"])
            for (key,text) in [("user.name","Browser Context QA"),("user.email","browser-context@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_=try await value.run(["config",key,text])}
            return value
        }
        func prepare()async throws {
            repo=try await repository(base.appendingPathComponent("repository"));child=try await repository(repo.root.appendingPathComponent("module"))
            try Data("child first\n".utf8).write(to:child.root.appendingPathComponent("child.txt"));try await child.stage(["child.txt"]);_=try await child.commit(message:"Child first")
            childRevision=try await child.rebaseCommit("HEAD").hash
            try Data("child second\n".utf8).write(to:child.root.appendingPathComponent("child.txt"));try await child.stage(["child.txt"]);_=try await child.commit(message:"Child second")
            try FileManager.default.createDirectory(at:repo.root.appendingPathComponent(folder),withIntermediateDirectories:true)
            for path in [file,second,nested] {try Data("first version\n".utf8).write(to:repo.root.appendingPathComponent(path))}
            let modules="[submodule \"module\"]\n\tpath = module\n\turl = ./module\n"
            try Data(modules.utf8).write(to:repo.root.appendingPathComponent(".gitmodules"));try await repo.stage([file,second,nested,".gitmodules"])
            _=try await repo.run(["update-index","--add","--cacheinfo","160000,"+childRevision+",module"])
            _=try await repo.commit(message:"Browser first")
            for path in [file,nested] {try Data("browsed version\n".utf8).write(to:repo.root.appendingPathComponent(path))}
            try await repo.stage([file,nested]);_=try await repo.commit(message:"Browser browsed revision")
            browsed=try await repo.rebaseCommit("HEAD").hash
            try Data("unrelated later version\n".utf8).write(to:repo.root.appendingPathComponent("later.txt"))
            try Data("later current version\n".utf8).write(to:repo.root.appendingPathComponent(file))
            try await repo.stage(["later.txt",file]);_=try await repo.commit(message:"Later HEAD")
            head=try await repo.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
            childHead=try await child.run(["rev-parse","HEAD"]).stdout;childIndex=try Data(contentsOf:child.root.appendingPathComponent(".git/index"))
            lease=RepositoryAccessLease(url:repo.root,provider:bookmarks)
            HistoryWholeProjectPreference.save(false,root:repo.root,defaults:preferences)
            let saved=try RepositoryAccessStore(storageURL:base.appendingPathComponent("private-access.json"))
            let root=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{[git] in GitRepository(root:$0,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false},savedAccessStore:saved,comparisonMarks:WorkingComparisonMarkStore(storageURL:base.appendingPathComponent("marks.json")),cachePersistenceDefaults:preferences,publishCachePersistence:{_ in})
            workspace=root;root.requiresRepositoryScope=false;root.repositoryBookmarkProvider=bookmarks;root.fileComparisonPreferences=replacement;root.notifyFinder={}
            root.blameRecentDocuments=try BlameRecentDocuments(url:base.appendingPathComponent("private-blame-recent.json"),provider:bookmarks)
            let window=NSWindow(contentRect:.init(x:-24000,y:-24000,width:320,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.alphaValue=0;window.orderFront(nil);host=window;root.workspaceWindow=window
            root.browserWindowPresentation={[weak self] owner in
                guard let self else{return}
                if !browsers.contains(where:{$0===owner}) {browsers.append(owner)}
                owner.commandKeyWindow={[weak owner] in owner?.window};owner.model.clipboard=clipboard
                owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)
            }
            root.logWindowPresentation={[weak self] owner in
                guard let self else{return}
                presentations.append(LogPresentation(owner:owner,root:owner.model.repository.root,paths:owner.model.historyPaths,end:owner.model.endRevision,selected:owner.model.selected,whole:owner.model.showWholeProject,pending:owner.model.pendingHistoryLoads,active:LogWindowModel.activeHistoryLoads))
                if !logs.contains(where:{$0===owner}) {logs.append(owner)}
                owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)
            }
            root.showRepositoryBrowser(repository:repo,access:lease,revision:browsed,preferences:preferences)
            try await BrowserHistoryContextVerification.wait("Root Browser load",window:browsers.first?.window){self.browsers.first?.model.busy==false && self.browsers.first?.model.entries.count==5}
        }
        func native(_ owner:RepositoryBrowserWindowController)throws->(RepositoryBrowserNativeTable,RepositoryBrowserFolderOutline) {
            let all=BrowserHistoryContextVerification.views(owner.window?.contentView)
            return (try BrowserHistoryContextVerification.unwrap(all.compactMap{$0 as? RepositoryBrowserNativeTable}.first,"Browser native list missing"),try BrowserHistoryContextVerification.unwrap(all.compactMap{$0 as? RepositoryBrowserFolderOutline}.first,"Browser native tree missing"))
        }
        func select(_ owner:RepositoryBrowserWindowController,_ ids:Set<String>)async throws {
            owner.model.selection=ids
            let table=try native(owner).0
            try await BrowserHistoryContextVerification.wait("Browser native selection",window:owner.window){Set(table.selectedRowIndexes.compactMap{owner.model.entries.indices.contains($0) ? owner.model.entries[$0].id:nil})==ids}
        }
        func capture(_ table:RepositoryBrowserNativeTable){table.presentSelectionMenu={[weak self] menu,point,_ in self?.popup=menu;self?.point=point}}
        func capture(_ tree:RepositoryBrowserFolderOutline){tree.presentSelectionMenu={[weak self] menu,point,_ in self?.popup=menu;self?.point=point}}
        func readyLog(_ owner:LogWindowController)async throws {
            try await BrowserHistoryContextVerification.wait("actual scoped Log completion",window:owner.window){!owner.model.busy && owner.model.pendingHistoryLoads==0 && !owner.model.historyProjectionWorkPending && owner.model.error==nil && !owner.model.entries.isEmpty}
        }
        func cleanup()async throws {
            logs.forEach{$0.model.cancelPendingNoteRead()};noteReply?.resume(throwing:OperationCancellationFailure.cancelled);noteReply=nil
            for window in NSApp.windows {if let blame=window.delegate as? BlameWindowController,!blames.contains(where:{$0===blame}) {blames.append(blame)}}
            browsers.forEach{$0.close()};logs.forEach{$0.close()};blames.forEach{$0.close()};workspace?.stopMonitoringForTermination();host?.close()
            try await BrowserHistoryContextVerification.wait("Browser/Log/Blame owned cleanup") {
                RepositoryBrowserWindowModel.activeOperations==0 && RepositoryBrowserFileOperation.activeRequests==0 && FinderFilesystemWorkflowRelease.activeRetirements==0 && self.browsers.allSatisfy{!$0.hasPendingWork} && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0 && LogWindowModel.activeNoteReads==0 && LogWindowModel.activeFileOpenReads==0 && BlameDocumentOpener.activeReads==0 && BlameWindowModel.activeHistoryOperations==0 && BlameWindowModel.activeSyntaxRequests==0 && self.workspace?.hasPendingFinderPublication != true && self.workspace?.hasPendingRepositoryWork != true && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil}
            }
            clipboard.releaseGlobally();preferences.removePersistentDomain(forName:suite);replacement.removePersistentDomain(forName:replacementSuite)
        }
        func preserved()async throws {
            try BrowserHistoryContextVerification.require(try await repo.run(["rev-parse","HEAD"]).stdout==head && Data(contentsOf:repo.root.appendingPathComponent(".git/index"))==index,"Browser family changed main HEAD/index")
            try BrowserHistoryContextVerification.require(try await child.run(["rev-parse","HEAD"]).stdout==childHead && Data(contentsOf:child.root.appendingPathComponent(".git/index"))==childIndex,"Browser family changed child HEAD/index")
            try BrowserHistoryContextVerification.require(try Data(contentsOf:repo.root.appendingPathComponent(file))==Data("later current version\n".utf8),"Browser menu changed literal file")
        }
    }
    static func verify(base:URL,git:URL)async throws {
        let c=Context(base:base,git:git)
        do {
            try await c.prepare()
            let browser=try unwrap(c.browsers.first,"Root Browser missing"),model=browser.model,window=try unwrap(browser.window,"Browser window missing")
            let (list,tree)=try c.native(browser);c.capture(list);c.capture(tree)
            let first=try unwrap(model.entries.first{$0.path.utf8.elementsEqual(c.file.utf8)},"Literal historical entry missing"),second=try unwrap(model.entries.first{$0.path==c.second},"Second historical entry missing"),folder=try unwrap(model.entries.first{$0.path==c.folder},"Folder entry missing"),module=try unwrap(model.entries.first{$0.path=="module"},"Gitlink entry missing")
            try await c.select(browser,[first.id,second.id])
            let row=try unwrap(model.entries.firstIndex{$0.id==second.id},"Selected mark row missing")
            let pointerMenu=try unwrap(list.menu(for:pointer(list,row:row)),"Pointer Browser menu missing")
            pointerMenu.delegate?.menuNeedsUpdate?(pointerMenu)
            try require(model.selection==[first.id,second.id] && model.focusedEntryID==second.id,"Pointed selected row lost highlights/mark")
            try require(pointerMenu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil},"Source file-menu icon missing")
            try send(try item(pointerMenu,"Copy to clipboard"))
            let names=model.entries.filter{[first.id,second.id].contains($0.id)}.map{$0.name+"\r\n"}.joined()
            try require(c.clipboard.string(forType:.string)==names,"Literal name/percent/newline copy changed bytes/order")
            window.makeFirstResponder(list);c.popup=nil;list.keyDown(with:key(window,109,.shift))
            let keyboardMenu=try unwrap(c.popup,"Contents Shift-F10 popup missing")
            try require(model.selection==[first.id,second.id],"Keyboard popup changed selected files")
            try require(abs((c.point?.y ?? -1000)-list.rect(ofRow:row).midY)<list.rowHeight,"Contents popup ignored selected mark")
            c.popup=nil;try require(list.accessibilityPerformShowMenu() && c.popup != nil,"Contents accessibility popup missing")
            let stale=try item(keyboardMenu,"Copy hash"),prior=c.clipboard.string(forType:.string)
            list.menu?.delegate?.menuNeedsUpdate?(list.menu!)
            try send(stale);try require(c.clipboard.string(forType:.string)==prior,"Replaced contents popup invoked")
            let closed=try item(list.menu!,"Copy hash");list.menu?.delegate?.menuDidClose?(list.menu!)
            await Task.yield();try await Task.sleep(nanoseconds:10_000_000)
            try send(closed);try require(c.clipboard.string(forType:.string)==prior,"Closed contents popup invoked late")
            let foreign=NSWindow(contentRect:.zero,styleMask:.titled,backing:.buffered,defer:false);foreign.isReleasedWhenClosed=false
            browser.commandKeyWindow={foreign};c.popup=nil;list.keyDown(with:key(window,109,.shift));try require(c.popup==nil,"Foreign key owner opened list popup")
            browser.commandKeyWindow={window};foreign.close()
            model.sortOrder=[KeyPathComparator(\RepositoryBrowserEntry.sizeSort,order:.reverse)]
            try await wait("sorted mark native rows",window:window){model.entries.indices.contains(list.selectedRow) && list.selectionMenuRow()==model.entries.firstIndex{$0.id==second.id}}
            c.popup=nil;list.keyDown(with:key(window,109,.shift))
            let sortedMark=try unwrap(model.entries.firstIndex{$0.id==second.id},"Sorted mark disappeared")
            try require(c.popup != nil && abs((c.point?.y ?? -1000)-list.rect(ofRow:sortedMark).midY)<list.rowHeight,"Sort moved popup to another identity")
            model.busy=true;c.popup=nil;try require(!list.accessibilityPerformShowMenu() && c.popup==nil,"Busy contents exposed popup");model.busy=false
            window.orderOut(nil);c.popup=nil
            try require(!list.accessibilityPerformShowMenu() && !tree.accessibilityPerformShowMenu() && c.popup==nil,"Ordered-out Browser exposed accessibility popup")
            browser.showWindow(nil)
            try await wait("ordered Browser restored",window:window){window.isVisible && list.isEnabled}
            try await c.select(browser,[first.id]);try require(list.accessibilityPerformShowMenu(),"Single-file popup missing")
            let single=try unwrap(c.popup,"Single file popup missing");try boldDefault(single)
            try require(single.items.contains{$0.title==NSLocalizedString("Show log",comment:"")},"Fixed history caption bypassed localization fallback")
            // Distinguish a previous navigation's accepted configuration from
            // the Browser snapshot without adding optional engine execution to
            // this UI family: mask zero keeps actual commands on the CLI.
            c.preferences.set(0,forKey:"UseLibgit2_mask")
            model.markForComparison(first)
            try await wait("historical comparison mark",window:window){!model.busy && model.comparisonMark != nil}
            try require(model.acceptedNavigationRepository?.libgit2Configuration?.mask==0,"Comparison setup did not retain distinct navigation configuration")
            try await c.select(browser,[second.id]);try require(list.accessibilityPerformShowMenu(),"Comparison-label popup missing")
            let mark=try unwrap(model.comparisonMark,"Historical mark missing")
            try require(c.popup?.items.contains{$0.title==String(format:NSLocalizedString("Compare with %@",comment:""),mark.label(for:second.path))}==true,"Formatted comparison caption changed literal mark label")

            // Real Root dispatch: a browsed old commit must configure both the
            // history endpoint and selection before exactly one cold read.
            c.preferences.set(true,forKey:"UseLibgit2")
            try await c.select(browser,[first.id]);try require(list.accessibilityPerformShowMenu(),"Root file history popup missing")
            try send(try item(try unwrap(c.popup,"Root file menu missing"),"Show log"))
            try await wait("Root file Log presentation"){c.presentations.count==1}
            let cold=c.presentations[0],log=cold.owner
            try require(cold.pending==1 && cold.active==1,"Cold Root Log scheduled a cancelled default/duplicate history read")
            try require(cold.paths==[c.file] && !cold.whole && cold.end==c.browsed && cold.selected==[c.browsed],"Cold Root Log lost path/end/selected browsed revision")
            try require(log.model.repository.root==c.repo.root && log.model.repository.executable==c.git && log.model.repositoryAccess===c.lease && log.model.colorPreferences===c.preferences,"Root file Log changed origin/runtime/preferences/lease")
            let accepted=try unwrap(model.snapshot?.acceptedBackend,"Browser snapshot backend absent")
            try require(NativeDiffBackendIdentity(log.model.repository.libgit2Configuration)==NativeDiffBackendIdentity(accepted) && accepted.enabled==false && c.preferences.bool(forKey:"UseLibgit2"),"Root Log used changed preferences instead of accepted backend")
            try await c.readyLog(log)
            try require(log.model.selected==[c.browsed] && log.model.entries.contains{$0.hash==c.browsed} && !log.model.entries.contains{$0.hash==String(decoding:c.head,as:UTF8.self).trimmingCharacters(in:.newlines)},"Actual file Log substituted current HEAD or lost selection")
            c.preferences.set(false,forKey:"UseLibgit2")
            for scope in [HistoryReferenceScope.basic,.local] {
                try await wait("idle cached Log admission",window:log.window){log.model.canReuseForPresentation}
                log.model.chooseStartReference("main HEAD")
                try await wait("actual multiple start tips",window:log.window){log.model.canChangeStartReference && log.model.canReuseForPresentation}
                try require(log.model.startRevisions==["main","HEAD"] && log.model.endRevision==nil && log.model.entries.contains{$0.hash==String(decoding:c.head,as:UTF8.self).trimmingCharacters(in:.newlines)},"Public start-reference control did not seed an unbounded two-tip walk")
                log.model.chooseReferenceScope(scope)
                try await wait("actual broad reference scope",window:log.window){log.model.canChangeStartReference && log.model.canReuseForPresentation}
                try require(log.model.referenceScope==scope && log.model.startRevisions==["main","HEAD"],"Public reference-set control did not retain start tips")
                let before=c.presentations.count
                model.showEntryLog(first)
                try await wait("scoped cached Log presentation"){c.presentations.count==before+1}
                let reopened=c.presentations.last!
                try require(reopened.owner===log && log.model.referenceScope == .current && log.model.startRevisions.isEmpty && reopened.paths==[c.file] && !reopened.whole && reopened.end==c.browsed && reopened.selected==[c.browsed],"Cached Browser Log retained broad references/start tips or lost file selection")
                try await c.readyLog(log)
                try require(log.model.selected==[c.browsed] && !log.model.entries.contains{$0.hash==String(decoding:c.head,as:UTF8.self).trimmingCharacters(in:.newlines)},"Cached Log actual walk escaped pinned endpoint")
            }
            // Secondary role check: ordinary Browser history must never reuse
            // an output/selection controller, even with an identical range.
            let selectionOwner=LogWindowController(repository:c.repo,access:c.lease,onChoose:{_ in},labelDefaults:c.preferences,loadsImmediately:false)
            c.logs.append(selectionOwner)
            let roleRange=HistoryRevisionRange(from:c.browsed,to:"HEAD")
            ReferenceLogWindowModel.configureRangeLog(selectionOwner.model,range:roleRange)
            try require(!selectionOwner.model.canReuseForPresentation && !selectionOwner.model.canReuseForRange(roleRange),"Selectable Log became a reusable Browser history owner")
            selectionOwner.close()
            log.model.readNote={_,token in c.noteToken=token;return try await withCheckedThrowingContinuation{c.noteReply=$0}}
            try await wait("Log note admission",window:log.window){log.model.canEditNotes}
            log.model.editNotes();try await wait("actual cached Log note read"){c.noteReply != nil && log.model.loadingNote}
            let retainedPaths=log.model.historyPaths,retainedEnd=log.model.endRevision,retainedSelection=log.model.selected
            let beforeBusy=c.presentations.count
            model.showEntryLog(first);try await wait("separate Log for busy cached owner"){c.presentations.count==beforeBusy+1}
            let separate=c.presentations.last!.owner
            try require(separate !== log && log.model.loadingNote && log.model.historyPaths==retainedPaths && log.model.endRevision==retainedEnd && log.model.selected==retainedSelection,"Repeated Browser history mutated the busy Log owner")
            log.model.cancelPendingNoteRead();c.noteReply?.resume(throwing:OperationCancellationFailure.cancelled);c.noteReply=nil
            try await c.readyLog(separate)
            let beforeFolder=c.presentations.count
            model.showFolderLog(folder.path);try await wait("Root folder Log presentation"){c.presentations.count==beforeFolder+1}
            let folderLog=c.presentations.last!
            try require(folderLog.paths==[folder.path] && !folderLog.whole && folderLog.end==c.browsed && folderLog.selected==[c.browsed],"Folder Log lost scoped selected revision")
            try await c.readyLog(folderLog.owner)

            // Native folder entry shares the same captured source commands.
            let folderRow=try unwrap((0..<tree.numberOfRows).first{(tree.item(atRow:$0) as? RepositoryBrowserFolderTree.Node)?.path==folder.path},"Folder outline node missing")
            let treeMenu=try unwrap(tree.menu(for:pointer(tree,row:folderRow)),"Folder pointer popup missing")
            treeMenu.delegate?.menuNeedsUpdate?(treeMenu);try boldDefault(treeMenu)
            try require(model.snapshot?.directory=="","Tree pointer menu navigated before Open")
            window.makeFirstResponder(tree);c.popup=nil;tree.keyDown(with:key(window,109,.shift));try require(c.popup != nil,"Folder Shift-F10 popup missing")
            c.popup=nil;try require(tree.accessibilityPerformShowMenu() && c.popup != nil,"Folder AX popup missing")
            let captured=try item(try unwrap(c.popup,"Folder menu absent"),"Copy to clipboard");try send(captured)
            try require(c.clipboard.string(forType:.string)==folder.name+"\r\n","Folder clipboard changed literal name")
            let oldTree=try item(try unwrap(c.popup,"Folder menu absent"),"Copy hash");treeMenu.delegate?.menuNeedsUpdate?(treeMenu);let treePrior=c.clipboard.string(forType:.string)
            try send(oldTree);try require(c.clipboard.string(forType:.string)==treePrior,"Replaced folder popup invoked")

            c.preferences.set(true,forKey:"UseLibgit2")
            let beforeSubmodule=c.presentations.count
            model.showSubmoduleLog(module);try await wait("Root pinned submodule Log"){c.presentations.count==beforeSubmodule+1 && !model.busy}
            let childLog=c.presentations.last!
            try require(childLog.root==c.child.root && childLog.paths.isEmpty && childLog.end==c.childRevision && childLog.selected==[c.childRevision] && childLog.owner.model.repositoryAccess===c.lease && childLog.owner.model.colorPreferences===c.preferences,"Submodule history lost child root/gitlink object/origin authority")
            try require(NativeDiffBackendIdentity(childLog.owner.model.repository.libgit2Configuration)==NativeDiffBackendIdentity(accepted),"Submodule Log changed captured backend")
            try await c.readyLog(childLog.owner)
            model.showEntryBlame(first)
            try await wait("Root historical Blame") {
                c.blames=NSApp.windows.compactMap{$0.delegate as? BlameWindowController}
                return c.blames.count==1 && c.blames[0].model.busy==false && c.blames[0].model.snapshot?.revision==c.browsed
            }
            let blame=c.blames[0]
            try require(blame.model.path.utf8.elementsEqual(c.file.utf8) && blame.model.repository.root==c.repo.root && blame.model.repositoryAccess===c.lease && blame.model.labelDefaults===c.preferences && NativeDiffBackendIdentity(blame.model.repository.libgit2Configuration)==NativeDiffBackendIdentity(accepted),"Root Blame changed literal path/repository/backend/private preferences/lease")
            let beforeClose=c.presentations.count,late=model.onLog
            browser.close();late(c.file,c.browsed)
            try require(c.presentations.count==beforeClose && !list.accessibilityPerformShowMenu() && !tree.accessibilityPerformShowMenu(),"Retired Browser callback/menu reopened history")
            try await c.preserved();try await c.cleanup()
            print("PASS: actual Browser list/tree pointer/ShiftF10/AX menus, exact selection mark through sorting, default Open/localized caption contract/source icons/literal copy and comparison caption, foreign/busy/replaced/closed/retired menus, real Root file/folder/submodule/Blame historical handoffs with scoped paths/selected pinned revisions/accepted backend/preferences/lease, single cold history admission and busy cached Log isolation; unchanged main/child HEAD/index; no physical VoiceOver, external apps or signed grants claimed")
        } catch {
            let original=error
            do {try await c.cleanup()} catch {throw Failure(description:"\(original); cleanup: \(error)")}
            throw original
        }
    }
}
