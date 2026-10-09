import AppKit
import TurtleGitCore
import Darwin

@main struct SubmoduleUpdateProgressReceiver {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message:message) } }
    @MainActor static func wait(_ stage: String, _ condition: () -> Bool) async throws { for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw Failure(message:stage) }
    @MainActor static var ownedModels: [SubmoduleUpdateProgressWindowModel] = []
    @MainActor static func cleanup() async throws {
        for model in ownedModels { model.invalidate() }
        try await wait("Receiver owned-operation cleanup") { ownedModels.allSatisfy { !$0.busy } }
        ownedModels.removeAll()
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run(); try await cleanup() } catch {
            let failure = error; do { try await cleanup() } catch { fputs("CLEANUP FAIL \(error)\n",stderr) }
            fputs("FAIL \(failure)\n",stderr); exit(1)
        }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let domain = "TurtleGit.SubmoduleUpdateProgress.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:domain)!
        defer { prefs.removePersistentDomain(forName:domain) }; DialogGeometry.install(preferences:prefs)
        func repository(_ name: String) async throws -> GitRepository {
            let folder = root.appendingPathComponent(name); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let repo = GitRepository(root:folder,executable:git); _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Update Fixture"),("user.email","update@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
            try Data("fixture\n".utf8).write(to:folder.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"fixture"); return repo
        }
        let source = try await repository("source"), parent = try await repository("parent"), first = "group/one ' 雪\nmodule", second = "group-other/two"
        for (name,path) in [("one",first),("two",second)] { _ = try await parent.run(["-c","protocol.file.allow=always","submodule","add","--name",name,"--",source.root.path,path]) }
        _ = try await parent.commit(message:"modules")
        let child = GitRepository(root:parent.root.appendingPathComponent(first),executable:git), other = GitRepository(root:parent.root.appendingPathComponent(second),executable:git)
        let old = try await source.run(["rev-parse","HEAD"]).stdout
        try Data("next\n".utf8).write(to:source.root.appendingPathComponent("file")); try await source.stage(["file"]); _ = try await source.commit(message:"next")
        let next = try await source.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await child.run(["-c","protocol.file.allow=always","fetch","origin"])
        _ = try await parent.run(["update-index","--cacheinfo","160000,"+next+","+first])
        let index = try Data(contentsOf:parent.root.appendingPathComponent(".git/index")), modules = try Data(contentsOf:parent.root.appendingPathComponent(".gitmodules")), head = try await parent.run(["rev-parse","HEAD"]).stdout
        let wrapper = root.appendingPathComponent("git-wrapper")
        let script = """
        #!/bin/sh
        updating=no
        for argument in "$@"; do [ "$argument" = update ] && updating=yes; done
        if [ "$updating" = yes ]; then
          printf '%s\\n' called >> "$0.calls"
          printf '%s\\n' 'live update fixture 雪'
          if [ -f "$0.pause" ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.started"
            wait "$task_child"
          fi
          if [ -f "$0.fail" ]; then
            task_line=0
            while [ "$task_line" -lt 3000 ]; do printf '%s\\n' 'fixture update failure with bounded output'; task_line=$((task_line+1)); done
            exit 7
          fi
        fi
        exec '\(git.path.replacingOccurrences(of:"'",with:"'\\''"))' "$@"
        """
        try script.write(to:wrapper,atomically:false,encoding:.utf8); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let repo = GitRepository(root:parent.root,executable:wrapper), access = RepositoryAccessLease(url:parent.root)
        let options = SubmoduleUpdateWindowController(repository:repo,access:access,scope:["group"],selected:[first],preferences:prefs)
        defer { options.close() }
        var submitted = 0, results = 0, progress: SubmoduleUpdateProgressWindowController?
        options.model.onSubmit = { paths, snapshot in
            submitted += 1; progress = SubmoduleUpdateProgressWindowController(repository:repo,access:access,paths:paths,options:snapshot,preferences:prefs)
            if let model = progress?.model { ownedModels.append(model) }
            progress?.model.onUpdated = { _ in results += 1 }; progress?.model.start()
        }
        options.model.load(); try await wait("Options scoped load") { !options.model.busy }
        try require(options.model.paths == [first] && options.model.selection == [first] && options.model.canApply,"Options scope/selection lost")
        options.model.options.noFetch = true; options.model.apply(); options.model.apply()
        try require(submitted == 1,"Options submitted twice")
        guard let manual = progress else { throw Failure(message:"Missing separate progress") }; defer { manual.close() }
        manual.model.start(); try await wait("Native selected Update") { !manual.model.busy }
        let childHead = try await child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines), otherHead = try await other.run(["rev-parse","HEAD"]).stdout
        try require(manual.model.success && results == 1 && childHead == next && otherHead == old && manual.model.postActions.isEmpty,"Update changed another module or repeated result")
        manual.close()
        let reopen = SubmoduleUpdateWindowModel(repository:repo,access:access,scope:["group"],selected:[],preferences:prefs)
        reopen.onSubmit = { _,_ in }; reopen.load(); try await wait("Options reopen") { !reopen.busy }
        try require(reopen.options.noFetch && reopen.selection == [first],"Options/history did not persist privately"); reopen.invalidate()
        var noFetch = SubmoduleUpdateOptions(); noFetch.noFetch = true
        for policy in [1,2] {
            prefs.set(policy,forKey:"AutoCloseGitProgress")
            let automatic = SubmoduleUpdateProgressWindowModel(repository:repo,access:access,paths:[first],options:noFetch,preferences:prefs); var closes = 0
            ownedModels.append(automatic); automatic.close = { closes += 1 }; prefs.set(0,forKey:"AutoCloseGitProgress")
            automatic.start(); try await wait("Automatic Update") { !automatic.busy }
            try require(automatic.success && closes == 1,"Update lost captured automatic-close policy"); automatic.invalidate()
        }
        let fail = URL(fileURLWithPath:wrapper.path+".fail"); try Data().write(to:fail); prefs.set(16,forKey:"GitOutputLimitinKiB")
        let failure = SubmoduleUpdateProgressWindowModel(repository:repo,access:access,paths:[first],options:noFetch,preferences:prefs); var failedResults = 0
        ownedModels.append(failure); failure.onUpdated = { _ in failedResults += 1 }; failure.start(); try await wait("Failed Update") { !failure.busy }
        try require(!failure.success && failure.exitCode == 7 && failedResults == 0 && failure.postActions.isEmpty && failure.output.utf8.count < 20_000,"Update failure published success or unbounded text")
        failure.invalidate(); try FileManager.default.removeItem(at:fail)
        let pause = URL(fileURLWithPath:wrapper.path+".pause"), marker = URL(fileURLWithPath:wrapper.path+".started")
        try Data().write(to:pause); prefs.set(true,forKey:"ConfirmKillProcess")
        let cancelled = SubmoduleUpdateProgressWindowController(repository:repo,access:access,paths:[first,second],options:noFetch,preferences:prefs); defer { cancelled.close() }
        var answer: ((Bool)->Void)?, cancelledResults = 0; cancelled.model.confirmCancellation = { answer = $0 }; cancelled.model.onUpdated = { _ in cancelledResults += 1 }
        ownedModels.append(cancelled.model); cancelled.model.start(); try await wait("Live Update") { FileManager.default.fileExists(atPath:marker.path) && cancelled.model.output.contains("live update fixture 雪") }
        let pids = try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap { Int32($0) }
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Quit allowed active Update")
        cancelled.model.cancel(); let firstAnswer = answer; firstAnswer?(false); firstAnswer?(true)
        try require(cancelled.model.busy && !cancelled.model.cancelling,"No/duplicate cancelled Update")
        cancelled.model.cancel(); answer?(true); answer?(true); try await wait("Canceled Update cleanup") { !cancelled.model.busy }
        try require(cancelled.model.cancelled && !cancelled.model.success && cancelledResults == 0 && pids.count == 2 && pids.allSatisfy { kill($0,0) != 0 },"Canceled Update leaked result/processes")
        cancelled.close(); try FileManager.default.removeItem(at:marker)
        let forced = SubmoduleUpdateProgressWindowController(repository:repo,access:access,paths:[first],options:noFetch,preferences:prefs); defer { forced.close() }
        var forcedResults = 0; forced.model.onUpdated = { _ in forcedResults += 1 }; ownedModels.append(forced.model); forced.model.start()
        try await wait("Forced Update") { FileManager.default.fileExists(atPath:marker.path) }
        let forcedPids = try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap { Int32($0) }
        forced.close(); try await wait("Forced cleanup") { !forced.model.busy }
        try require(forcedResults == 0 && forcedPids.count == 2 && forcedPids.allSatisfy { kill($0,0) != 0 },"Forced Update close leaked callbacks/processes")
        try FileManager.default.removeItem(at:marker)
        prefs.set(2,forKey:"AutoCloseGitProgress")
        let deferred = SubmoduleUpdateProgressWindowModel(repository:repo,access:access,paths:[first],options:noFetch,preferences:prefs)
        ownedModels.append(deferred); var deferredAnswer: ((Bool)->Void)?, deferredCloses = 0
        deferred.confirmCancellation = { deferredAnswer = $0 }; deferred.close = { deferredCloses += 1 }; deferred.start()
        try await wait("Deferred-answer Update") { FileManager.default.fileExists(atPath:marker.path) }
        let deferredPids = try String(contentsOf:marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        try require(deferredPids.count == 2,"Missing deferred fixture process ownership")
        deferred.cancel(); try require(deferred.confirmingCancellation,"Deferred cancellation question missing")
        // End only the fixture sleeper: wrapper proceeds to real Git without canceling the operation.
        try require(kill(deferredPids[1],SIGTERM) == 0,"Could not release owned fixture sleeper")
        try await wait("Completion while cancellation answer pending") { !deferred.busy }
        try require(deferred.success && deferred.confirmingCancellation && deferredCloses == 0,"Completion closed behind pending cancellation question")
        deferredAnswer?(false); deferredAnswer?(true)
        try require(deferredCloses == 1 && !deferred.cancelled && deferredPids.allSatisfy { kill($0,0) != 0 },"Late/duplicate answer canceled success or repeated automatic close")
        deferred.invalidate(); try FileManager.default.removeItem(at:pause)
        try require(try Data(contentsOf:parent.root.appendingPathComponent(".git/index")) == index && Data(contentsOf:parent.root.appendingPathComponent(".gitmodules")) == modules,"Update changed index/gitmodules")
        let after = try await parent.run(["rev-parse","HEAD"]).stdout; try require(after == head,"Update moved parent HEAD")
        // Real bisect metadata controls source post-actions; selecting Reset executes the actual Git reset.
        _ = try await parent.commit(message:"new gitlink")
        try Data("third\n".utf8).write(to:parent.root.appendingPathComponent("file")); try await parent.stage(["file"]); _ = try await parent.commit(message:"third")
        _ = try await parent.run(["bisect","start","HEAD","HEAD~2"])
        prefs.set(1,forKey:"AutoCloseGitProgress")
        let bisect = SubmoduleUpdateProgressWindowModel(repository:repo,access:access,paths:[first],options:noFetch,preferences:prefs); var bisectCloses = 0, operations: [BisectOperation] = [], resetDone = false
        bisect.close = { bisectCloses += 1 }; bisect.onBisect = { operation in operations.append(operation); Task { _ = try? await parent.bisect(operation); resetDone = true } }
        ownedModels.append(bisect); bisect.start(); try await wait("Bisect Update") { !bisect.busy }
        try require(bisect.success && bisect.postActions == [.good,.bad,.skip,.reset] && bisectCloses == 0,"Bisect post-actions/order or no-options auto-close differs")
        for operation in bisect.postActions { try require(bisect.action(for:operation).icon.image() != nil,"Missing original bisect artwork") }
        bisect.perform(.reset); bisect.perform(.reset); try await wait("Bisect Reset callback") { resetDone }
        let state = try await parent.bisectState(); try require(operations == [.reset] && bisectCloses == 1 && !state.active,"Bisect post-action repeated or reset failed"); bisect.invalidate()
        try require(!NSApplication.shared.windows.contains { $0.isVisible },"Receiver displayed UI")
        print("PASS separate scoped Update options/progress, actual selected checkout, saved options, auto-close, bounded failure, live UTF-8, No/Yes/duplicate/deferred cancellation, Quit/forced-close process ownership, original bisect actions/reset; parent HEAD/index/gitmodules preserved before bisect. No displayed/signed/Finder/network acceptance.")
    }
}
