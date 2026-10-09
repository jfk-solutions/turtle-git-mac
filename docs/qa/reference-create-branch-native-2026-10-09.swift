import AppKit
import TurtleGitCore

@main struct ReferenceCreateBranchVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func find<T: NSView>(_ type: T.Type, _ view: NSView) -> T? {
        if let result = view as? T, !(result is NSTableView) || result.accessibilityLabel()=="References" { return result }; for child in view.subviews { if let result = find(type,child) { return result } }; return nil
    }
    @MainActor static func wait(_ windows: [NSWindow] = [], _ ready: () -> Bool) async throws {
        for _ in 0..<1500 { windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }; if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        for window in NSApplication.shared.windows {
            if let owner=window.delegate as? ReferenceBrowserWindowController { print("TIMEOUT browser",owner.model.busy,owner.model.hasChild,owner.model.selected?.rawValue ?? "nil",owner.model.error ?? "nil") }
            if let child=window.delegate as? BranchTagWindowController { print("TIMEOUT branch",child.model.busy,child.model.chooser.busy,child.model.chooser.revision,child.model.error ?? "nil",child.model.options.name) }
        }
        throw Failure(message:"Timeout")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Create Branch QA failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), git=URL(fileURLWithPath:CommandLine.arguments[2]), repo=GitRepository(root:root,executable:git)
        let suite="TurtleGit.ReferenceCreateBranch.QA."+UUID().uuidString, prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Branch QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        _ = try await repo.run(["commit","--allow-empty","-m","base"]); let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["commit","--allow-empty","-m","next"]); let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let remote="refs/remotes/origin/team/topic"; _ = try await repo.run(["update-ref",remote,base]); _ = try await repo.run(["symbolic-ref","refs/remotes/origin/HEAD",remote]); _ = try await repo.run(["tag","release",base])
        let owner=ReferenceBrowserWindowController(repository:repo,access:nil,initial:remote,preferences:prefs) { _ in }; defer { owner.close() }
        owner.presentBranch={ parent,child in parent.makeFirstResponder(nil); return !parent.isVisible && !child.isVisible }
        var configured=0, created=0
        owner.model.configureBranch={ child in configured += 1; child.model.onCreated={ _ in created += 1 } }
        owner.model.load(); try await wait([owner.window!]) { !owner.model.busy && owner.model.snapshot != nil }
        print("PHASE: table"); fflush(stdout)
        guard let table=find(NSTableView.self,owner.window!.contentView!),let menu=table.menu else { throw Failure(message:"Native reference table missing") }
        try await wait([owner.window!]) { table.selectedRow >= 0 }
        menu.delegate?.menuNeedsUpdate?(menu); let item=menu.indexOfItem(withTitle:"Create Branch…")
        try require(item>=0 && menu.items[item].isEnabled && menu.items[item].image != nil,"Create Branch menu/icon missing")
        print("PHASE: open"); fflush(stdout)
        menu.performActionForItem(at:item)
        guard let child=owner.branchDialog else { throw Failure(message:"Owned branch dialog missing") }
        try await wait([child.window!]) { !child.model.busy && !child.model.chooser.busy }
        try require(configured==1 && !child.model.isTag && !child.model.useHead && child.model.chooser.revision==base,"Dialog did not capture source hash")
        try require(owner.model.hasChild && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Owner close/Quit escaped")
        owner.showCreateBranch(); owner.showMerge(); owner.showSwitch(); try require(owner.branchDialog === child && configured==1,"Competing child escaped")
        print("PHASE: create"); fflush(stdout)
        _ = try await repo.run(["update-ref",remote,head])
        child.model.options.name="created/from-browser"; child.model.switchAfterCreation=false; child.model.create()
        try await wait([owner.window!]) { owner.branchDialog == nil && !owner.model.hasChild && !owner.model.busy }
        let result=try await repo.run(["rev-parse","refs/heads/created/from-browser"]).text.trimmingCharacters(in:.newlines)
        try require(result==base && created==1 && owner.model.snapshot?.references.contains(where:{$0.name.rawValue=="refs/heads/created/from-browser"})==true,"Created at moved ref or browser did not refresh")
        for (name,enabled) in [("refs/heads/main",false),("refs/tags/release",false),("refs/remotes/origin/HEAD",true)] {
            let choice=owner.model.snapshot!.initialSelection(name); owner.model.setFolder(choice.folder); owner.model.selected=choice.reference
            try require(owner.model.canCreateBranch==enabled,"Remote namespace gate differs")
        }
        print("PHASE: cancel/reject"); fflush(stdout)
        // Cancel/rejected presentation release and refresh ownership without mutation.
        for reject in [false,true] {
            let choice=owner.model.snapshot!.initialSelection(remote); owner.model.setFolder(choice.folder); owner.model.selected=choice.reference
            if reject { owner.presentBranch={ _,_ in false } }
            owner.showCreateBranch()
            if !reject { guard let cancel=owner.branchDialog else { throw Failure(message:"Cancel child missing") }; try await wait([cancel.window!]) { !cancel.model.busy && !cancel.model.chooser.busy }; cancel.model.close() }
            try await wait([owner.window!]) { owner.branchDialog==nil && !owner.model.hasChild && !owner.model.busy }
        }
        print("PHASE: force cleanup"); fflush(stdout)
        // Force-close a live creation process. No rollback of already completed work is implied.
        let helper=root.appendingPathComponent("slow-branch"), marker=URL(fileURLWithPath:helper.path+".started"), quoted="'"+git.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        let script="""
        #!/bin/sh
        if [ "${4-}" = branch ] && [ "${5-}" != --show-current ]; then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started"
          wait "$task_child"
        fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let closing=ReferenceBrowserWindowController(repository:GitRepository(root:root,executable:helper),access:nil,initial:remote,preferences:prefs) { _ in }; var ids:[Int32]=[]
        defer { closing.close(); for pid in ids where kill(pid,0)==0 { _ = kill(pid,SIGTERM) } }
        closing.presentBranch={parent,_ in parent.makeFirstResponder(nil); return true}; closing.model.load(); try await wait([closing.window!]) { !closing.model.busy }
        closing.showCreateBranch(); guard let active=closing.branchDialog else { throw Failure(message:"Active child missing") }; try await wait([active.window!]) { !active.model.busy && !active.model.chooser.busy }
        active.model.options.name="must-not-create"; active.model.switchAfterCreation=false; var late=0; active.model.onCreated={ _ in late += 1 }; active.model.create()
        try await wait { FileManager.default.fileExists(atPath:marker.path) }
        ids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap { Int32($0) }; try require(ids.count==2 && ids.allSatisfy{kill($0,0)==0},"Creation not live")
        closing.close(); try await wait { ids.allSatisfy{kill($0,0) != 0} }; try await Task.sleep(nanoseconds:100_000_000)
        try require(closing.branchDialog==nil && !closing.model.hasChild && !active.model.busy && active.model.error==nil && late==0,"Closed creation published late result")
        let absent=try await repo.run(["show-ref","--verify","--quiet","refs/heads/must-not-create"],successfulExitCodes:0...1).exitCode
        try require(absent==1,"Cancelled creation mutated refs")
        print("PASS: native remote Create Branch menu/icon, pinned hash despite moved remote, owned options/configuration, real creation and browser refresh, Cancel/rejected/competing/close/Quit and forced live creation process cleanup. Private repos/preferences, no ordered windows or physical sheets.")
    }
}
