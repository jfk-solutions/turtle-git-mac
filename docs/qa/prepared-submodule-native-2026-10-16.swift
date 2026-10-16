import AppKit
import TurtleGitCore

@main struct PreparedSubmoduleVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Prepared submodule timeout at line \(line)")}
    @MainActor static func capture(_ window:NSWindow,to file:URL) async throws {
        window.contentView?.layoutSubtreeIfNeeded();window.orderFront(nil);try await Task.sleep(nanoseconds:350_000_000)
        let process = Process();process.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture");process.arguments = ["-x","-o","-l",String(window.windowNumber),file.path]
        try process.run();process.waitUntilExit();window.orderOut(nil)
        try require(process.terminationStatus == 0 && FileManager.default.fileExists(atPath:file.path),"Passive submodule capture failed")
    }
    @MainActor static func main() async {do {try await verify()} catch {fputs("Prepared submodule failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]),git = URL(fileURLWithPath:CommandLine.arguments[2]),parent = GitRepository(root:root,executable:git)
        let path = "child 雪\nmodule",location = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at:location,withIntermediateDirectories:true)
        let child = GitRepository(root:location,executable:git)
        for repo in [parent,child] {_ = try await repo.run(["init","-b","main"]);for (key,value) in [("user.name","QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}}
        try Data("base\n".utf8).write(to:location.appendingPathComponent("file"));try await child.stage(["file"]);_ = try await child.commit(message:"base child")
        let base = try await child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await parent.run(["update-index","--add","--cacheinfo","160000," + base + "," + path]);_ = try await parent.commit(message:"attach")
        try Data("indexed\n".utf8).write(to:location.appendingPathComponent("file"));try await child.stage(["file"]);_ = try await child.commit(message:"indexed child")
        let indexed = try await child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await parent.run(["update-index","--cacheinfo","160000," + indexed + "," + path])
        try Data("current\n".utf8).write(to:location.appendingPathComponent("file"));try await child.stage(["file"]);_ = try await child.commit(message:"current child")
        let current = try await child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("dirty\n".utf8).write(to:location.appendingPathComponent("file"))
        var index = try Data(contentsOf:root.appendingPathComponent(".git/index"));let childIndex = try Data(contentsOf:location.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.PreparedSubmodule." + UUID().uuidString,prefs = UserDefaults(suiteName:suite)!;defer {prefs.removePersistentDomain(forName:suite)}
        let store = WorkingComparisonMarkStore(storageURL:root.appendingPathComponent(".git/marks.json"))
        let workspace = RepositoryModel(startMonitoring:false,initializePreferences:false,comparisonMarks:store);workspace.fileComparisonPreferences = prefs;workspace.fileComparisonQuestion = {_ in true}
        var windows:[SubmoduleDiffWindowController] = []
        workspace.submoduleDiffPresentation = {controller in controller.window?.alphaValue = 0;controller.window?.orderFront(nil);windows.append(controller)}
        defer {for controller in windows {controller.close()}}
        let revert = RevertWindowController(repository:parent,access:nil,preferences:prefs);revert.window?.alphaValue = 0;defer {revert.close()}
        revert.model.setScope(["."]);try await wait {revert.model.canInteract}
        let menu = revert.model.commands.fileMenu([path])
        try require(menu.markIsDirectory && revert.model.canMarkForComparison(menu) && !revert.model.canPrepareFile(menu),"Gitlink Mark/Save gates conflated")
        revert.model.onPreparedFileCompare = {mark,current in workspace.showPreparedFileComparison(repository:parent,access:nil,marked:mark,current:current,owner:revert.window)}
        revert.model.markForComparison(menu);revert.model.compareWithMarkedFile(revert.model.preparedMenu(menu))
        try await wait {windows.count == 1 && !workspace.busy && windows[0].model.details != nil && !windows[0].model.busy}
        let window = windows[0],model = window.model
        try require(model.fromIndex && model.details?.from.revision == indexed && model.details?.to.revision == current && model.details?.dirty == true,"Prepared route used HEAD instead of index or lost dirty checkout")
        var comparisons:[(ComparisonRevision,ComparisonRevision,Bool)] = []
        model.onCompare = {_,old,new in comparisons.append((old,new,ComparisonToolInvocation.capture))}
        ComparisonToolInvocation.$alternate.withValue(true){model.compare()};try await wait {!model.busy}
        try require(comparisons.count == 1 && comparisons[0].0 == .revision(indexed) && comparisons[0].1 == .revision(current) && comparisons[0].2,"Compare lost indexed objects or captured alternate choice")
        var logs:[String] = [];model.onLog = {_,hash in logs.append(hash)};model.log(model.details!.from);try await wait {!model.busy};model.log(model.details!.to);try await wait {!model.busy}
        try require(logs == [indexed,current],"Prepared Log sides lost object identities")
        // Owning-window F5 only, including modifier and foreign-owner rejection.
        var reads = 0;let read = model.readDetails;model.readDetails = {token in reads += 1;return try await read(token)}
        func event(_ flags:NSEvent.ModifierFlags)->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:96)!}
        window.commandKeyWindow = {nil};_ = window.window!.performKeyEquivalent(with:event([]));try require(!model.busy && reads == 0,"Foreign F5 refreshed")
        window.commandKeyWindow = { [weak window] in window?.window };_ = window.window!.performKeyEquivalent(with:event(.command));try require(!model.busy && reads == 0,"Modified F5 refreshed")
        try require(window.window!.performKeyEquivalent(with:event([])) && model.busy,"Owning F5 missing");try await wait {!model.busy};try require(reads == 1 && model.details?.from.revision == indexed,"F5 changed index baseline")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"Prepared reads changed parent index")
        try require(try Data(contentsOf:location.appendingPathComponent(".git/index")) == childIndex,"Prepared reads changed child index")
        window.close()
        // Mixed file/submodule marks report an error instead of opening a regular-file viewer.
        workspace.showPreparedFileComparison(repository:parent,access:nil,marked:PreparedFileComparisonMark(path:path,revision:"",isDirectory:true),current:PreparedFileComparisonMark(path:"ordinary",revision:""),owner:revert.window)
        try await wait {!workspace.busy};try require(workspace.error != nil && windows.count == 1,"Mixed marks opened an invalid child");workspace.error = nil
        // Retain both tree paths for a historical R100 gitlink, even though the old disk path is gone.
        _ = try await parent.commit(message:"indexed child pointer");let before = try await parent.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let renamed = "renamed 雪\nmodule",movedURL = root.appendingPathComponent(renamed)
        try FileManager.default.moveItem(at:location,to:movedURL)
        _ = try await parent.run(["update-index","--force-remove","--",path]);_ = try await parent.run(["update-index","--add","--cacheinfo","160000," + indexed + "," + renamed]);_ = try await parent.commit(message:"rename gitlink")
        let after = try await parent.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let snapshot = try await parent.revisionComparison(from:.revision(before),to:.revision(after))
        let file = snapshot.files.first{$0.path == renamed && $0.isSubmodule}
        try require(file?.oldPath == path,"Fixture did not create a renamed gitlink")
        let list = RevisionComparisonWindowModel(repository:parent,access:nil,from:.revision(before),to:.revision(after),preferences:prefs);list.installEmbeddedSnapshot(snapshot,bare:false)
        var oldPaths:[String?] = [];list.onSubmoduleCompare = {_,old,_,_ in oldPaths.append(old)};list.compare([renamed]);try await wait {!list.hasOwnedPreparation}
        try require(oldPaths.count == 1 && oldPaths[0] == path,"Changed Files lost historical From path");list.invalidate()
        workspace.showFileComparisons(repository:parent,access:nil,snapshot:snapshot,owner:revert.window)
        try await wait {windows.count == 2 && !workspace.busy && !windows[1].model.busy && windows[1].model.details != nil}
        let historical = windows[1]
        try require(historical.model.path == renamed && historical.model.fromPath == path && !historical.model.fromIndex && historical.model.details?.from.revision == indexed && historical.model.details?.to.revision == indexed,"Shared historical handoff treated rename as addition")
        if let folder = ProcessInfo.processInfo.environment["TURTLEGIT_SUBMODULE_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            NSApp.setActivationPolicy(.accessory);historical.window!.alphaValue = 1
            for (appearance,name) in [(NSAppearance.Name.aqua,"submodule-renamed-light"),(.darkAqua,"submodule-renamed-dark")] {
                historical.window!.appearance = NSAppearance(named:appearance);try await capture(historical.window!,to:directory.appendingPathComponent(name + ".png"))
            }
            historical.window!.alphaValue = 0
        }
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"Historical handoff changed parent index")
        try require(try Data(contentsOf:movedURL.appendingPathComponent(".git/index")) == childIndex,"Historical handoff changed child index")
        // A renamed comparison still owns read cancellation, close-after-drain and its current target.
        var pending:CheckedContinuation<SubmoduleComparison,Error>?,token:OperationCancellation?
        let details = historical.model.details!
        historical.model.readDetails = {request in token = request;return try await withCheckedThrowingContinuation {pending = $0}}
        historical.model.load();try await wait {pending != nil};try require(!historical.windowShouldClose(historical.window!) && token?.isCancelled == true,"Renamed read escaped close ownership")
        pending?.resume(returning:details);pending = nil;try await wait {historical.model.retired && SubmoduleDiffWindowModel.activeReads == 0}
        try require(FileListComparisonSession.activeOperations == 0 && !workspace.busy,"Prepared route leaked worker ownership")
        try require(try Data(contentsOf:movedURL.appendingPathComponent("file")) == Data("dirty\n".utf8),"Comparison changed working bytes")
        print("PASS prepared submodules: Revert directory Mark/file-only Save gates, actual index-to-checkout presenter, captured Compare/Log objects and alternate choice, scoped F5, mixed-mark error, historical rename paths through Changed Files/shared dispatch, private preferences and close-after-drain with both indexes/working bytes intact")
    }
}
