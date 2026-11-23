// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func quietScopedOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;quietScopedOrder(mode,relativeTo:number)}
    @objc func quietScopedSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?){sheet.alphaValue=0;quietScopedSheet(sheet,completionHandler:completionHandler)}
}
@MainActor @main enum ScopedWorkingReadsVerification {
    typealias Prior=StatusPrimaryActivationVerification
    static func require(_ value:Bool,_ text:String,line:Int = #line)throws {try Prior.require(value,"Scoped native \(line): "+text)}
    static func wait(_ text:String,_ ready:()->Bool)async throws {try await Prior.wait(text,ready)}
    static func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    struct Receipt {let file:String,args:[String]}
    static func wrapper(base:URL,git:URL)throws->URL {
        let result=base.appendingPathComponent("held-helper"),records=base.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at:records,withIntermediateDirectories:true)
        let script="""
        #!/bin/sh
        set -C
        receipts=\(quote(records.path))
        hold=\(quote(base.appendingPathComponent("hold-status").path))
        marker=\(quote(base.appendingPathComponent("status-ready").path))
        (umask 077; printf '%s\\000' "$@" > "$receipts/$$.args") || exit 96
        is_status=false
        for word in "$@"; do [ "$word" = status ] && is_status=true; done
        if $is_status && [ -f "$hold" ]; then
          (set +C; printf '%s\\n' "$$" > "$marker")
          while [ -f "$hold" ]; do /bin/sleep 0.02; done
        fi
        exec \(quote(git.path)) "$@"
        """
        try Data(script.utf8).write(to:result);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:result.path)
        return result
    }
    @MainActor final class Context {
        let base:URL,folder:URL,repo:GitRepository,seed:GitRepository,prefs:UserDefaults,suite:String
        let scope="selected 雪\n[*]",other="other generated",tracked:String,old:String,renamed:String,untracked:String,clean:String,ignored:String,otherTracked:String
        var owners:[NSWindowController]=[],roots:[RepositoryModel]=[],head=Data(),index=Data(),working:[String:Data]=[:]
        init(base:URL,name:String,git:URL,wrapper:URL)throws {
            self.base=base;folder=base.appendingPathComponent(name).standardizedFileURL
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            tracked=scope+"/modified.txt";old=scope+"/rename old.txt";renamed=scope+"/renamed.txt";untracked=scope+"/unknown\t.txt";clean=scope+"/clean.txt";ignored=scope+"/ignored.tmp";otherTracked=other+"/outside.txt"
            repo=GitRepository(root:folder,executable:wrapper,libgit2Configuration:.init(enabled:false));seed=GitRepository(root:folder,executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.ScopedReads."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            for key in ["UseLibgit2","EnableLogCache","EnableGravatar","ConfirmKillProcess","RevertWithRecycleBin"] {prefs.set(false,forKey:key)}
        }
        func setup()async throws {
            _=try await seed.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Scoped Native QA"),("user.email","scoped@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await seed.run(["config",key,value])}
            for directory in [scope,other] {try FileManager.default.createDirectory(at:folder.appendingPathComponent(directory),withIntermediateDirectories:true)}
            for(path,text)in[(other+"/unstaged.txt","outside original unstaged\n"),(tracked,"base modified\n"),(old,"independent rename body\n"),(clean,"clean direct body\n"),(otherTracked,"outside base\n"),(".gitignore","*.tmp\n")] {try Data(text.utf8).write(to:folder.appendingPathComponent(path))}
            try await seed.stage(["."]);_=try await seed.commit(message:"Scoped working read source")
            try Data("selected working change\n".utf8).write(to:folder.appendingPathComponent(tracked));try Data("outside staged first\noutside staged second\n".utf8).write(to:folder.appendingPathComponent(otherTracked))
            _=try await seed.run(["mv","--",old,renamed]);try Data("selected unknown\n".utf8).write(to:folder.appendingPathComponent(untracked));try Data("selected ignored\n".utf8).write(to:folder.appendingPathComponent(ignored))
            try Data("outside unstaged edit\n".utf8).write(to:folder.appendingPathComponent(other+"/unstaged.txt"))
            try await seed.stage([tracked,otherTracked])
            try Data("selected working change\nselected extra\n".utf8).write(to:folder.appendingPathComponent(tracked))
            try Data("outside staged first\noutside staged second\noutside unstaged extra\n".utf8).write(to:folder.appendingPathComponent(otherTracked))
            for number in 0..<40 {try Data("outside generated\n".utf8).write(to:folder.appendingPathComponent(other+"/generated-\(number).tmp"))}
            try Data("outside unknown\n".utf8).write(to:folder.appendingPathComponent(other+"/unknown.txt"))
            head=try await seed.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
            for path in [tracked,renamed,clean,untracked,ignored,otherTracked,other+"/unstaged.txt"] {working[path]=try Data(contentsOf:folder.appendingPathComponent(path))}
        }
        func receipts()->[Receipt] {
            ((try? FileManager.default.contentsOfDirectory(at:base.appendingPathComponent("receipts"),includingPropertiesForKeys:nil)) ?? []).compactMap {url in
                guard let data=try? Data(contentsOf:url),data.last==0 else{return nil}
                let values=data.split(separator:0,omittingEmptySubsequences:false).dropLast().map{String(decoding:$0,as:UTF8.self)}
                guard let root=values.firstIndex(of:"-C"),values.indices.contains(root+1),values[root+1]==folder.path else{return nil}
                return Receipt(file:url.lastPathComponent,args:values)
            }
        }
        func mark()->Set<String> {Set(receipts().map(\.file))}
        func prove(_ phase:String,after before:Set<String>,allowed:[String],requiresStatus:Bool=true,commitStaged:String?=nil)throws {
            let values=receipts().filter{!before.contains($0.file)}
            var inspected=0,statuses=0,raw=0,indexes=0
            for value in values {
                let args=value.args
                var cursor=0
                while cursor<args.count {
                    if ["-C","-c"].contains(args[cursor]) {cursor += 2;continue}
                    if args[cursor].hasPrefix("-") {cursor += 1;continue}
                    break
                }
                guard cursor<args.count else{continue};let command=args[cursor]
                guard command=="status" || command=="ls-files" || ((command=="diff" || command=="diff-index") && (args.contains("--raw") || args.contains("--numstat") || args.contains("--name-status"))) else{continue}
                inspected += 1;if command=="status" {statuses += 1};if command=="ls-files" {indexes += 1};if args.contains("--raw") {raw += 1}
                if commitStaged != nil,(command=="diff" || command=="diff-index"),args.contains("--cached"),args.last=="--" {continue}
                guard let boundary=args.lastIndex(of:"--"),boundary+1<args.count else{throw NSError(domain:"ScopedNative",code:1,userInfo:[NSLocalizedDescriptionKey:"Unbounded query at \(phase): \(String(reflecting:args))"])}
                for path in args[(boundary+1)...] {
                    let acceptedSupplement=command != "status" || args.contains("--untracked-files=no") && !args.contains("--ignored")
                    let permitted=acceptedSupplement ? allowed+(commitStaged.map{[$0]} ?? []):allowed
                    try require(permitted.contains{root in GitReferenceName.equal(root,path) || path.utf8.starts(with:(root+"/").utf8)},"Query escaped original scope at \(phase): \(String(reflecting:args))")
                }
            }
            try require(inspected>0 && (!requiresStatus || statuses>0),"No actual scoped Git query recorded at "+phase)
            let receipt:[String:Any]=["phase":phase,"scope":allowed,"statusQueries":statuses,"rawQueries":raw,"indexQueries":indexes,"commands":values.map{["file":$0.file,"args":$0.args]}]
            try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:base.appendingPathComponent(folder.lastPathComponent+"-"+phase+"-argv.json"))
        }
        func own(_ owner:NSWindowController){owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)}
        func mounted()async throws {
            guard let owner=owners.first else {throw Prior.Failure(description:"No owned report")}
            try await wait("Scoped report did not mount its exact accepted projection") {
                owner.window?.contentView?.layoutSubtreeIfNeeded()
                if let add=owner as? AddWindowController {
                    return Prior.views(owner.window?.contentView).compactMap{$0 as? NSTableView}.contains {table in
                        guard let source=table.dataSource as? AddFileTable.Coordinator else{return false}
                        return table.window === owner.window && table.numberOfRows==add.model.entries.count && GitPathSet(source.rows.map(\.path))==GitPathSet(add.model.entries.map(\.path))
                    }
                }
                guard let revert=owner as? RevertWindowController else{return false}
                return Prior.views(owner.window?.contentView).compactMap{$0 as? StatusListPrimaryActionBridge.Probe}.contains {probe in
                    probe.active && probe.window === owner.window && GitPathSet(probe.rows.compactMap{$0})==GitPathSet(revert.model.entries.map(\.path))
                }
            }
        }
        func root()->RepositoryModel {
            let value=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotStore:FinderSnapshotStore(url:folder.appendingPathComponent("finder.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:folder.appendingPathComponent("marks.json")),cachePersistenceDefaults:prefs)
            value.fileComparisonPreferences=prefs;roots.append(value);return value
        }
        func preserved()async throws {
            try require(try await seed.run(["rev-parse","HEAD"]).stdout==head,"Scoped read changed HEAD")
            try require(try Data(contentsOf:folder.appendingPathComponent(".git/index"))==index,"Scoped read changed exact index")
            for(path,bytes)in working {try require(try Data(contentsOf:folder.appendingPathComponent(path))==bytes,"Scoped operation changed unrelated/accepted bytes: "+path)}
        }
        func cleanup()async throws {
            try? FileManager.default.removeItem(at:base.appendingPathComponent("hold-status"));owners.forEach{$0.close()};roots.forEach{$0.stopMonitoringForTermination()}
            try await wait("Owned scoped windows/workers did not drain"){Prior.drained() && AddWindowModel.activeOperations==0 && RevertProgressWindowModel.activeOperations==0 && RevertProgressWindowController.activeReleases==0 && roots.allSatisfy{!$0.hasPendingRepositoryWork} && owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil}}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func add(base:URL,git:URL,wrapper:URL)async throws {
        let c=try Context(base:base,name:"add",git:git,wrapper:wrapper)
        do {
            try await c.setup();let owner=AddWindowController(repository:c.repo,access:nil,defaults:c.prefs),model=owner.model
            model.setScope([c.scope]);let before=c.mark();c.own(owner);model.reload()
            try await wait("Actual scoped Add report unavailable"){owner.window?.contentView?.layoutSubtreeIfNeeded();return !model.busy && model.entries.contains{$0.path==c.untracked}}
            try require(model.entries.allSatisfy{$0.path.utf8.starts(with:(c.scope+"/").utf8)} && !model.entries.contains{$0.path==c.ignored},"Add initial ignore/scope semantics changed")
            try await c.mounted()
            try c.prove("folder",after:before,allowed:[c.scope]);try await c.preserved()
            let direct=[c.tracked,c.renamed,c.clean,c.untracked,c.ignored],next=c.mark()
            model.setScope(direct);model.includeIgnored=true;model.reload()
            try await wait("Scoped Add direct/ignored reload unavailable"){owner.window?.contentView?.layoutSubtreeIfNeeded();return !model.busy && GitPathSet(model.entries.map(\.path))==GitPathSet(direct)}
            try await c.mounted()
            try require(model.invocationPaths==direct && model.entries.contains{$0.path==c.clean && $0.state == .normal},"Add lost clean direct row or original invocation")
            try require(GitPathSet(model.indexFlagFiles.map(\.id))==GitPathSet(direct),"Add flags gathered unrelated working tree")
            try c.prove("direct-reload",after:next,allowed:direct);try await c.preserved();try await c.cleanup();print("PASS SCOPED COHORT: add")
        } catch {try? await c.cleanup();throw error}
    }
    static func revert(base:URL,git:URL,wrapper:URL)async throws {
        let c=try Context(base:base,name:"revert",git:git,wrapper:wrapper)
        do {
            try await c.setup();let owner=RevertWindowController(repository:c.repo,access:nil,preferences:c.prefs),model=owner.model
            let before=c.mark();c.own(owner);model.setScope([c.scope])
            try await wait("Actual scoped Revert report unavailable"){owner.window?.contentView?.layoutSubtreeIfNeeded();return model.canInteract && model.entries.contains{$0.path==c.tracked} && model.entries.contains{$0.path==c.renamed}}
            try require(model.entries.allSatisfy{$0.path.utf8.starts(with:(c.scope+"/").utf8)},"Revert displayed unrelated inventory")
            let rename=try Prior.unwrap(model.entries.first{$0.path==c.renamed},"Scoped rename absent")
            try require(rename.isRenamed && rename.reportingOriginalPath==c.old,"Scoped directory lost old-name pairing inside its boundary")
            try await c.mounted()
            try c.prove("folder",after:before,allowed:[c.scope]);try await c.preserved()
            let reload=c.mark();model.reload();try await wait("Scoped Revert refresh did not drain"){model.canInteract}
            try c.prove("refresh",after:reload,allowed:[c.scope]);try await c.preserved()
            let root=c.root();var progress:RevertProgressWindowController?,attempts=0,factoryScope:[String]?,finished=false
            root.makeDirectRevertProgress={repository,access,entries,amend,againstHead,prefs,policy,scope in
                factoryScope=scope
                let child=RevertProgressWindowController(repository:repository,access:access,entries:entries,amend:amend,againstHead:againstHead,autoCloseSuccess:false,preferences:prefs,policy:policy,paths:scope)
                c.owners.append(child);progress=child
                child.model.execute={rows,token,notify,output in
                    attempts += 1
                    if attempts==1 {throw NSError(domain:"ScopedRetryFixture",code:1,userInfo:[NSLocalizedDescriptionKey:"Private first-attempt failure before mutation"])}
                    return try await repository.revertWorkingFiles(rows,amend:amend,amendDiffToLastCommit:againstHead,policy:policy,paths:scope,cancellation:token,progress:notify,onOutput:output)
                }
                return child
            }
            model.onAccepted={entries in
                let accepted=model.invocationPaths
                _=root.showDirectRevert(repository:c.repo,access:nil,entries:entries,owner:nil,preferences:c.prefs,policy:.init(recycle:false),needsConfirmation:false,paths:accepted,available:{true},completion:{finished=$0})
            }
            model.checked=[];model.setChecked([c.tracked],value:true);model.apply()
            try await wait("Actual Root Revert failure/retry window unavailable"){progress?.model.failed==true && progress?.model.busy==false}
            let child=try Prior.unwrap(progress,"Owned progress absent")
            try require(factoryScope==[c.scope] && child.model.invocationPaths==[c.scope] && root.hasPendingRepositoryWork,"Root lost immutable invocation boundary/child ownership")
            try await c.preserved()
            let outsideIndex=try await c.seed.run(["ls-files","--stage","-z","--",c.otherTracked]).stdout
            let retry=c.mark();child.model.retry()
            try await wait("Actual scoped Revert retry did not drain"){child.model.busy==false && child.model.failed==false && attempts==2}
            try c.prove("retry-mutation",after:retry,allowed:[c.scope])
            try require(try Data(contentsOf:c.folder.appendingPathComponent(c.tracked))==Data("base modified\n".utf8),"Scoped retry did not actually restore selected contents")
            try require(try await c.seed.run(["ls-files","--stage","-z","--",c.otherTracked]).stdout==outsideIndex,"Scoped retry changed unrelated staged inventory")
            c.working[c.tracked]=Data("base modified\n".utf8);c.index=try Data(contentsOf:c.folder.appendingPathComponent(".git/index"))
            child.close();try await wait("Root selected request did not close/drain"){finished && !root.hasPendingRepositoryWork}
            try await c.preserved();try await c.cleanup();print("PASS SCOPED COHORT: revert")
        } catch {try? await c.cleanup();throw error}
    }
    static func commit(base:URL,git:URL,wrapper:URL)async throws {
        let c=try Context(base:base,name:"commit",git:git,wrapper:wrapper)
        do {
            try await c.setup()
            for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation","AddBeforeCommit"] {c.prefs.set(true,forKey:key)}
            c.prefs.set(false,forKey:"TurtleGit.Commit.GitGuiInterface")
            let owner=CommitWindowController(repository:c.repo,access:nil,defaults:c.prefs),model=owner.model
            let before=c.mark();c.own(owner);model.reload(paths:[c.scope],wholeProject:false)
            @MainActor func ready()->Bool {
                owner.window?.contentView?.layoutSubtreeIfNeeded()
                return model.fileListAvailable && model.commitIdentityPrepared && model.changelistsLoaded && !model.loadingFileMetadata && !model.fileWorkPending && !model.savingPreferences
            }
            @MainActor func scopedProjection()throws {
                let ids=GitPathSet(model.visibleEntries.map(\.path))
                try require(!model.showWholeProject && ids.contains(c.untracked) && ids.contains(c.tracked) && ids.contains(c.otherTracked),"Scoped Commit omitted selected/unversioned or global staged row")
                try require(!ids.contains(c.other+"/unknown.txt") && !ids.contains(c.other+"/unstaged.txt"),"Scoped Commit inventoried unrelated unstaged/untracked rows")
                let outside=try Prior.unwrap(model.entries.first{$0.path==c.otherTracked},"Outside staged row absent")
                try require(outside.index=="M" && outside.worktree=="M" && model.stagingState(outside) == .mixed,"Scoped Commit lost outside partially staged metadata")
                try require(model.statistics[c.otherTracked]?.added==2 && model.statistics[c.otherTracked]?.removed==1,"Classic outside row lost cached source-statistics fallback")
                try require(model.statistics[c.tracked]?.added==2 && model.statistics[c.tracked]?.removed==1,"Classic selected row lost whole-working statistics precedence")
            }
            try await wait("Actual scoped Classic Commit unavailable"){ready() && model.fileListTable(key:"checkbox")?.window === owner.window}
            try scopedProjection()
            let report=try await Prior.bridge(owner)
            try require(GitPathSet(report.rows.compactMap{$0})==GitPathSet(model.visibleEntries.map(\.path)),"Classic native projection differs from accepted scoped rows")
            try c.prove("commit-classic",after:before,allowed:[c.scope],commitStaged:c.otherTracked);try await c.preserved()
            let whole=c.mark();model.setShowWholeProject(true)
            try await wait("Actual Whole Project did not reload expanded inventory"){ready() && model.showWholeProject && model.visibleEntries.contains{$0.path==c.other+"/unknown.txt"} && model.visibleEntries.contains{$0.path==c.other+"/unstaged.txt"}}
            let global=c.receipts().filter{!whole.contains($0.file)}
            try require(global.contains{$0.args.contains("status") && !$0.args.contains("--")},"Whole Project did not perform its explicit global status read")
            try JSONSerialization.data(withJSONObject:global.map{["file":$0.file,"args":$0.args]},options:[.prettyPrinted,.sortedKeys]).write(to:base.appendingPathComponent("commit-whole-project-argv.json"))
            try await c.preserved()
            let restore=c.mark();model.setShowWholeProject(false)
            try await wait("Actual Whole Project restore did not settle"){ready() && !model.showWholeProject}
            try scopedProjection();try c.prove("commit-restored",after:restore,allowed:[c.scope],commitStaged:c.otherTracked);try await c.preserved()
            let staging=c.mark();model.setCommitInterface(true)
            try await wait("Actual scoped staging reports unavailable"){ready() && model.gitGuiInterface && model.fileListTable(key:"staged")?.window === owner.window && model.fileListTable(key:"unstaged")?.window === owner.window}
            try scopedProjection()
            try require(model.stagedEntries.contains{$0.path==c.otherTracked} && model.unstagedEntries.contains{$0.path==c.otherTracked} && model.unstagedEntries.contains{$0.path==c.untracked},"Staging panes lost outside partial/selected untracked split")
            try require(model.stagedStatistics[c.otherTracked]?.added==2 && model.stagedStatistics[c.otherTracked]?.removed==1 && model.unstagedStatistics[c.otherTracked]?.added==1 && model.unstagedStatistics[c.otherTracked]?.removed==0,"Outside partially staged panes lost bounded cached/working statistics")
            try c.prove("commit-staging",after:staging,allowed:[c.scope],commitStaged:c.otherTracked);try await c.preserved()
            let hold=base.appendingPathComponent("hold-status"),marker=base.appendingPathComponent("status-ready")
            try? FileManager.default.removeItem(at:marker);try Data().write(to:hold)
            let cancel=c.mark();model.reload()
            try await wait("Actual scoped Commit status read did not hold"){FileManager.default.fileExists(atPath:marker.path)}
            try require(CommitWindowModel.activeReloads>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held Commit read lost Quit ownership")
            model.cancel()
            try await wait("Actual scoped Commit Cancel did not drain"){owner.window?.isVisible != true && !model.busy && Prior.drained()}
            try? FileManager.default.removeItem(at:hold)
            try c.prove("commit-cancel",after:cancel,allowed:[c.scope],commitStaged:c.otherTracked);try await c.preserved()
            try await c.cleanup();print("PASS SCOPED COHORT: commit")
        } catch {try? await c.cleanup();throw error}
    }
    static func rescopeCancel(base:URL,git:URL,wrapper:URL)async throws {
        let c=try Context(base:base,name:"rescope",git:git,wrapper:wrapper)
        do {
            try await c.setup();let owner=RevertWindowController(repository:c.repo,access:nil,preferences:c.prefs),model=owner.model
            let hold=base.appendingPathComponent("hold-status"),marker=base.appendingPathComponent("status-ready")
            try? FileManager.default.removeItem(at:marker);try Data().write(to:hold)
            let before=c.mark();c.own(owner);model.setScope([c.scope])
            try await wait("Actual first scoped status command did not hold"){FileManager.default.fileExists(atPath:marker.path)}
            model.setScope([c.other])
            try await wait("Replacement scoped command absent"){c.receipts().contains{$0.args.contains("status") && $0.args.last==c.other}}
            try require(model.busy && RevertWindowModel.activeOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Rescope dropped active read/Quit ownership")
            try FileManager.default.removeItem(at:hold)
            try await wait("Latest scoped Revert report did not publish"){owner.window?.contentView?.layoutSubtreeIfNeeded();return model.canInteract && model.invocationPaths==[c.other] && model.entries.contains{$0.path==c.otherTracked}}
            try require(!model.entries.contains{$0.path==c.tracked},"Retired initial scope published into replacement")
            try c.prove("rescope",after:before,allowed:[c.scope,c.other]);try await c.preserved()
            let add=AddWindowController(repository:c.repo,access:nil,defaults:c.prefs);add.model.setScope([c.scope]);c.own(add)
            try? FileManager.default.removeItem(at:marker);try Data().write(to:hold);let cancel=c.mark()
            add.model.reload();try await wait("Actual Add selected status did not hold"){FileManager.default.fileExists(atPath:marker.path)}
            add.model.cancel()
            try await wait("Cancelled Add read/window did not drain"){!add.model.busy && add.window?.isVisible != true && Prior.drained() && AddWindowModel.activeOperations==0}
            try? FileManager.default.removeItem(at:hold)
            try c.prove("cancel",after:cancel,allowed:[c.scope]);try await c.preserved();try await c.cleanup();print("PASS SCOPED COHORT: rescope-cancel")
        } catch {try? await c.cleanup();throw error}
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietScopedOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietScopedSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quiet);method_exchangeImplementations(sheet,quietSheet)
        defer{method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quiet)}
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),only=Set(CommandLine.arguments.dropFirst(3))
        try require(only.isSubset(of:["add","revert","rescope-cancel","commit"]),"Unknown scoped cohort")
        let executable=try wrapper(base:base,git:git)
        if only.isEmpty || only.contains("commit"){try await commit(base:base,git:git,wrapper:executable)}
        if only.isEmpty || only.contains("add"){try await add(base:base,git:git,wrapper:executable)}
        if only.isEmpty || only.contains("revert"){try await revert(base:base,git:git,wrapper:executable)}
        if only.isEmpty || only.contains("rescope-cancel"){try await rescopeCancel(base:base,git:git,wrapper:executable)}
        print("PASS: Scoped Add/Revert native reads, literal status/raw/index argv receipts, accepted clean/ignored/rename scope, actual Root retry boundary, rescope/cancel ownership and no unrelated inventory")
    }
}
