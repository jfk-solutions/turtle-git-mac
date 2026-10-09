import AppKit
import TurtleGitCore

@main struct ReferenceFetchVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message:message) } }
    @MainActor static func find(_ view: NSView) -> NSTableView? {
        if let result=view as? NSTableView, result.accessibilityLabel()=="References" { return result }; for child in view.subviews { if let result=find(child) { return result } }; return nil
    }
    @MainActor static func wait(_ windows:[NSWindow]=[], _ ready:()->Bool) async throws {
        for _ in 0..<2000 { windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }; if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw Failure(message:"Timeout")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Fetch QA failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.ReferenceFetch.QA."+UUID().uuidString, prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        prefs.set(0,forKey:"AutoCloseGitProgress"); prefs.set(false,forKey:"ConfirmKillProcess")
        let remoteRoot=root.appendingPathComponent("remote"), client=root.appendingPathComponent("client")
        try FileManager.default.createDirectory(at:remoteRoot,withIntermediateDirectories:true)
        let producer=GitRepository(root:remoteRoot,executable:git)
        _ = try await producer.run(["init","-b","main"])
        for (key,value) in [("user.name","Fetch QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await producer.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:remoteRoot.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message:"base")
        _ = try await producer.run(["clone",remoteRoot.path,client.path])
        let repo=GitRepository(root:client,executable:git), ref="refs/remotes/origin/main"
        let head=try await repo.run(["rev-parse","HEAD"]).stdout, index=try Data(contentsOf:client.appendingPathComponent(".git/index")), file=try Data(contentsOf:client.appendingPathComponent("file"))
        _ = try await producer.run(["commit","--allow-empty","-m","next"]); let next=try await producer.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let owner=ReferenceBrowserWindowController(repository:repo,access:nil,initial:ref,preferences:prefs) { _ in }; defer { owner.close() }
        owner.presentFetch={parent,child in parent.makeFirstResponder(nil); return !parent.isVisible && !child.isVisible }
        var configured=0, changes=0
        owner.model.configureFetch={ child in configured += 1; child.model.onChanged={ _ in changes += 1 }; child.presentFetchProgress={parent,child in parent.makeFirstResponder(nil); return !parent.isVisible && !child.isVisible } }
        owner.model.load(); try await wait([owner.window!]) { !owner.model.busy && owner.model.snapshot != nil }
        guard let table=find(owner.window!.contentView!),let menu=table.menu else { throw Failure(message:"Native table missing") }
        try await wait([owner.window!]) { table.selectedRow >= 0 }; menu.delegate?.menuNeedsUpdate?(menu)
        let fetch=menu.indexOfItem(withTitle:"Fetch from \"origin\""), merge=menu.items.firstIndex { $0.title.hasPrefix("Merge to") } ?? -1
        try require(fetch>=0 && menu.items[fetch].isEnabled && menu.items[fetch].image != nil && fetch<merge,"Fetch menu/icon/order missing")
        menu.performActionForItem(at:fetch)
        guard let child=owner.fetchDialog else { throw Failure(message:"Fetch child missing") }
        try await wait([child.window!]) { !child.model.busy }
        try require(configured==1 && !child.model.isPull && child.model.options.remote=="origin" && !child.model.options.arbitraryURL && !child.model.options.allRemotes,"Remote preset/configuration differs")
        try require(owner.model.hasChild && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Owner close/Quit escaped")
        owner.showFetch(); owner.showCreateBranch(); owner.showMerge(); owner.showSwitch(); try require(owner.fetchDialog === child && configured==1,"Competing action escaped")
        child.model.fetch()
        try await wait([child.window!]) { child.fetchProgressController?.model.busy==false }
        guard let progress=child.fetchProgressController else { throw Failure(message:"Progress missing") }
        try require(progress.model.success && changes==1 && owner.model.hasChild && child.model.fetchProgress != nil,"Result ownership escaped")
        let fetched=try await repo.run(["rev-parse",ref]).text.trimmingCharacters(in:.newlines); try require(fetched==next,"Local fetch did not update remote ref")
        progress.close(); try await wait([owner.window!]) { owner.fetchDialog==nil && !owner.model.hasChild && !owner.model.busy }
        try require(owner.model.snapshot?.references.first(where:{$0.name.rawValue==ref})?.hash==next,"Browser did not refresh after acknowledgement")
        for reject in [false,true] {
            let choice=owner.model.snapshot!.initialSelection(ref); owner.model.setFolder(choice.folder); owner.model.selected=choice.reference
            if reject { owner.presentFetch={ _,_ in false } }; owner.showFetch()
            if !reject { guard let cancel=owner.fetchDialog else { throw Failure(message:"Cancel child missing") }; try await wait([cancel.window!]) { !cancel.model.busy }; cancel.model.cancel() }
            try await wait([owner.window!]) { owner.fetchDialog==nil && !owner.model.hasChild && !owner.model.busy }
        }
        // Owned metadata and transport processes must stop on forced browser closure.
        for stage in ["remote","fetch"] {
            let helper=root.appendingPathComponent("slow-"+stage), marker=URL(fileURLWithPath:helper.path+".started"), pause=URL(fileURLWithPath:helper.path+".pause"), quoted="'"+git.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
            let script="""
            #!/bin/sh
            if [ "${4-}" = '\(stage)' ] && [ -f "$0.pause" ]; then
              printf 'owned Fetch work\\n'
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.started"
              wait "$task_child"
            fi
            exec \(quoted) "$@"
            """
            try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
            let closing=ReferenceBrowserWindowController(repository:GitRepository(root:client,executable:helper),access:nil,initial:ref,preferences:prefs) { _ in }; var ids:[Int32]=[]
            defer { closing.close(); for pid in ids where kill(pid,0)==0 { _ = kill(pid,SIGTERM) } }
            closing.presentFetch={parent,_ in parent.makeFirstResponder(nil); return true}; closing.model.configureFetch={ child in child.presentFetchProgress={parent,_ in parent.makeFirstResponder(nil); return true} }
            closing.model.load(); try await wait([closing.window!]) { !closing.model.busy }
            if stage=="remote" { try Data().write(to:pause) }
            closing.showFetch(); guard let active=closing.fetchDialog else { throw Failure(message:"Active Fetch missing") }
            var outcome:FetchProgressWindowModel?, lateAnswer:((Bool)->Void)?, late=0
            active.model.onChanged={ _ in late += 1 }
            if stage=="fetch" {
                try await wait([active.window!]) { !active.model.busy }; try Data().write(to:pause); active.model.fetch()
                try await wait { active.fetchProgressController != nil }; outcome=active.fetchProgressController!.model
                prefs.set(true,forKey:"ConfirmKillProcess"); outcome!.confirmCancellation={ lateAnswer=$0 }
            }
            try await wait { FileManager.default.fileExists(atPath:marker.path) }
            ids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap { Int32($0) }; try require(ids.count==2 && ids.allSatisfy{kill($0,0)==0},"Owned process not live")
            outcome?.cancel(); closing.close(); let frozen=outcome?.rawOutput
            lateAnswer?(true); outcome?.perform(.fetch)
            try await wait { ids.allSatisfy{kill($0,0) != 0} }; try await Task.sleep(nanoseconds:100_000_000)
            try require(closing.fetchDialog==nil && !closing.model.hasChild && !active.model.busy && active.model.closed && active.model.error==nil && late==0 && outcome?.rawOutput==frozen,"Closed Fetch published late result")
            prefs.set(false,forKey:"ConfirmKillProcess")
        }
        let standalone=FetchWindowController(repository:repo,access:nil,preferences:prefs); defer { standalone.close() }
        standalone.presentFetchProgress={parent,_ in parent.makeFirstResponder(nil); return true}
        standalone.model.load(remote:"origin"); try await wait([standalone.window!]) { !standalone.model.busy }; standalone.model.fetch()
        try await wait([standalone.window!]) { standalone.fetchProgressController?.model.busy==false }
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Standalone Fetch result escaped Quit guard")
        standalone.model.cancel(); try require(standalone.model.closed && standalone.fetchProgressController==nil,"Standalone acknowledgement retained child")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(head==afterHead && index==Data(contentsOf:client.appendingPathComponent(".git/index")) && file==Data(contentsOf:client.appendingPathComponent("file")),"Fetch modified local HEAD/index/worktree")
        print("PASS: native Fetch remote menu/icon/order, configured remote preset, owned real local transport/progress acknowledgement/browser refresh, Cancel/reject/competing/close/Quit and forced metadata/transport process cleanup with ignored late Cancel answer. Private repositories/preferences; unchanged HEAD/index/worktree; no ordered windows or physical sheets.")
    }
}
