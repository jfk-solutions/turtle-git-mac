import AppKit
import TurtleGitCore

@main struct ReferenceDeleteVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool,_ message: String) throws { if !value { throw Failure(message:message) } }
    @MainActor static func find(_ view: NSView) -> NSTableView? {
        if let table=view as? NSTableView,table.accessibilityLabel()=="References" { return table }
        for child in view.subviews { if let result=find(child) { return result } };return nil
    }
    @MainActor static func wait(_ windows:[NSWindow]=[],_ ready:()->Bool) async throws {
        for _ in 0..<2000 { windows.forEach{$0.contentView?.layoutSubtreeIfNeeded()};if ready(){return};try await Task.sleep(nanoseconds:10_000_000) };throw Failure(message:"Timeout")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Reference deletion QA failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),client=root.appendingPathComponent("client"),remoteRoot=root.appendingPathComponent("remote.git")
        let suite="TurtleGit.ReferenceDelete.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite);prefs.synchronize() }
        try FileManager.default.createDirectory(at:client,withIntermediateDirectories:true)
        let repo=GitRepository(root:client,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Delete QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:client.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        for branch in ["keep","remoteTopic","heldRemote","slow/branch","slow/merge-base"] { _ = try await repo.run(["branch",branch]) }
        _ = try await repo.run(["tag","-a","release","-m","release"])
        _ = try await repo.run(["switch","-c","unmerged"]);_ = try await repo.run(["commit","--allow-empty","-m","unmerged"]);_ = try await repo.run(["switch","main"])
        _ = try await repo.run(["clone","--bare",client.path,remoteRoot.path]);_ = try await repo.run(["remote","add","origin",remoteRoot.path]);_ = try await repo.run(["fetch","origin"])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:client.appendingPathComponent(".git/index")),file=try Data(contentsOf:client.appendingPathComponent("file"))
        let owner=ReferenceBrowserWindowController(repository:repo,access:nil,initial:"refs/heads/keep",preferences:prefs){_ in};defer {owner.close()}
        owner.model.load();try await wait([owner.window!]){!owner.model.busy && owner.model.snapshot != nil}
        var prompt:ReferenceBrowserDeletionConfirmation?,answer:CheckedContinuation<Bool,Never>?
        owner.model.confirmDeletion={confirmation in prompt=confirmation;return await withCheckedContinuation {answer=$0}}
        func choose(_ name:String) async throws {
            let choice=owner.model.snapshot!.initialSelection(name);owner.model.setFolder(choice.folder);owner.model.selected=choice.reference
            try await wait([owner.window!]){(find(owner.window!.contentView!)?.selectedRow ?? -1) >= 0}
        }
        func menu() throws -> NSMenu {
            guard let table=find(owner.window!.contentView!),let menu=table.menu else {throw Failure(message:"Native reference menu absent")};menu.delegate?.menuNeedsUpdate?(menu);return menu
        }
        func invoke(_ title:String) throws {
            let menu=try menu();guard let entry=menu.items.first(where:{$0.title==title}),let action=entry.action else {throw Failure(message:"Deletion command absent: "+title)}
            try require(entry.isEnabled && entry.image?.name()==MenuIcon.remove.contextImage(defaults:prefs)?.name(),"Deletion original icon/enablement")
            try require(NSApplication.shared.sendAction(action,to:entry.target,from:entry),"Deletion dispatch")
        }
        try await choose("refs/heads/keep");try invoke("Delete branch");try await wait{answer != nil}
        try require(prompt?.name=="keep" && prompt?.warning==false && owner.model.deletingReference,"Merged confirmation")
        owner.model.load();owner.model.currentBranch();owner.showFetch();owner.model.accept()
        try require(owner.model.busy && !owner.model.canAccept && owner.fetchDialog==nil && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Pending confirmation escaped gates")
        let no=answer;answer=nil;no?.resume(returning:false);try await wait([owner.window!]){!owner.model.busy}
        try require(owner.model.snapshot?.references.contains{$0.name=="refs/heads/keep"}==true,"No changed branch")
        for (name,title) in [("refs/heads/unmerged","Delete branch"),("refs/tags/release","Delete tag"),("refs/remotes/origin/remoteTopic","Delete remote branch")] {
            prompt=nil;try await choose(name);try invoke(title);try await wait{answer != nil}
            try require(prompt?.reference==GitReferenceName(name),"Confirmation lost canonical name")
            if title=="Delete branch" {try require(prompt?.unmerged==true,"Unmerged warning absent")}
            if title=="Delete tag" {try require(prompt?.warning==false,"Tag warning differs")}
            if title=="Delete remote branch" {try require(prompt?.message.hasSuffix("This action will remove the branches on the remote.")==true,"Remote warning absent")}
            let yes=answer;answer=nil;yes?.resume(returning:true);try await wait([owner.window!]){!owner.model.busy}
            try require(owner.model.error==nil && owner.model.snapshot?.references.contains{$0.name==GitReferenceName(name)}==false,"Delete/Refresh did not remove selection")
        }
        let remote=try await GitRepository(root:remoteRoot,executable:git).referenceBrowser()
        try require(!remote.references.contains{$0.name=="refs/heads/remoteTopic"} && owner.model.snapshot!.references.contains{$0.name=="refs/heads/remoteTopic"},"Remote command deleted wrong namespace")
        _ = try await repo.run(["update-ref","refs/notes/custom","HEAD"]);owner.model.load();try await wait([owner.window!]){!owner.model.busy}
        try await choose("refs/notes/custom");try require(!(try menu()).items.contains{$0.title.hasPrefix("Delete")},"Notes deletion incorrectly offered")
        try await choose("refs/heads/main");try require((try menu()).items.contains{$0.title=="Delete branch"},"Current branch source menu gate differs")
        // A forced owner close rejects an answer already awaiting user input.
        try await choose("refs/heads/keep");try invoke("Delete branch");try await wait{answer != nil};owner.close()
        let stale=answer;answer=nil;stale?.resume(returning:true);try await Task.sleep(nanoseconds:100_000_000)
        let kept=try await repo.referenceBrowser();try require(kept.references.contains{$0.name=="refs/heads/keep"} && owner.model.closed && !owner.model.busy,"Late confirmation mutated closed owner")
        // Preflight, local mutation and remote Push processes are independently owned.
        for stage in ["merge-base","branch","push"] {
            let target=stage=="push" ? "refs/remotes/origin/heldRemote" : "refs/heads/slow/"+stage
            let helper=root.appendingPathComponent("slow-"+stage),marker=URL(fileURLWithPath:helper.path+".started"),pause=URL(fileURLWithPath:helper.path+".pause")
            let quoted="'"+git.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
            let script="""
            #!/bin/sh
            task_match=false
            for task_argument in "$@"; do
              if [ "$task_argument" = '\(stage)' ]; then task_match=true; fi
            done
            if [ "$task_match" = true ] && [ -f "$0.pause" ]; then
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.started"
              wait "$task_child"
            fi
            exec \(quoted) "$@"
            """
            try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
            let closing=ReferenceBrowserWindowController(repository:GitRepository(root:client,executable:helper),access:nil,initial:target,preferences:prefs){_ in};var ids:[Int32]=[]
            defer {closing.close();for pid in ids where kill(pid,0)==0 {_ = kill(pid,SIGTERM)}}
            closing.model.confirmDeletion={_ in true};closing.model.load();try await wait([closing.window!]){!closing.model.busy && closing.model.chosen != nil}
            try Data().write(to:pause);closing.model.deleteChosen();try await wait{FileManager.default.fileExists(atPath:marker.path)}
            ids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)};try require(ids.count==2 && ids.allSatisfy{kill($0,0)==0},"Owned deletion process absent")
            closing.model.load();try require(closing.model.deletingReference && closing.model.busy,"Refresh superseded deletion")
            closing.close();let frozenError=closing.model.error;try await wait{ids.allSatisfy{kill($0,0) != 0}};try await Task.sleep(nanoseconds:100_000_000)
            let local=try await repo.referenceBrowser();try require(local.references.contains{$0.name==GitReferenceName(target)} && closing.model.closed && !closing.model.busy && frozenError==closing.model.error,"Forced deletion continued or published late error")
            print("PASS forced reference deletion: "+stage)
        }
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(head==after && index==Data(contentsOf:client.appendingPathComponent(".git/index")) && file==Data(contentsOf:client.appendingPathComponent("file")),"Deletion changed HEAD/index/worktree")
        try require(NSApplication.shared.windows.allSatisfy{!$0.isVisible},"Receiver displayed windows")
        print("PASS deletion menus/icons, captured confirmations/No/Yes, unmerged/tag/remote effects and Refresh, owner/close/Quit/duplicate/late-answer gates")
    }
}
