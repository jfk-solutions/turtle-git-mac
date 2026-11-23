// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func quietChangedOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;quietChangedOrder(mode,relativeTo:number)}
    @objc func quietChangedSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?){sheet.alphaValue=0;quietChangedSheet(sheet,completionHandler:completionHandler)}
}
@MainActor @main enum ChangedScopedStatusVerification {
    typealias Old=ScopedWorkingReadsVerification
    typealias Prior=StatusPrimaryActivationVerification
    typealias Context=Old.Context
    static func require(_ value:Bool,_ text:String,line:Int = #line)throws {try Prior.require(value,"Changed scoped \(line): "+text)}
    static func wait(_ text:String,_ ready:()->Bool)async throws {try await Prior.wait(text,ready)}
    static func ready(_ owner:StatusWindowController)->Bool {owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.hasStatusSnapshot}
    static func mount(_ owner:StatusWindowController)async throws {
        let probe=try await Prior.bridge(owner)
        try require(GitPathSet(probe.rows.compactMap{$0})==GitPathSet(owner.model.visibleFiles.map(\.id)),"Native report differs from published scoped identities")
    }
    static func prove(_ c:Context,_ phase:String,after mark:Set<String>,scope:[String]?,staged:Bool,outside:[String]=[],requiresStatus:Bool=true)throws {
        let rows=c.receipts().filter{!mark.contains($0.file)}
        var queries=0,statuses=0
        for row in rows {
            let args=row.args;var cursor=0
            while cursor<args.count {
                if ["-C","-c"].contains(args[cursor]) {cursor += 2;continue}
                if args[cursor].hasPrefix("-") {cursor += 1;continue};break
            }
            guard cursor<args.count else{continue};let command=args[cursor]
            guard command=="status" || command=="ls-files" || ["diff","diff-index"].contains(command) && !Set(args).isDisjoint(with:["--raw","--numstat","--name-status","--name-only"]) else{continue}
            queries += 1;if command=="status"{statuses += 1}
            guard let scope else{continue}
            if staged,["diff","diff-index"].contains(command),args.contains("--cached"),args.last=="--" {continue}
            guard let boundary=args.lastIndex(of:"--"),boundary+1<args.count else {throw Prior.Failure(description:"Unbounded Changed query at \(phase): \(String(reflecting:args))")}
            let supplement=staged && (command != "status" || args.contains("--untracked-files=no") && !args.contains("--ignored"))
            for path in args[(boundary+1)...] {
                let within=scope.contains{GitReferenceName.equal(path,$0) || path.utf8.starts(with:($0+"/").utf8)}
                try require(within || supplement && outside.contains{GitReferenceName.equal($0,path)},"Changed query escaped accepted boundary at \(phase): \(String(reflecting:args))")
            }
        }
        try require(queries>0 && (!requiresStatus || statuses>0),"Missing actual Changed query at "+phase)
        let receipt:[String:Any]=["phase":phase,"scope":scope ?? [],"global":scope==nil,"includedStaged":staged,"outside":outside,"queries":rows.map{["file":$0.file,"args":$0.args]}]
        try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:c.base.appendingPathComponent(c.folder.lastPathComponent+"-"+phase+"-argv.json"))
    }
    static func prepare(base:URL,git:URL,wrapper:URL,name:String,crossBoundary:Bool)async throws->(Context,String,String) {
        let c=try Context(base:base,name:name,git:git,wrapper:wrapper);try await c.setup()
        let old=c.other+"/unstaged.txt",destination=(crossBoundary ? c.scope:c.other)+"/moved 雪.txt"
        _=try await c.seed.run(["mv","--",old,destination])
        c.working.removeValue(forKey:old);c.working[destination]=try Data(contentsOf:c.folder.appendingPathComponent(destination))
        c.index=try Data(contentsOf:c.folder.appendingPathComponent(".git/index"))
        c.prefs.set(false,forKey:"ChangedFilesIncludeStaged")
        return(c,old,destination)
    }
    static func projection(base:URL,git:URL,wrapper:URL)async throws {
        let(c,old,moved)=try await prepare(base:base,git:git,wrapper:wrapper,name:"projection",crossBoundary:true)
        do {
            let root=c.root(),owner=StatusWindowController(repository:c.repo,access:nil,defaults:c.prefs),model=owner.model
            let before=c.mark();c.own(owner);model.setScope([c.scope])
            try await wait("Scoped Working Tree unavailable"){ready(owner)};try await mount(owner)
            let accepted=try Prior.unwrap(model.files.first{$0.id==moved},"Selected arrival absent")
            try require(accepted.entry.reportingActions.contains(.added) && !accepted.entry.isRenamed && accepted.entry.reportingOriginalPath==nil,"Global rename escaped the original literal selected query")
            try require(model.fileMenu([moved]).commands.contains(.oldNameLog)==false,"Scoped Added arrival exposed global old-name action")
            try require(!model.visibleFiles.contains{$0.id==c.otherTracked},"Show Staged off included outside staged row")
            try prove(c,"initial",after:before,scope:[c.scope],staged:false);try await c.preserved()
            var comparisons:[(RevisionComparisonSnapshot,CommitFile)]=[]
            root.fileComparisonPresentation={comparisons.append(($0,$1))}
            model.onPrimaryFileActivation={plan,token in try await root.showStatusListPrimaryFiles(plan,access:nil,cancellation:token)}
            try await Prior.select(owner,paths:[moved],accepted:{model.selection==GitPathSet([moved])})
            model.diff([moved],saving:false)
            try await wait("Actual scoped Added comparison did not drain"){!model.busy && !root.hasPendingRepositoryWork && comparisons.count==1}
            let comparison=try Prior.unwrap(comparisons.first,"Actual comparison absent"),document=try await c.repo.comparisonFile(comparison.0,path:moved)
            try require(comparison.1.action=="A" && comparison.1.oldPath==nil && comparison.0.from == .emptyTree && document.base.bytes.isEmpty && document.base.mode==nil && document.destination.bytes==c.working[moved],"Scoped accepted Added operands were reclassified during Root handoff")
            let included=c.mark();var filter=model.filter;filter.showAllStaged=true;model.setFilter(filter)
            try await wait("Show Staged refresh did not settle"){ready(owner) && model.files.contains{$0.id==c.otherTracked}}
            try await mount(owner)
            let outside=try Prior.unwrap(model.files.first{$0.id==c.otherTracked},"Outside MM absent")
            let rename=try Prior.unwrap(model.files.first{$0.id==moved},"Included staged Rename absent")
            try require(outside.entry.index=="M" && outside.entry.worktree=="M" && rename.entry.isRenamed && rename.entry.reportingOriginalPath==old,"Included staged raw rows lost MM/R provenance")
            try require(model.fileMenu([moved]).commands.contains(.oldNameLog),"Included staged Rename lost old-name action")
            try require(model.statistics[c.otherTracked]?.added==2 && model.statistics[c.otherTracked]?.removed==1 && model.statistics[c.tracked]?.added==2 && model.statistics[c.tracked]?.removed==1,"Inside whole/outside cached line counts differ from authored source history")
            try require(!model.files.contains{$0.id==c.other+"/unknown.txt"},"Included staged widened untracked inventory")
            try prove(c,"staged-on",after:included,scope:[c.scope],staged:true,outside:[c.otherTracked,old,moved]);try await c.preserved()
            let whole=c.mark();filter=model.filter;filter.wholeProject=true;model.setFilter(filter)
            try await wait("Whole Project did not acquire outside unknown file"){ready(owner) && model.visibleFiles.contains{$0.id==c.other+"/unknown.txt"}}
            try prove(c,"whole",after:whole,scope:nil,staged:true);try await c.preserved()
            let restored=c.mark();filter=model.filter;filter.wholeProject=false;filter.showAllStaged=false;model.setFilter(filter)
            try await wait("Scoped source projection did not return"){ready(owner) && model.files.first{$0.id==moved}?.entry.reportingActions.contains(.added)==true}
            try require(!model.visibleFiles.contains{$0.id==c.otherTracked} && !model.files.contains{$0.id==c.other+"/unknown.txt"},"Restored scope retained outside snapshot")
            try prove(c,"restored",after:restored,scope:[c.scope],staged:false);try await c.preserved();try await c.cleanup();print("PASS CHANGED COHORT: projection")
        } catch {try? await c.cleanup();throw error}
    }
    static func retry(base:URL,git:URL,wrapper:URL)async throws {
        let(c,old,moved)=try await prepare(base:base,git:git,wrapper:wrapper,name:"retry",crossBoundary:false)
        do {
            c.prefs.set(true,forKey:"ChangedFilesIncludeStaged")
            let root=c.root(),owner=StatusWindowController(repository:c.repo,access:nil,defaults:c.prefs),model=owner.model
            c.own(owner);model.setScope([c.scope]);try await wait("Outside staged source Rename unavailable"){ready(owner) && model.files.first{$0.id==moved}?.entry.isRenamed==true}
            try await mount(owner)
            var progress:RevertProgressWindowController?,attempts=0,finished=false,scope:WorkingFileRevertReadScope?
            root.makeDirectRevertProgress={repository,access,rows,amend,against,prefs,policy,paths,readScope in
                scope=readScope
                let child=RevertProgressWindowController(repository:repository,access:access,entries:rows,amend:amend,againstHead:against,autoCloseSuccess:false,preferences:prefs,policy:policy,paths:paths,readScope:readScope)
                c.owners.append(child);progress=child
                child.model.execute={rows,token,notify,output in
                    attempts += 1
                    if attempts==1 {throw Prior.Failure(description:"Private Revert failure before mutation")}
                    return try await repository.revertWorkingFiles(rows,amend:amend,amendDiffToLastCommit:against,policy:policy,paths:paths,readScope:readScope,cancellation:token,progress:notify,onOutput:output)
                };return child
            }
            model.onRevert={rows,policy,_,done in
                let captured=WorkingFileRevertReadScope(paths:model.pendingRevertInvocationPaths,includedStaged:model.pendingRevertIncludesStaged,additionalPaths:model.pendingRevertAdditionalPaths)
                return root.showDirectRevert(repository:c.repo,access:nil,entries:rows,owner:nil,preferences:c.prefs,policy:policy,needsConfirmation:false,paths:captured.paths,readScope:captured,available:{model.revertSelectionIsCurrent},completion:{finished=$0;done($0)})
            }
            try await Prior.select(owner,paths:[moved],accepted:{model.selection==GitPathSet([moved])})
            let unrelatedIndex=try await c.seed.run(["ls-files","--stage","-z","--",c.tracked,c.otherTracked,c.renamed]).stdout
            let before=c.mark();model.requestRevert(model.fileMenu([moved]))
            try await wait("Actual scoped Rename Revert failure unavailable"){progress?.model.failed==true && progress?.model.busy==false}
            let child=try Prior.unwrap(progress,"Owned Revert missing"),captured=try Prior.unwrap(scope,"Read scope missing")
            try require(captured.paths==[c.scope] && captured.includedStaged && GitPathSet(captured.additionalPaths)==GitPathSet([old,moved]),"Accepted Revert widened read scope or admitted another staged row")
            try require(model.busy && root.hasPendingRepositoryWork && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Failed result lost source/Quit ownership")
            try await c.preserved();child.model.retry()
            try await wait("Outside accepted Rename Retry did not complete"){child.model.busy==false && child.model.failed==false && attempts==2}
            try require(FileManager.default.fileExists(atPath:c.folder.appendingPathComponent(old).path) && !FileManager.default.fileExists(atPath:c.folder.appendingPathComponent(moved).path),"Actual Retry failed to restore accepted original path")
            try require(try Data(contentsOf:c.folder.appendingPathComponent(old))==Data("outside original unstaged\n".utf8),"Retry restored wrong outside Rename source bytes")
            child.close();try await wait("Source/Root Revert completion did not drain"){finished && !root.hasPendingRepositoryWork && ready(owner)}
            try prove(c,"revert-retry",after:before,scope:[c.scope],staged:true,outside:[old,moved,c.otherTracked])
            try require(try await c.seed.run(["ls-files","--stage","-z","--",c.tracked,c.otherTracked,c.renamed]).stdout==unrelatedIndex,"Outside Rename Revert altered unrelated staged entries")
            c.working.removeValue(forKey:moved);c.working[old]=Data("outside original unstaged\n".utf8);c.index=try Data(contentsOf:c.folder.appendingPathComponent(".git/index"))
            try await c.preserved()
            var filter=model.filter;filter.showAllStaged=false;model.setFilter(filter);try await wait("Show Staged off post-Revert did not settle"){ready(owner)}
            try require(!model.fileMenu([old]).offersRevert && !model.fileMenu([moved]).offersRevert,"Scoped off snapshot reacquired outside Revert target")
            try await c.cleanup();print("PASS CHANGED COHORT: retry")
        } catch {try? await c.cleanup();throw error}
    }
    static func cancellation(base:URL,git:URL,wrapper:URL)async throws {
        let c=try Context(base:base,name:"cancellation",git:git,wrapper:wrapper)
        do {
            try await c.setup();c.prefs.set(false,forKey:"ChangedFilesIncludeStaged")
            let owner=StatusWindowController(repository:c.repo,access:nil,defaults:c.prefs),model=owner.model
            c.own(owner);model.setScope([c.scope]);try await wait("Initial Changed snapshot unavailable"){ready(owner)};try await mount(owner)
            let accepted=model.files.map(\.entry),hold=base.appendingPathComponent("hold-status"),marker=base.appendingPathComponent("status-ready")
            try? FileManager.default.removeItem(at:marker);try Data().write(to:hold)
            let before=c.mark();model.reload();try await wait("Actual Changed refresh status did not hold"){FileManager.default.fileExists(atPath:marker.path)}
            try require(StatusWindowModel.activeOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held refresh lost Quit guard")
            try require(model.cancelOperation(),"Actual Cancel refused active refresh")
            try await wait("Cancelled Changed refresh did not drain"){!model.busy && Prior.drained()}
            try? FileManager.default.removeItem(at:hold)
            try require(owner.window?.isVisible==true && model.refreshCancelled && model.files.map(\.entry)==accepted,"Cancelled refresh closed source or replaced last complete report")
            try prove(c,"cancel",after:before,scope:[c.scope],staged:false);try await c.preserved()
            try? FileManager.default.removeItem(at:marker);try Data().write(to:hold)
            let rescope=c.mark();model.reload();try await wait("Second Changed refresh did not hold"){FileManager.default.fileExists(atPath:marker.path)}
            model.setScope([c.other]);try require(model.cancelOperation(),"Pending rescope Cancel refused")
            try await wait("Queued replacement status absent"){c.receipts().contains{$0.args.contains("status") && $0.args.last==c.other}}
            try FileManager.default.removeItem(at:hold)
            try await wait("Queued rescope failed to publish latest report"){ready(owner) && model.filter.paths==[c.other] && model.files.contains{$0.id==c.otherTracked}}
            try require(!model.files.contains{$0.id==c.tracked},"Retired scope polluted replacement report")
            try prove(c,"rescope",after:rescope,scope:[c.scope,c.other],staged:false);try await c.preserved()
            try? FileManager.default.removeItem(at:marker);try Data().write(to:hold)
            let forced=c.mark();model.reload();try await wait("Forced-close Changed worker did not hold"){FileManager.default.fileExists(atPath:marker.path)}
            owner.close();try await wait("Forced Changed close did not drain real worker"){model.retired && owner.window?.isVisible != true && Prior.drained()}
            try? FileManager.default.removeItem(at:hold)
            try prove(c,"forced-close",after:forced,scope:[c.other],staged:false);try await c.preserved();try await c.cleanup();print("PASS CHANGED COHORT: cancellation")
        } catch {try? await c.cleanup();throw error}
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietChangedOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietChangedSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quiet);method_exchangeImplementations(sheet,quietSheet)
        defer{method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quiet)}
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),only=Set(CommandLine.arguments.dropFirst(3))
        try require(only.isSubset(of:["projection","retry","cancellation"]),"Unknown Changed cohort")
        let wrapper=try Old.wrapper(base:base,git:git)
        if only.isEmpty || only.contains("projection"){try await projection(base:base,git:git,wrapper:wrapper)}
        if only.isEmpty || only.contains("retry"){try await retry(base:base,git:git,wrapper:wrapper)}
        if only.isEmpty || only.contains("cancellation"){try await cancellation(base:base,git:git,wrapper:wrapper)}
        print("PASS: Changed scoped reports, conditional outside staged Rename/MM, accepted Added comparison, immutable Revert Retry, literal argv and Cancel/rescope/forced-close ownership")
    }
}
