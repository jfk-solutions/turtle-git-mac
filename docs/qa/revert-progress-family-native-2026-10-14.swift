import AppKit
import TurtleGitCore

@main struct RevertProgressFamilyVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws { for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(description: "Revert timeout at line \(line)") }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Revert progress family failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"]); for (key, value) in [("user.name", "Revert QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let path = "file 雪.txt", file = root.appendingPathComponent(path); try Data("base".utf8).write(to: file); try await repo.stage([path]); _ = try await repo.commit(message: "base"); try Data("changed".utf8).write(to: file)
        let entries = try await repo.status().filter { ![FileState.untracked, .ignored].contains($0.state) }, head = try await repo.run(["rev-parse", "HEAD"]).text
        let suite = "TurtleGit.RevertFamily." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!; prefs.set(0, forKey: "AutoCloseGitProgress"); prefs.set(false, forKey: "ConfirmKillProcess"); defer { prefs.removePersistentDomain(forName: suite) }
        ProgressActionLog.install(store: ActionLogStore(storageURL: root.appendingPathComponent("actions.log")), preferences: prefs)
        let retry = RevertProgressWindowController(repository: repo, access: nil, entries: entries, amend: false, againstHead: false, autoCloseSuccess: false, preferences: prefs); defer { retry.close(); for copy in retry.model.trashedFiles { try? FileManager.default.removeItem(at: copy) } }
        let lock = root.appendingPathComponent(".git/index.lock"); try Data("foreign lock".utf8).write(to: lock)
        retry.model.start(); try await wait { !retry.model.busy }; try require(retry.model.failed && !retry.model.retired && retry.model.trashedFiles.isEmpty, "Lock failure did not retain recoverable result")
        try FileManager.default.removeItem(at: lock); try Data("updated draft".utf8).write(to: file); try await repo.stage([path]); retry.model.retry(); try await wait { !retry.model.busy }
        try require(!retry.model.failed && !retry.model.cancelled && String(contentsOf: file) == "base" && retry.model.trashedFiles.count == 1 && retry.model.clipboardOutput.contains(path), "Fresh Retry lost current status, recovery or output"); retry.close()
        // Captured no-errors policy closes a successful result, without an extra validation run.
        try Data("again".utf8).write(to: file); let again = try await repo.status().filter { ![FileState.untracked, .ignored].contains($0.state) }; prefs.set(2, forKey: "AutoCloseGitProgress")
        let automatic = RevertProgressWindowController(repository: repo, access: nil, entries: again, amend: false, againstHead: false, autoCloseSuccess: false, preferences: prefs); defer { automatic.close(); for copy in automatic.model.trashedFiles { try? FileManager.default.removeItem(at: copy) } }
        prefs.set(0, forKey: "AutoCloseGitProgress"); automatic.model.start(); try await wait { RevertProgressWindowModel.activeOperations == 0 }; try require(automatic.model.retired && String(contentsOf: file) == "base", "Captured auto-close preference lost")
        // Real running restore remains protected until its current step finishes.
        try FileManager.default.removeItem(at: file); let missing = try await repo.status().filter { ![FileState.untracked, .ignored].contains($0.state) }
        let helper = root.appendingPathComponent("gated-revert"), marker = root.appendingPathComponent(".git/revert-ready"), release = root.appendingPathComponent(".git/revert-release")
        let script = #"""
        #!/bin/sh
        # Inspect a function-local argv copy; exec always receives the original.
        locate_command() {
          [ "$#" -ge 4 ] && [ "$1" = --literal-pathspecs ] && [ "$2" = -C ] || exit 91
          repository=$3
          shift 3
          while [ "$#" -gt 0 ] && [ "$1" = -c ];do
            [ "$#" -ge 3 ] || exit 92
            shift 2
          done
          command=$1
        }
        locate_command "$@"
        if [ "$command" = restore ];then
          case "$TG_REVERT_PHASE" in cancel|retire) ;; *) exit 93 ;; esac
          receipt="$repository/.git/revert-$TG_REVERT_PHASE"
          printf '%s\0' "$@" > "$receipt.argv"
          /bin/cat > "$receipt.stdin"
          printf 'Restore: 10%%\rRestore: 80%%\r\n'
          : > "$repository/.git/revert-ready"
          while [ ! -f "$repository/.git/revert-release" ];do /bin/sleep 0.05;done
          exec "$TG_REVERT_GIT" "$@" < "$receipt.stdin"
        fi
        exec "$TG_REVERT_GIT" "$@"
        """#
        try Data(script.utf8).write(to: helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let oldGit=ProcessInfo.processInfo.environment["TG_REVERT_GIT"],oldPhase=ProcessInfo.processInfo.environment["TG_REVERT_PHASE"]
        setenv("TG_REVERT_GIT",git.path,1);setenv("TG_REVERT_PHASE","cancel",1)
        defer {
            if let oldGit {setenv("TG_REVERT_GIT",oldGit,1)}else{unsetenv("TG_REVERT_GIT")}
            if let oldPhase {setenv("TG_REVERT_PHASE",oldPhase,1)}else{unsetenv("TG_REVERT_PHASE")}
        }
        func verifyReceipt(_ phase:String)throws {
            let receipt=root.appendingPathComponent(".git/revert-"+phase)
            func read(_ suffix:String)throws->Data {
                let url=URL(fileURLWithPath:receipt.path+suffix),size=try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber
                try require(size != nil && size!.intValue<=65_536,"Protected restore receipt is oversized: "+phase+suffix)
                return try Data(contentsOf:url)
            }
            let arguments=try read(".argv"),input=try read(".stdin")
            try require(arguments.last==0,"Protected restore argv receipt is incomplete")
            var actual:[String]=[]
            for field in arguments.split(separator:0,omittingEmptySubsequences:false).dropLast() {
                guard let value=String(data:field,encoding:.utf8) else{throw Failure(description:"Protected restore argv is not exact UTF-8")}
                actual.append(value)
            }
            let expected=["--literal-pathspecs","-C",root.path,"-c","core.precomposeunicode=false","restore","--source="+head.trimmingCharacters(in:.newlines),"--staged","--worktree","--pathspec-from-file=-","--pathspec-file-nul"]
            try require(actual.map{Data($0.utf8)}==expected.map{Data($0.utf8)},"Protected restore changed exact global options, command or NUL pathspec framing: "+phase)
            try require(input.count<=65_536 && input==Data((path+"\0").utf8),"Protected restore lost its exact literal selected-name packet: "+phase)
        }
        prefs.set(true, forKey: "ConfirmKillProcess")
        let slow = RevertProgressWindowController(repository: GitRepository(root: root, executable: helper), access: nil, entries: missing, amend: false, againstHead: false, autoCloseSuccess: false, preferences: prefs); defer { try? Data().write(to: release); slow.close() }
        var answer: CheckedContinuation<Bool, Never>?, finished = 0
        defer{answer?.resume(returning:false);answer=nil}
        slow.model.confirmCancellation = { await withCheckedContinuation { answer = $0 } }; slow.model.onFinished = { _, _ in finished += 1 }
        slow.model.start(); try await wait { FileManager.default.fileExists(atPath: marker.path) && slow.model.commandOutput.contains("Restore: 80%") }
        try verifyReceipt("cancel")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")); slow.model.cancel(); try await wait { answer != nil }; answer?.resume(returning: false); answer = nil; try await wait { !slow.model.confirmingCancellation }; try require(slow.model.busy && !slow.model.cancelRequested, "No cancelled protected step")
        slow.model.cancel(); try await wait { answer != nil }; answer?.resume(returning: true); answer = nil; try await wait { slow.model.cancelRequested }
        try require(slow.model.busy && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Queued cancellation lost lifetime")
        try Data().write(to: release); try await wait { !slow.model.busy }; try require(slow.model.cancelled && !slow.model.failed && finished == 1 && Data(contentsOf: root.appendingPathComponent(".git/index")) == index, "Cancelled protected step published index or lost completion"); slow.close()
        // Forced retirement retains a pending operation and rejects late result callbacks.
        try FileManager.default.removeItem(at: marker); try FileManager.default.removeItem(at: release); try FileManager.default.removeItem(at: file)
        setenv("TG_REVERT_PHASE","retire",1)
        let lateEntries = try await repo.status().filter { ![FileState.untracked, .ignored].contains($0.state) }, late = RevertProgressWindowController(repository: GitRepository(root: root, executable: helper), access: nil, entries: lateEntries, amend: false, againstHead: false, autoCloseSuccess: false, preferences: prefs); defer { try? Data().write(to: release); late.close() }; var lateFinished = 0; late.model.onFinished = { _, _ in lateFinished += 1 }; late.model.start(); try await wait { FileManager.default.fileExists(atPath: marker.path) };try verifyReceipt("retire"); late.close(); let frozen = late.model.commandOutput
        try require(late.model.retired && RevertProgressWindowModel.activeOperations > 0, "Forced closure lost protected lifetime"); try Data().write(to: release); try await wait { RevertProgressWindowModel.activeOperations == 0 }; try require(lateFinished == 0 && late.model.commandOutput == frozen, "Retired result published")
        let after = try await repo.run(["rev-parse", "HEAD"]).text; try require(head == after, "Revert changed HEAD")
        try await verifyPolicies(root:root,git:git)
        print("PASS Revert family: foreign-lock failure/fresh Retry/Trash recovery, captured auto-close, real CR stream, declined/queued cancellation and protected index, forced-retirement counter/Quit and late-result suppression")
    }
    @MainActor static func verifyPolicies(root:URL,git:URL)async throws {
        for recycle in [false,true] {for renamed in [false,true] {
            let directory=root.appendingPathComponent("policy-\(recycle)-\(renamed)")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let repo=GitRepository(root:directory,executable:git)
            _=try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Policy QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            let old=directory.appendingPathComponent("old.txt"),normal=directory.appendingPathComponent("normal.txt"),new=directory.appendingPathComponent("renamed.txt"),added=directory.appendingPathComponent("added.txt")
            let oldBase=(0..<30).map{"retained old line \($0)"}.joined(separator:"\n")+"\n"
            try Data(oldBase.utf8).write(to:old);try Data("normal base\n".utf8).write(to:normal)
            try await repo.stage(["old.txt","normal.txt"]);_=try await repo.commit(message:"policy base")
            let head=try await repo.run(["rev-parse","HEAD"]).stdout
            _=try await repo.run(["mv","old.txt","renamed.txt"])
            let renamedDraft=Data((oldBase+"renamed draft\n").utf8),normalDraft=Data("normal draft\n".utf8),addedDraft=Data("added local\n".utf8)
            try renamedDraft.write(to:new);try normalDraft.write(to:normal);try addedDraft.write(to:added);try await repo.stage(["added.txt"])
            let entries=try await repo.status().filter{![FileState.untracked,.ignored].contains($0.state)}
            try require(entries.contains{$0.originalPath=="old.txt" && $0.path=="renamed.txt"},"Policy fixture did not retain a genuine rename")
            let suite="TurtleGit.RevertPolicy."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
            defer{prefs.removePersistentDomain(forName:suite)}
            prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess")
            prefs.set(recycle,forKey:"RevertWithRecycleBin");prefs.set(renamed,forKey:"RevertRenamedFilesWithRecycleBin")
            let child=RevertProgressWindowController(repository:repo,access:nil,entries:entries,amend:false,againstHead:false,autoCloseSuccess:false,preferences:prefs)
            defer{child.close();for copy in child.model.trashedFiles{try? FileManager.default.removeItem(at:copy)}}
            let captured=WorkingFileRevertPolicy(recycle:recycle,recycleRenamedFiles:renamed)
            try require(child.model.policy==captured,"Progress did not capture private master/rename settings")
            let detail=WorkingFileRevertPresentation.confirmation(child.model.policy)
            try require(detail.contains("Added files remain") && (recycle ? (renamed ? detail.contains("are moved to Trash"):detail.contains("except renamed files")):detail.contains("will not be saved to Trash")),"Confirmation misrepresented captured disposition")
            let lock=directory.appendingPathComponent(".git/index.lock")
            try Data("foreign lock".utf8).write(to:lock)
            // Both initial execution and Retry must retain the approved policy,
            // even when the same preferences domain changes while the result is open.
            prefs.set(!recycle,forKey:"RevertWithRecycleBin");prefs.set(!renamed,forKey:"RevertRenamedFilesWithRecycleBin")
            child.model.start();try await wait{!child.model.busy}
            try require(child.model.failed && child.model.trashedFiles.isEmpty && child.model.policy==captured,"Failed preparation changed disposal policy or moved files")
            try require(try Data(contentsOf:normal)==normalDraft && Data(contentsOf:new)==renamedDraft,"Lock failure disposed working bytes")
            try FileManager.default.removeItem(at:lock)
            child.model.retry();try await wait{!child.model.busy}
            try require(!child.model.failed && !child.model.cancelled && child.model.policy==captured,"Retry did not reuse captured disposition")
            let expectedCopies=(recycle ? 1:0)+(recycle && renamed ? 1:0)
            try require(child.model.trashedFiles.count==expectedCopies,"Saved-copy result included unperformed Trash operations")
            let copies=try child.model.trashedFiles.map{try Data(contentsOf:$0)}
            try require(copies.contains(normalDraft)==recycle && copies.contains(renamedDraft)==(recycle && renamed),"Wrong working bytes retained in Trash")
            try require(try Data(contentsOf:normal)==Data("normal base\n".utf8) && Data(contentsOf:old)==Data(oldBase.utf8) && !FileManager.default.fileExists(atPath:new.path),"Disposition changed Revert file/rename semantics")
            try require(try Data(contentsOf:added)==addedDraft,"Added file was disposed rather than unstaged")
            let index=try await repo.run(["ls-files","--stage"]).text
            try require(index.contains("old.txt") && index.contains("normal.txt") && !index.contains("renamed.txt") && !index.contains("added.txt"),"Revert policy published wrong index")
            try require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"Revert policy changed HEAD")
            try require(child.model.clipboardOutput.contains("Moved to Trash:")==(!copies.isEmpty),"Result invented or hid recovery copies")
            child.close();try await wait{RevertProgressWindowController.activeReleases==0}
        }}
    }


}
