import AppKit
import Darwin
import TurtleGitCore

@main struct GitPropertiesVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ description:String) throws { if !value { throw Failure(description:description) } }
    @MainActor static func wait(_ value:@escaping ()->Bool) async throws {
        for _ in 0..<1000 { if value() { return };try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Git Properties did not settle")
    }
    @MainActor static func views(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(views) }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Git Properties failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),engine=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:engine)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Properties QA"),("user.email","properties@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        for (path,text) in [("file.txt","base\n"),("second.txt","second\n")] { try Data(text.utf8).write(to:root.appendingPathComponent(path)) }
        try await repo.stage(["file.txt","second.txt"]);_ = try await repo.commit(message:"baseline")
        _ = try await repo.run(["update-index","--assume-unchanged","--","second.txt"])
        try Data("working only\n".utf8).write(to:root.appendingPathComponent("file.txt"))
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let name="TurtleGit.GitProperties.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:name)!
        defer { prefs.removePersistentDomain(forName:name) }
        let context=GitPropertiesContext(repository:repo,paths:["file.txt","second.txt"],access:nil,submodule:false)
        let owner=GitPropertiesWindowController(contexts:[context],preferences:prefs),model=owner.model,window=owner.window!
        defer { owner.close() }
        try await wait { !model.busy && model.current != nil }
        try require(model.draft.assumeUnchanged == .mixed && model.current?.allVersioned == true,"Mixed flags/selected paths")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"Property load modified the index")
        window.contentView?.layoutSubtreeIfNeeded()
        let controls=views(window.contentView!).compactMap { $0 as? NSButton }
        try require(controls.contains { $0.title == "Assume valid/unchanged" && $0.state == .mixed && $0.allowsMixedState },"Native three-state checkbox missing")
        try require(controls.contains { $0.title == "Executable (+x)" && !$0.allowsMixedState },"Uniform source checkbox gained a mixed state")
        let values=views(window.contentView!).compactMap { $0 as? NSTextField }
        try require(values.contains { $0.stringValue == "Properties QA" && !$0.isEditable && $0.isSelectable },"Read-only values cannot be selected/copied")
        var changed=0;model.onChanged={ value in if value.root == root { changed += 1 } }
        var logRoot:URL?,logPaths:[String]=[];model.onLog={ logRoot=$0.repository.root;logPaths=$0.paths }
        model.showLog();try require(logRoot == root && logPaths == context.paths,"Log lost captured repository/selection")
        let isolated=RepositoryModel(startMonitoring:false,initializePreferences:false)
        isolated.settingsContextOverride=(repo,nil,true);isolated.root=URL(fileURLWithPath:"/unused/other")
        let settings=try isolated.gitConfigurationContext();try require(settings.repository.root == root && settings.localAvailable,"Settings followed another workspace")
        model.set(\GitPropertyDraft.executable,.on);try require(model.draft.symlink == .off && model.canApply,"Executable draft gate")
        model.apply();model.apply()
        try await wait { !model.busy && GitPropertiesWindowModel.activeOperations == 0 }
        try require(changed == 1 && model.current?.entries.allSatisfy({ $0.mode == "100755" }) == true && !model.changed,"Apply duplicated/lost mode change")
        try require(try Data(contentsOf:root.appendingPathComponent("file.txt")) == Data("working only\n".utf8),"Apply staged working bytes")
        model.set(\GitPropertyDraft.symlink,.on);try require(model.draft.executable == .off,"Mutual exclusion failed")
        owner.close();let actual=try await repo.gitProperties(paths:context.paths)
        try require(actual.entries.allSatisfy { $0.mode == "100755" },"Cancel committed an unsaved draft")
        // A selected gitlink gets source mode gates and an initialized child page.
        let child=root.appendingPathComponent("module");try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
        let childRepo=GitRepository(root:child,executable:engine)
        _ = try await childRepo.run(["init","-b","child"])
        for (key,value) in [("user.name","Child QA"),("user.email","child@example.invalid"),("commit.gpgsign","false")] { _ = try await childRepo.run(["config",key,value]) }
        try Data("child\n".utf8).write(to:child.appendingPathComponent("child.txt"));try await childRepo.stage(["child.txt"]);_ = try await childRepo.commit(message:"child")
        let childHead=try await childRepo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-index","--add","--cacheinfo","160000,"+childHead+",module"])
        let moduleOwner=GitPropertiesWindowController(contexts:[GitPropertiesContext(repository:repo,paths:["module"],access:nil,submodule:true)],preferences:prefs)
        try await wait { !moduleOwner.model.busy && moduleOwner.model.contexts.count == 2 }
        try require(moduleOwner.model.current?.hasSubmodule == true,"Gitlink metadata")
        let old=moduleOwner.model.draft;moduleOwner.model.set(\GitPropertyDraft.executable,.on)
        try require(moduleOwner.model.draft == old,"Hidden gitlink mode was editable")
        moduleOwner.model.selected=1;try require(moduleOwner.model.current?.branch == "child" && moduleOwner.model.current?.allVersioned == false,"Child repository page")
        moduleOwner.close()
        // Force-close a live reader; Quit accounting outlives its window.
        let helper=root.appendingPathComponent("held-properties")
        func quote(_ value:String)->String { "'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'" }
        let script="""
        #!/bin/sh
        for arg in "$@"; do
          if [ "$arg" = symbolic-ref ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
            /bin/mv "$0.ready.tmp" "$0.ready"
            wait "$task_child"
          fi
        done
        exec \(quote(engine.path)) "$@"
        """
        try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let slow=GitPropertiesWindowController(contexts:[GitPropertiesContext(repository:GitRepository(root:root,executable:helper),paths:["file.txt"],access:nil,submodule:false)],preferences:prefs)
        let marker=URL(fileURLWithPath:helper.path+".ready");try await wait { FileManager.default.fileExists(atPath:marker.path) }
        let pids=try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap { Int32($0) }
        try require(!slow.windowShouldClose(slow.window!),"Busy close guard")
        slow.close();try require(slow.model.retired && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Closed reader lost Quit ownership")
        try await wait { !slow.model.busy && GitPropertiesWindowModel.activeOperations == 0 }
        try require(pids.count == 2 && pids.allSatisfy({ kill($0,0) != 0 }) && slow.model.snapshots[0] == nil,"Late result or owned process leaked")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;try require(head == after,"Properties moved HEAD")
        print("Git Properties: source values/mixed native controls, captured Log/Settings contexts, duplicate Apply/Cancel/mode gates, initialized Git/Submodule pages and forced-read close/Quit/reaping passed. Private repositories/preferences; no general clipboard.")
    }
}
