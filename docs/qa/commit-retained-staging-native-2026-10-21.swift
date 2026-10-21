// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func turtleRetainedCommitOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-18000,y:-18000));turtleRetainedCommitOrder(place,relativeTo:number)
    }
}
@MainActor enum RetainedCommitStagingVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws{if !condition{throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func wait(line:Int = #line,_ predicate:()->Bool)async throws{for _ in 0..<3000{if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Retained staging timeout at \(line)")}
    static func ready(_ model:CommitWindowModel)async throws {
        do{try await wait{!model.busy && !model.fileWorkPending && !model.stagingStateNeedsRefresh && model.commitIdentityPrepared && model.changelistsLoaded && !model.loadingAuthorIdentity && !model.loadingAuthorDate && !model.loadingAmendMessage && !model.mergeHintVisible && !model.stagingHintVisible}}
        catch{throw Failure(description:"Native retained-stage readiness: busy=\(model.busy) workers=\(model.pendingFileOperations) refresh=\(model.stagingStateNeedsRefresh) staging=\(model.stagingEnabled) identity=\(model.commitIdentityPrepared) changelists=\(model.changelistsLoaded) author=\(model.loadingAuthorIdentity) authorDate=\(model.loadingAuthorDate) amend=\(model.loadingAmendMessage) hint=\(model.stagingHintVisible) error=\(model.error ?? "nil"); \(error)")}
        try require(model.stagingEnabled && model.error==nil,"Native retained-stage failed or mode unavailable: "+(model.error ?? "nil"))
    }
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.RetainedStaging."+UUID().uuidString,prefs:UserDefaults
        var owners:[CommitWindowController]=[]
        init(){prefs=UserDefaults(suiteName:suite)!;for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation"]{prefs.set(true,forKey:key)};prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"SelectFilesForCommit");prefs.set(false,forKey:"AddBeforeCommit")}
        func fixture(_ name:String,_ files:[String:String])async throws->GitRepository {
            let folder=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let repo=GitRepository(root:folder,executable:git,libgit2Configuration:.init(enabled:false));_=try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Retained staging QA"),("user.email","staging@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport","true")] {_=try await repo.run(["config",key,value])}
            for(path,text)in files{try Data(text.utf8).write(to:folder.appendingPathComponent(path))};try await repo.stage(Array(files.keys));_=try await repo.commit(message:"base");return repo
        }
        func owner(_ repo:GitRepository)->CommitWindowController {
            let owner=CommitWindowController(repository:repo,access:RepositoryAccessLease(url:root),defaults:prefs);owners.append(owner);owner.window?.alphaValue=0;owner.window?.orderFront(nil);owner.model.reload(paths:["."]);return owner
        }
        func drained()->Bool{CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && owners.allSatisfy{!$0.model.fileWorkPending}}
        func cleanup()async{owners.forEach{$0.close()};for window in NSApp.windows{window.orderOut(nil);window.close()};for _ in 0..<3000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)};prefs.removePersistentDomain(forName:suite)}
    }
    static func cached(_ repo:GitRepository)async throws->Set<Data>{Set(try await repo.run(["diff","--cached","--no-renames","--name-only","-z"]).stdout.split(separator:0).map{Data($0)})}
    static func staging(_ c:Context)async throws {
        let old="old 雪\n[*]",new="-new 雪\t[*]",repo=try await c.fixture("rename",[old:"renamed bytes\n","other":"unrelated base\n"])
        try Data("unrelated staged\n".utf8).write(to:repo.root.appendingPathComponent("other"));try await repo.stage(["other"]);_=try await repo.run(["mv","--",old,new])
        let owner=c.owner(repo),model=owner.model;try await ready(model)
        let row=try unwrap(model.entries.first{$0.path==new},"Actual rename row missing");try require(row.index=="R" && row.originalPath==old && model.stagingState(row) == .on,"Initial actual rename projection missing")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        model.setFileChecked(row,files:model.visibleEntries,highlighted:[row.id],checked:false,receipt:model.fileCheckReceipt);try await ready(model)
        try require(model.entries.contains(row) && model.stagingState(row) == .off,"Whole-file Off replaced retained source rename row or failed state refresh")
        try require(try await cached(repo)==[Data("other".utf8)],"Rename Off touched unrelated stage or left old rename side")
        model.setFileChecked(row,files:model.visibleEntries,highlighted:[row.id],checked:true,receipt:model.fileCheckReceipt);try await ready(model)
        let fresh=try await repo.status();try require(fresh.first{$0.path==new}?.index=="R" && model.stagingState(row) == .on && model.entries.contains(row),"Retained rename On failed to stage both original sides")
        let staged=try await cached(repo);try require(staged==Set([old,new,"other"].map{Data($0.utf8)}),"Actual rename stage pathset or unrelated index changed")
        let other=try await repo.run(["show",":other"]).stdout;try require(other==Data("unrelated staged\n".utf8),"Unrelated index content changed")
        let tree=try await repo.run(["write-tree"]).stdout,stale=model.fileCheckReceipt;model.stagedDiff.toggle();model.moveToStage([row.id],staged:false,receipt:stale);await Task.yield()
        let afterStaleReceipt=try await repo.run(["write-tree"]).stdout
        try require(!model.busy && afterStaleReceipt==tree,"Retired native table receipt mutated index")
        model.setGroupChecked([row],checked:false,receipt:model.fileCheckReceipt);try await ready(model);model.setGroupChecked([row],checked:true,receipt:model.fileCheckReceipt);try await ready(model)
        try require(try await repo.run(["write-tree"]).stdout==tree,"Native group Off/On did not restore same exact rename tree")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && (try Data(contentsOf:repo.root.appendingPathComponent(new)))==Data("renamed bytes\n".utf8),"Staging changed source HEAD/working bytes")
        try await ambiguous(c)
    }
    static func ambiguous(_ c:Context)async throws {
        let repo=try await c.fixture("ambiguous",["remove":"identical\n","rename":"identical\n","other":"identical\n"])
        try FileManager.default.removeItem(at:repo.root.appendingPathComponent("remove"));_=try await repo.run(["mv","rename","renamed"])
        let owner=c.owner(repo),model=owner.model;try await ready(model)
        let rename=try unwrap(model.entries.first{$0.path=="renamed"},"Ambiguous retained rename missing"),remove=try unwrap(model.entries.first{$0.path=="remove"},"Ambiguous deletion missing"),retained=model.entries
        try require(rename.originalPath=="rename" && rename.index=="R","Initial native rename did not capture original source")
        model.setFileChecked(remove,files:model.visibleEntries,highlighted:[remove.id],checked:true,receipt:model.fileCheckReceipt);try await ready(model)
        try require(model.entries==retained && model.stagingState(remove) == .on && model.stagingState(rename) == .on,"Index re-pairing replaced native list/group rows")
        model.setFileChecked(rename,files:model.visibleEntries,highlighted:[rename.id,remove.id],checked:false,receipt:model.fileCheckReceipt);try await ready(model)
        try require(try await cached(repo).isEmpty,"Highlighted ambiguous retained rows left an original deletion staged")
        try require(model.entries==retained && model.stagingState(rename) == .off && model.stagingState(remove) == .off,"Ambiguous refresh lost exact retained row states")
        model.setGroupChecked([rename,remove],checked:true,receipt:model.fileCheckReceipt);try await ready(model)
        let staged=try await cached(repo);try require(staged==Set(["rename","renamed","remove"].map{Data($0.utf8)}),"Group stage used fresh guessed rename pairing instead of captured exact paths")
        model.setGroupChecked([rename,remove],checked:false,receipt:model.fileCheckReceipt);try await ready(model);try require(try await cached(repo).isEmpty,"Repeated ambiguous group Unstage left cached paths")
        try await retainedCopy(c)
    }
    static func retainedCopy(_ c:Context)async throws {
        let repo=try await c.fixture("copy",["source":"base copy\n"])
        try Data("base copy\n".utf8).write(to:repo.root.appendingPathComponent("copy"));try Data("unrelated source edit\n".utf8).write(to:repo.root.appendingPathComponent("source"))
        let owner=c.owner(repo),model=owner.model;try await ready(model)
        // Porcelain need not detect copies. Explicitly supply the legal retained
        // C-row model state, backed by independent real source/destination bytes;
        // this checks frontend scope, not Git's heuristic copy detection.
        let row=try unwrap(StatusEntry.parse(Data("C  copy\0source\0".utf8)).first,"Retained copy record missing")
        model.entries=model.entries.filter{$0.path != "copy"}+[row]
        model.setFileChecked(row,files:model.visibleEntries,highlighted:[row.id],checked:true,receipt:model.fileCheckReceipt);try await ready(model)
        try require(try await cached(repo)==[Data("copy".utf8)],"Retained native copy staged its modified source")
        let source=try await repo.run(["show",":source"]).stdout;try require(source==Data("base copy\n".utf8) && (try Data(contentsOf:repo.root.appendingPathComponent("source")))==Data("unrelated source edit\n".utf8),"Retained copy changed source index/working bytes")
        model.setGroupChecked([row],checked:false,receipt:model.fileCheckReceipt);try await ready(model);try require(try await cached(repo).isEmpty,"Copy Unstage expanded to source or retained destination")
    }
    static func ownership(_ c:Context)async throws {
        let old="old",new="new",repo=try await c.fixture("ownership",[old:"rename\n","other":"other\n"]);_=try await repo.run(["mv",old,new])
        let wrapper=c.root.appendingPathComponent("stage-git"),marker=c.root.appendingPathComponent("stage-pids")
        func q(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        let script="""
        #!/bin/sh
        case " $* " in *' add '*)
          /bin/sleep 30 &
          turtle_child=$!
          trap 'kill "$turtle_child" 2>/dev/null;wait "$turtle_child" 2>/dev/null;exit 143' TERM INT
          printf '%s %s\\n' "$$" "$turtle_child" > \(q(marker.path))
          wait "$turtle_child"
          ;;
        esac
        exec \(q(c.git.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let wrapped=GitRepository(root:repo.root,executable:wrapper,libgit2Configuration:.init(enabled:false)),owner=c.owner(wrapped),model=owner.model;try await ready(model)
        let row=try unwrap(model.entries.first{$0.path==new},"Owned rename row missing");model.moveToStage([row.id],staged:false);try await ready(model)
        let before=try await repo.run(["write-tree"]).stdout;var closed=false;owner.onClosed={closed=true}
        model.moveToStage([row.id],staged:true,receipt:model.fileCheckReceipt);try await wait{FileManager.default.fileExists(atPath:marker.path)}
        let pids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)};try require(pids.count==2 && model.fileWorkPending,"Actual staging operation was not owned")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped actual native whole-file staging")
        owner.close();try require(!closed && model.fileWorkPending,"Native owner released live Stage worker")
        try await wait{closed && !model.fileWorkPending};for pid in pids{try require(kill(pid,0) == -1 && errno==ESRCH,"Owned staging helper was not reaped")}
        let after=try await repo.run(["write-tree"]).stdout;try require(after==before && !model.messageFocusAvailable && (try Data(contentsOf:repo.root.appendingPathComponent(new)))==Data("rename\n".utf8),"Cancelled/retired Stage published index or changed working bytes")
        let retired=model.fileCheckReceipt;model.moveToStage([row.id],staged:true,receipt:retired);await Task.yield()
        let afterRetiredCallback=try await repo.run(["write-tree"]).stdout
        try require(!model.fileWorkPending && afterRetiredCallback==before,"Retired Commit accepted late Stage")
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleRetainedCommitOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let context=Context(),which=CommandLine.arguments[3]
        do{switch which{case "staging":try await staging(context);default:try await ownership(context)};await context.cleanup();try require(context.drained(),"Retained Commit owned work did not drain");print("PASS: retained Commit "+which)}catch{await context.cleanup();fputs("Retained Commit failed: \(error)\n",stderr);exit(1)}
    }
}
@main struct RetainedCommitMain{static func main()async{await RetainedCommitStagingVerification.main()}}
