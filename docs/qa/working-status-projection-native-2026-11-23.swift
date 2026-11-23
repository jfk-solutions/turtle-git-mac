// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func quietSourceStatusOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;quietSourceStatusOrder(mode,relativeTo:number)}
    @objc func quietSourceStatusSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?){sheet.alphaValue=0;quietSourceStatusSheet(sheet,completionHandler:completionHandler)}
}
@MainActor @main enum WorkingStatusProjectionVerification {
    typealias Prior=StatusPrimaryActivationVerification
    static func require(_ value:Bool,_ text:String,line:Int = #line)throws {try Prior.require(value,"Working projection \(line): "+text)}
    static func wait(_ label:String,_ ready:()->Bool)async throws {try await Prior.wait(label,ready)}
    @MainActor final class Context {
        let folder:URL,repo:GitRepository,prefs:UserDefaults,suite:String
        let source="source 雪\n[*].txt",copy="copied 雪\t.txt",old="rename old.txt",renamed="rename destination.txt"
        let original=Data((0..<90).map{"copied historical source line \($0)\n"}.joined().utf8)
        var owners:[NSWindowController]=[],roots:[RepositoryModel]=[],head=Data(),index=Data(),working:[String:Data]=[:]
        init(_ base:URL,_ git:URL)throws {
            folder=base.standardizedFileURL;try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            repo=GitRepository(root:folder,executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.SourceStatus."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            for key in ["UseLibgit2","EnableLogCache","EnableGravatar","TurtleGit.Commit.GitGuiInterface","SelectFilesForCommit"] {prefs.set(false,forKey:key)}
            for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation","AddBeforeCommit","LogIncludeWorkingTreeChanges","ShowAppContextMenuIcons"] {prefs.set(true,forKey:key)}
            prefs.set(3,forKey:"NumDiffWarning")
        }
        func setup()async throws {
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Source Status QA"),("user.email","source-status@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
            try original.write(to:folder.appendingPathComponent(source))
            try Data((0..<70).map{"independent renamed source \($0)\n"}.joined().utf8).write(to:folder.appendingPathComponent(old))
            try await repo.stage(["."]);_=try await repo.commit(message:"Natural working copy/rename source")
            try original.write(to:folder.appendingPathComponent(copy))
            var changed=original;changed.append(Data("independent source modification\n".utf8));try changed.write(to:folder.appendingPathComponent(source))
            _=try await repo.run(["mv","--",old,renamed]);try await repo.stage([source,copy])
            head=try await repo.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
            for path in [source,copy,renamed] {working[path]=try Data(contentsOf:folder.appendingPathComponent(path))}
            let actual=try await repo.status(refreshIndex:false)
            print("NATURAL SOURCE STATUS: "+String(reflecting:actual.map{"\($0.path):\($0.index)\($0.worktree),caption=\($0.actionCaption),raw=\($0.reportingActions.rawValue),old=\(String(reflecting:$0.reportingOriginalPath))"}))
            try check(try Prior.unwrap(actual.first{$0.path==copy},"Natural copy absent"))
            let rename=try Prior.unwrap(actual.first{$0.path==renamed},"Natural rename absent")
            try require(rename.isRenamed && rename.reportingOriginalPath==old,"Natural rename lost raw old path")
        }
        func check(_ entry:StatusEntry)throws {
            try require(entry.index=="A" && entry.worktree==" " && entry.originalPath==nil,"Copy reporting rewrote actual porcelain staging identity")
            try require(!entry.isCopied && entry.reportingOriginalPath==nil && entry.actionCaption=="Added","Exact pinned -C -M order did not preserve Added/no-origin witness")
            try require(entry.statusTextRole == .added && entry.statusIcon.image() != nil,"Copy role/source icon lost")
            try require(entry.statusOriginDescription().isEmpty,"Pinned Added row invented a Copy/Rename origin")
        }
        func root()->RepositoryModel {
            let value=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotStore:FinderSnapshotStore(url:folder.appendingPathComponent("finder.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:folder.appendingPathComponent("marks.json")),cachePersistenceDefaults:prefs)
            value.fileComparisonPreferences=prefs;roots.append(value);return value
        }
        func own(_ owner:NSWindowController){owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)}
        func preserved()async throws {
            try require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"Read-only status/action changed HEAD")
            try require(try Data(contentsOf:folder.appendingPathComponent(".git/index"))==index,"Read-only status/action changed exact index")
            for(path,bytes)in working {try require(try Data(contentsOf:folder.appendingPathComponent(path))==bytes,"Copy reporting changed source/destination bytes")}
        }
        func cleanup()async throws {
            owners.forEach{$0.close()};roots.forEach{$0.stopMonitoringForTermination()}
            try await wait("Owned status projection windows/workers did not drain") {Prior.drained() && RevertProgressWindowModel.activeOperations==0 && RevertProgressWindowController.activeReleases==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeHistoryProjectionWorkers==0 && LogWindowModel.activeActionReads==0 && LogWindowModel.activeFileNavigationActivities==0 && roots.allSatisfy{!$0.hasPendingRepositoryWork} && owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil}}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func waitStaging(_ label:String,model:CommitWindowModel,row:StatusEntry,state:NSControl.StateValue)async throws {
        do {try await wait(label){!model.busy && !model.fileWorkPending && !model.stagingStateNeedsRefresh && model.stagingState(row)==state}}
        catch {
            let current=model.entries.first{$0.path==row.path}
            try require(false,label+"; busy=\(model.busy),work=\(model.fileWorkPending),refresh=\(model.stagingStateNeedsRefresh),staging=\(model.stagingEnabled),state=\(model.stagingState(row).rawValue),expected=\(state.rawValue),sameRow=\(current==row),generation=\(model.fileCheckReceipt.generation),error=\(model.error ?? "none")")
            throw error
        }
    }
    static func snapshot(_ values:[(RevisionComparisonSnapshot,CommitFile)],_ c:Context)async throws {
        try require(values.count==2 && GitPathSet(values.map{$0.1.path})==GitPathSet([c.copy,c.renamed]),"Actual Added/Rename comparison omitted/repeated child")
        for (snapshot,file) in values {
            let document=try await c.repo.comparisonFile(snapshot,path:file.path)
            if file.path==c.copy {
                try require(file.action=="A" && file.oldPath==nil && snapshot.from == .emptyTree,"Pinned Added copy acquired a historical Copy/Rename operand")
                try require(document.base.bytes.isEmpty && document.base.mode==nil && document.destination.bytes==c.original,"Added copied destination lost its empty old side")
            } else {
                try require(file.action.hasPrefix("R") && file.oldPath==c.old && document.base.path==c.old,"Actual Rename lost accepted historical old path")
                try require(document.base.bytes==c.working[c.renamed] && document.destination.bytes==c.working[c.renamed],"Rename changed historical source/destination bytes")
            }
        }
    }
    static func surface(_ kind:String,base:URL,git:URL)async throws {
        let c=try Context(base,git)
        do {
            try await c.setup();let root=c.root();var values:[(RevisionComparisonSnapshot,CommitFile)]=[]
            root.fileComparisonPresentation={values.append(($0,$1))}
            switch kind {
            case "commit":
                let owner=CommitWindowController(repository:c.repo,access:nil,defaults:c.prefs);c.own(owner);let model=owner.model
                model.reload(paths:["."])
                try await wait("Actual Commit pinned report unavailable"){owner.window?.contentView?.layoutSubtreeIfNeeded();return model.fileListAvailable && model.commitIdentityPrepared && model.changelistsLoaded && !model.loadingFileMetadata && !model.fileWorkPending}
                let row=try Prior.unwrap(model.entries.first{$0.path==c.copy},"Commit omitted copied destination");try c.check(row)
                let report=try await Prior.bridge(owner)
                try require(report.rows.contains(c.copy),"Commit native report omitted copy identity")
                model.checked=[c.copy]
                try require(model.checkedFileList.contains("Added") && model.fileHelp(row).isEmpty,"Commit Added caption/report/origin differs")
                var logged:[String]=[];model.onFileLog={logged.append($0)}
                let copyMenu=model.fileMenu([c.copy]);try require(!copyMenu.commands.contains(.oldNameLog) && !copyMenu.commands.contains(.blame),"Pinned Added row exposed Copy old-name/Blame menu")
                let menu=model.fileMenu([c.renamed]);try require(menu.commands.contains(.oldNameLog),"Actual Rename old-name action absent")
                model.fileAction(.oldNameLog,snapshot:menu);try await wait("Commit old-name handoff did not drain"){!model.busy}
                try require(logged==[c.old] && model.checked==GitPathSet([c.copy]),"Rename old-name log changed independent checked identity")
                model.onPrimaryFileActivation={plan,token in try await root.showStatusListPrimaryFiles(plan,access:nil,cancellation:token)}
                model.compare(paths:[c.copy,c.renamed]);try await wait("Commit Added/Rename preparation did not drain"){!model.primaryActivationPending && !model.busy && !root.hasPendingRepositoryWork}
                try await snapshot(values,c);try await c.preserved()
                let sourceIndex=try await c.repo.run(["ls-files","--stage","-z","--",c.source]).stdout
                model.setStagingEnabled(true)
                try await wait("Staging preference did not settle"){model.stagingEnabled && !model.savingPreferences && model.fileListAvailable}
                let stagedRow=try Prior.unwrap(model.entries.first{$0.path==c.copy},"Accepted staging destination absent")
                try require(stagedRow==row && model.stagingState(stagedRow) == .on,"Staging mode replaced accepted row or lost initial staged state")
                model.setFileChecked(stagedRow,files:model.visibleEntries,highlighted:[c.copy],checked:false,receipt:model.fileCheckReceipt)
                try await waitStaging("Copied destination unstage state did not settle",model:model,row:stagedRow,state:.off)
                let unstaged=try Prior.unwrap(model.entries.first{$0.path==c.copy},"Retained unstaged destination absent")
                try require(unstaged==stagedRow && unstaged.actionCaption=="Added","Checkbox unstage replaced source m_Action/reporting metadata before F5")
                try require(try await c.repo.run(["ls-files","--stage","-z","--",c.copy]).stdout.isEmpty,"Unstage checkbox did not remove destination index entry")
                try require(try Data(contentsOf:c.folder.appendingPathComponent(c.copy))==c.original,"Unstage checkbox changed copied destination bytes")
                try require(try await c.repo.run(["ls-files","--stage","-z","--",c.source]).stdout==sourceIndex,"Unstaging Copy changed/deleted source index entry")
                model.setFileChecked(unstaged,files:model.visibleEntries,highlighted:[c.copy],checked:true,receipt:model.fileCheckReceipt)
                try await waitStaging("Copied destination restage state did not settle",model:model,row:unstaged,state:.on)
                try require(model.entries.first{$0.path==c.copy}==stagedRow,"Restaging replaced accepted source action/metadata")
                try require(!((try await c.repo.run(["ls-files","--stage","-z","--",c.copy])).stdout.isEmpty),"Stage checkbox did not restore destination index entry")
                try require(try await c.repo.run(["show",":"+c.copy]).stdout==c.original,"Restaged index content differs from copied destination")
                try require(try await c.repo.run(["ls-files","--stage","-z","--",c.source]).stdout==sourceIndex,"Staging Copy treated its origin as Rename removal")
                model.setStagingEnabled(false)
                try await wait("Classic checkbox preference did not settle"){!model.stagingEnabled && !model.savingPreferences && model.fileListAvailable}
                model.checked=[c.copy];model.message="Commit copied destination only"
                var committed=false,completedProgress:CommitProgressWindowModel?
                model.onCommitted={_ in committed=true}
                // This cohort verifies the real commit/index operation. Its
                // optional success-result choice uses the established injected
                // response seam; it must not wait forever for an invisible Close.
                model.onCommitProgress={value in completedProgress=value;value.dismissWithoutWindow=true}
                try await wait("Actual copied-only commit was not available"){model.canCommit}
                model.commit()
                do {try await wait("Actual copied-only commit did not drain"){committed && !model.busy && !model.attemptWorkPending && !model.fileWorkPending}}
                catch {
                    let actualHead=(try? await c.repo.run(["rev-parse","HEAD"]).stdout) ?? Data()
                    let actualIndex=(try? Data(contentsOf:c.folder.appendingPathComponent(".git/index"))) ?? Data()
                    let diagnostic:[String:Any]=["committed":committed,"busy":model.busy,"attemptWork":model.attemptWorkPending,"fileWork":model.fileWorkPending,"error":model.error ?? "none","messageAvailable":model.messageFocusAvailable,"checked":Array(model.checked),"highlighted":Array(model.selection),"progressBusy":completedProgress?.busy ?? false,"progressSuccess":completedProgress?.success ?? false,"progressOutput":completedProgress?.output ?? "none","sheet":String(describing:owner.window?.attachedSheet),"head":actualHead.base64EncodedString(),"index":actualIndex.base64EncodedString()]
                    try JSONSerialization.data(withJSONObject:diagnostic,options:[.prettyPrinted,.sortedKeys]).write(to:c.folder.appendingPathComponent("commit-outcome.json"))
                    try require(false,"Actual copied-only commit did not drain; committed=\(committed),busy=\(model.busy),attempt=\(model.attemptWorkPending),fileWork=\(model.fileWorkPending),error=\(model.error ?? "none"),progressSuccess=\(completedProgress?.success == true),HEAD=\(String(decoding:actualHead,as:UTF8.self)); commit-outcome.json retained")
                    throw error
                }
                try require(completedProgress?.success==true && completedProgress?.busy==false && completedProgress?.isAbandoned==false,"Actual commit progress did not report successful Git completion")
                try require(try await c.repo.run(["cat-file","-p","HEAD:"+c.source]).stdout==c.original,"Copy commit removed/changed original HEAD source")
                // Checkbox Commit resets unchecked ordinary Modified rows to
                // HEAD; only the source Added/Deleted/Renamed restoration queues
                // are re-applied. Working edits survive independently.
                let sourceHeadOID=try await c.repo.run(["rev-parse","HEAD:"+c.source]).text.trimmingCharacters(in:.newlines)
                let expectedSourceIndex=Data("100644 \(sourceHeadOID) 0\t\(c.source)\0".utf8)
                try require(try await c.repo.run(["ls-files","--stage","-z","--",c.source]).stdout==expectedSourceIndex,"Unchecked Modified source did not reset to exact HEAD index entry")
                try require(try Data(contentsOf:c.folder.appendingPathComponent(c.source))==c.working[c.source],"Checkbox Commit changed unchecked source working bytes")
                let sourceStatus=try await c.repo.status(readPolicy:.automatic,includeIgnored:false).first{$0.path==c.source}
                try require(sourceStatus?.index==" " && sourceStatus?.worktree=="M","Unchecked source working modification was lost or accidentally staged")
                c.head=try await c.repo.run(["rev-parse","HEAD"]).stdout;c.index=try Data(contentsOf:c.folder.appendingPathComponent(".git/index"))
            case "status":
                let owner=StatusWindowController(repository:c.repo,access:nil,defaults:c.prefs);c.own(owner);let model=owner.model
                model.reload();try await wait("Actual status pinned report unavailable"){owner.window?.contentView?.layoutSubtreeIfNeeded();return !model.busy && model.hasStatusSnapshot}
                let row=try Prior.unwrap(model.files.first{$0.id==c.copy},"Status omitted copied destination");try c.check(row.entry)
                try require(row.status=="Added" && model.clipboardText([c.copy],copy:.pathsAndStatus).contains("Added"),"Status clipboard/caption differs")
                var logged:[String]=[];model.onAction={_,paths in logged += paths}
                try require(!model.fileMenu([c.copy]).commands.contains(.oldNameLog),"Added Status row invented old-name menu")
                model.fileAction(.oldNameLog,snapshot:model.fileMenu([c.renamed]));try await wait("Status old-name action did not drain"){!model.busy}
                try require(logged==[c.old],"Status old-name log lost raw rename origin")
                model.onPrimaryFileActivation={plan,token in try await root.showStatusListPrimaryFiles(plan,access:nil,cancellation:token)}
                model.diff([c.copy,c.renamed]);try await wait("Status Copy comparison did not drain"){!model.primaryActivationPending && !model.busy && !root.hasPendingRepositoryWork}
                try await snapshot(values,c)
            case "add":
                let owner=AddWindowController(repository:c.repo,access:nil,defaults:c.prefs),model=owner.model
                model.setScope([c.copy,c.source,c.renamed]);c.own(owner);model.reload()
                try await wait("Actual Add direct-file report unavailable"){owner.window?.contentView?.layoutSubtreeIfNeeded();return !model.busy && model.entries.count==3}
                let row=try Prior.unwrap(model.entries.first{$0.path==c.copy},"Add omitted copied destination");try c.check(row.status)
                let table=try Prior.unwrap(Prior.views(owner.window?.contentView).compactMap{$0 as? AddNativeTable}.first,"Actual Add native report missing")
                let coordinator=try Prior.unwrap(table.dataSource as? AddFileTable.Coordinator,"Actual Add coordinator missing")
                let nativeRows=coordinator.rows,position=try Prior.unwrap(nativeRows.firstIndex{$0.path==c.copy},"Add native copy row absent")
                CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integer:position));try await wait("Native Add copy highlight absent"){model.highlighted==GitPathSet([c.copy])}
                try require(coordinator.oldLogPath==nil && !coordinator.canBlame && coordinator.clipboardText("pathsStatus").contains("Added"),"Add actual menu/clipboard did not retain pinned Added/no-origin")
                let cell=table.view(atColumn:1,row:position,makeIfNecessary:true)
                try require(cell?.toolTip?.contains("Added")==true,"Add native tooltip omitted Added caption")
                model.onPrimaryFileActivation={plan,token in try await root.showStatusListPrimaryFiles(plan,access:nil,cancellation:token)}
                let renameRow=try Prior.unwrap(model.entries.first{$0.path==c.renamed},"Add rename absent")
                model.compareFileActions([row,renameRow],alternate:false);try await wait("Add Copy comparison did not drain"){!model.primaryActivationPending && !model.busy && !root.hasPendingRepositoryWork}
                try await snapshot(values,c)
            default:throw NSError(domain:"SourceStatusFixture",code:1)
            }
            try await c.preserved();try await c.cleanup();print("PASS STATUS PROJECTION COHORT: "+kind)
        } catch {try? await c.cleanup();throw error}
    }
    static func log(base:URL,git:URL)async throws {
        let c=try Context(base,git);let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        do {
            try await c.setup();let root=c.root();var owner:LogWindowController?,values:[(RevisionComparisonSnapshot,CommitFile)]=[]
            root.logWindowPresentation={value in owner=value;c.own(value)};root.fileComparisonPresentation={values.append(($0,$1))}
            root.showLog(repository:c.repo,access:RepositoryAccessLease(url:c.folder),paths:[],preferences:c.prefs)
            try await wait("Root Log working snapshot unavailable"){owner != nil && owner?.model.busy==false && owner?.model.workingTreeSnapshot != nil}
            let controller=try Prior.unwrap(owner,"Log owner absent"),model=controller.model
            model.select([""]);model.clipboard=board
            try await wait("Actual Log working rows unavailable"){controller.window?.contentView?.layoutSubtreeIfNeeded();return !model.busy && model.visibleFiles.contains{$0.path==c.copy} && Prior.views(controller.window?.contentView).contains{$0 is LogChangedFileNativeTable}}
            let file=try Prior.unwrap(model.visibleFiles.first{$0.path==c.copy},"Log copied row absent"),entry=try Prior.unwrap(model.workingStatusEntry(file),"Log raw status absent");try c.check(entry)
            try require(model.fileStatus(file)=="Added" && model.fileStatusTextRole(file) == .added && model.changedFileIcon(file) != nil,"Log Added caption/color/icon differs")
            model.copyChangedFileIDs([c.copy],status:true);try require(board.string(forType:.string)?.contains("Added")==true,"Actual Log clipboard lost Added caption")
            var logged:[String]=[];model.onFileLog={path,_ in logged.append(path)};try require(file.oldPath==nil && !model.canBlameFile([c.copy]),"Actual Added Log row exposed Copy old-name/Blame identity")
            model.fileLog([c.renamed],oldName:true)
            try await wait("Log old-name preparation did not drain"){!model.fileNavigationReadPending}
            try require(logged==[c.old],"Log old-name action lost Rename origin")
            model.primaryFileAction([c.copy,c.renamed],mode:.compareWithBase)
            try await wait("Log Copy comparison did not drain"){!model.fileNavigationReadPending && !root.hasPendingRepositoryWork}
            try await snapshot(values,c);try await c.preserved();try await c.cleanup();print("PASS STATUS PROJECTION COHORT: log")
        } catch {try? await c.cleanup();throw error}
    }
    static func revert(base:URL,git:URL)async throws {
        let c=try Context(base,git)
        do {
            try await c.setup();c.prefs.set(false,forKey:"RevertWithRecycleBin")
            let sourceIndex=try await c.repo.run(["ls-files","--stage","-z","--",c.source]).stdout
            let owner=RevertWindowController(repository:c.repo,access:nil,preferences:c.prefs)
            c.own(owner);owner.model.setScope([c.copy,c.renamed])
            try await wait("Actual Revert Added/Rename report unavailable"){owner.window?.contentView?.layoutSubtreeIfNeeded();return owner.model.canInteract && owner.model.entries.contains{$0.path==c.copy} && owner.model.entries.contains{$0.path==c.renamed}}
            let added=try Prior.unwrap(owner.model.entries.first{$0.path==c.copy},"Revert Added row absent"),renamed=try Prior.unwrap(owner.model.entries.first{$0.path==c.renamed},"Revert Rename row absent")
            try c.check(added);try require(renamed.isRenamed && renamed.reportingOriginalPath==c.old,"Revert source Rename origin lost")
            var progress:RevertProgressWindowController?,finished=false,succeeded=false
            owner.model.onAccepted={entries in
                let child=RevertProgressWindowController(repository:c.repo,access:nil,entries:entries,amend:false,againstHead:false,autoCloseSuccess:false,preferences:c.prefs,policy:.init(recycle:false))
                progress=child;c.own(child);child.model.onFinished={_,success in finished=true;succeeded=success};child.model.start()
            }
            owner.model.checked=[];owner.model.setChecked([c.copy,c.renamed],value:true);owner.model.apply()
            try await wait("Actual Revert report/progress did not drain"){finished && progress?.model.busy==false && RevertProgressWindowModel.activeOperations==0}
            try require(succeeded && progress?.model.trashedFiles.isEmpty==true,"Source Added/Rename Revert failed or ignored captured no-Trash policy")
            try require(try Data(contentsOf:c.folder.appendingPathComponent(c.copy))==c.original,"Added-only Revert removed copied working bytes")
            try require(try Data(contentsOf:c.folder.appendingPathComponent(c.old))==c.working[c.renamed] && !FileManager.default.fileExists(atPath:c.folder.appendingPathComponent(c.renamed).path),"Raw Rename Revert failed to restore accepted old path")
            try require(try await c.repo.run(["ls-files","--stage","-z","--",c.source]).stdout==sourceIndex,"Revert included unrelated copy source in selected paths")
            try require(try await c.repo.run(["ls-files","-z","--",c.copy]).stdout.isEmpty,"Added-only Revert left destination staged")
            c.working[c.old]=c.working.removeValue(forKey:c.renamed);c.index=try Data(contentsOf:c.folder.appendingPathComponent(".git/index"))
            try await c.preserved();try await c.cleanup();print("PASS STATUS PROJECTION COHORT: revert")
        } catch {try? await c.cleanup();throw error}
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietSourceStatusOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietSourceStatusSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quiet);method_exchangeImplementations(sheet,quietSheet)
        defer{method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quiet)}
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),only=Set(CommandLine.arguments.dropFirst(3))
        try require(only.isSubset(of:["commit","status","add","log","revert"]),"Unknown status projection selector")
        for kind in ["commit","status","add"] where only.isEmpty || only.contains(kind) {try await surface(kind,base:base.appendingPathComponent(kind),git:git)}
        if only.isEmpty || only.contains("log") {try await log(base:base.appendingPathComponent("log"),git:git)}
        if only.isEmpty || only.contains("revert") {try await revert(base:base.appendingPathComponent("revert"),git:git)}
        print("PASS: Pinned working status Added/Rename projection through actual Commit/Status/Add/Log reads, source captions/colors/icons/actual rename origins, old-name actions, clipboard and Root comparison operands; exact pinned copy-as-Added behavior, raw staging and source bytes preserved")
    }
}
