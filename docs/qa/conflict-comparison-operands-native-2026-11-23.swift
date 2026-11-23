// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func quietConflictOperandOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;quietConflictOperandOrder(mode,relativeTo:number)}
    @objc func quietConflictOperandSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {sheet.alphaValue=0;quietConflictOperandSheet(sheet,completionHandler:completionHandler)}
}

/// Actual native Resolve menus + configured Root handoff. External document
/// presentation is intercepted; repositories, defaults and windows are private.
@MainActor @main enum ConflictComparisonOperandsVerification {
    typealias Prior=StatusPrimaryActivationVerification
    static func require(_ value:Bool,_ text:String,line:Int = #line)throws {try Prior.require(value,"Conflict operands \(line): "+text)}
    static func wait(_ text:String,_ ready:()->Bool)async throws {try await Prior.wait(text,ready)}
    static var drained:Bool {Prior.drained() && ResolveWindowController.activeReleases==0 && SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowController.activeInlineReleases==0}
    struct Delivery {let snapshot:RevisionComparisonSnapshot,file:CommitFile}
    @MainActor final class Context {
        let folder:URL,repo:GitRepository,prefs:UserDefaults,suite:String
        let paths=["a conflict 雪\n[*].txt","b conflict.txt","c conflict\t.txt","d conflict.txt"]
        var head=Data(),index=Data(),working:[String:Data]=[:],owners:[NSWindowController]=[],roots:[RepositoryModel]=[],unblock:[()->Void]=[]
        init(base:URL,git:URL)throws {
            folder=base.standardizedFileURL;try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            repo=GitRepository(root:folder,executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.ConflictOperands."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            for key in ["UseLibgit2","EnableGravatar","EnableLogCache","ConfirmKillProcess"] {prefs.set(false,forKey:key)}
            prefs.set(true,forKey:"ShowAppContextMenuIcons");prefs.set(3,forKey:"NumDiffWarning")
        }
        func setup(unborn:Bool=false)async throws {
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Conflict Operand QA"),("user.email","conflict-operands@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
            if !unborn {
                for path in paths {try Data("HEAD historical contents\n".utf8).write(to:folder.appendingPathComponent(path))}
                try await repo.stage(paths);_=try await repo.commit(message:"Historical comparison operand distinct from stage 1")
            }
            var objects:[String]=[]
            for text in ["ancestor stage one\n","index mine\n","index theirs\n"] {objects.append(try await repo.run(["hash-object","-w","--stdin"],input:Data(text.utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines))}
            var records=Data()
            for path in paths {
                records.append(contentsOf:("0 "+String(repeating:"0",count:40)+"\t"+path+"\0").utf8)
                for number in 1...3 {records.append(contentsOf:"100644 \(objects[number-1]) \(number)\t\(path)\0".utf8)}
                let bytes=Data("<<<<<<< mine\nworking conflict\n=======\nother\n>>>>>>> theirs\n".utf8)
                try bytes.write(to:folder.appendingPathComponent(path));working[path]=bytes
            }
            _=try await repo.run(["update-index","-z","--index-info"],input:records)
            try MergeToolPreferences.load(from:prefs).save(to:prefs)
            head=try await repo.run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1).stdout
            index=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
        }
        func root()->RepositoryModel {
            let value=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotStore:FinderSnapshotStore(url:folder.appendingPathComponent("finder.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:folder.appendingPathComponent("marks.json")),cachePersistenceDefaults:prefs)
            value.fileComparisonPreferences=prefs;roots.append(value);return value
        }
        func own(_ value:NSWindowController) {owners.append(value);value.window?.alphaValue=0;value.window?.setFrameOrigin(.init(x:-24000,y:-24000));value.showWindow(nil)}
        func ready(_ owner:ResolveWindowController)async throws {
            try await wait("Actual Resolve report not ready") {
                owner.window?.contentView?.layoutSubtreeIfNeeded()
                return owner.model.canInteract && owner.model.entries.count==paths.count &&
                    Prior.views(owner.window?.contentView).compactMap{$0 as? ConflictReportNativeTable}.contains{$0.numberOfRows==paths.count && $0.window===owner.window && !$0.isHiddenOrHasHiddenAncestor}
            }
        }
        func mounted(_ root:RepositoryModel)async throws->ResolveWindowController {
            let owner=ResolveWindowController(repository:repo,access:nil,paths:[],preferences:prefs)
            owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000))
            root.configureResolveInteractions(owner,repository:repo,access:nil,preferences:prefs)
            owner.showWindow(nil);owner.model.loadInitial()
            try await wait("Actual Resolve report did not mount") {
                owner.window?.contentView?.layoutSubtreeIfNeeded()
                guard owner.model.canInteract,owner.model.entries.count==self.paths.count,
                      let table=try? ConflictComparisonOperandsVerification.table(owner),let coordinator=table.dataSource as? ConflictReportTable.Coordinator else{return false}
                return table.numberOfRows==self.paths.count && coordinator.owner.rows.count==self.paths.count && table.isEnabled && !table.isHiddenOrHasHiddenAncestor
            }
            return owner
        }
        func preserved()async throws {
            try require(try await repo.run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1).stdout==head,"Read-only comparison changed HEAD")
            try require(try Data(contentsOf:folder.appendingPathComponent(".git/index"))==index,"Read-only comparison changed exact index")
            for(path,bytes)in working {try require(try Data(contentsOf:folder.appendingPathComponent(path))==bytes,"Read-only comparison changed "+path)}
        }
        func cleanup()async throws {
            owners.forEach{$0.close()};unblock.forEach{$0()};unblock=[];roots.forEach{$0.stopMonitoringForTermination()}
            try await wait("Owned conflict operand windows/workers did not drain") {drained && roots.allSatisfy{!$0.hasPendingRepositoryWork} && owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil}}
            for owner in owners.compactMap({$0 as? ResolveWindowController}) {owner.model.onWorkingFileComparison=nil;owner.model.onWorkingFileUnifiedComparison=nil;owner.model.readWorkingComparisonStatus=nil;owner.model.confirmPrimaryFileActivation=nil}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func table(_ owner:ResolveWindowController)throws->ConflictReportNativeTable {
        try Prior.unwrap(Prior.views(owner.window?.contentView).compactMap{$0 as? ConflictReportNativeTable}.first{$0.window===owner.window},"Resolve native report missing")
    }
    @discardableResult static func select(_ owner:ResolveWindowController,_ paths:[String])async throws->[String] {
        let table=try table(owner),rows=owner.model.sortedReportEntries.map(\.path),wanted=GitPathSet(paths)
        try require(rows.filter{wanted.contains($0)}.count==wanted.count,"Required native conflict identity absent")
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(rows.indices.filter{wanted.contains(rows[$0])}))
        try await wait("Actual Resolve selected projection did not settle"){owner.model.selection==wanted && table.selectedRowIndexes==IndexSet(rows.indices.filter{wanted.contains(rows[$0])})}
        return rows.filter{wanted.contains($0)}
    }
    static func nativeMenu(_ owner:ResolveWindowController,alternate:Bool=false)async throws->NSMenu {
        let table=try table(owner)
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        let row=try Prior.unwrap(table.selectedRowIndexes.first,"No selected Resolve row"),column=min(1,table.tableColumns.count-1)
        let rect=table.frameOfCell(atColumn:column,row:row).intersection(table.visibleRect)
        try require(!rect.isEmpty && table.window===owner.window,"Resolve menu target clipped or reparented")
        let point=table.convert(.init(x:rect.midX,y:rect.midY),to:nil)
        let event=try Prior.unwrap(NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:owner.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1),"Native menu event missing")
        return try ComparisonToolInvocation.$alternate.withValue(alternate){
            let menu=try Prior.unwrap(table.menu(for:event),"Actual Resolve context menu unavailable")
            let before=menuDiagnostic(menu)
            // menu(for:) prepares the pointed row. AppKit's subsequent menu
            // tracking invokes this real delegate before item inspection.
            menu.delegate?.menuNeedsUpdate?(menu)
            print("CONFLICT OPERAND MENU: before=\(before),after=\(menuDiagnostic(menu)),delegate=\(String(describing:menu.delegate)),ownerVisible=\(owner.window?.isVisible == true),busy=\(owner.model.busy),pending=\(owner.model.primaryActivationPending),available=\(owner.model.canInteract),nativeEnabled=\(table.isEnabled),nativeOwner=\(table.window === owner.window),nativeRows=\(table.numberOfRows),nativeSelected=\(Array(table.selectedRowIndexes)),pointedRow=\(row),column=\(column),rect=\(rect),selection=\(String(reflecting:Array(owner.model.selection))),modelRows=\(String(reflecting:owner.model.sortedReportEntries.prefix(16).map(\.path))),nativePaths=\(String(reflecting:(table.dataSource as? ConflictReportTable.Coordinator)?.owner.rows.prefix(16).map(\.path)))")
            return menu
        }
    }
    static func menuDiagnostic(_ menu:NSMenu)->String {
        menu.items.prefix(24).map {item in
            "\(String(reflecting:item.title)):enabled=\(item.isEnabled),icon=\(item.image != nil),children=\(item.submenu.map{menuDiagnostic($0)} ?? "[]")"
        }.joined(separator:" | ")
    }
    static func invoke(_ menu:NSMenu,_ title:String)throws->NSMenuItem {
        let item=try Prior.unwrap(menu.items.first{$0.title==NSLocalizedString(title,comment:"")},"Actual menu missing "+title+"; "+menuDiagnostic(menu))
        try require(item.isEnabled && item.image != nil,"Resolve command lost source icon/availability")
        try require(NSApp.sendAction(try Prior.unwrap(item.action,"Menu action absent"),to:item.target,from:item),"Native action was not dispatched")
        return item
    }
    static func working(base:URL,git:URL,unborn:Bool)async throws {
        let c=try Context(base:base,git:git)
        do {
            try await c.setup(unborn:unborn);let root=c.root(),owner=try await c.mounted(root),model=owner.model
            let ordered=try await select(owner,c.paths),stages=model.sortedReportEntries,configured=try Prior.unwrap(model.onWorkingFileComparison,"Root did not configure working comparison")
            var plans:[StatusListPrimaryActivation]=[],values:[Delivery]=[],warningDetached=true
            model.onWorkingFileComparison={plan,token in plans.append(plan);try await configured(plan,token)}
            root.fileComparisonPresentation={snapshot,file in values.append(Delivery(snapshot:snapshot,file:file));warningDetached = warningDetached && owner.window?.attachedSheet==nil}
            let menu=try await nativeMenu(owner),item=try invoke(menu,"Compare with base")
            try await wait("Actual selection warning absent"){owner.window?.attachedSheet != nil}
            let warning=owner.window!.attachedSheet!,yes=try Prior.unwrap(Prior.views(warning.contentView).compactMap{$0 as? NSButton}.first{$0.title=="Yes"},"Actual Yes button absent")
            try require(values.isEmpty && model.primaryActivationPending && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Warning released source/Quit ownership")
            yes.performClick(nil)
            try await wait("Configured Root comparison did not drain"){!model.busy && !model.primaryActivationPending && !root.hasPendingRepositoryWork && warning.sheetParent==nil}
            try require(plans.count==1 && values.map{$0.file.path}==ordered && warningDetached,"Compare lost order, repeated warning or presented before sheet detachment")
            let plan=plans[0],base:ComparisonRevision=unborn ? .emptyTree:.revision(String(decoding:c.head,as:UTF8.self).trimmingCharacters(in:.newlines))
            try require(plan.base==base && plan.expectedConflicts==stages && plan.preferences === c.prefs && plan.repository.libgit2Configuration?.enabled==false && !plan.isRebase,"Accepted base/stages/backend/preferences/orientation changed")
            try require(plan.actions.allSatisfy{if case .comparison = $0{return true};return false},"Explicit Compare entered conflict editor")
            for value in values {
                try require(value.snapshot.from==base && value.snapshot.to == .workingTree && value.file.action==(unborn ? "A":"M"),"Wrong empty/HEAD direction or raw conflict flags")
                let doc=try await c.repo.comparisonFile(value.snapshot,path:value.file.path)
                try require(doc.base.bytes==Data((unborn ? "":"HEAD historical contents\n").utf8) && doc.destination.bytes==c.working[value.file.path],"Explicit working Compare used stage 1 or index side")
            }
            _=NSApp.sendAction(item.action!,to:item.target,from:item)
            try require(plans.count==1,"Native command receipt executed twice")
            var unified:Data?,unifiedAlternate=false,unifiedToken:OperationCancellation?,unifiedDetached=false
            try require(model.onWorkingFileUnifiedComparison != nil,"Root did not configure working unified route")
            model.onFileUnified={bytes,alternate,token in unified=bytes;unifiedAlternate=alternate;unifiedToken=token;unifiedDetached=owner.window?.attachedSheet==nil}
            _ = try invoke(try await nativeMenu(owner,alternate:true),"Show changes as unified diff")
            try await wait("Configured unified HEAD/working route did not drain"){!model.busy && !model.primaryActivationPending && !root.hasPendingRepositoryWork}
            if unborn {
                // Unlike the two-pane DiffNull path, GNUDIFF1 names HEAD and
                // must refuse an initial repository without that revision.
                try require(unified==nil && model.error != nil,"Unborn unified invented a historical HEAD")
                model.error=nil;try await wait("Unborn unified error did not detach"){owner.window?.attachedSheet==nil}
            } else {
                let patch=try Prior.unwrap(unified,"Unified route did not present raw bytes"),text=String(decoding:patch,as:UTF8.self)
                try require(unifiedAlternate && unifiedToken?.isCancelled==false && unifiedDetached,"Unified lost Shift/token or introduced many-diff warning")
                try require(text.contains("diff --git") && text.contains("+working conflict") && text.contains("-HEAD historical contents") && !text.contains("-ancestor stage one"),"Unified bytes compare stage1/index instead of captured HEAD/working")
                // GNUDIFF1 appends one patch per selected report row; do not turn
                // the operation into a fresh all-tree diff or one view per row.
                let patchHeaders=text.components(separatedBy:"diff --git ").dropFirst().map{String($0.prefix(180))}
                try require(patchHeaders.count==ordered.count,"Unified did not aggregate exactly the selected rows")
                var expectedPatch=Data()
                for path in ordered {
                    let direct=try await c.repo.run(["diff","--stat","-p","--no-ext-diff","--no-textconv","--no-color","--end-of-options",String(decoding:c.head,as:UTF8.self).trimmingCharacters(in:.newlines),"--",path],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"])
                    expectedPatch.append(direct.stdout)
                }
                try require(patch==expectedPatch,"Unified lost report order, raw bytes or per-path statistics")
            }

            // Retain the ancestor viewer and the literal two-file command as
            // separate operations; neither becomes selected-row HEAD Compare.
            var ancestor:ConflictBaseComparison?,pairs:[[String]]=[]
            model.onComparison={ancestor=$0};model.viewConflictBase([ordered[0]])
            try await wait("Explicit stage-1 viewer did not drain"){!model.busy}
            try require(ancestor?.document.base.bytes==Data("ancestor stage one\n".utf8) && plans.count==1,"Stage-1 viewer was replaced by HEAD comparison")
            model.onFilePair={pairs.append($0)};_ = try await select(owner,Array(ordered.prefix(2)))
            _ = try invoke(try await nativeMenu(owner),ResolveFileCommand.compareTwo.title)
            try await wait("Literal two-file command did not drain"){!model.busy}
            try require(pairs==[Array(ordered.prefix(2))] && plans.count==1,"Two-file command became a per-row historical comparison")
            try await c.preserved();try await c.cleanup();print("PASS CONFLICT OPERAND COHORT: "+(unborn ? "unborn":"working"))
        } catch {try? await c.cleanup();throw error}
    }
    static func retirement(base:URL,git:URL)async throws {
        let c=try Context(base:base,git:git)
        do {
            try await c.setup();let root=c.root(),owner=try await c.mounted(root),model=owner.model
            _ = try await select(owner,c.paths)
            var delivered=0,release:CheckedContinuation<Bool,Never>?
            c.unblock.append{release?.resume(returning:false);release=nil}
            root.fileComparisonPresentation={_,_ in delivered += 1}
            model.confirmPrimaryFileActivation={_ in await withCheckedContinuation{release=$0}}
            for reason in ["selection","settings","backend","stages","orientation","cancel","quit"] {
                _ = try await select(owner,c.paths)
                _ = try invoke(try await nativeMenu(owner),"Compare with base")
                try await wait("Held comparison warning absent for "+reason){release != nil}
                let oldDiff=c.prefs.data(forKey:"TurtleGit.DiffTools"),marker=c.folder.appendingPathComponent(".git/rebase-merge")
                switch reason {
                case "selection":model.selection=GitPathSet([c.paths[0]])
                case "settings":c.prefs.set(Data("retired tool intent".utf8),forKey:"TurtleGit.DiffTools")
                case "backend":c.prefs.set(true,forKey:"UseLibgit2")
                case "stages":
                    let oid=try await c.repo.run(["hash-object","-w","--stdin"],input:Data("changed stage during warning\n".utf8)).text.trimmingCharacters(in:.newlines)
                    _=try await c.repo.run(["update-index","-z","--index-info"],input:Data("100644 \(oid) 2\t\(c.paths[0])\0".utf8))
                case "orientation":try FileManager.default.createDirectory(at:marker,withIntermediateDirectories:true)
                case "cancel":model.cancel()
                case "quit":model.confirmingQuit=true
                default:break
                }
                try require(model.primaryActivationPending && ResolveWindowModel.activeOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired warning dropped worker/Quit ownership for "+reason)
                release?.resume(returning:true);release=nil
                try await wait("Retired comparison did not drain for "+reason){!model.busy && !model.primaryActivationPending && !root.hasPendingRepositoryWork}
                try require(delivered==0 && owner.window?.isVisible==true,"Retired comparison launched or closed source for "+reason)
                if reason=="stages" || reason=="orientation" {try require(model.error != nil,"Changed stages/orientation was not rejected")}
                if reason=="stages" {try c.index.write(to:c.folder.appendingPathComponent(".git/index"),options:.atomic)}
                if reason=="orientation" {try FileManager.default.removeItem(at:marker)}
                if let oldDiff {c.prefs.set(oldDiff,forKey:"TurtleGit.DiffTools")} else {c.prefs.removeObject(forKey:"TurtleGit.DiffTools")}
                c.prefs.set(false,forKey:"UseLibgit2");model.confirmingQuit=false;model.error=nil
                try await wait("Retired comparison error sheet did not detach"){owner.window?.attachedSheet==nil}
                try await c.preserved()
            }
            model.confirmPrimaryFileActivation=nil
            _ = try await select(owner,c.paths);_ = try invoke(try await nativeMenu(owner),"Compare with base")
            try await wait("Actual close-cancellation comparison sheet absent"){owner.window?.attachedSheet != nil}
            let question=owner.window!.attachedSheet!
            try require(!owner.windowShouldClose(owner.window!),"Source close bypassed live comparison warning")
            try await wait("Source-close cancellation did not drain paired warning"){!model.busy && !model.primaryActivationPending && question.sheetParent==nil && owner.window?.attachedSheet !== question}
            try require(delivered==0 && owner.window?.isVisible==true,"Cancelled native warning launched/closed source")
            model.confirmPrimaryFileActivation={_ in await withCheckedContinuation{release=$0}}
            // A suspended selected raw-status read is still owned by its source,
            // including actual forced close and application Quit admission.
            var rawRelease:CheckedContinuation<Void,Never>?,readToken:OperationCancellation?,closed=0
            owner.onClosed={closed += 1};c.unblock.append{rawRelease?.resume();rawRelease=nil}
            model.readWorkingComparisonStatus={paths,token in
                try require(GitPathSet(paths)==GitPathSet(c.paths),"Scoped raw read widened/lost selected paths")
                let result=try await c.repo.run(["status","--porcelain=v1","-z","--untracked-files=no","--"]+paths,environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:token)
                readToken=token;await withCheckedContinuation{rawRelease=$0};return StatusEntry.parse(result.stdout)
            }
            _ = try await select(owner,c.paths);_ = try invoke(try await nativeMenu(owner),"Compare with base")
            try await wait("Scoped orientation preflight did not hold"){rawRelease != nil}
            let preflightMarker=c.folder.appendingPathComponent(".git/rebase-merge")
            try FileManager.default.createDirectory(at:preflightMarker,withIntermediateDirectories:true)
            rawRelease?.resume();rawRelease=nil
            try await wait("Changed orientation after raw read did not refuse"){!model.busy && !model.primaryActivationPending && model.error != nil}
            try require(release==nil && delivered==0 && owner.window?.isVisible==true,"Changed raw-read orientation reached warning/child or closed source")
            try FileManager.default.removeItem(at:preflightMarker);model.error=nil
            try await wait("Raw-preflight error sheet did not detach"){owner.window?.attachedSheet==nil}
            try await c.preserved()
            _ = try await select(owner,c.paths);_ = try invoke(try await nativeMenu(owner),"Compare with base")
            try await wait("Scoped raw read did not hold"){rawRelease != nil}
            owner.close()
            try require(readToken?.isCancelled==true && closed==0 && model.primaryActivationPending && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced close released actual read/Quit before acknowledgement")
            rawRelease?.resume();rawRelease=nil
            try await wait("Forced comparison source did not drain"){closed==1 && !model.primaryActivationPending && !root.hasPendingRepositoryWork && drained}
            try require(delivered==0,"Forced source close presented a late comparison")
            try await c.preserved();try await c.cleanup();print("PASS CONFLICT OPERAND COHORT: retirement")
        } catch {try? await c.cleanup();throw error}
    }
    static func syncBoundary(base:URL,git:URL)async throws {
        let c=try Context(base:base,git:git)
        do {
            try await c.setup();let owner=SynchronizationWindowController(repository:c.repo,access:nil,preferences:c.prefs),model=owner.model
            c.own(owner)
            try await wait("Sync initial read did not drain"){!model.busy && !model.hasPendingInlineWork}
            model.tab=6;model.refreshConflictFiles()
            try await wait("Actual Sync conflict report did not mount") {owner.window?.contentView?.layoutSubtreeIfNeeded();return !model.conflictFileActions.busy && model.conflicts.count==c.paths.count}
            let menu=model.conflictMenu(c.paths)
            let allowed:Set<StatusFileCommand>=[.log,.editor,.open,.openWith,.reveal]
            try require(menu.commands.allSatisfy{allowed.contains($0)},"Sync source mask acquired unsupported working Compare")
            try await c.preserved();try await c.cleanup();print("PASS CONFLICT OPERAND COHORT: sync")
        } catch {try? await c.cleanup();throw error}
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietConflictOperandOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietConflictOperandSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quiet);method_exchangeImplementations(sheet,quietSheet)
        defer{method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quiet)}
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),only=Set(CommandLine.arguments.dropFirst(3))
        try require(only.isSubset(of:["working","unborn","retirement","sync"]),"Unknown conflict operand cohort")
        if only.isEmpty || only.contains("working") {try await working(base:base.appendingPathComponent("working"),git:git,unborn:false)}
        if only.isEmpty || only.contains("unborn") {try await working(base:base.appendingPathComponent("unborn"),git:git,unborn:true)}
        if only.isEmpty || only.contains("retirement") {try await retirement(base:base.appendingPathComponent("retirement"),git:git)}
        if only.isEmpty || only.contains("sync") {try await syncBoundary(base:base.appendingPathComponent("sync"),git:git)}
        print("PASS: Conflict comparison operands; actual native Resolve Compare uses accepted HEAD/empty rows and exact stages, separate ancestor/two-file meanings, cancellation/late replies/forced-close/Quit drain; Sync source mask retained")
    }
}
