// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// One real Root-configured Log over private history and working conflicts.
/// External application execution is injected; native conflict children are real.
@MainActor enum LogPrimaryActivationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"Log primary \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func wait(_ label:String,window:NSWindow?=nil,diagnostic:()->String={""},_ condition:()->Bool)async throws {
        for _ in 0..<3500 {window?.contentView?.layoutSubtreeIfNeeded();if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Log primary timeout: "+label+" "+diagnostic())
    }
    static func key(_ window:NSWindow)->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!}
    @MainActor final class Gate<Value> {
        private var reply:CheckedContinuation<Value,Never>?
        var entered:Bool {reply != nil}
        func read()async->Value {await withCheckedContinuation{reply=$0}}
        func finish(_ value:Value){let old=reply;reply=nil;old?.resume(returning:value)}
    }
    @MainActor final class Context {
        let base:URL,git:URL,suite="TurtleGit.LogPrimary."+UUID().uuidString,foreignSuite="TurtleGit.LogPrimary.Foreign."+UUID().uuidString
        let preferences:UserDefaults,foreign:UserDefaults,clipboard=NSPasteboard.withUniqueName()
        let conflict="a-conflict 雪.txt",normal="b-normal.md",second="c-second.txt",unknown="d-untracked.txt"
        var root:URL {base.appendingPathComponent("repository")}
        var quickHold:URL {base.appendingPathComponent("quick-hold")}
        var quickEntered:URL {base.appendingPathComponent("quick-entered")}
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        var repo:GitRepository!,workspace:RepositoryModel!,owner:LogWindowController?
        var children:[NSWindowController]=[],plans:[LogFilePrimaryActivation]=[],forward=true
        var comparisons:[(ComparisonRevision,ComparisonRevision,String)]=[],externalCalls:[(String,Bool,NSWindow?,MergeToolPreferences,Bool)]=[]
        var readGate:Gate<ConflictEntry>?,warningGate:Gate<Bool>?,readToken:OperationCancellation?,heldEntry:ConflictEntry?
        weak var lease:RepositoryAccessLease?
        var preparingPanel:NSWindow?,presentationDrains:[Bool]=[],head="",mergeParents:[String]=[],stageBlobs:[String]=[]
        var warnings:[Int]=[],extraWarnings=0,changes=0
        init(base:URL,git:URL) {self.base=base.standardizedFileURL;self.git=git;preferences=UserDefaults(suiteName:suite)!;foreign=UserDefaults(suiteName:foreignSuite)!
            for key in ["UseLibgit2","EnableLogCache","EnableGravatar"] {preferences.set(false,forKey:key)}
            preferences.set(true,forKey:"LogIncludeWorkingTreeChanges");preferences.set(3,forKey:"NumDiffWarning");preferences.set(true,forKey:"RefreshFileListAfterResolvingConflict");preferences.set(true,forKey:"ConflictDontGuessBranchNames")
            foreign.set(true,forKey:"UseLibgit2");foreign.set(false,forKey:"ConflictDontGuessBranchNames")
        }
        func prepare()async throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            // Bundled associations carry UUID identities. Freeze one private
            // persisted value before independent model/Root snapshot loads.
            try MergeToolPreferences.load(from:preferences).save(to:preferences)
            let helper=base.appendingPathComponent("held-helper")
            let wrapper="""
            #!/bin/sh
            unmerged=no
            for argument in "$@"; do
              if [ "$argument" = --unmerged ]; then unmerged=yes; fi
            done
            if [ "$unmerged" = yes ] && [ -f \(quote(quickHold.path)) ]; then
              : > \(quote(quickEntered.path))
              while [ -f \(quote(quickHold.path)) ]; do /bin/sleep 0.05; done
            fi
            exec \(quote(git.path)) "$@"
            """
            try wrapper.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
            repo=GitRepository(root:root,executable:helper,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for (key,value) in [("user.name","Primary QA"),("user.email","primary@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            func write(_ value:String)throws {for name in [conflict,normal,second] {try Data(value.utf8).write(to:root.appendingPathComponent(name))}}
            try write("base\n");try await repo.stage(["."]);_=try await repo.commit(message:"Base")
            _=try await repo.run(["checkout","-b","side"]);try write("side\n");try await repo.stage(["."]);_=try await repo.commit(message:"Side")
            let side=try await repo.rebaseCommit("HEAD").hash
            _=try await repo.run(["checkout","main"]);try write("main\n");try await repo.stage(["."]);_=try await repo.commit(message:"Main")
            let main=try await repo.rebaseCommit("HEAD").hash
            try write("merged\n");try await repo.stage(["."])
            let tree=String(decoding:try await repo.run(["write-tree"]).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
            head=String(decoding:try await repo.run(["commit-tree",tree,"-p",main,"-p",side,"-m","Merge"]).stdout,as:UTF8.self).trimmingCharacters(in:.newlines);mergeParents=[main,side]
            _=try await repo.run(["reset","--hard",head])
            for text in ["base\n","mine\n","theirs\n"] {stageBlobs.append(String(decoding:try await repo.run(["hash-object","-w","--stdin"],input:Data(text.utf8)).stdout,as:UTF8.self).trimmingCharacters(in:.newlines))}
            try await installConflict()
            try Data("normal dirty\n".utf8).write(to:root.appendingPathComponent(normal));try Data("second dirty\n".utf8).write(to:root.appendingPathComponent(second));try Data("untracked\n".utf8).write(to:root.appendingPathComponent(unknown))
            workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotStore:FinderSnapshotStore(url:base.appendingPathComponent("finder-snapshot.json")),savedAccessStore:try RepositoryAccessStore(storageURL:base.appendingPathComponent("repository-access.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:base.appendingPathComponent("comparison-marks.json")),cachePersistenceDefaults:preferences);workspace.fileComparisonPreferences=preferences
            workspace.logWindowPresentation={[weak self] controller in guard let self else{return};self.owner=controller;controller.window?.alphaValue=0;controller.showWindow(nil);(controller.window as? LogHistoryWindow)?.commandKeyWindow={[weak controller] in controller?.window};controller.model.clipboard=self.clipboard}
            workspace.fileComparisonQuestion={[weak self] _ in self?.extraWarnings += 1;return true}
            workspace.fileComparisonPresentation={[weak self] snapshot,file in self?.comparisons.append((snapshot.from,snapshot.to,file.path))}
            workspace.conflictWindowPresentation={[weak self] child in
                guard let self else{return}
                self.presentationDrains.append(self.owner?.window?.attachedSheet==nil && self.preparingPanel?.sheetParent==nil)
                self.children.append(child);child.window?.alphaValue=0;child.showWindow(nil)
            }
            workspace.openExternalConflict={[weak self] repository,access,path,alternate,owner,_,_,_,tools in
                guard let self else{return false}
                self.externalCalls.append((path,alternate,owner,tools,access === self.lease))
                return false
            }
            workspace.readConflictEditorEntry={[weak self] repository,path,token in
                let entry=try await repository.conflictEditorEntry(path:path,cancellation:token)
                guard let self else{return entry}
                self.readToken=token;self.heldEntry=entry;self.preparingPanel=self.owner?.window?.attachedSheet
                if let gate=self.readGate {return await gate.read()}
                return entry
            }
            var access:RepositoryAccessLease?=RepositoryAccessLease(url:root);lease=access
            workspace.showLog(repository:repo,access:access,paths:[],preferences:preferences);access=nil
            try await wait("Root-configured Log",window:owner?.window){self.owner != nil && self.owner?.model.busy==false && self.owner?.model.pendingHistoryLoads==0 && self.owner?.model.files.count==4}
            let model=try unwrap(owner?.model,"Log owner missing"),launch=try unwrap(model.onPrimaryFileActivation,"Root did not configure owned primary launch")
            model.onPrimaryFileActivation={[weak self] plan,token in guard let self else{throw OperationCancellationFailure.cancelled};self.plans.append(plan);if self.forward {try await launch(plan,token)}}
            model.confirmPrimaryFileActivation={[weak self] count in guard let self else{return false};self.warnings.append(count);if let gate=self.warningGate {return await gate.read()};return true}
        }
        func installConflict(path:String?=nil)async throws {
            let path=path ?? conflict,zero=String(repeating:"0",count:40)
            let rows="0 "+zero+"\t"+path+"\0"+stageBlobs.enumerated().map{"100644 "+$0.element+" "+String($0.offset+1)+"\t"+path+"\0"}.joined()
            _=try await repo.run(["update-index","-z","--index-info"],input:Data(rows.utf8))
            try Data("<<<<<<< mine\nmine\n=======\ntheirs\n>>>>>>> theirs\n".utf8).write(to:root.appendingPathComponent(path))
        }
        func table()throws->LogChangedFileNativeTable {try unwrap(views(owner?.window?.contentView).compactMap{$0 as? LogChangedFileNativeTable}.first,"Actual Log file report missing")}
        func focusDiagnostic(_ table:LogChangedFileNativeTable,_ window:NSWindow)->String {
            let responder=window.firstResponder.map{String(reflecting:type(of:$0))} ?? "nil"
            return "responder=\(responder), currentTable=\((try? self.table()) === table), attached=\(table.window === window), visible=\(window.isVisible), hidden=\(table.isHiddenOrHasHiddenAncestor), enabled=\(table.isEnabled), ownerAvailable=\(table.ownerAvailable()), inspect=\(owner?.model.canInspectHistory == true), rows=\(table.numberOfRows)/\(owner?.model.fileTableRows.count ?? -1), selection=\(table.selectedRowIndexes), sheet=\(window.attachedSheet != nil), modal=\(NSApp.modalWindow != nil)"
        }
        func select(_ ids:GitPathSet)async throws {
            let model=try unwrap(owner?.model,"Source Log missing"),table=try table(),window=try unwrap(owner?.window,"Source window missing")
            func ready()->Bool {
                owner?.window === window && !model.isInvalidated && !model.busy && model.canInspectHistory &&
                (try? self.table()) === table && table.window === window && window.isVisible &&
                !table.isHiddenOrHasHiddenAncestor && table.isEnabled && table.ownerAvailable() &&
                table.numberOfRows==model.fileTableRows.count
            }
            // Row count/model settlement may precede AppKit's actual enable
            // update. Never send Return through a table that refused focus.
            try await wait("rendered source rows and native admission",window:window,diagnostic:{self.focusDiagnostic(table,window)}){ready()}
            let rows=model.fileTableRows,indexes=IndexSet(rows.indices.filter{rows[$0].file != nil && ids.contains(rows[$0].rawID)})
            try require(indexes.count==ids.count,"Native selected occurrence missing")
            table.selectRowIndexes(indexes,byExtendingSelection:false)
            try await wait("native selected IDs and readiness",window:window,diagnostic:{self.focusDiagnostic(table,window)}){ready() && model.selectedFiles==ids && table.selectedRowIndexes==indexes}
            try require(window.makeFirstResponder(table),"Source window rejected native table focus; "+focusDiagnostic(table,window))
            try await wait("native first-responder ownership",window:window,diagnostic:{self.focusDiagnostic(table,window)}){ready() && window.firstResponder === table}
        }
        func activate()throws {
            let table=try table(),window=try unwrap(owner?.window,"Source window missing")
            try require(table.window === window && table.isEnabled && table.ownerAvailable() && window.isVisible && !table.isHiddenOrHasHiddenAncestor,"Source table lost native admission; "+focusDiagnostic(table,window))
            try require(window.firstResponder===table,"Source table does not own Return; "+focusDiagnostic(table,window))
            // The native report captures Shift from its actual key event before
            // asynchronous preparation; a TaskLocal value cannot substitute it.
            table.keyDown(with:LogPrimaryActivationVerification.key(window))
        }
        func working()async throws {
            let model=try unwrap(owner?.model,"Working Log missing")
            model.select([""])
            try await wait("working source snapshot",window:owner?.window){!model.busy && model.selectedWorkingTree && model.files.count==4}
        }
        func finishRead(){if let entry=heldEntry {readGate?.finish(entry)};readGate=nil;heldEntry=nil}
        func cleanup()async throws {
            try? FileManager.default.removeItem(at:quickHold)
            warningGate?.finish(false);warningGate=nil;finishRead();workspace?.cancelConflictEditorPreparations()
            children.forEach{$0.close()};owner?.close();workspace?.stopMonitoringForTermination()
            try await wait("owned primary/child cleanup") {
                FileListComparisonSession.activeOperations==0 && LogWindowModel.activeFileNavigationActivities==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0 && LogWindowModel.activeFileOpenReads==0 && self.workspace?.conflictEditorPreparationCount==0 && self.workspace?.hasPendingFinderPublication != true && self.workspace?.hasPendingRepositoryWork != true && self.children.compactMap{$0 as? TextConflictWindowController}.allSatisfy{!$0.mergeToolHasPendingWork} && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}
            }
            MergeToolApplication.discardAll();children=[];plans=[];owner=nil;clipboard.releaseGlobally();preferences.removePersistentDomain(forName:suite);foreign.removePersistentDomain(forName:foreignSuite)
        }
    }
    static func verify(base:URL,git:URL)async throws {
        let c=Context(base:base,git:git)
        do {
            try await c.prepare()
            let owner=try unwrap(c.owner,"Source owner missing"),model=owner.model,window=try unwrap(owner.window,"Source window missing")
            let savedIdentity=ConflictIdentityOptions(defaults:c.preferences),savedTools=MergeToolPreferences.load(from:c.preferences)
            // Historical parent occurrences retain distinct from revisions even
            // when they name the very same destination path.
            c.forward=false;model.select([c.head]);try await wait("historical parent details",window:window){!model.busy && model.fileGroups.count==2 && model.files.count==6}
            let historical=model.fileTableRows.compactMap(\.file).filter{$0.path==c.normal}
            try require(historical.count==2 && GitPathSet(historical.map(\.id)).count==2,"Parent occurrences collapsed")
            try await c.select(GitPathSet(historical.map(\.id)));try c.activate()
            try await wait("historical plan settlement"){!model.fileNavigationReadPending && !model.busy && c.plans.count==1}
            let old=try unwrap(c.plans.first,"Historical plan missing")
            try require(old.actions.count==2 && old.actions.map{$0.file.id}==historical.map(\.id),"Historical primary lost occurrence order")
            for (index,action) in old.actions.enumerated() {if case .comparison(let file,let from,let to)=action {try require(file.id==historical[index].id && from == .revision(c.mergeParents[file.parentIndex ?? 0]) && to == .revision(c.head),"Historical comparison retargeted parent") } else {throw Failure(description:"Historical row became working/conflict action")}}
            c.plans=[];c.forward=true;try await c.working()
            let ids=GitPathSet(model.fileTableRows.compactMap(\.file).map(\.id))
            // A single warning guards the entire mixed selection. Declining it
            // never starts Root preparation or any child/viewer.
            model.confirmPrimaryFileActivation={count in c.warnings.append(count);return false}
            try await c.select(ids);try c.activate();try await wait("declined mixed warning"){!model.fileNavigationReadPending && !model.busy}
            try require(c.warnings==[4] && c.plans.isEmpty && c.children.isEmpty && c.comparisons.isEmpty && c.workspace.conflictEditorPreparationCount==0,"Declined warning launched part of mixed selection")
            model.confirmPrimaryFileActivation={count in c.warnings.append(count);if let gate=c.warningGate {return await gate.read()};return true}
            c.readGate=Gate<ConflictEntry>();try await c.select(ids);try c.activate()
            try await wait("real conflict preparation held",window:window){c.readGate?.entered==true && c.workspace.conflictEditorPreparationCount==1}
            c.preparingPanel=window.attachedSheet
            try require(c.preparingPanel != nil && model.fileNavigationReadPending && c.lease != nil && FileListComparisonSession.activeOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Conflict preparation lost owner/lease/Quit lifetime")
            let plan=try unwrap(c.plans.last,"Mixed plan missing")
            try require(plan.selectedCount==4 && plan.preferences === c.preferences && plan.window === window && plan.ownerIsCurrent() && plan.alternateTool && plan.repository.libgit2Configuration?.enabled==false && Data(plan.repository.executable.path.utf8)==Data(c.repo.executable.path.utf8) && Data(plan.repository.root.path.utf8)==Data(c.repo.root.path.utf8) && plan.mergeTools==savedTools && plan.conflictIdentity==savedIdentity,"Accepted plan recaptured root/backend/settings/Shift")
            let kinds=plan.actions.map{action->String in switch action {case .conflict:return "conflict";case .comparison,.statusComparison:return "comparison";case .workingFile:return "working"}}
            try require(kinds==["conflict","comparison","comparison","working"] && plan.actions.map{$0.file.id}==model.fileTableRows.compactMap(\.file).map(\.id),"Mixed primary replaced row kinds or list order")
            c.workspace.fileComparisonPreferences=c.foreign;c.finishRead()
            try await wait("mixed actual launch acknowledgement",window:window){!model.fileNavigationReadPending && !model.busy && c.workspace.conflictEditorPreparationCount==0 && c.children.count==1 && c.comparisons.count==3}
            try require(c.warnings==[4,4] && c.extraWarnings==0 && c.presentationDrains==[true] && c.preparingPanel?.sheetParent==nil && window.attachedSheet==nil,"Repeated warning or early native child presentation")
            try require(c.comparisons.map{$0.2}==[c.normal,c.second,c.unknown],"Ordinary/untracked comparisons changed source order")
            try require(c.comparisons.prefix(2).allSatisfy{$0.0==plan.workingBase && $0.1 == .workingTree},"Ordinary comparisons changed the accepted base")
            // StartDiffWC:2996 clears Added/Deleted intent and captures the
            // source m_CurrentVersion (empty working-tree sentinel), not HEAD.
            guard case .workingFile(let local,let currentVersion)=plan.actions[3] else{throw Failure(description:"Untracked primary lost typed working-file intent")}
            try require(local.path==c.unknown && currentVersion == .workingTree && c.comparisons[2].0 == .workingTree && c.comparisons[2].1 == .workingTree,"Actual untracked preview substituted HEAD for the captured working version")
            try require(c.externalCalls.count==1 && c.externalCalls[0].0==c.conflict && c.externalCalls[0].1 && c.externalCalls[0].2===window && c.externalCalls[0].3==savedTools && c.externalCalls[0].4,"Actual conflict launch lost captured owner/tool/lease")
            let child=try unwrap(c.children.first as? TextConflictWindowController,"Real text conflict child was not created")
            try await wait("actual text child load",window:child.window){!child.model.preparing && child.model.document != nil}
            try require(child.model.comparisonDefaults === c.preferences && child.model.repository.libgit2Configuration?.enabled==false && child.window?.isVisible==true && c.changes==0,"Native child lost settings/backend or launch claimed resolution")
            try require(try await c.repo.conflicts().count==1,"Presentation silently resolved conflict")
            let onChanged=child.model.onChanged
            child.model.onChanged={output in c.changes += 1;onChanged(output)}
            child.model.result="resolved by native editor\n";var saved:Bool?
            child.model.save(markResolved:true,completion:{saved=$0})
            try await wait("actual native save/resolve and refresh",window:window){saved != nil && c.changes>0 && !model.busy && model.files.allSatisfy{!$0.action.hasPrefix("U")}}
            let remainingAfterSave=try await c.repo.conflicts()
            try require(saved==true && c.changes>0 && remainingAfterSave.isEmpty,"Native result save did not resolve/refresh actual index")
            child.close();try await wait("resolved editor closure"){child.window?.isVisible != true}
            // A genuine multi-conflict Return launches each distinct native
            // editor in list order; two rows stay below the source minimum
            // warning threshold, rather than inventing another per-file prompt.
            try await c.installConflict();try await c.installConflict(path:c.second)
            model.reload();try await wait("two actual unmerged source rows",window:window){!model.busy && model.files.filter{$0.action.hasPrefix("U")}.count==2}
            let multipleIDs=GitPathSet(model.fileTableRows.compactMap(\.file).filter{$0.action.hasPrefix("U")}.map(\.id))
            let multipleStart=c.children.count,multipleWarningCount=c.warnings.count,multipleComparisons=c.comparisons.count
            try await c.select(multipleIDs);try c.activate()
            try await wait("two native conflict launch acknowledgements",window:window){!model.fileNavigationReadPending && !model.busy && c.workspace.conflictEditorPreparationCount==0 && c.children.count==multipleStart+2}
            let multiple=Array(c.children.suffix(2)).compactMap{$0 as? TextConflictWindowController}
            try require(multiple.count==2 && multiple.map{$0.model.path}==[c.conflict,c.second] && c.comparisons.count==multipleComparisons && c.warnings.count==multipleWarningCount && c.presentationDrains.suffix(2).allSatisfy{$0},"Multiple conflicts became comparisons, reordered native editors or repeated warnings")
            let remainingMultiple=try await c.repo.conflicts()
            try require(GitPathSet(remainingMultiple.map(\.path))==GitPathSet([c.conflict,c.second]),"Multi-conflict presentation silently resolved a path")
            for editor in multiple {editor.close()}
            try await wait("multiple conflict children closed"){multiple.allSatisfy{$0.window?.isVisible != true && !$0.model.preparing}}
            _=try await c.repo.run(["reset","--quiet","HEAD","--",c.second])
            try Data("second dirty\n".utf8).write(to:c.root.appendingPathComponent(c.second))
            // Replacing a selection while its single warning continuation is
            // held cancels that request but retains its real counter until reply.
            try await c.installConflict();model.reload();try await wait("restored working conflicts",window:window){!model.busy && model.files.count==4 && model.files.contains{$0.action.hasPrefix("U")}}
            try await c.working();let restored=GitPathSet(model.fileTableRows.compactMap(\.file).map(\.id))
            c.warningGate=Gate<Bool>();let beforePlans=c.plans.count,beforeChildren=c.children.count
            try await c.select(restored);try c.activate();try await wait("held mixed warning"){c.warningGate?.entered==true}
            model.selectedFiles=[c.normal]
            try require(model.fileNavigationReadPending && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Selection replacement released noncooperative warning too soon")
            c.warningGate?.finish(true);c.warningGate=nil
            try await wait("replaced warning drain"){!model.fileNavigationReadPending && !model.busy}
            try require(c.plans.count==beforePlans && c.children.count==beforeChildren,"Replaced warning launched stale rows")
            // A changed raw tool intent also retires the accepted warning,
            // even when a malformed private value would decode to defaults.
            c.warningGate=Gate<Bool>();try await c.select(restored);try c.activate();try await wait("held settings warning"){c.warningGate?.entered==true}
            let mergeIntent=c.preferences.data(forKey:"TurtleGit.MergeTools")
            c.preferences.set(Data("changed private merge intent".utf8),forKey:"TurtleGit.MergeTools")
            c.warningGate?.finish(true);c.warningGate=nil
            try await wait("changed tool intent drain"){!model.fileNavigationReadPending && !model.busy}
            try require(c.plans.count==beforePlans && c.children.count==beforeChildren,"Changed raw merge intent launched an obsolete warning request")
            if let mergeIntent {c.preferences.set(mergeIntent,forKey:"TurtleGit.MergeTools")} else {c.preferences.removeObject(forKey:"TurtleGit.MergeTools")}
            // Captured backend/settings staleness suppresses a held Root reader.
            c.readGate=Gate<ConflictEntry>();try await c.select([c.conflict]);try c.activate();try await wait("settings-fenced held entry"){c.readGate?.entered==true}
            c.preferences.set(true,forKey:"UseLibgit2")
            try await wait("source backend cancellation"){c.readToken?.isCancelled==true}
            c.finishRead();try await wait("cancelled settings read drain"){!model.fileNavigationReadPending && !model.busy && c.workspace.conflictEditorPreparationCount==0}
            try require(c.children.count==beforeChildren && model.error==nil,"Stale backend preparation opened child/error")
            c.preferences.set(false,forKey:"UseLibgit2")
            // Quick Resolve shares a real cancellable preflight and keeps the
            // accepted repository until its synchronous handoff has returned.
            var quickHandoffs:[(RepositoryAction,[String],Bool,Bool)]=[]
            let quickCallback=model.onConflictAction
            model.onConflictAction={action,paths in quickHandoffs.append((action,paths,model.fileNavigationReadPending,model.acceptedNavigationRepository?.libgit2Configuration?.enabled==false))}
            try await c.select([c.conflict]);try Data().write(to:c.quickHold)
            model.requestWorkingConflict(.resolveMine,ids:[c.conflict])
            try await wait("real quick Resolve Git preflight held"){FileManager.default.fileExists(atPath:c.quickEntered.path)}
            try require(model.fileNavigationReadPending && FileListComparisonSession.activeOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quick Resolve preflight lost cancellation/Quit ownership")
            try require(model.cancelFileNavigationRead(),"Quick Resolve preflight did not admit cancellation")
            try await wait("quick Resolve Git/process drain"){!model.fileNavigationReadPending && !model.busy}
            try? FileManager.default.removeItem(at:c.quickHold)
            try require(quickHandoffs.isEmpty && model.error==nil,"Cancelled quick Resolve handed off stale paths/error")
            model.requestWorkingConflict(.resolveMine,ids:[c.conflict])
            try await wait("quick Resolve accepted handoff"){!model.fileNavigationReadPending && !model.busy && quickHandoffs.count==1}
            try require(quickHandoffs[0].0 == .resolveMine && quickHandoffs[0].1==[c.conflict] && quickHandoffs[0].2 && quickHandoffs[0].3,"Quick Resolve changed captured path/backend or dropped activity before handoff")
            model.onConflictAction=quickCallback
            // A forced parent close retains the noncooperative Root worker and
            // access object, then completes only after its actual drain.
            c.readGate=Gate<ConflictEntry>();try await c.select([c.conflict]);try c.activate();try await wait("close-fenced held entry",window:window){c.readGate?.entered==true}
            let closedPanel=window.attachedSheet;var closed=false,paired=false
            let oldClosed=owner.onClosed
            owner.onClosed={closed=true;paired=closedPanel?.sheetParent==nil && window.attachedSheet==nil && !model.fileNavigationReadPending;oldClosed()}
            owner.close()
            try require(c.lease != nil && c.workspace.conflictEditorPreparationCount==1 && FileListComparisonSession.activeOperations>0 && !closed && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced close dropped actual launch ownership")
            c.finishRead();try await wait("forced source/Root completion"){closed && c.workspace.conflictEditorPreparationCount==0 && !model.fileNavigationReadPending}
            try require(paired && c.children.count==beforeChildren,"Closed source handed off an editor or completed before paired sheet drain")
            try require(try await c.repo.rebaseCommit("HEAD").hash==c.head && Data(contentsOf:c.root.appendingPathComponent(c.normal))==Data("normal dirty\n".utf8) && Data(contentsOf:c.root.appendingPathComponent(c.second))==Data("second dirty\n".utf8) && Data(contentsOf:c.root.appendingPathComponent(c.unknown))==Data("untracked\n".utf8),"Primary family changed unrelated HEAD/workfiles")
            print("PASS: mixed Log primary typed row order/parent IDs, one warning/decline, captured backend/settings/Shift/access, actual Root/native conflict launch after paired progress drain, ordinary/untracked comparisons, real save/resolve refresh, selection/backend cancellation and forced-close/Quit ownership. No external applications or Word/LibreOffice automation executed; unbundled checks do not prove App Store grants.")
        } catch {try? await c.cleanup();throw error}
        try await c.cleanup()
    }
}
