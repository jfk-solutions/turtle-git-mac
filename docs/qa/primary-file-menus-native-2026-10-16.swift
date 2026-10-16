import AppKit
import TurtleGitCore

@main struct PrimaryFileMenusVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(_ ready:()->Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Primary file menu timeout")
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Primary file menus failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let repo = GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("tracked"))
        try Data("outside\n".utf8).write(to:root.appendingPathComponent("outside"))
        try Data("ignored-*\n".utf8).write(to:root.appendingPathComponent(".gitignore"))
        try await repo.stage(["tracked","outside",".gitignore"]); _ = try await repo.commit(message:"base")
        try Data("changed\n".utf8).write(to:root.appendingPathComponent("tracked"))
        try Data("staged outside\n".utf8).write(to:root.appendingPathComponent("outside")); try await repo.stage(["outside"])
        let unknown = "unknown 雪\nname"
        try Data("unknown\n".utf8).write(to:root.appendingPathComponent(unknown))
        for path in ["ignored-normal","mode-executable","mode-symlink"] { try Data("target\n".utf8).write(to:root.appendingPathComponent(path)) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("folder"),withIntermediateDirectories:true)
        try Data("inside\n".utf8).write(to:root.appendingPathComponent("folder/inside"))
        let head = try await repo.run(["rev-parse","HEAD"]).stdout
        let outside = try await repo.run(["ls-files","--stage","-z","--","outside"]).stdout
        let suite = "TurtleGit.PrimaryFileMenus." + UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(true,forKey:"AddBeforeCommit")
        let status = StatusWindowController(repository:repo,access:nil,defaults:defaults), model = status.model
        let commit = CommitWindowController(repository:repo,access:nil,defaults:defaults), cm = commit.model
        var progress:[AddProgressWindowController] = []
        defer { for child in progress { child.model.retire(); child.close() }; cm.invalidateForClose(); commit.close(); model.invalidate(); status.close() }
        model.setScope([]); cm.reload()
        try await wait { !model.busy && !cm.busy && StatusWindowModel.activeOperations == 0 }
        try require(model.hasHead,"Existing HEAD not retained")
        let selected:Set<String> = ["tracked",unknown]
        let statusTracked = model.fileMenu(selected,mark:"tracked"), statusUnknown = model.fileMenu(selected,mark:unknown)
        let commitTracked = cm.fileMenu(selected,mark:"tracked"), commitUnknown = cm.fileMenu(selected,mark:unknown)
        for menu in [statusTracked,commitTracked] { try require(menu.offersCompare && menu.offersRevert && !menu.offersAdd && !menu.offersIgnore,"Tracked mark must gate mixed selection") }
        for menu in [statusUnknown,commitUnknown] {
            try require(menu.offersAdd && menu.offersIgnore && !menu.offersCompare && !menu.offersRevert,"Untracked mark must gate mixed selection")
            try require(menu.addModes(extended:false) == [.normal] && menu.addModes(extended:true) == [.normal,.executable,.symlink],"Shift Add mode list differs from source")
        }
        // Synthetic conflict models exercise both owners without manufacturing a
        // merge or dispatching a write through an invented index state.
        let conflict = StatusEntry.parse(Data("UU conflict\0".utf8))[0]
        cm.entries.append(conflict)
        let mixedConflict = cm.fileMenu(["tracked","conflict"],mark:"conflict")
        try require(mixedConflict.offersResolve && mixedConflict.offersRevert,"Conflict mark lost mixed Resolve commands")
        cm.entries.removeAll { $0.path == "conflict" }
        let dirEntry = StatusEntry.parse(Data("?? folder\0".utf8))[0]
        let directoryMenu = StatusFileMenuSnapshot(generation:UUID(),entries:[dirEntry],mark:dirEntry,commands:[],markIsDirectory:true)
        try require(directoryMenu.addModes(extended:true) == [.normal],"Directory mark exposed file-mode Add variants")
        var commits:[[String]] = []
        model.onAction = { action,paths in if action == .commit { commits.append(paths) } }
        model.commitSelection(statusTracked)
        try require(commits.count == 1 && Set(commits[0]) == selected,"Context Commit used invocation/whole-project scope instead of captured rows")
        model.selection = ["outside"]
        model.commitSelection(statusTracked); model.addSelection(statusUnknown,mode:.normal)
        try require(commits.count == 1,"Stale context Commit escaped selection epoch")
        model.selection = []
        var dispatched:[([String],WorkingFileAddMode)] = []
        model.onAddFiles = { paths,mode in
            dispatched.append((paths,mode))
            let child = AddProgressWindowController(repository:repo,access:nil,paths:paths,mode:mode)
            child.model.onFinished = { _,_ in model.requestReload() }
            progress.append(child); child.model.start()
        }
        var filter = model.filter; filter.showIgnored = true; model.setFilter(filter)
        try await wait { !model.busy }
        for (path,mode,expectedMode) in [("ignored-normal",WorkingFileAddMode.normal,"100644"),("mode-executable",.executable,"100755"),("mode-symlink",.symlink,"120000")] {
            let menu = model.fileMenu([path],mark:path)
            try require(menu.offersAdd,"Add missing for ignored/untracked path " + path)
            model.addSelection(menu,mode:mode)
            try await wait { progress.last?.model.busy == false && !model.busy && StatusWindowModel.activeOperations == 0 }
            try require(progress.last?.model.success == true,"Native Add progress failed: " + (progress.last?.model.information ?? "no child"))
            let index = try await repo.run(["ls-files","--stage","--",path]).text
            try require(index.hasPrefix(expectedMode),"Native Add mode mismatch " + index)
            try require(try Data(contentsOf:root.appendingPathComponent(path)) == Data("target\n".utf8),"Add changed disk file")
        }
        try require(dispatched.count == 3,"Add handoff count differs")
        let beforeFlags = model.fileMenu(["tracked",unknown],mark:"tracked")
        let files = model.files.filter { selected.contains($0.id) }, mark = model.files.first { $0.id == "tracked" }!
        var confirmed = 0; model.confirmFlags = { _ in confirmed += 1; return true }
        model.withFileMenu(beforeFlags) { model.setFlags(.skipWorktree,files:files,selectionMark:mark) }
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(confirmed == 1 && model.error?.contains(unknown) == true,"Mixed index flags failed to report unindexed path")
        let flagged = try await repo.workingTreeStatus()
        try require(flagged.contains { $0.id == "tracked" && $0.skipWorktree },"Eligible selected stage-zero entry was not updated")
        filter = model.filter; filter.showLocalChangesIgnored = true; model.setFilter(filter)
        try await wait { !model.busy }
        try require(!model.canCommit(model.fileMenu(["tracked"],mark:"tracked")),"Flagged mark still offered context Commit")
        let flaggedUnknown = model.fileMenu(["tracked",unknown],mark:unknown)
        try require(model.canCommit(flaggedUnknown),"Untracked marked selection lost Commit")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout == head,"Context workflows changed HEAD")
        try require(try await repo.run(["ls-files","--stage","-z","--","outside"]).stdout == outside,"Context workflows changed unrelated staged entry")
        model.invalidate(); cm.invalidateForClose()
        model.commitSelection(flaggedUnknown); model.addSelection(flaggedUnknown,mode:.normal)
        try require(commits.count == 1 && dispatched.count == 3,"Retired owner dispatched context action")
        for child in progress { child.close() }; commit.close(); status.close()
        print("PASS: primary marked-row mixed menus, Shift Add variants/directory gate, captured Commit paths/stale retirement, native force Add progress and staged modes, mixed index flags/partial diagnostic, unrelated index and HEAD preservation; owned windows closed")
    }
}
