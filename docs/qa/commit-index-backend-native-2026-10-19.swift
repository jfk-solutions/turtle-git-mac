// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum CommitIndexBackendVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static var owners:[CommitWindowModel]=[]
    static var controllers:[CommitWindowController]=[]
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Commit index timeout at \(line)")}
    static func drained()->Bool{CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0}
    static func cleanup()async{
        owners.forEach{$0.commitProgress?.cancellation.cancel();$0.invalidateForClose()}
        controllers.forEach{$0.close()}
        for _ in 0..<3000{owners.forEach{if $0.commitProgress?.busy==false{$0.commitProgress?.choose(nil)}};if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
        owners=[];controllers=[]
    }
    static func verify()async throws{
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),helper=URL(fileURLWithPath:CommandLine.arguments[3]),fm=FileManager.default
        let suite="TurtleGit.CommitIndexBackend."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,board=NSPasteboard.withUniqueName()
        defer{board.releaseGlobally();prefs.removePersistentDomain(forName:suite)}
        prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoCloseGitProgress")
        func fixture(_ name:String)async throws->GitRepository{
            let root=base.appendingPathComponent(name);try fm.createDirectory(at:root,withIntermediateDirectories:true)
            let repo=GitRepository(root:root,executable:git,askpass:nil)
            _ = try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Commit index QA"),("user.email","commit@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
            for path in ["checked.txt","unchecked.txt"]{try Data("base\n".utf8).write(to:root.appendingPathComponent(path))}
            try Data("*.txt filter=qa -text\n".utf8).write(to:root.appendingPathComponent(".gitattributes"))
            try await repo.stage(["checked.txt","unchecked.txt",".gitattributes"]);_ = try await repo.commit(message:"base")
            let filter=root.appendingPathComponent("clean")
            let script="""
            #!/bin/sh
            printf '%s\\n' "$PWD" >> "$0.log"
            if [ -f "$0.hold" ]; then
              /bin/rm -f "$0.hold"
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.ready"
              wait "$task_child"
            fi
            exec /usr/bin/sed 's/working/CLEANED/g'
            """
            try script.write(to:filter,atomically:true,encoding:.utf8);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:filter.path)
            let quoted="'"+filter.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
            _ = try await repo.run(["config","filter.qa.clean",quoted]);_ = try await repo.run(["config","filter.qa.required","true"])
            try Data("staged checked\n".utf8).write(to:root.appendingPathComponent("checked.txt"));try Data("staged unchecked\n".utf8).write(to:root.appendingPathComponent("unchecked.txt"));try await repo.stage(["checked.txt","unchecked.txt"])
            try Data("working checked\n".utf8).write(to:root.appendingPathComponent("checked.txt"));try Data("working unchecked\n".utf8).write(to:root.appendingPathComponent("unchecked.txt"))
            return repo
        }
        func owner(_ repo:GitRepository)async throws->CommitWindowModel{
            let controller=CommitWindowController(repository:repo,access:RepositoryAccessLease(url:repo.root),defaults:prefs),model=controller.model
            controllers.append(controller);owners.append(model);controller.window!.alphaValue=0;controller.window!.orderFront(nil)
            model.captureCommitBackend={.load(from:prefs,helperURL:helper)}
            model.reload(paths:["."]);try await wait{!model.busy && model.changelistsLoaded}
            model.message="native checkbox commit";model.checked=["checked.txt"]
            return model
        }
        // Default mask excludes COMMIT_UPDATE_INDEX3; explicit master-disable
        // also retains CLI index preparation even when bit3 is set.
        for(name,enabled,mask)in [("default-cli",true,nil as Int?),("master-disabled",false,8),("selected-tracked",true,8)]{
            prefs.removeObject(forKey:"UseLibgit2_mask");prefs.set(enabled,forKey:"UseLibgit2")
            if let mask{prefs.set(mask,forKey:"UseLibgit2_mask")}
            let repo=try await fixture(name)
            if name=="selected-tracked"{_ = try await repo.run(["update-index","--chmod=+x","--","checked.txt"])}
            let model=try await owner(repo)
            // An explicit staged executable mode survives a regular disk file;
            // checkbox mode updates its contents while retaining that index intent.
            if name=="selected-tracked"{try fm.setAttributes([.posixPermissions:0o644],ofItemAtPath:repo.root.appendingPathComponent("checked.txt").path)}
            model.commit();try await wait{model.commitProgress?.busy==false}
            let progress=model.commitProgress!
            try require(progress.success && model.acceptedCommitBackend?.requests(.commitUpdateIndex)==(name=="selected-tracked"),"Native Commit backend mismatch: "+name+" "+progress.output)
            progress.choose(nil);try await wait{!model.busy}
            let bytes=try await repo.run(["show","HEAD:checked.txt"]).stdout
            try require(bytes==Data("CLEANED checked\n".utf8),"CLI checkbox Commit lost selected working bytes")
            if name=="selected-tracked"{let mode=try await repo.run(["ls-tree","HEAD","--","checked.txt"]).text;try require(mode.hasPrefix("100755 "),"Selected checkbox preparation lost executable mode")}
        }
        prefs.set(true,forKey:"UseLibgit2");prefs.set(8,forKey:"UseLibgit2_mask")
        let repo=try await fixture("selected-held")
        let oneFilter=repo.root.appendingPathComponent("clean-one");try fm.copyItem(at:repo.root.appendingPathComponent("clean"),to:oneFilter)
        let cleanCommand="'"+oneFilter.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        _ = try await repo.run(["config","filter.one.clean",cleanCommand]);_ = try await repo.run(["config","filter.one.required","true"]);_ = try await repo.run(["config","filter.one.process","exit 86"])
        try Data("*.txt filter=qa -text\nuntracked.txt filter=one -text\n".utf8).write(to:repo.root.appendingPathComponent(".gitattributes"))
        try Data("working selected\n".utf8).write(to:repo.root.appendingPathComponent("untracked.txt"))
        let model=try await owner(repo);model.checked=["untracked.txt"];var committed=0;model.onCommitted={_ in committed += 1}
        model.issueProperties=IssueTrackerProperties(values:["bugtraq.warnifnoissue":"true"])
        var reply:((Bool)->Void)?;model.confirmMissingIssue={reply=$0}
        defer{reply?(false);reply=nil}
        model.commit();try await wait{reply != nil}
        prefs.set(false,forKey:"UseLibgit2");prefs.set(0,forKey:"UseLibgit2_mask")
        model.commit()
        reply?(true);reply=nil;try await wait{model.commitProgress?.busy==false}
        let progress=model.commitProgress!
        try require(progress.success && committed==1 && model.acceptedCommitBackend?.requests(.commitUpdateIndex)==true,"Accepted checkbox backend changed during preflight warning: "+progress.output)
        let cleanCalls=try String(contentsOf:repo.root.appendingPathComponent("clean-one.log"),encoding:.utf8).split(whereSeparator:\.isNewline)
        try require(cleanCalls.count==1,"Selected native Commit did not use one-shot clean exactly once")
        let checked=try await repo.run(["show","HEAD:untracked.txt"]).stdout,unchecked=try await repo.run(["show","HEAD:unchecked.txt"]).stdout
        let stagedUnchecked=try await repo.run(["show",":unchecked.txt"]).stdout
        try require(checked==Data("CLEANED selected\n".utf8) && unchecked==Data("base\n".utf8) && stagedUnchecked==Data("base\n".utf8),"Selected helper checkbox Commit changed selected/unchecked index policy")
        try require(try Data(contentsOf:repo.root.appendingPathComponent("unchecked.txt"))==Data("working unchecked\n".utf8),"Checkbox Commit changed unchecked working bytes")
        progress.choose(nil);try await wait{!model.busy}
        // Real clean worker cancellation retains HEAD/index until actual drain.
        prefs.set(true,forKey:"UseLibgit2");prefs.set(8,forKey:"UseLibgit2_mask")
        let cancelled=try await fixture("cancelled"),cancelModel=try await owner(cancelled)
        let head=try await cancelled.run(["rev-parse","HEAD"]).stdout
        cancelModel.issueProperties=IssueTrackerProperties(values:["bugtraq.warnifnoissue":"true"])
        var cancelReply:((Bool)->Void)?;cancelModel.confirmMissingIssue={cancelReply=$0};defer{cancelReply?(false)}
        cancelModel.commit();try await wait{cancelReply != nil}
        let index=try Data(contentsOf:cancelled.root.appendingPathComponent(".git/index"))
        try Data().write(to:cancelled.root.appendingPathComponent("clean.hold"));cancelReply?(true);cancelReply=nil
        let ready=cancelled.root.appendingPathComponent("clean.ready")
        try await wait{fm.fileExists(atPath:ready.path) && cancelModel.commitProgress != nil}
        let pids=try String(contentsOf:ready,encoding:.utf8).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        try require(pids.count==2,"Commit clean marker lost shell/child PIDs")
        let cancelledProgress=cancelModel.commitProgress!;cancelledProgress.cancel()
        try require(CommitWindowModel.activeCommitPreflights>0,"Commit cancellation released actual worker early")
        try await wait{!cancelledProgress.busy && pids.allSatisfy{kill($0,0) != 0}}
        try? fm.removeItem(at:cancelled.root.appendingPathComponent("clean.hold"))
        let afterHead=try await cancelled.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:cancelled.root.appendingPathComponent(".git/index"))
        try require(!cancelledProgress.success && head==afterHead && index==afterIndex,"Cancelled checkbox preparation published index/HEAD")
        cancelledProgress.choose(nil);try await wait{!cancelModel.busy && drained()}
        print("PASS Commit index backend: default/disabled and captured bit3 checkbox preparation, actual one-shot clean, checked later working bytes, unchecked index policy and cancelled child drain")
    }
}
