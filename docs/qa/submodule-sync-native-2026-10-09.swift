import AppKit
import TurtleGitCore
import Darwin

@main struct SubmoduleSyncReceiver {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message: message) } }
    @MainActor static func wait(_ stage: String, _ condition: () -> Bool) async throws { for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw Failure(message:stage) }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() } catch { fputs("FAIL \(error)\n",stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let domain = "TurtleGit.SubmoduleSync.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:domain)!
        defer { prefs.removePersistentDomain(forName:domain) }; DialogGeometry.install(preferences:prefs)
        func repository(_ name: String) async throws -> GitRepository {
            let folder = root.appendingPathComponent(name); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let repo = GitRepository(root:folder,executable:git); _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Sync Fixture"),("user.email","sync@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
            try Data("fixture\n".utf8).write(to:folder.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"fixture"); return repo
        }
        let source = try await repository("source"), parent = try await repository("parent")
        for name in ["one","two"] { _ = try await parent.run(["-c","protocol.file.allow=always","submodule","add","--name",name,"--",source.root.path,"modules/"+name]); _ = try await parent.run(["config","--file",".gitmodules","submodule."+name+".url","ssh://sync-fixture.invalid/"+name]) }
        let index = try Data(contentsOf:parent.root.appendingPathComponent(".git/index")), modules = try Data(contentsOf:parent.root.appendingPathComponent(".gitmodules")), head = try await parent.run(["rev-parse","HEAD"]).stdout
        let wrapper = root.appendingPathComponent("git-wrapper")
        let script = """
        #!/bin/sh
        sync=no
        for argument in "$@"; do [ "$argument" = sync ] && sync=yes; done
        if [ "$sync" = yes ]; then
          printf '%s\\n' called >> "$0.calls"
          printf '%s\\n' 'live fixture output 雪'
          if [ -f "$0.pause" ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.started"
            wait "$task_child"
          fi
          if [ -f "$0.fail-first" ] && [ ! -f "$0.failed" ]; then touch "$0.failed"; exit 7; fi
        fi
        exec '\(git.path.replacingOccurrences(of:"'",with:"'\\''"))' "$@"
        """
        try script.write(to:wrapper,atomically:false,encoding:.utf8); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let repo = GitRepository(root:parent.root,executable:wrapper), access = RepositoryAccessLease(url:parent.root)
        let manual = SubmoduleSyncWindowController(repository:repo,access:access,scope:["modules/one"],preferences:prefs)
        defer { manual.close() }
        var results = 0; manual.model.onSynced = { result in results += 1 }
        manual.model.start(); manual.model.start(); try await wait("Native scoped Sync") { !manual.model.busy }
        let first = try await parent.run(["config","--get","submodule.one.url"]).text.trimmingCharacters(in:.newlines)
        let second = try await parent.run(["config","--get","submodule.two.url"]).text.trimmingCharacters(in:.newlines)
        try require(manual.model.success && results == 1 && first == "ssh://sync-fixture.invalid/one" && second != "ssh://sync-fixture.invalid/two", "Native scoped Sync changed an unselected module or repeated completion")
        manual.close()
        let failedFlag = URL(fileURLWithPath:wrapper.path+".fail-first"); try Data().write(to:failedFlag)
        let partial = SubmoduleSyncWindowModel(repository:repo,access:access,scope:["modules/one","modules/two"],preferences:prefs)
        var partialCodes: [Int32] = []; partial.onSynced = { partialCodes = $0.entries.map(\.exitCode) }
        partial.start(); try await wait("Native partial Sync") { !partial.busy }
        let nextSecond = try await parent.run(["config","--get","submodule.two.url"]).text.trimmingCharacters(in:.newlines)
        try require(!partial.success && partial.exitCode == 7 && partialCodes == [7,0] && nextSecond == "ssh://sync-fixture.invalid/two", "Native ordinary failure stopped a later directory")
        partial.invalidate(); try FileManager.default.removeItem(at:failedFlag)
        for policy in [1,2] {
            prefs.set(policy,forKey:"AutoCloseGitProgress")
            let automatic = SubmoduleSyncWindowModel(repository:repo,access:access,scope:[],preferences:prefs); var closes = 0
            automatic.close = { closes += 1 }; prefs.set(0,forKey:"AutoCloseGitProgress")
            automatic.start(); try await wait("Native automatic Sync") { !automatic.busy }
            try require(automatic.success && closes == 1,"Sync did not capture automatic-close policy"); automatic.invalidate()
        }
        let pause = URL(fileURLWithPath:wrapper.path+".pause"), marker = URL(fileURLWithPath:wrapper.path+".started")
        try Data().write(to:pause); prefs.set(true,forKey:"ConfirmKillProcess")
        let cancelled = SubmoduleSyncWindowController(repository:repo,access:access,scope:["modules/one","modules/two"],preferences:prefs); defer { cancelled.close() }
        var answer: ((Bool)->Void)?, cancelledResults = 0; cancelled.model.confirmCancellation = { answer = $0 }; cancelled.model.onSynced = { _ in cancelledResults += 1 }
        cancelled.model.start(); try await wait("Live Sync process") { FileManager.default.fileExists(atPath:marker.path) && cancelled.model.output.contains("live fixture output 雪") }
        let pids = try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap { Int32($0) }
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Quit allowed active Sync")
        cancelled.model.cancel(); let firstAnswer = answer; firstAnswer?(false); firstAnswer?(true)
        try require(cancelled.model.busy && !cancelled.model.cancelling,"No/duplicate response cancelled Sync")
        cancelled.model.cancel(); answer?(true); answer?(true); try await wait("Sync cancelled cleanup") { !cancelled.model.busy }
        try require(cancelled.model.cancelled && !cancelled.model.success && cancelledResults == 0 && pids.count == 2 && pids.allSatisfy { kill($0,0) != 0 },"Live Sync cancellation left result/processes")
        cancelled.close(); try FileManager.default.removeItem(at:marker)
        let forced = SubmoduleSyncWindowController(repository:repo,access:access,scope:["modules/one","modules/two"],preferences:prefs); defer { forced.close() }
        var forcedResults = 0; forced.model.onSynced = { _ in forcedResults += 1 }; forced.model.start()
        try await wait("Forced Sync process") { FileManager.default.fileExists(atPath:marker.path) }
        let forcedPids = try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap { Int32($0) }
        forced.close(); try await wait("Forced Sync cleanup") { !forced.model.busy }
        try require(forcedResults == 0 && forcedPids.count == 2 && forcedPids.allSatisfy { kill($0,0) != 0 },"Forced Sync close published result or leaked process")
        try require(try Data(contentsOf:parent.root.appendingPathComponent(".git/index")) == index && Data(contentsOf:parent.root.appendingPathComponent(".gitmodules")) == modules,"Sync changed index or tracked config")
        let after = try await parent.run(["rev-parse","HEAD"]).stdout; try require(after == head,"Sync moved HEAD")
        try require(!NSApplication.shared.windows.contains { $0.isVisible },"Receiver displayed UI")
        print("PASS native scoped and whole Sync, partial-error continuation/status, captured auto-close, live UTF-8 output, No/Yes/duplicate cancellation, Quit/forced-close ownership; parent HEAD/index/gitmodules preserved. No displayed/signed/Finder/network acceptance.")
    }
}
