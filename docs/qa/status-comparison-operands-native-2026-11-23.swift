// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func quietOperandOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;quietOperandOrder(mode,relativeTo:number)}
    @objc func quietOperandSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {sheet.alphaValue=0;quietOperandSheet(sheet,completionHandler:completionHandler)}
}

@MainActor @main enum StatusComparisonOperandsVerification {
    typealias Prior=StatusPrimaryActivationVerification
    static func require(_ value:Bool,_ text:String,line:Int = #line)throws {try Prior.require(value,"Operands \(line): "+text)}
    static func wait(_ text:String,_ ready:()->Bool)async throws {try await Prior.wait(text,ready)}
    static func entry(_ path:String,_ code:String,old:String?=nil)->StatusEntry {
        StatusEntry.parse(Data((code+" "+path+"\0"+(old.map{$0+"\0"} ?? "")).utf8))[0]
    }
    struct Delivery {let snapshot:RevisionComparisonSnapshot,file:CommitFile}
    @MainActor final class Context {
        let folder:URL,repo:GitRepository,prefs:UserDefaults,suite:String
        let added="a added.txt",deleted="b deleted.txt",renamed="c renamed 雪.txt",renameOld="old rename\n雪.txt",copied="d copied.txt",copyOld="old copy\t雪.txt",modified="e modified.txt",link="f link 雪",module="g module"
        var copySourceOverride:String?
        var head="",parent="",owners:[NSWindowController]=[],roots:[RepositoryModel]=[],unblock:[()->Void]=[]
        var expectedIndex=Data(),expectedHead=Data(),files:[String:Data]=[:],links:[String:String]=[:]
        init(base:URL,git:URL)throws {
            folder=base.standardizedFileURL;try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            repo=GitRepository(root:folder,executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.StatusOperands."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation","AddBeforeCommit"] {prefs.set(true,forKey:key)}
            for key in ["UseLibgit2","EnableGravatar","TurtleGit.Commit.GitGuiInterface","SelectFilesForCommit"] {prefs.set(false,forKey:key)}
            prefs.set(3,forKey:"NumDiffWarning")
        }
        var wanted:[String] {[added,deleted,renamed,copied,modified,link]}
        func setup(initial:Bool=false,rootCommit:Bool=false)async throws {
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Operand QA"),("user.email","operands@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
            if initial {
                for path in [added,renamed,copied,modified] {try Data((path+" initial\n").utf8).write(to:folder.appendingPathComponent(path))}
                try FileManager.default.createSymbolicLink(atPath:folder.appendingPathComponent(link).path,withDestinationPath:"initial-target")
                try await repo.stage(["."]);return
            }
            for(path,text)in[(deleted,"delete base\n"),(renameOld,"rename original\n"),(copyOld,"copy original\n"),("copy decoy.txt","copy original\n"),(modified,"parent value\n"),("target-old.txt","must not follow old symlink\n"),("target-new.txt","must not follow new symlink\n")] {try Data(text.utf8).write(to:folder.appendingPathComponent(path))}
            try FileManager.default.createSymbolicLink(atPath:folder.appendingPathComponent(link).path,withDestinationPath:"target-old.txt")
            try await repo.stage(["."]);_=try await repo.commit(message:"Operand parent")
            parent=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
            if !rootCommit {
                try Data("HEAD value\n".utf8).write(to:folder.appendingPathComponent(modified));try await repo.stage([modified]);_=try await repo.commit(message:"Operand HEAD")
            }
            head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
            _=try await repo.run(["rm","--",deleted]);_=try await repo.run(["mv","--",renameOld,renamed])
            try Data("accepted added\n".utf8).write(to:folder.appendingPathComponent(added))
            try Data("copy original\n".utf8).write(to:folder.appendingPathComponent(copied))
            try Data("working value\n".utf8).write(to:folder.appendingPathComponent(modified))
            try FileManager.default.removeItem(at:folder.appendingPathComponent(link));try FileManager.default.createSymbolicLink(atPath:folder.appendingPathComponent(link).path,withDestinationPath:"target-new.txt")
            try await repo.stage([added,copied,modified,link])
            try FileManager.default.createDirectory(at:folder.appendingPathComponent(module),withIntermediateDirectories:true)
            _=try await repo.run(["update-index","--add","--cacheinfo","160000,"+head+","+module])
        }
        func root()->RepositoryModel {
            let value=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotStore:FinderSnapshotStore(url:folder.appendingPathComponent("finder.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:folder.appendingPathComponent("marks.json")),cachePersistenceDefaults:prefs)
            value.fileComparisonPreferences=prefs;roots.append(value);return value
        }
        func checkpoint()async throws {
            expectedHead=try await repo.run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1).stdout
            expectedIndex=try Data(contentsOf:folder.appendingPathComponent(".git/index"));files=[:];links=[:]
            for path in wanted+[renameOld,copyOld,"copy decoy.txt","target-old.txt","target-new.txt"] {
                let url=folder.appendingPathComponent(path)
                if let target=try? FileManager.default.destinationOfSymbolicLink(atPath:url.path) {links[path]=target}
                else if let bytes=try? Data(contentsOf:url) {files[path]=bytes}
            }
        }
        func preserved()async throws {
            try require(try await repo.run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1).stdout==expectedHead,"Read-only operands changed HEAD")
            try require(try Data(contentsOf:folder.appendingPathComponent(".git/index"))==expectedIndex,"Read-only operands changed exact index")
            for(path,bytes)in files {try require(try Data(contentsOf:folder.appendingPathComponent(path))==bytes,"Comparison changed disk bytes: "+path)}
            for(path,target)in links {try require(try FileManager.default.destinationOfSymbolicLink(atPath:folder.appendingPathComponent(path).path)==target,"Comparison followed/replaced symlink")}
        }
        func cleanup()async throws {
            owners.forEach{$0.close()};unblock.forEach{$0()};unblock=[];roots.forEach{$0.stopMonitoringForTermination()}
            try await wait("Owned operand windows/workers did not drain") {Prior.drained() && SubmoduleDiffWindowModel.activeReads==0 && SubmoduleDiffWindowController.activeReleases==0 && roots.allSatisfy{!$0.hasPendingRepositoryWork} && owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil}}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    enum Kind:String,CaseIterable {case commit,status,revert}
    @MainActor final class Surface {
        let kind:Kind,owner:NSWindowController,commit:CommitWindowController?,status:StatusWindowController?,revert:RevertWindowController?
        init(_ kind:Kind,_ c:Context,amend:Bool=false,againstHEAD:Bool=false,copyProjection:Bool=false) {
            self.kind=kind
            switch kind {
            case .commit:
                let value=CommitWindowController(repository:c.repo,access:nil,defaults:c.prefs);commit=value;status=nil;revert=nil;owner=value
                value.model.missingStagedRecovery.choose={_ in .init(action:.ignore,doSameForRest:true)}
                if copyProjection {
                    value.model.queryCommitStatus={[weak c] amend,token in
                        guard let c else{throw OperationCancellationFailure.cancelled}
                        let actual=try await c.repo.commitDialogStatus(amendToParent:amend,cancellation:token,refreshIndex:false)
                        // Controlled accepted C metadata: CLI status explicitly
                        // requests rename detection, so do not mislabel this as
                        // a naturally detected copy. Both source blobs are real.
                        return actual.map{GitReferenceName.equal($0.path,c.copied) ? StatusComparisonOperandsVerification.entry(c.copied,"C ",old:c.copySourceOverride ?? c.copyOld):$0}
                    }
                }
                value.model.amendDiffToLastCommit=againstHEAD;value.model.amend=amend
            case .status:
                let value=StatusWindowController(repository:c.repo,access:nil,defaults:c.prefs);status=value;commit=nil;revert=nil;owner=value
                value.model.missingStagedRecovery.choose={_ in .init(action:.ignore,doSameForRest:true)}
            case .revert:
                let value=RevertWindowController(repository:c.repo,access:nil,preferences:c.prefs);revert=value;commit=nil;status=nil;owner=value
                value.model.commands.missingStagedRecovery.choose={_ in .init(action:.ignore,doSameForRest:true)}
            }
            c.owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)
            commit?.model.reload(paths:["."]);status?.model.reload();revert?.model.setScope(["."])
        }
        var pending:Bool {commit?.model.primaryActivationPending ?? status?.model.primaryActivationPending ?? revert!.model.commands.primaryActivationPending}
        var busy:Bool {commit?.model.busy ?? status?.model.busy ?? (revert!.model.busy || revert!.model.commands.busy)}
        var selection:GitPathSet {commit?.model.selection ?? status?.model.selection ?? revert!.model.highlighted}
        func ready()async throws {
            try await wait("Actual \(kind) operand report unavailable") {
                owner.window?.contentView?.layoutSubtreeIfNeeded()
                if let commit {return commit.model.fileListAvailable && !commit.model.busy && !commit.model.fileWorkPending && !commit.model.loadingAmendMessage && commit.model.commitIdentityPrepared && commit.model.changelistsLoaded && !commit.model.loadingFileMetadata}
                if let status {return !status.model.busy && status.model.hasStatusSnapshot}
                return revert!.model.canInteract
            }
            if commit != nil {_ = try await currentCommitProjection()}
            else {_=try await Prior.bridge(owner)}
        }
        func currentCommitProjection()async throws->StatusListPrimaryActionBridge.Probe? {
            guard let commit else{return nil}
            var accepted:StatusListPrimaryActionBridge.Probe?
            do {try await wait("Current Commit operand projection unavailable") {
                self.owner.window?.contentView?.layoutSubtreeIfNeeded()
                let expected=commit.model.displayedFileEntries.map{GitReferenceName($0.path)}
                let probes=Prior.views(self.owner.window?.contentView).compactMap{$0 as? StatusListPrimaryActionBridge.Probe}
                guard let probe=probes.first(where:{$0.active && $0.window === self.owner.window && !$0.isHiddenOrHasHiddenAncestor && $0.revision==commit.model.fileReportRevision && $0.rows.compactMap({$0}).map({GitReferenceName($0)})==expected}),
                      probe.revision==commit.model.fileReportRevision,
                      probe.rows.compactMap({$0}).map({GitReferenceName($0)})==expected,
                      let table=try? Prior.table(self.owner),table.window === self.owner.window,
                      table.numberOfRows==probe.rows.count,!table.isHiddenOrHasHiddenAncestor,table.isEnabled else{return false}
                let ready=commit.model.fileListAvailable && !commit.model.busy && !commit.model.fileWorkPending && !commit.model.loadingFileMetadata
                if ready {accepted=probe};return ready
            }} catch {
                let probes=Prior.views(owner.window?.contentView).compactMap{$0 as? StatusListPrimaryActionBridge.Probe}
                print("OPERAND PROJECTION: expectedRevision=\(commit.model.fileReportRevision),actual=\(probes.map{String(describing:$0.revision)}),expectedRows=\(commit.model.displayedFileEntries.prefix(24).map{String(reflecting:$0.path)})")
                print(diagnostic("projection-readiness-failure"))
                throw error
            }
            return try Prior.unwrap(accepted,"Current Commit operand projection was not retained")
        }
        func diagnostic(_ phase:String)->String {
            let entries:[StatusEntry]
            if let commit {entries=commit.model.entries}
            else if let status {entries=status.model.files.map(\.entry)}
            else {entries=revert!.model.commands.files.map(\.entry)}
            let rows=Prior.views(owner.window?.contentView).compactMap{$0 as? StatusListPrimaryActionBridge.Probe}.map{probe in
                "active=\(probe.active),revision=\(probe.revision),current=\(Prior.currentReport(owner,probe)),hidden=\(probe.isHiddenOrHasHiddenAncestor),rows=\(Array(probe.rows.prefix(24))),owner=\(probe.window === owner.window)"
            }
            let tables=Prior.views(owner.window?.contentView).compactMap{$0 as? NSTableView}.map{
                "count=\($0.numberOfRows),selection=\(Array($0.selectedRowIndexes)),owner=\($0.window === owner.window),hidden=\($0.isHiddenOrHasHiddenAncestor)"
            }
            let states=entries.prefix(24).map{"\(String(reflecting:$0.path)):\($0.index)\($0.worktree),old=\(String(reflecting:$0.originalPath)),hasUnversionedCopy=\($0.hasUnversionedCopy)"}
            return "OPERAND SOURCE phase=\(phase),kind=\(kind),visible=\(owner.window?.isVisible == true),busy=\(busy),pending=\(pending),amend=\(commit?.model.amend == true),againstHEAD=\(commit?.model.amendDiffToLastCommit == true),hasHead=\(commit?.model.hasHead == true),hasParent=\(commit?.model.hasParent == true),entries=\(states),probes=\(rows),tables=\(tables)"
        }
        func select(_ paths:[String])async throws->[String] {
            let bridge=try await Prior.bridge(owner),wanted=GitPathSet(paths),ordered=bridge.rows.compactMap{$0}.filter{wanted.contains($0)}
            try await Prior.select(owner,paths:ordered){self.selection==GitPathSet(ordered)}
            let table=try Prior.table(owner)
            try require(table.selectedRowIndexes==IndexSet(bridge.rows.indices.filter{bridge.rows[$0].map{GitPathSet(ordered).contains($0)} ?? false}),"Native source projection differs")
            return ordered
        }
        func enter()async throws {
            // Return uses the exact accepted mounted projection, not a separate
            // lookup that may choose an active but hidden/stale SwiftUI bridge.
            let bridge:StatusListPrimaryActionBridge.Probe
            if let current=try await currentCommitProjection() {bridge=current}
            else {bridge=try await Prior.bridge(owner)}
            let table=try Prior.table(owner),window=owner.window!
            bridge.commandKeyWindow={[weak window] in window}
            try require(window.makeFirstResponder(table) && window.firstResponder === table,"Source report refused Return focus")
            try require(Prior.currentReport(owner,bridge),"Return projection retired before dispatch; "+Prior.inputState(owner,bridge))
            let forward=bridge.activate
            var receipts:[StatusListPrimaryActionReceipt]=[]
            bridge.activate={receipt in
                receipts.append(receipt)
                Prior.boundary("operand Return forwarded paths=\(String(reflecting:receipt.paths)),mark=\(String(reflecting:receipt.path)),alternate=\(receipt.alternate),receiptRevision=\(receipt.revision),"+Prior.inputState(self.owner,bridge))
                forward?(receipt)
            }
            defer{bridge.activate=forward}
            Prior.boundary("operand Return begin "+Prior.inputState(owner,bridge)+","+diagnostic("before-Return"))
            try require(bridge.observe(SyncPrimaryActivationVerification.key(window,code:36))==nil,"Native Return escaped source list")
            Prior.boundary("operand Return ended forwarded=\(receipts.count),"+Prior.inputState(owner,bridge)+","+diagnostic("after-Return"))
            try require(receipts.count==1,"Native Return consumed without forwarding one accepted selected-row receipt; "+Prior.inputState(owner,bridge))
            try require(receipts[0].revision==bridge.revision && GitPathSet(receipts[0].paths)==selection,"Native Return forwarded another generation/selected path set; "+diagnostic("forwarded-Return"))
        }
        func launch(_ value:StatusListPrimaryActivationSession.Launch?) {commit?.model.onPrimaryFileActivation=value;status?.model.onPrimaryFileActivation=value;revert?.model.onPrimaryFileActivation=value}
        func confirm(_ value:((Int)async->Bool)?) {commit?.model.confirmPrimaryFileActivation=value;status?.model.confirmPrimaryFileActivation=value;revert?.model.confirmPrimaryFileActivation=value}
        func compare(_ paths:[String]) {commit?.model.compare(paths:paths);status?.model.diff(paths);revert?.model.diff(paths)}
    }
    static func verifyDeliveries(_ values:[Delivery],plan:StatusListPrimaryActivation,repository:GitRepository,expectedBase:ComparisonRevision,symlinkTarget:String="target-new.txt")async throws {
        let expected=plan.actions.compactMap{action->StatusEntry? in if case .comparison(let row)=action{return row.entry};return nil}
        try require(values.map{$0.file.path}==expected.map(\.path),"Root lost accepted display order")
        for(value,row)in zip(values,expected) {
            let code:String=expectedBase == .emptyTree ? "A":row.state == .conflicted ? "M":row.index=="A" || row.worktree=="A" ? "A":row.index=="D" || row.worktree=="D" ? "D":row.index=="R" || row.worktree=="R" ? "R":row.index=="C" || row.worktree=="C" ? "C":"M"
            try require(value.file.action==code,"Accepted action reclassified for "+row.path)
            try require(value.snapshot.from==(code=="A" ? .emptyTree:expectedBase) && value.snapshot.to==(code=="D" ? .emptyTree:.workingTree),"Null/pinned operands recaptured for "+row.path)
            if code=="R" || code=="C" {try require(value.file.oldPath.map{Data($0.utf8)}==row.originalPath.map{Data($0.utf8)},"Accepted raw old path replaced")}
            let document=try await repository.comparisonFile(value.snapshot,path:row.path)
            if code=="A" {try require(document.base.bytes.isEmpty && document.base.mode==nil,"Added old side was not empty")}
            if code=="D" {try require(document.destination.bytes.isEmpty && document.destination.mode==nil,"Deleted destination used recreated disk leaf")}
            if code=="R" || code=="C" {try require(document.base.path.utf8.elementsEqual(row.originalPath!.utf8) && document.base.mode != nil,"R/C old operand lost accepted source")}
            if code=="R",row.originalPath?.hasPrefix("old rename")==true {try require(document.base.bytes==Data("rename original\n".utf8),"Rename used a fresh paired source blob")}
            if code=="C" {try require(document.base.bytes==Data("copy original\n".utf8),"Copy used an unrelated source blob")}
            if row.path.contains("link") {try require(document.destination.mode=="120000" && document.destination.bytes==Data(symlinkTarget.utf8),"Symlink target was followed or retyped")}
        }
    }
    static func ordinary(base:URL,git:URL,kind:Kind,amend:Bool=false,againstHEAD:Bool=false,initial:Bool=false,rootCommit:Bool=false)async throws {
        let c=try Context(base:base,git:git)
        var source:Surface?
        do {
            try await c.setup(initial:initial,rootCommit:rootCommit)
            let view=Surface(kind,c,amend:amend,againstHEAD:againstHEAD,copyProjection:kind == .commit && !amend && !initial);source=view;try await view.ready()
            print(view.diagnostic(base.lastPathComponent+"-ready"))
            let selected=try await view.select(c.wanted);try require(selected.count>=4,"Operand selection did not exercise shared warning; "+view.diagnostic("warning-count"))
            if rootCommit {
                // Pinned CommitDlg.cpp1508–1513 likewise normalizes root amend
                // to comparison against HEAD when no parent exists.
                try require(view.commit?.model.amend == true && view.commit?.model.amendDiffToLastCommit == true && view.commit?.model.amendToParent == false,"Root amend did not normalize to HEAD; "+view.diagnostic("root-normalization"))
            }
            let expectedBase:ComparisonRevision=initial ? .emptyTree:.revision(view.commit?.model.amendToParent == true ? c.parent:c.head)
            let required=c.wanted.filter{!(initial || expectedBase == .emptyTree) || $0 != c.deleted}
            try require(GitPathSet(selected)==GitPathSet(required),"Actual report omitted accepted A/D/R/C/M/link projection; required=\(String(reflecting:required)),selected=\(String(reflecting:selected)); "+view.diagnostic("required-rows"))
            let root=c.root();var deliveries:[Delivery]=[],accepted:StatusListPrimaryActivation?,warnings:[Int]=[]
            root.fileComparisonPresentation={deliveries.append(Delivery(snapshot:$0,file:$1))}
            view.launch{plan,token in accepted=plan;try await root.showStatusListPrimaryFiles(plan,access:nil,cancellation:token)}
            var answer:CheckedContinuation<Bool,Never>?
            c.unblock.append{answer?.resume(returning:false);answer=nil}
            view.confirm{count in warnings.append(count);return await withCheckedContinuation{answer=$0}}
            try await view.enter();try await wait("Accepted operand warning absent"){answer != nil}
            if !initial && !rootCommit {
                // Files change while the immutable row plan is held. No source
                // refresh is requested: this inspects the accepted list.
                try Data("recreated deleted disk\n".utf8).write(to:c.folder.appendingPathComponent(c.deleted))
                try Data("renamed destination changed after admission\n".utf8).write(to:c.folder.appendingPathComponent(c.renamed))
                let alternate=try await c.repo.run(["commit-tree",c.head+"^{tree}","-p",c.head],input:Data("Private moved HEAD\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
                _=try await c.repo.run(["update-ref","HEAD",alternate])
            }
            try await c.checkpoint();answer?.resume(returning:true);answer=nil
            try await wait("Accepted Root operand dispatch did not drain"){!view.pending && !view.busy && !root.hasPendingRepositoryWork}
            let plan=try Prior.unwrap(accepted,"Source did not deliver an operand plan")
            try require(warnings==[selected.count] && plan.base==expectedBase,"Source base/warning intent changed")
            try require(plan.actions.allSatisfy{if case .comparison = $0{return true};return false},"Tracked accepted operand became preview/missing dispatch")
            try await verifyDeliveries(deliveries,plan:plan,repository:c.repo,expectedBase:expectedBase,symlinkTarget:initial ? "initial-target":"target-new.txt")
            if expectedBase != .emptyTree,let modified=deliveries.first(where:{$0.file.path==c.modified}) {
                let document=try await c.repo.comparisonFile(modified.snapshot,path:c.modified)
                let old=rootCommit || expectedBase == .revision(c.parent) && c.parent != c.head ? "parent value\n":"HEAD value\n"
                try require(document.base.bytes==Data(old.utf8),"HEAD/amend old operand bytes changed")
            }
            try await c.preserved()
            // Explicit Compare uses the same accepted row operands, without
            // becoming default conflict-edit or unversioned preview dispatch.
            deliveries=[];accepted=nil;view.confirm{_ in true};view.compare(selected)
            try await wait("Explicit accepted comparison did not drain"){!view.pending && !view.busy && !root.hasPendingRepositoryWork}
            let explicit=try Prior.unwrap(accepted,"Explicit menu did not use typed accepted rows")
            try await verifyDeliveries(deliveries,plan:explicit,repository:c.repo,expectedBase:explicit.base,symlinkTarget:initial ? "initial-target":"target-new.txt")
            if kind == .commit,!amend,!initial,let commit=view.commit {
                deliveries=[];accepted=nil;c.copySourceOverride="absent accepted copy source.txt"
                commit.model.reload(paths:["."]);try await view.ready();_ = try await view.select([c.copied])
                let reloadedRow=commit.model.entries.first{$0.path==c.copied}
                let describeRow:(StatusEntry)->String={row in
                    "path=\(String(reflecting:row.path)),XY=\(row.index)\(row.worktree),originalPath=\(String(reflecting:row.originalPath)),reportingActions=\(row.reportingActions.rawValue),comparisonAction=\(row.comparisonAction),reportingOriginalPath=\(String(reflecting:row.reportingOriginalPath)),hasUnversionedCopy=\(row.hasUnversionedCopy)"
                }
                do {
                    try await view.enter()
                    try await wait("Required absent accepted origin did not refuse") {!view.pending && !view.busy && commit.model.error != nil}
                    try require(deliveries.isEmpty && commit.window?.isVisible==true,"Missing accepted origin was silently reclassified Added")
                } catch {
                    let planDescription=accepted.map{plan in
                        let actions=plan.actions.prefix(24).map{action in
                            let kind:String
                            switch action {case .conflict:kind="conflict";case .comparison:kind="comparison";case .workingFile:kind="workingFile";case .skipMissing:kind="skipMissing"}
                            return kind+"["+describeRow(action.file.entry)+"]"
                        }
                        return "base=\(plan.base),count=\(plan.selectedCount),ownerCurrent=\(plan.ownerIsCurrent()),sameWindow=\(plan.window === commit.window),actions=\(actions)"
                    } ?? "none"
                    let delivered=deliveries.prefix(24).map{"path=\(String(reflecting:$0.file.path)),action=\($0.file.action),old=\(String(reflecting:$0.file.oldPath)),from=\($0.snapshot.from),to=\($0.snapshot.to)"}
                    print("MISSING ORIGIN: reloadedRow=\(reloadedRow.map(describeRow) ?? "absent"),acceptedPlan=\(planDescription),error=\(String(reflecting:commit.model.error)),pending=\(view.pending),busy=\(view.busy),sheet=\(commit.window?.attachedSheet != nil),visible=\(commit.window?.isVisible == true),sourceClosed=\(!commit.model.messageFocusAvailable),fileListAvailable=\(commit.model.fileListAvailable),reportRevision=\(commit.model.fileReportRevision),menuRevision=\(commit.model.fileReportMenuRevision),deliveries=\(delivered),boundaries=\(Prior.inputBoundaries)")
                    print(view.diagnostic("missing-origin-failure"));fflush(stdout)
                    throw error
                }
                commit.model.error=nil
                try await wait("Missing-origin error did not detach"){commit.window?.attachedSheet==nil}
            }
            if !initial && !rootCommit {
                var pointer=false,pointerOperands=false;root.fileComparisonPresentation=nil
                root.submoduleDiffPresentation={child in c.owners.append(child);pointer=true;pointerOperands=child.model.from.isEmpty && child.model.to==nil && child.model.toIndex}
                let pointerSelection=try await view.select([c.module]);try require(pointerSelection==[c.module],"Actual source omitted added gitlink");try await view.enter()
                try await wait("Actual gitlink route absent"){pointer && !view.pending && !view.busy}
                try require(pointerOperands,"Added gitlink did not use null/index pointer route")
            }
            try await c.preserved()
            view.launch(nil);view.confirm(nil);try await c.cleanup();print("PASS OPERAND COHORT: "+base.lastPathComponent)
        } catch {source?.launch(nil);source?.confirm(nil);try? await c.cleanup();throw error}
    }
    static func gui(base:URL,git:URL)async throws {
        let c=try Context(base:base,git:git)
        do {
            try await c.setup();c.prefs.set(true,forKey:"TurtleGit.Commit.GitGuiInterface")
            let owner=CommitWindowController(repository:c.repo,access:nil,defaults:c.prefs),model=owner.model,root=c.root()
            c.owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil);model.reload(paths:["."])
            func ready()async throws {
                try await wait("Actual GUI staged operand report unavailable") {
                    owner.window?.contentView?.layoutSubtreeIfNeeded()
                    return model.gitGuiInterface && model.fileListAvailable && !model.busy && !model.fileWorkPending && !model.loadingAmendMessage && !model.loadingFileMetadata && model.commitIdentityPrepared && model.changelistsLoaded && model.fileListTable(key:"staged") != nil
                }
            }
            try await ready()
            let pane=model.guiFileListSnapshot(staged:true),wanted=GitPathSet([c.added,c.deleted,c.renamed,c.modified])
            let selected=pane.entries.filter{wanted.contains($0.path)}.map(\.path)
            try require(GitPathSet(selected)==wanted,"GUI staged projection omitted accepted A/D/R/M")
            let table=try Prior.unwrap(model.fileListTable(key:"staged"),"GUI table not mounted")
            try require(table.window===owner.window && owner.window!.makeFirstResponder(table),"GUI staged focus owner changed")
            table.selectRowIndexes(IndexSet(pane.entries.indices.filter{wanted.contains(pane.entries[$0].path)}),byExtendingSelection:false)
            try await wait("Actual GUI native selection unavailable"){model.guiStaged && model.selection==wanted && model.guiPatch?.busy != true}
            var deliveries:[Delivery]=[],plan:StatusListPrimaryActivation?,warnings:[Int]=[],answer:CheckedContinuation<Bool,Never>?
            c.unblock.append{answer?.resume(returning:false);answer=nil}
            root.fileComparisonPresentation={deliveries.append(Delivery(snapshot:$0,file:$1))}
            model.onPrimaryFileActivation={value,token in plan=value;try await root.showStatusListPrimaryFiles(value,access:nil,cancellation:token)}
            model.confirmPrimaryFileActivation={count in warnings.append(count);return await withCheckedContinuation{answer=$0}}
            let menu=model.fileMenu(selected,orderedEntries:pane.entries,gui:pane)
            model.withFileMenu(menu){model.compare(paths:selected)}
            try await wait("GUI explicit Compare did not retain pane question"){answer != nil}
            try Data("GUI deleted recreated after acceptance\n".utf8).write(to:c.folder.appendingPathComponent(c.deleted))
            try await c.checkpoint();answer?.resume(returning:true);answer=nil
            try await wait("GUI explicit Compare did not drain"){!model.primaryActivationPending && !model.busy && !root.hasPendingRepositoryWork}
            let accepted=try Prior.unwrap(plan,"GUI explicit Compare lost post-own-busy receipt")
            try require(warnings==[selected.count] && accepted.actions.allSatisfy{if case .comparison = $0{return true};return false},"GUI warning/mode changed")
            try await verifyDeliveries(deliveries,plan:accepted,repository:c.repo,expectedBase:.revision(c.head));try await c.preserved()
            // Retire the accepted staging-pane generation while its question is
            // suspended. A stale affirmative reply must never launch a child.
            deliveries=[];plan=nil;warnings=[]
            let fresh=model.guiFileListSnapshot(staged:true),next=model.fileMenu(selected,orderedEntries:fresh.entries,gui:fresh)
            model.withFileMenu(next){model.compare(paths:selected)}
            try await wait("GUI stale-generation question absent"){answer != nil}
            model.stagingEnabled.toggle()
            answer?.resume(returning:true);answer=nil
            try await wait("GUI retired staging pane did not cancel/drain"){!model.primaryActivationPending && !model.busy && !root.hasPendingRepositoryWork}
            try require(plan==nil && deliveries.isEmpty && owner.window?.isVisible==true,"Stale GUI staging generation launched or closed source")
            try await c.preserved();model.onPrimaryFileActivation=nil;model.confirmPrimaryFileActivation=nil;try await c.cleanup();print("PASS OPERAND COHORT: gui")
        } catch {try? await c.cleanup();throw error}
    }
    static func setupOperandReplay(_ c:ReplayRecoveryPrimaryVerification.Context)async throws {
        let repo=c.repository
        _=try await repo.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Replay Operand QA"),("user.email","replay-operands@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
        // Different historical blobs make the accepted Rename and Deleted
        // identities unambiguous; no fresh detector may swap their operands.
        for(path,text)in[(c.conflict,"conflict base\n"),(c.other,"conflict base\n"),(c.retained,"unique historical rename source\n"),(c.modified,"independent historical deleted source\n"),(c.normal,"ordinary historical base\n")] {try Data(text.utf8).write(to:c.folder.appendingPathComponent(path))}
        try await repo.stage(["."]);_=try await repo.commit(message:"Replay operand base")
        let base=try await repo.rebaseCommit("HEAD")
        _=try await repo.run(["switch","-c","upstream"])
        for path in [c.conflict,c.other] {try Data("upstream conflict\n".utf8).write(to:c.folder.appendingPathComponent(path))}
        try await repo.stage(["."]);_=try await repo.commit(message:"Replay operand upstream")
        _=try await repo.run(["switch","-c","topic",base.hash])
        for path in [c.conflict,c.other] {try Data("topic conflict\n".utf8).write(to:c.folder.appendingPathComponent(path))}
        try Data("ordinary cleanly applied topic\n".utf8).write(to:c.folder.appendingPathComponent(c.normal))
        try await repo.stage(["."]);_=try await repo.commit(message:"Replay operand topic")
        var options=RebaseOptions();options.branch="topic";options.upstream="upstream"
        let plan=try await repo.rebasePlan(options)
        let editor=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac")
        try require(FileManager.default.isExecutableFile(atPath:editor.path),"Built private replay sequence editor unavailable")
        _=try await repo.startRebase(plan,editorExecutable:editor)
        try require(try await repo.conflicts().count==2,"Operand replay did not stop with actual conflicts")
        try MergeToolPreferences.load(from:c.prefs).save(to:c.prefs)
    }
    static func replay(base:URL,git:URL)async throws {
        let c=try ReplayRecoveryPrimaryVerification.Context(base:base,git:git,cherry:false)
        do {
            try await setupOperandReplay(c)
            let renamed="retained renamed 雪.txt",added="ordinary added.txt"
            try await c.repository.stage([c.retained]);_=try await c.repository.run(["mv","--",c.retained,renamed]);_=try await c.repository.run(["rm","-f","--",c.modified])
            try Data("new replay addition\n".utf8).write(to:c.folder.appendingPathComponent(added));try await c.repository.stage([added])
            let owner=RebaseWindowController(repository:c.repository,access:nil,preferences:c.prefs),root=c.root();c.own(owner)
            ReplayRecoveryPrimaryVerification.configure(root,owner,c);owner.model.load()
            let table=try await ReplayRecoveryPrimaryVerification.table(owner)
            let rawStatus=try await c.repository.run(["status","--porcelain=v1","-z","--untracked-files=all"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"]).stdout
            let rowEvidence=owner.model.conflictTableRows.prefix(24).map {row in
                "\(String(reflecting:row.entry.path)):\(row.entry.index)\(row.entry.worktree),old=\(String(reflecting:row.entry.originalPath)),copy=\(row.entry.hasUnversionedCopy)"
            }
            let nativeDiagnostic=ReplayRecoveryPrimaryVerification.selectionDiagnostic(owner,table)
            let diagnostic="OPERAND REPLAY rows=\(rowEvidence),raw=\(String(reflecting:String(decoding:rawStatus.prefix(8192),as:UTF8.self))),native=\(nativeDiagnostic)"
            print(diagnostic)
            try Data(diagnostic.utf8).write(to:c.folder.deletingLastPathComponent().appendingPathComponent("replay-operands-projection.txt"))
            let selected=try await ReplayRecoveryPrimaryVerification.select([renamed,added,c.modified,c.normal],owner,table)
            try require(GitPathSet(selected)==GitPathSet([renamed,added,c.modified,c.normal]),"Actual Replay omitted accepted operand rows")
            var plan:StatusListPrimaryActivation?,values:[Delivery]=[],warnings:[Int]=[],answer:CheckedContinuation<Bool,Never>?
            c.unblock.append{answer?.resume(returning:false);answer=nil}
            root.fileComparisonPresentation={values.append(Delivery(snapshot:$0,file:$1))}
            owner.model.onPrimaryConflictFileActivation={value,token in plan=value;try await root.showStatusListPrimaryFiles(value,access:nil,cancellation:token)}
            owner.model.confirmPrimaryConflictFileActivation={count in warnings.append(count);return await withCheckedContinuation{answer=$0}}
            try await ReplayRecoveryPrimaryVerification.enter(owner,table)
            try await wait("Replay accepted operand warning absent"){answer != nil}
            try Data("recreated replay deleted leaf\n".utf8).write(to:c.folder.appendingPathComponent(c.modified))
            try Data("renamed replay destination after admission\n".utf8).write(to:c.folder.appendingPathComponent(renamed))
            // This family intentionally changes the private setup after the
            // existing helper's original baseline. Retain its strict original
            // assertions unchanged; record this cohort's new exact baseline.
            let replayHead=try await c.repository.run(["rev-parse","HEAD"]).stdout
            let replayIndex=try Data(contentsOf:c.folder.appendingPathComponent(".git/index"))
            var replayFiles:[String:Data]=[:]
            for path in [renamed,added,c.modified,c.normal,c.conflict] {replayFiles[path]=try Data(contentsOf:c.folder.appendingPathComponent(path))}
            answer?.resume(returning:true);answer=nil
            try await wait("Replay accepted operand dispatch did not drain"){!owner.model.busy && !owner.model.primaryConflictActivationPending && !root.hasPendingRepositoryWork}
            let accepted=try Prior.unwrap(plan,"Replay did not deliver accepted rows")
            try require(warnings==[selected.count] && accepted.actions.map{$0.file.entry.path}==selected,"Replay warning/order changed")
            try await verifyDeliveries(values,plan:accepted,repository:c.repository,expectedBase:accepted.base)
            for(path,code)in[(renamed,"R"),(added,"A"),(c.modified,"D"),(c.normal,"M")] {
                let value=try Prior.unwrap(values.first{$0.file.path==path},"Replay omitted authored "+code+" operand")
                try require(value.file.action==code,"Replay historical fixture did not retain authored "+code+" identity")
                let content=try await c.repository.comparisonFile(value.snapshot,path:path)
                if path==renamed {try require(value.file.oldPath==c.retained && content.base.bytes==Data("unique historical rename source\n".utf8),"Replay rename used deleted row's historical origin")}
                if path==c.modified {try require(content.base.bytes==Data("independent historical deleted source\n".utf8),"Replay deletion used renamed row's historical origin")}
                if path==c.normal {try require(content.base.bytes==Data("ordinary historical base\n".utf8),"Replay ordinary old side changed")}
            }
            owner.model.confirmPrimaryConflictFileActivation={_ in true}
            // Compare a real conflict explicitly: HEAD/working contents rather
            // than the stage-1 ancestor or primary conflict editor.
            values=[];plan=nil
            let menu=owner.model.conflictFileMenu([c.conflict]);owner.model.compareConflictMenu(menu)
            try await wait("Replay explicit conflict comparison did not drain"){!owner.model.busy && !owner.model.primaryConflictActivationPending && !root.hasPendingRepositoryWork}
            let explicit=try Prior.unwrap(plan,"Replay explicit conflict Compare skipped typed plan")
            try require(explicit.actions.allSatisfy{if case .comparison = $0{return true};return false},"Explicit Compare launched conflict editor")
            try await verifyDeliveries(values,plan:explicit,repository:c.repository,expectedBase:explicit.base)
            try require(try await c.repository.run(["rev-parse","HEAD"]).stdout==replayHead,"Replay read-only operands changed HEAD")
            try require(try Data(contentsOf:c.folder.appendingPathComponent(".git/index"))==replayIndex,"Replay read-only operands changed exact index")
            for(path,bytes)in replayFiles {try require(try Data(contentsOf:c.folder.appendingPathComponent(path))==bytes,"Replay comparison changed "+path)}
            try await c.cleanup();print("PASS OPERAND COHORT: replay")
        } catch {try? await c.cleanup();throw error}
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietOperandOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietOperandSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quiet);method_exchangeImplementations(sheet,quietSheet)
        defer{method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quiet)}
        let base=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL,git=URL(fileURLWithPath:CommandLine.arguments[2])
        let only=Set(CommandLine.arguments.dropFirst(3))
        let valid:Set<String>=["commit","status","revert","amend-parent","amend-HEAD","root-amend","unborn","replay","gui"]
        try require(only.isSubset(of:valid),"Unknown operand cohort selector")
        for kind in Kind.allCases where only.isEmpty || only.contains(kind.rawValue) {try await ordinary(base:base.appendingPathComponent(kind.rawValue),git:git,kind:kind)}
        if only.isEmpty || only.contains("amend-parent") {try await ordinary(base:base.appendingPathComponent("amend-parent"),git:git,kind:.commit,amend:true)}
        if only.isEmpty || only.contains("amend-HEAD") {try await ordinary(base:base.appendingPathComponent("amend-HEAD"),git:git,kind:.commit,amend:true,againstHEAD:true)}
        if only.isEmpty || only.contains("root-amend") {try await ordinary(base:base.appendingPathComponent("root-amend"),git:git,kind:.commit,amend:true,rootCommit:true)}
        if only.isEmpty || only.contains("unborn") {try await ordinary(base:base.appendingPathComponent("unborn"),git:git,kind:.commit,initial:true)}
        if only.isEmpty || only.contains("gui") {try await gui(base:base.appendingPathComponent("gui"),git:git)}
        if only.isEmpty || only.contains("replay") {try await replay(base:base.appendingPathComponent("replay"),git:git)}
        print("PASS: Accepted status comparison operands through actual Classic/Working Tree/Revert/Replay source reports and Root; ordered A/D/R/controlled-C/null sides/raw old paths, held warning, HEAD/amend/root/unborn, GUI explicit Compare/stale staging receipt, symlink and gitlink routes; private owners drained")
    }
}
