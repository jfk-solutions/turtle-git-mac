// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func turtleGuiStageOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-22000,y:-22000));turtleGuiStageOrder(mode,relativeTo:number)
    }
    @objc func turtleGuiStageSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {
        sheet.alphaValue=0;sheet.setFrameOrigin(.init(x:-22000,y:-22000));turtleGuiStageSheet(sheet,completionHandler:completionHandler)
    }
}
@MainActor @main struct CommitGuiStagingVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws {if !condition{throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Commit GUI staging did not settle at line \(line)")
    }
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func drained()->Bool {CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileDrops==0 && PatchWindowModel.activeOperations==0}
    @MainActor final class Context {
        let root:URL,git:URL,repository:GitRepository,prefs:UserDefaults,suite:String
        var owners:[CommitWindowController]=[],release:[()->Void]=[]
        let partial="part 雪\t[*].txt",untracked="-new 🦎.txt",deleted="deleted.txt",sentinel="unrelated.txt"
        var base=Data(),staged=Data(),working=Data(),head=Data(),sentinelIndex=Data(),contents:[String:Data]=[:]
        init(root:URL,git:URL)throws {
            self.root=root;self.git=git;repository=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.CommitGuiStaging."+UUID().uuidString;prefs=try unwrap(UserDefaults(suiteName:suite),"Private preferences unavailable")
            for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation","TurtleGit.Commit.GitGuiInterface","AddBeforeCommit"] {prefs.set(true,forKey:key)}
            for key in ["EnableGravatar","SelectFilesForCommit","UseLibgit2"] {prefs.set(false,forKey:key)}
        }
        func setup()async throws {
            _=try await repository.run(["init","-b","main"])
            for(key,value)in [("user.name","GUI staging QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport","true")] {_=try await repository.run(["config",key,value])}
            base=Data((1...32).map{"base context \($0)\n"}.joined().utf8)
            staged=Data(String(decoding:base,as:UTF8.self).replacingOccurrences(of:"base context 2\n",with:"staged change 2\n").utf8)
            working=Data(String(decoding:staged,as:UTF8.self).replacingOccurrences(of:"base context 30\n",with:"working change 30\n").utf8)
            for(path,bytes)in [(partial,base),(deleted,Data("deleted source\n".utf8)),(sentinel,Data("unrelated base\n".utf8))] {try bytes.write(to:root.appendingPathComponent(path))}
            try await repository.stage([partial,deleted,sentinel]);_=try await repository.commit(message:"GUI stage fixture")
            try staged.write(to:root.appendingPathComponent(partial));try await repository.stage([partial])
            try working.write(to:root.appendingPathComponent(partial))
            try Data("untouched staged sentinel\n".utf8).write(to:root.appendingPathComponent(sentinel));try await repository.stage([sentinel])
            try Data("untracked literal path\n".utf8).write(to:root.appendingPathComponent(untracked));try FileManager.default.removeItem(at:root.appendingPathComponent(deleted))
            head=try await repository.run(["rev-parse","HEAD"]).stdout;sentinelIndex=try await repository.run(["show",":"+sentinel]).stdout
            for path in [partial,untracked,sentinel] {contents[path]=try Data(contentsOf:root.appendingPathComponent(path))}
        }
        func open(_ source:GitRepository?=nil)async throws->CommitWindowController {
            let owner=CommitWindowController(repository:source ?? repository,access:nil,defaults:prefs);owners.append(owner)
            owner.window?.alphaValue=0;owner.showWindow(nil);owner.model.reload(paths:["."])
            try await CommitGuiStagingVerification.ready(owner)
            try require(owner.model.gitGuiInterface && owner.model.error==nil,"Git GUI mode did not load")
            return owner
        }
        func preserved()async throws {
            try require(try await repository.run(["rev-parse","HEAD"]).stdout==head,"Staging changed HEAD")
            try require(try await repository.run(["show",":"+sentinel]).stdout==sentinelIndex,"Staging changed unrelated index bytes")
            for(path,bytes)in contents {try require(try Data(contentsOf:root.appendingPathComponent(path))==bytes,"Staging changed working bytes: "+path)}
            try require(!FileManager.default.fileExists(atPath:root.appendingPathComponent(deleted).path),"Staging recreated deleted working file")
        }
        func clean()async {
            release.forEach{$0()};release=[];owners.forEach{$0.close()}
            for _ in 0..<2000 {if drained() && owners.allSatisfy({!$0.model.fileWorkPending}) {break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func ready(_ owner:CommitWindowController)async throws {
        let model=owner.model
        do {try await wait{!model.busy && !model.savingPreferences && !model.fileWorkPending && !model.stagingStateNeedsRefresh && model.commitIdentityPrepared && model.changelistsLoaded && !model.loadingAuthorIdentity && !model.loadingAuthorDate && !model.loadingAmendMessage && !model.mergeHintVisible && !model.stagingHintVisible && model.guiPatch?.busy != true}}
        catch {throw Failure(description:"GUI staging readiness: busy=\(model.busy),refresh=\(model.stagingStateNeedsRefresh),rows=\(model.entries.map(\.path)),error=\(model.error ?? "none"); \(error)")}
        try require(model.error==nil,"GUI staging operation failed: "+(model.error ?? "none"))
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGuiStageOrder(_:relativeTo:)))!
        let begin=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGuiStageSheet(_:completionHandler:)))!
        method_exchangeImplementations(original,hidden);method_exchangeImplementations(begin,quiet)
        defer {method_exchangeImplementations(begin,quiet);method_exchangeImplementations(original,hidden)}
        let context=try Context(root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))
        do {try await context.setup();try await verify(context);await context.clean()}
        catch {await context.clean();throw error}
        try require(drained() && context.owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Owned GUI staging windows/workers survived cleanup")
        print("PASS: Commit GUI staging native tables, captured transfer adapter, double-action hookup, partial/untracked/deleted literal paths, stable loading/empty appearance, owner/selection guards and drain")
    }
    static func nativeTables(_ owner:CommitWindowController)throws->[NSTableView] {
        let tables=views(owner.window?.contentView).compactMap{$0 as? NSTableView}.filter{$0.headerView != nil && $0.tableColumns.count>=2}
        try require(tables.count==2,"Expected two persistent native staged/unstaged tables, found \(tables.count)")
        // Unstaged is the upper split, staged the lower split. Associate only
        // tables attached to this owner, never a stale detached native adapter.
        return tables.sorted{$0.convert($0.bounds,to:nil).midY > $1.convert($1.bounds,to:nil).midY}
    }
    static func table(_ owner:CommitWindowController,staged:Bool)throws->NSTableView {
        let result=try nativeTables(owner)[staged ? 1:0]
        try require(result.window === owner.window,"Native table is detached or belongs to another owner")
        let headers=result.tableColumns.map{$0.headerCell.stringValue}
        try require(headers.contains("Path") && headers.contains("Status"),"Native file table lost accessible headers: \(headers)")
        return result
    }
    @discardableResult static func select(_ owner:CommitWindowController,paths:[String],staged:Bool)async throws->NSTableView {
        try await ready(owner)
        let model=owner.model,snapshot=model.guiFileListSnapshot(staged:staged),wanted=GitPathSet(paths)
        let table=try Self.table(owner,staged:staged)
        try await wait{table.numberOfRows==snapshot.entries.count}
        let indexes=IndexSet(snapshot.entries.indices.filter{wanted.contains(snapshot.entries[$0].id)})
        try require(indexes.count==wanted.count,"Selection paths absent from actual \(staged ? "staged":"unstaged") table: \(paths)")
        owner.window?.makeFirstResponder(table);table.deselectAll(nil);table.selectRowIndexes(indexes,byExtendingSelection:false)
        do {try await wait{model.guiStaged==staged && model.selection==wanted}}
        catch {throw Failure(description:"GUI native selection failed: staged=\(staged),wanted=\(Array(wanted)),indexes=\(Array(indexes)),native=\(Array(table.selectedRowIndexes)),rows=\(snapshot.entries.map(\.path)),model=\(Array(model.selection)),side=\(model.guiStaged),busy=\(model.busy),patchBusy=\(model.guiPatch?.busy == true),sheet=\(owner.window?.attachedSheet != nil); \(error)")}
        // Row selection publishes before its asynchronous patch read. Callers
        // need this exact selected-path preview, not the cleared loading model.
        try await ready(owner)
        try require(model.guiPatch.map{!$0.busy && $0.staged==staged && GitPathSet($0.paths)==wanted && $0.error==nil}==true,"Selected row preview is not current: "+stagingDiagnostic(owner,paths:paths,staged:staged))
        return try Self.table(owner,staged:staged)
    }
    static func stagingDiagnostic(_ owner:CommitWindowController,paths:[String],staged:Bool)->String {
        let model=owner.model,snapshot=model.guiFileListSnapshot(staged:staged)
        let native=(try? nativeTables(owner))?.map{["selected":Array($0.selectedRowIndexes),"clicked":$0.clickedRow,"rows":$0.numberOfRows] as [String:Any]} ?? []
        let state:[String:Any]=["requested":paths,"sourceStaged":staged,"side":model.guiStaged,
            "selection":Array(model.selection),"staged":model.stagedEntries.map(\.path),"unstaged":model.unstagedEntries.map(\.path),
            "states":model.entries.map{["path":$0.path,"index":String($0.index),"working":String($0.worktree),"stage":model.stagingState($0).rawValue] as [String:Any]},
            "snapshotStates":snapshot.states,"canMove":model.canMoveGuiFiles(paths,snapshot:snapshot),
            "busy":model.busy,"fileWork":model.fileWorkPending,"needsRefresh":model.stagingStateNeedsRefresh,
            "patchPaths":model.guiPatch?.paths ?? [],"patchBusy":model.guiPatch?.busy == true,"error":model.error ?? "none","tables":native]
        return (try? JSONSerialization.data(withJSONObject:state,options:.sortedKeys)).flatMap{String(data:$0,encoding:.utf8)} ?? "unavailable"
    }
    struct ListGeometry {let frames:[NSRect];let diagnostic:String}
    static func listGeometry(_ owner:CommitWindowController)throws->ListGeometry {
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        let tables=try nativeTables(owner)
        let frames=tables.flatMap { table -> [NSRect] in
            guard let scroll=table.enclosingScrollView,let header=table.headerView else{return []}
            return [scroll.convert(scroll.bounds,to:nil),header.convert(header.bounds,to:nil)]
        }
        func record(_ view:NSView)->[String:Any] {
            ["class":String(describing:type(of:view)),"identity":String(describing:ObjectIdentifier(view)),
             "frame":NSStringFromRect(view.frame),"bounds":NSStringFromRect(view.bounds),"windowRect":NSStringFromRect(view.convert(view.bounds,to:nil)),
             "intrinsic":NSStringFromSize(view.intrinsicContentSize),"fitting":NSStringFromSize(view.fittingSize),"hidden":view.isHidden]
        }
        let details=tables.map{table -> [String:Any] in
            var chain:[[String:Any]]=[],parent:NSView?=table
            while let view=parent {chain.append(record(view));parent=view.superview}
            let scroll=table.enclosingScrollView
            return ["ancestors":chain,"rows":table.numberOfRows,"columns":table.tableColumns.map{["title":$0.headerCell.stringValue,"width":$0.width] as [String:Any]},
                    "horizontalScroller":scroll?.hasHorizontalScroller==true,"horizontalHidden":scroll?.horizontalScroller?.isHidden ?? true,
                    "horizontalFrame":scroll?.horizontalScroller.map{NSStringFromRect($0.frame)} ?? "none","autohidesScrollers":scroll?.autohidesScrollers ?? false]
        }
        let splits=views(owner.window?.contentView).compactMap{$0 as? NSSplitView}.map{split -> [String:Any] in ["view":record(split),"vertical":split.isVertical,"children":split.subviews.map{record($0)}]}
        let value:[String:Any]=["window":owner.window.map{NSStringFromRect($0.frame)} ?? "none","contentLayout":owner.window.map{NSStringFromRect($0.contentLayoutRect)} ?? "none",
                              "content":owner.window?.contentView.map{record($0)} ?? [:],"tables":details,"splits":splits]
        let diagnostic=(try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys)).flatMap{String(data:$0,encoding:.utf8)} ?? "unavailable"
        return ListGeometry(frames:frames,diagnostic:diagnostic)
    }
    static func stableGeometry(_ expected:ListGeometry,_ owner:CommitWindowController,_ phase:String)throws {
        let actual=try listGeometry(owner)
        try require(expected.frames.count==4 && actual.frames.count==4,"Missing native list/header geometry at "+phase)
        for (before,after) in zip(expected.frames,actual.frames) {
            try require(abs(before.minX-after.minX)<=0.5 && abs(before.minY-after.minY)<=0.5 && abs(before.width-after.width)<=0.5 && abs(before.height-after.height)<=0.5,"Staging file/header geometry jumped at \(phase): before=\(expected.frames),after=\(actual.frames); beforeLayout=\(expected.diagnostic); afterLayout=\(actual.diagnostic)")
        }
    }
    static func transferByAdapter(_ owner:CommitWindowController,paths:[String],staged:Bool)async throws {
        _ = try await select(owner,paths:paths,staged:staged)
        try await ready(owner)
        let native=try Self.table(owner,staged:staged)
        // The real pointer double-click is accepted separately by physical CUA.
        // Retain native hookup checks, but do not claim action-only/synthetic
        // offscreen events reproduce SwiftUI's pointer gesture pipeline.
        _ = try unwrap(native.doubleAction,"Native table has no double-click action")
        _ = try unwrap(native.target,"Native double-click has no owned target")
        let title=staged ? "Unstage files":"Stage files"
        let geometry=try listGeometry(owner)
        let snapshot=owner.model.guiFileListSnapshot(staged:staged)
        try require(owner.model.canMoveGuiFiles(paths,snapshot:snapshot),"Selected native rows have no eligible transfer adapter: "+stagingDiagnostic(owner,paths:paths,staged:staged))
        var accepted=false
        let observation=owner.model.$busy.dropFirst().sink{if $0 {accepted=true}}
        defer {observation.cancel()}
        // Behavioral boundary: invoke the captured transfer adapter used by
        // native buttons/context/primaryAction after real table selection. This
        // deliberately does NOT claim offscreen native button/gesture dispatch.
        // Actual two-way double-click acceptance is recorded by physical CUA.
        owner.model.activateGuiFiles(paths,snapshot:snapshot)
        try require(accepted,"Eligible captured transfer adapter did not accept work: "+stagingDiagnostic(owner,paths:paths,staged:staged))
        try await ready(owner)
        try stableGeometry(geometry,owner,"completed captured transfer "+title)
        let wanted=GitPathSet(paths),after=stagingDiagnostic(owner,paths:paths,staged:staged)
        try require(owner.model.guiStaged == !staged && owner.model.selection==wanted,"Moved paths lost exact destination-side native selection: \(after)")
        try require(owner.model.guiPatch.map{GitPathSet($0.paths)==wanted}==true,"Staging continuation lost the captured selected-file preview: \(after)")
    }
    static func capture(_ owner:CommitWindowController,to path:URL)throws {
        let view=try unwrap(owner.window?.contentView,"Missing appearance owner")
        view.layoutSubtreeIfNeeded()
        let bitmap=try unwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds),"Offscreen appearance bitmap unavailable")
        view.cacheDisplay(in:view.bounds,to:bitmap)
        try unwrap(bitmap.representation(using:.png,properties:[:]),"Offscreen appearance PNG unavailable").write(to:path)
    }
    static func verify(_ c:Context)async throws {
        let owner=try await c.open(),model=owner.model
        let partial=c.partial,new=c.untracked,deleted=c.deleted
        try require(model.stagedEntries.contains{GitReferenceName.equal($0.path,partial)} && model.unstagedEntries.contains{GitReferenceName.equal($0.path,partial)},"Partially staged file must appear on both sides")
        try require(try await c.repository.run(["show",":"+partial]).stdout==c.staged,"Fixture did not retain partial index bytes")
        let partialRow=try unwrap(model.entries.first{GitReferenceName.equal($0.path,partial)},"Missing partial row")
        try require(model.guiFileStatus(partialRow,staged:false)=="Partially staged" && model.guiFileStatus(partialRow,staged:true)=="Partially staged","Both native sides must retain partial-staged status")
        _ = try table(owner,staged:false);_ = try table(owner,staged:true)
        // Real NSTableView selection updates the patch owner without mutating
        // the index. The captured adapter then performs actual staged-path Git work.
        _ = try await select(owner,paths:[partial],staged:false)
        let emptyEvent=model.guiFileListSnapshot(staged:false),beforeEmptyEvent=try await c.repository.run(["write-tree"]).stdout
        try require(!model.selection.isEmpty && !model.canMoveGuiFiles([String](),snapshot:emptyEvent),"Empty native activation reused existing highlighted rows")
        model.activateGuiFiles([String](),snapshot:emptyEvent)
        try require(try await c.repository.run(["write-tree"]).stdout==beforeEmptyEvent,"Empty native activation transferred highlighted rows")
        try require(try await c.repository.run(["show",":"+partial]).stdout==c.staged,"Selecting an unstaged row changed partial stage")
        try await transferByAdapter(owner,paths:[partial],staged:false)
        try require(try await c.repository.run(["show",":"+partial]).stdout==c.working,"Stage adapter did not stage full selected content")
        try await c.preserved()
        try await transferByAdapter(owner,paths:[partial],staged:true)
        try require(try await c.repository.run(["show",":"+partial]).stdout==c.base,"Unstage adapter did not restore base index")
        try await transferByAdapter(owner,paths:[new,deleted],staged:false)
        let stagedNames=GitPathSet(try await c.repository.run(["diff","--cached","--name-only","-z","--no-renames"]).stdout.split(separator:0).map{String(decoding:$0,as:UTF8.self)})
        try require(stagedNames.contains(new) && stagedNames.contains(deleted),"Multirow native staging omitted untracked or deleted path")
        try require(try await c.repository.run(["show",":"+new]).stdout==c.contents[new],"Untracked stage lost literal path or bytes")
        try await transferByAdapter(owner,paths:[new,deleted],staged:true)
        let after=GitPathSet(try await c.repository.run(["diff","--cached","--name-only","-z","--no-renames"]).stdout.split(separator:0).map{String(decoding:$0,as:UTF8.self)})
        try require(!after.contains(new) && !after.contains(deleted) && after.contains(c.sentinel),"Native unstage changed unrelated stage or left selected paths staged")
        try await c.preserved()
        // A real hunk write remains a blocking operation, unlike a read-only
        // preview. Stage just the first separated hunk to recreate partial state.
        _ = try await select(owner,paths:[partial],staged:false)
        let patch=try unwrap(model.guiPatch,"Selected file has no hunk preview")
        let hunk=try unwrap(patch.document.files.first?.hunks.first,"Fixture has no separated hunk")
        patch.selectedLines=[hunk.header]
        try require(patch.canApplyHunks,"Actual first-hunk action unavailable")
        patch.apply(entireHunks:true)
        try require(patch.applyingChanges,"Actual hunk apply did not enter owned write state")
        model.setCommitInterface(false)
        try require(model.gitGuiInterface,"Interface switch retired an accepted index write")
        try await ready(owner)
        let firstHunkIndex=try await c.repository.run(["show",":"+partial]).stdout
        try require(patch.error==nil && firstHunkIndex==c.staged,"Real first-hunk staging failed to retain partial index bytes")
        _ = try await select(owner,paths:[partial],staged:false)
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            owner.window?.appearance=NSAppearance(named:appearance);await Task.yield()
            try capture(owner,to:c.root.appendingPathComponent("commit-gui-files-"+name+".png"))
        }
        try await c.preserved()
        try await emptyAndLoading(c,owner:owner)
    }
    static func emptyAndLoading(_ c:Context,owner:CommitWindowController)async throws {
        let model=owner.model,original=model.queryCommitStatus
        var reply:CheckedContinuation<[StatusEntry],Never>?,token:OperationCancellation?
        let rows=try await c.repository.commitDialogStatus(amendToParent:false,refreshIndex:false)
        func release(){let pending=reply;reply=nil;pending?.resume(returning:rows)}
        c.release.append{release()}
        model.queryCommitStatus={_,owned in token=owned;return await withCheckedContinuation{reply=$0}}
        let old=model.guiFileListSnapshot(staged:false),tree=try await c.repository.run(["write-tree"]).stdout
        let idleGeometry=try listGeometry(owner)
        model.reload();try await wait{reply != nil && model.busy}
        try require(model.reloadPhase == .changes && model.guiFileListMessage(staged:false)?.contains("Reading changes…")==true && model.guiFileListMessage(staged:true)?.contains("Reading changes…")==true,"Held status read did not expose its truthful changes phase")
        await Task.yield()
        try stableGeometry(idleGeometry,owner,"held changes read: operation band and list progress/status")
        let tables=try nativeTables(owner)
        try require(tables.count==2 && model.guiFileListMessage(staged:false) != nil && model.guiFileListMessage(staged:true) != nil,"Loading removed file frames or feedback")
        model.activateGuiFiles([c.partial],snapshot:old)
        try require(try await c.repository.run(["write-tree"]).stdout==tree,"Loading/stale table receipt mutated index")
        try require(!model.canMoveGuiFiles([c.partial],snapshot:old),"Loading admitted a staging action")
        release();try await ready(owner);model.queryCommitStatus=original
        try require(model.reloadPhase==nil,"Completed reload retained an obsolete phase")
        try stableGeometry(idleGeometry,owner,"changes read drained")
        // Replacing the presentation must retire its captured staging callbacks.
        _ = try await select(owner,paths:[c.partial],staged:false)
        let stale=model.guiFileListSnapshot(staged:false)
        let retiredPreview=try unwrap(model.guiPatch,"Missing read-only preview owner")
        let previousText=retiredPreview.document.text
        var previewCancellations=0
        // This is the existing input-session admission/cancellation boundary,
        // not a synthetic slow Git process or an index-write flag override.
        try require(retiredPreview.beginStartupInput{previewCancellations+=1},"Could not hold preview input session")
        try require(retiredPreview.busy && !retiredPreview.applyingChanges,"Held preview was mistaken for a write")
        model.setCommitInterface(false)
        try require(!model.gitGuiInterface && retiredPreview.retired && previewCancellations==1 && model.guiPatch==nil,"Read-only preview prevented mode switch or lost its cancellation")
        retiredPreview.setReadOnlyDiff(Data("late obsolete preview".utf8));retiredPreview.finishStartupInput()
        try require(retiredPreview.document.text==previousText && !retiredPreview.busy && model.guiPatch==nil,"Retired preview input published late content or reattached")
        try await ready(owner)
        model.activateGuiFiles([c.partial],snapshot:stale)
        try require(try await c.repository.run(["write-tree"]).stdout==tree,"Retired GUI receipt mutated Classic index")
        model.setCommitInterface(true);try await ready(owner)
        model.activateGuiFiles([c.partial],snapshot:stale)
        try require(try await c.repository.run(["write-tree"]).stdout==tree,"Old GUI generation revived after returning from Classic")
        let folder=c.root.appendingPathComponent("empty-repository");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let empty=GitRepository(root:folder,executable:c.git,libgit2Configuration:.init(enabled:false))
        _=try await empty.run(["init","-b","main"])
        for(key,value)in [("user.name","Empty staging QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport","true")] {_=try await empty.run(["config",key,value])}
        _=try await empty.run(["commit","--allow-empty","-m","empty source"])
        let emptyOwner=try await c.open(empty)
        try require(emptyOwner.model.stagedEntries.isEmpty && emptyOwner.model.unstagedEntries.isEmpty,"Empty fixture contains changes")
        try require(emptyOwner.model.selection.isEmpty && emptyOwner.model.guiPatch==nil,"Empty/no-selection pane retained a blank preview instead of its selection prompt")
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            emptyOwner.window?.appearance=NSAppearance(named:appearance)
            await Task.yield()
            for staged in [false,true] {
                let native=try table(emptyOwner,staged:staged)
                try require(native.numberOfRows==0 && native.headerView != nil && native.enclosingScrollView != nil,"Empty table lost its native frame/header/scroll surface")
                try require(emptyOwner.model.guiFileListMessage(staged:staged) != nil,"Empty table lacks explicit feedback")
            }
            try capture(emptyOwner,to:c.root.appendingPathComponent("commit-gui-empty-"+name+".png"))
        }
        // Forced retirement fences a read held beyond cancellation and cannot
        // revive the source table when the accepted worker eventually returns.
        model.queryCommitStatus={_,owned in token=owned;return await withCheckedContinuation{reply=$0}}
        model.reload();try await wait{reply != nil && model.busy}
        owner.close();try require(token?.isCancelled==true,"Close did not cancel accepted staging reload")
        release();try await wait{CommitWindowModel.activeReloads==0 && !model.fileWorkPending}
        try require(owner.window?.isVisible != true && model.guiPatch==nil && model.reloadPhase==nil,"Retired loading Commit revived its staging viewer or retained an obsolete phase")
        try await c.preserved()
    }
}
