import AppKit
import TurtleGitCore

@main struct FileListRefreshVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {var settled = 0;for _ in 0..<2000 {try await Task.sleep(nanoseconds:10_000_000);settled = ready() ? settled+1:0;if settled == 2 {return}};throw Failure(description:"File-list timeout at line \(line)")}
    @MainActor static func views(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(views)}
    @MainActor struct Host {
        let owner:NSWindowController,coordinator:FileListRefreshCoordinator
        let ids:()->[String],selected:()->GitPathSet,checks:()->GitPathSet,busy:()->Bool
        let choose:(GitPathSet)->Void,reload:()->Void,filter:()->Void
    }
    @MainActor static func main() async {do {try await verify()} catch {fputs("File-list refresh failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]),repo = GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport","false"),("tgit.showpatch","false")] {_ = try await repo.run(["config",key,value])}
        let paths = (0..<180).map{String(format:"file-%03d 雪.txt",$0)}
        for path in paths {try Data("base\n".utf8).write(to:root.appendingPathComponent(path))};try await repo.stage(paths);_ = try await repo.commit(message:"base")
        for path in paths {try Data("modified\n".utf8).write(to:root.appendingPathComponent(path))}
        try Data("untracked\n".utf8).write(to:root.appendingPathComponent("unknown"))
        let tree = try await repo.run(["write-tree"]).stdout,head = try await repo.run(["rev-parse","HEAD"]).stdout
        let suite = "TurtleGit.FileListRefresh." + UUID().uuidString,prefs = UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"Commit.SkipCancelConfirmation");defer {prefs.removePersistentDomain(forName:suite)}
        var owned:[NSWindowController] = [];defer {owned.forEach{$0.close()}}
        for kind in ["status","revert","commit"] {
            prefs.set(true,forKey:"RememberFileListPosition")
            let host:Host
            if kind == "status" {
                let controller = StatusWindowController(repository:repo,access:nil,defaults:prefs),model = controller.model;owned.append(controller)
                host = Host(owner:controller,coordinator:model.fileListRefresh,ids:{model.tableRows.map(\.row.id)},selected:{model.selection},checks:{[]},busy:{model.busy},choose:{model.selection = $0},reload:{model.reload()},filter:{var value=model.filter;value.showUnversioned = false;model.setFilter(value)})
            } else if kind == "revert" {
                let controller = RevertWindowController(repository:repo,access:nil,preferences:prefs),model = controller.model;owned.append(controller)
                host = Host(owner:controller,coordinator:model.fileListRefresh,ids:{model.rows.map(\.id)},selected:{model.highlighted},checks:{model.checked},busy:{model.busy},choose:{model.highlighted = $0},reload:{model.reload()},filter:{model.reload()})
                model.checked = GitPathSet(paths.prefix(3))
            } else {
                let controller = CommitWindowController(repository:repo,access:nil,defaults:prefs),model = controller.model;owned.append(controller)
                host = Host(owner:controller,coordinator:model.fileListRefresh,ids:{model.visibleFileRowIDs},selected:{model.selection},checks:{model.checked},busy:{model.busy},choose:{model.selection = $0},reload:{model.reload()},filter:{model.setShowUnversioned(false)})
                model.message = "Retain this draft";model.checked = GitPathSet(paths.prefix(3))
            }
            host.owner.window?.alphaValue = 0;host.owner.window?.orderFront(nil);host.reload()
            try await wait {!host.busy() && !host.coordinator.hasPendingPosition && host.ids().count >= paths.count}
            if let owner = host.owner as? RevertWindowController {owner.model.checked = GitPathSet(paths.prefix(3))}
            if let owner = host.owner as? CommitWindowController {owner.model.checked = GitPathSet(paths.prefix(3))}
            let allViews = views(host.owner.window!.contentView!),probe = allViews.compactMap{$0 as? CommitFileInteraction.Probe}.first!,table = allViews.compactMap{$0 as? NSTableView}.first!
            try await wait {table.numberOfRows == host.ids().count && probe.rows.map(\.id) == host.ids()}
            let target = paths[110],other = paths[112]
            let wanted:GitPathSet = [target,other]
            CommitFileInteraction.replaceSelection(in:table,with:IndexSet(host.ids().indices.filter {wanted.contains(host.ids()[$0])}))
            try await wait {table.selectedRowIndexes.count == 2 && host.selected() == wanted}
            let clip = table.enclosingScrollView!.contentView
            clip.scroll(to:NSPoint(x:0,y:table.rect(ofRow:85).minY));table.enclosingScrollView!.reflectScrolledClipView(clip)
            let origin = clip.bounds.origin,checked = host.checks()
            try require(origin.y > 100,"Fixture did not scroll \(kind)")
            host.reload();try await wait {!host.busy() && !host.coordinator.hasPendingPosition}
            try require(host.selected() == [target,other] && abs(clip.bounds.origin.y-origin.y)<2 && host.checks()==checked,"Refresh lost viewport/selection/check separation: \(kind)")
            host.filter();try await wait {!host.busy() && !host.coordinator.hasPendingPosition && table.numberOfRows == host.ids().count}
            try require(host.selected() == [target,other] && abs(clip.bounds.origin.y-origin.y)<2,"Filter lost reading position: \(kind)")
            // Ctrl/Cmd-A selects native file rows, excludes group headers and leaves checkbox contents alone.
            try await wait {probe.enabled}
            try require(host.owner.window!.makeFirstResponder(table),"Native table refused keyboard focus: \(kind)")
            func key(_ code:UInt16,_ flags:NSEvent.ModifierFlags)->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:host.owner.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!}
            try require(probe.observe(key(0,.control)) == nil,"Ctrl A not handled: \(kind)")
            try await wait {host.selected().count == probe.rows.compactMap(\.entry).count}
            try require(GitPathSet(probe.rows.compactMap{$0.entry?.path}) == host.selected() && host.checks()==checked,"Select All selected group/check state: \(kind)")
            try require(probe.observe(key(0,.command)) == nil,"Cmd A not handled: \(kind)")
            try await wait {host.selected().count == probe.rows.compactMap(\.entry).count && table.selectedRowIndexes.count == host.selected().count}
            prefs.set(false,forKey:"RememberFileListPosition");host.reload()
            try await wait {!host.busy() && !host.coordinator.hasPendingPosition}
            try require(host.selected().isEmpty && clip.bounds.origin.y < 2 && host.checks()==checked,"Disabled position preference retained selection/scroll or changed checks: \(kind), selected=\(host.selected().count), native=\(table.selectedRowIndexes.count), origin=\(clip.bounds.origin.y), checksMatch=\(host.checks()==checked)")
            // A newer table gesture cancels a pending restore rather than moving its viewport later.
            prefs.set(true,forKey:"RememberFileListPosition")
            CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integer:host.ids().firstIndex(of:target)!))
            try await wait {table.selectedRowIndexes.count == 1 && host.selected() == [target]}
            clip.scroll(to:NSPoint(x:0,y:table.rect(ofRow:85).minY));table.enclosingScrollView!.reflectScrolledClipView(clip)
            let ticket = host.coordinator.begin(preferences:prefs,selectedIDs:host.selected())
            var finished = false
            Task {await host.coordinator.restore(ticket,ids:["not-yet-rendered"]);host.coordinator.finish(ticket);finished = true}
            await Task.yield();_ = probe.observe(key(0,.control))
            try await wait {finished && !host.coordinator.hasPendingPosition}
            let settled = clip.bounds.origin.y;try await Task.sleep(nanoseconds:30_000_000)
            try require(abs(clip.bounds.origin.y-settled)<1,"Cancelled restore moved viewport later: \(kind)")
            host.owner.close()
        }
        // The final optional LFS read belongs to Working Tree's complete snapshot.
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".git/lfs"),withIntermediateDirectories:true)
        let status = StatusWindowController(repository:repo,access:nil,defaults:prefs),model=status.model;owned.append(status)
        status.window?.alphaValue = 0;var columns=model.fileColumns;columns.visible.insert(.lfsOwner);model.fileColumns = columns
        model.queryLFSOwners = {_ in []};model.reload();try await wait {!model.busy}
        let before = model.files.map(\.entry);try Data("base\n".utf8).write(to:root.appendingPathComponent(paths[0]))
        var locks:CheckedContinuation<[LFSLock],Error>?
        model.queryLFSOwners = {_ in try await withCheckedThrowingContinuation {locks = $0}}
        model.reload();try await wait {locks != nil}
        try require(model.files.map(\.entry) == before && model.lfsOwnershipKnown,"Incomplete LFS snapshot replaced old rows")
        locks?.resume(throwing:Failure(description:"Injected LFS read failure"));locks = nil;try await wait {!model.busy}
        try require(model.files.map(\.entry) == before && model.error != nil,"Failed LFS read published partial status")
        model.error = nil;try await wait {status.window?.attachedSheet == nil}
        status.commandKeyWindow = { [weak status] in status?.window }
        func statusKey(_ code:UInt16,_ flags:NSEvent.ModifierFlags = [])->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:status.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!}
        _ = status.window!.performKeyEquivalent(with:statusKey(96,.command));try require(!model.busy,"Modified F5 refreshed Working Tree")
        status.commandKeyWindow = {nil};_ = status.window!.performKeyEquivalent(with:statusKey(96));try require(!model.busy,"Foreign F5 refreshed Working Tree")
        status.commandKeyWindow = { [weak status] in status?.window };_ = status.window!.performKeyEquivalent(with:statusKey(96));try await wait {locks != nil}
        _ = status.window!.performKeyEquivalent(with:statusKey(53));locks?.resume(returning:[]);locks = nil;try await wait {!model.busy}
        try require(model.error == nil && model.files.map(\.entry) == before,"Read-only Escape cancellation reported mutation or published late rows");status.close()
        try Data("modified\n".utf8).write(to:root.appendingPathComponent(paths[0]))
        // Full Commit reload owns Quit/access even when a forced close removes its controller.
        let commit = CommitWindowController(repository:repo,access:nil,defaults:prefs);owned.append(commit)
        var reply:CheckedContinuation<[StatusEntry],Error>?,token:OperationCancellation?
        commit.model.queryCommitStatus = {_,request in token = request;return try await withCheckedThrowingContinuation {reply = $0}}
        commit.model.reload();try await wait {reply != nil};commit.close()
        try require(token?.isCancelled == true && CommitWindowModel.activeReloads == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired full reload lost worker/Quit ownership")
        reply?.resume(returning:[]);reply = nil;try await wait {CommitWindowModel.activeReloads == 0 && StatusWindowModel.activeOperations == 0 && RevertWindowModel.activeOperations == 0}
        try require(commit.model.entries.isEmpty,"Retired full reload published rows")
        try require(try await repo.run(["write-tree"]).stdout == tree,"List refresh changed indexed contents")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout == head,"List refresh changed HEAD")
        print("PASS file-list refresh: Commit/Working Tree/Revert native viewport and multi-selection, independent checks, filters and preference off, file-only Ctrl/Cmd-A, superseded user intent, complete LFS snapshot/failure, scoped F5/Escape, retired full-Commit reload/Quit and unchanged HEAD/index contents")
    }
}
