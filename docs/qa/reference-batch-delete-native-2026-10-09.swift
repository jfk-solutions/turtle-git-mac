import AppKit
import TurtleGitCore

@main struct BatchReferenceDeleteVerification {
    struct Failure: Error { let message:String }
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(message:message)}}
    @MainActor static func find(_ view:NSView) -> NSTableView? {if let table=view as? NSTableView,table.accessibilityLabel()=="References" {return table};for child in view.subviews {if let result=find(child){return result}};return nil}
    @MainActor static func wait(_ windows:[NSWindow]=[],_ ready:()->Bool) async throws {for _ in 0..<2000 {windows.forEach{$0.contentView?.layoutSubtreeIfNeeded()};if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(message:"Timeout")}
    @MainActor static func main() async {do {try await verify()} catch {fputs("Batch deletion QA failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),client=root.appendingPathComponent("client"),repo=GitRepository(root:client,executable:git)
        let suite="TurtleGit.ReferenceBatchDelete.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite);prefs.synchronize()}
        try FileManager.default.createDirectory(at:client,withIntermediateDirectories:true)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Batch QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:client.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        for name in ["batch/one","batch/two","keep/one","keep/two","remote/one","remote/two"] {_ = try await repo.run(["branch",name])}
        for name in ["one","two","three"] {_ = try await repo.run(["tag",name])}
        for name in ["alpha","zeta"] {
            let bare=root.appendingPathComponent(name+".git");_ = try await repo.run(["clone","--bare",client.path,bare.path]);_ = try await repo.run(["remote","add",name,bare.path]);_ = try await repo.run(["fetch",name])
        }
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:client.appendingPathComponent(".git/index")),file=try Data(contentsOf:client.appendingPathComponent("file"))
        let owner=ReferenceBrowserWindowController(repository:repo,access:nil,initial:"HEAD",preferences:prefs,picking:false){_ in};defer {owner.close()}
        owner.model.load();try await wait([owner.window!]){!owner.model.busy && owner.model.snapshot != nil};owner.model.setFolder("refs")
        var prompt:ReferenceBrowserDeletionConfirmation?,answer:CheckedContinuation<Bool,Never>?
        owner.model.confirmDeletion={value in prompt=value;return await withCheckedContinuation {answer=$0}}
        func choose(_ names:[String]) async throws {
            owner.model.setFolder("refs")
            owner.model.select(Set(names.map { GitReferenceName($0) }),last:GitReferenceName(names.last!))
            try await wait([owner.window!]){find(owner.window!.contentView!)?.selectedRowIndexes.count==names.count}
        }
        func menu() throws -> NSMenu {guard let table=find(owner.window!.contentView!),let menu=table.menu else {throw Failure(message:"Menu absent")};menu.delegate?.menuNeedsUpdate?(menu);return menu}
        func invoke(_ title:String) throws {
            let menu=try menu();try require(menu.items.first?.isSeparatorItem==false,"Leading separator")
            guard let item=menu.items.first(where:{$0.title==title}),let action=item.action else {throw Failure(message:"Batch command absent "+title)}
            try require(item.isEnabled && item.image?.name()==MenuIcon.remove.contextImage(defaults:prefs)?.name(),"Delete artwork/enablement")
            try require(NSApplication.shared.sendAction(action,to:item.target,from:item),"Batch dispatch")
        }
        let branches=["refs/heads/batch/one","refs/heads/batch/two"]
        try await choose(branches);try invoke("Delete 2 branches");try await wait{answer != nil}
        try require(prompt?.references==branches.map { GitReferenceName($0) } && prompt?.uncheckedMerge==true && prompt?.unmerged==false,"Batch branch warning/capture")
        owner.model.load();owner.model.deleteChosen();owner.model.accept()
        try require(owner.model.deletingReference && owner.model.busy && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Pending batch escaped gates")
        let no=answer;answer=nil;no?.resume(returning:false);try await wait([owner.window!]){!owner.model.busy}
        try require(owner.model.snapshot!.references.contains{$0.name==GitReferenceName(branches[0])},"No deleted batch")
        let tags=["refs/tags/one","refs/tags/two","refs/tags/three"]
        let remotes=["refs/remotes/alpha/remote/one","refs/remotes/alpha/remote/two","refs/remotes/zeta/remote/one"]
        for (names,title) in [(branches,"Delete 2 branches"),(tags,"Delete 3 tags"),(remotes,"Delete 3 remote branches")] {
            prompt=nil;try await choose(names);try invoke(title);try await wait{answer != nil}
            try require(prompt?.references.count==names.count,"Batch capture count")
            if title.contains("tags") {try require(prompt?.warning==false && prompt?.uncheckedMerge==false,"Tags gained merge warning")}
            if title.contains("remote") {try require(prompt?.warning==true && prompt?.message.hasSuffix("This action will remove the branches on the remote.")==true,"Remote batch warning")}
            let yes=answer;answer=nil;yes?.resume(returning:true);try await wait([owner.window!]){!owner.model.busy}
            try require(owner.model.error==nil && !owner.model.snapshot!.references.contains{names.map { GitReferenceName($0) }.contains($0.name)},"Batch mutation/Refresh")
        }
        let alpha=try await GitRepository(root:root.appendingPathComponent("alpha.git"),executable:git).referenceBrowser(),zeta=try await GitRepository(root:root.appendingPathComponent("zeta.git"),executable:git).referenceBrowser()
        try require(!alpha.references.contains{$0.name=="refs/heads/remote/one" || $0.name=="refs/heads/remote/two"} && !zeta.references.contains{$0.name=="refs/heads/remote/one"} && zeta.references.contains{$0.name=="refs/heads/remote/two"},"Remote groups deleted incorrect refs")
        try await choose(["refs/heads/keep/one","refs/remotes/zeta/remote/two"]);try require(!(try menu()).items.contains{$0.title.hasPrefix("Delete")},"Mixed namespace batch offered")
        let kept=["refs/heads/keep/one","refs/heads/keep/two"]
        try await choose(kept);try invoke("Delete 2 branches");try await wait{answer != nil};owner.close();let late=answer;answer=nil;late?.resume(returning:true);try await Task.sleep(nanoseconds:100_000_000)
        let afterLate=try await repo.referenceBrowser();try require(afterLate.references.contains{$0.name==GitReferenceName(kept[0])} && afterLate.references.contains{$0.name==GitReferenceName(kept[1])},"Late Yes deleted closed batch")
        for stage in ["check-ref-format","branch","push"] {
            let names=stage=="push" ? ["refs/remotes/zeta/keep/one","refs/remotes/zeta/keep/two"] : kept
            let helper=root.appendingPathComponent("slow-"+stage),marker=URL(fileURLWithPath:helper.path+".started"),pause=URL(fileURLWithPath:helper.path+".pause"),quoted="'"+git.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
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
            let closing=ReferenceBrowserWindowController(repository:GitRepository(root:client,executable:helper),access:nil,initial:"refs",preferences:prefs,picking:false){_ in};var ids:[Int32]=[]
            defer {closing.close();for pid in ids where kill(pid,0)==0 {_ = kill(pid,SIGTERM)}}
            closing.model.load();try await wait([closing.window!]){!closing.model.busy && closing.model.snapshot != nil};closing.model.select(Set(names.map { GitReferenceName($0) }),last:GitReferenceName(names.last!));closing.model.confirmDeletion={_ in true}
            try Data().write(to:pause);closing.model.deleteChosen();try await wait{FileManager.default.fileExists(atPath:marker.path)}
            ids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)};try require(ids.count==2 && ids.allSatisfy{kill($0,0)==0},"Live batch process absent")
            closing.close();let error=closing.model.error;try await wait{ids.allSatisfy{kill($0,0) != 0}};try await Task.sleep(nanoseconds:100_000_000)
            let refs=try await repo.referenceBrowser();try require(!closing.model.busy && closing.model.closed && error==closing.model.error && names.allSatisfy{value in refs.references.contains{$0.name==GitReferenceName(value)}},"Forced batch continued or published late result")
            print("PASS batch forced cleanup: "+stage)
        }
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(head==after && index==Data(contentsOf:client.appendingPathComponent(".git/index")) && file==Data(contentsOf:client.appendingPathComponent("file")),"Batch deletion changed HEAD/index/worktree")
        try require(NSApplication.shared.windows.allSatisfy{!$0.isVisible},"Displayed QA windows")
        print("PASS batch branch/tag/remote menus, warnings, No/Yes/Refresh, mixed namespaces, late confirmation and close/Quit/cancellation gates")
    }
}
