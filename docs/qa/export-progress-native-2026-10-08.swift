import AppKit
import SwiftUI
import TurtleGitCore

@main struct ExportProgressVerification {
    @MainActor static func wait(_ condition:@escaping ()->Bool) async throws { let end = Date().addingTimeInterval(30); while !condition() && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }; precondition(condition(),"Export timed out") }
    static func unzip(_ file:URL,_ path:String) throws -> Data { let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/unzip"); p.arguments = ["-p",file.path,path]; let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); precondition(p.terminationStatus == 0); return data }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2]), suite = "TurtleGit.ExportProgress.QA." + UUID().uuidString
        let prefs = UserDefaults(suiteName:suite)!; defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        let repo = GitRepository(root:root,executable:git); _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Export QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let child = root.appendingPathComponent("folder"); try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
        try Data("root bytes\n".utf8).write(to:root.appendingPathComponent("file")); try Data("child bytes\n".utf8).write(to:child.appendingPathComponent("child")); try await repo.stage(["file","folder/child"]); _ = try await repo.commit(message:"base")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        for policy in GitProgressAutoClose.allCases {
            for scope in ["","folder"] {
                prefs.set(policy.rawValue,forKey:"AutoCloseGitProgress")
                let url = root.appendingPathComponent("export-\(policy.rawValue)-\(scope.isEmpty ? "whole" : "child").zip")
                let result = ExportProgressWindowModel(repository:repo,access:nil,outputAccess:nil,revision:"HEAD",directory:scope,destination:url,preferences:prefs)
                prefs.set((policy.rawValue+1)%3,forKey:"AutoCloseGitProgress")
                var closes = 0; result.close = { closes += 1 }; result.showInFinder = { _ in preconditionFailure("Automatic Explore") }; await result.run()
                precondition(result.success && !result.cancelled && closes == (policy == .noErrors ? 1 : 0))
                let expected = scope.isEmpty ? "root bytes\n" : "child bytes\n", bytes = try unzip(url,scope.isEmpty ? "file" : "child"); precondition(bytes == Data(expected.utf8))
                let host = NSHostingView(rootView:ExportProgressDialog(model:result)); host.frame = NSRect(x:0,y:0,width:760,height:430); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
            }
        }
        // Options own result until acknowledgement; captured destination and
        // scope survive later field edits; Explore closes before one handoff.
        prefs.set(0,forKey:"AutoCloseGitProgress")
        let owner = ExportWindowModel(repository:repo,access:nil,directory:"folder",preferences:prefs); owner.load(revision:"HEAD"); try await wait { !owner.busy }; owner.wholeProject = false
        let optionsHost = NSHostingView(rootView:ExportDialog(model:owner)); optionsHost.frame = NSRect(x:0,y:0,width:620,height:360); optionsHost.layoutSubtreeIfNeeded(); precondition(optionsHost.fittingSize.width > 0)
        let captured = root.appendingPathComponent("captured.zip"); owner.destination = root.appendingPathComponent("captured").path
        var result:ExportProgressWindowModel?, ownerOrder:[String] = []
        owner.onProgress = { result = $0 }; owner.close = { ownerOrder.append("close") }; owner.export(); owner.destination = root.appendingPathComponent("wrong.zip").path; owner.wholeProject = true
        try await wait { result?.busy == false }; precondition(owner.busy && owner.exported == nil && result!.destination == captured)
        result!.showInFinder = { url in precondition(url == captured); ownerOrder.append("finder") }; result!.explore(); result!.explore()
        precondition(!owner.busy && owner.progress == nil && owner.exported == captured && ownerOrder == ["close","finder"])
        let scoped = try unzip(captured,"child"); precondition(scoped == Data("child bytes\n".utf8))
        // Source rejects a directory before showing the overwrite question.
        let directoryZIP = root.appendingPathComponent("directory.zip"); try FileManager.default.createDirectory(at:directoryZIP,withIntermediateDirectories:true)
        let invalidDestination = ExportWindowModel(repository:repo,access:nil,preferences:prefs); invalidDestination.load(revision:"HEAD"); try await wait { !invalidDestination.busy }; invalidDestination.destination = directoryZIP.path
        invalidDestination.onProgress = { _ in preconditionFailure("Directory started progress") }; invalidDestination.confirmOverwrite = { _ in preconditionFailure("Directory asked overwrite") }; invalidDestination.export(); try await wait { !invalidDestination.busy }
        precondition(invalidDestination.error == "You selected a folder.\nExports are only possible to a (zip) file." && invalidDestination.progress == nil)
        // Existing destination No and cancellation during confirmation preserve
        // bytes and do not start a new result with a fresh cancellation token.
        let existing = root.appendingPathComponent("existing.zip"); try Data("existing bytes".utf8).write(to:existing)
        let no = ExportWindowModel(repository:repo,access:nil,preferences:prefs); no.load(revision:"HEAD"); try await wait { !no.busy }; no.destination = existing.path; no.onProgress = { _ in preconditionFailure("Declined overwrite") }; no.confirmOverwrite = { _ in false }; no.export(); try await wait { !no.busy }
        let unchanged = try Data(contentsOf:existing); precondition(unchanged == Data("existing bytes".utf8))
        var choose:CheckedContinuation<Bool,Never>?
        no.confirmOverwrite = { _ in await withCheckedContinuation { choose = $0 } }; no.export(); try await wait { choose != nil }; no.cancel(); choose!.resume(returning:true); choose = nil; try await wait { !no.busy }; let stillUnchanged = try Data(contentsOf:existing); precondition(stillUnchanged == unchanged)
        // Invalid revision failure has no Explore or Retry; failed Close returns
        // options. A newly reviewed export can succeed.
        let failed = ExportWindowModel(repository:repo,access:nil,preferences:prefs); failed.load(revision:"no-such-revision"); try await wait { !failed.busy }; failed.destination = root.appendingPathComponent("failed.zip").path
        var failedResult:ExportProgressWindowModel?; failed.onProgress = { failedResult = $0 }; failed.export(); try await wait { failedResult?.busy == false }; precondition(!failedResult!.success && failed.busy); failedResult!.showInFinder = { _ in preconditionFailure("Failed Explore") }; failedResult!.explore(); failedResult!.close(); precondition(!failed.busy && failed.progress == nil && failed.error == nil)
        failed.target = .head; failedResult = nil; failed.export(); try await wait { failedResult?.busy == false }; precondition(failedResult!.success); failedResult!.close()
        // Slow archive writes to Core's temporary sibling. Cancellation preserves
        // a previous destination and removes the partial temporary archive.
        let helper = root.appendingPathComponent("slow-git"), marker = URL(fileURLWithPath:helper.path+".started"), release = URL(fileURLWithPath:helper.path+".release")
        let quoted = "'" + git.path.replacingOccurrences(of:"'",with:"'\\''") + "'"
        let script = """
        #!/bin/sh
        if [ "${4-}" = archive ] && [ ! -f "$0.release" ]; then
          for task_arg in "$@"; do
            case "$task_arg" in --output=*) printf 'partial zip' > "${task_arg#--output=}";; esac
          done
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started"
          wait "$task_child"
        fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let slowRepo = GitRepository(root:root,executable:helper); prefs.set(true,forKey:"ConfirmKillProcess"); prefs.set(2,forKey:"AutoCloseGitProgress")
        let slow = ExportProgressWindowModel(repository:slowRepo,access:nil,outputAccess:nil,revision:"HEAD",directory:"",destination:existing,preferences:prefs); var cancelledCloses = 0; slow.close = { cancelledCloses += 1 }; slow.start(); try await wait { FileManager.default.fileExists(atPath:marker.path) }
        let pids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; precondition(pids.count == 2)
        slow.confirmCancellation = { $0(false) }; slow.cancel(); precondition(slow.busy && !slow.cancelling)
        slow.confirmCancellation = { $0(true) }; slow.cancel(); try await wait { !slow.busy }; precondition(slow.cancelled && !slow.success && cancelledCloses == 0); try await wait { kill(pids[0],0) != 0 && kill(pids[1],0) != 0 }
        let previous = try Data(contentsOf:existing), leftovers = try FileManager.default.contentsOfDirectory(atPath:root.path).filter { $0.hasPrefix(".TurtleGitArchive-") }; precondition(previous == unchanged && leftovers.isEmpty)
        try FileManager.default.removeItem(at:marker); try Data().write(to:release)
        let retry = ExportProgressWindowModel(repository:slowRepo,access:nil,outputAccess:nil,revision:"HEAD",directory:"",destination:existing,preferences:prefs); await retry.run(); precondition(retry.success); let replacement = try unzip(existing,"file"); precondition(replacement == Data("root bytes\n".utf8))
        // Successful completion waits for a pending confirmation before auto-close.
        try FileManager.default.removeItem(at:release)
        let deferred = ExportProgressWindowModel(repository:slowRepo,access:nil,outputAccess:nil,revision:"HEAD",directory:"",destination:root.appendingPathComponent("deferred.zip"),preferences:prefs)
        var answer:((Bool)->Void)?, deferredCloses = 0; deferred.close = { deferredCloses += 1 }; deferred.confirmCancellation = { answer = $0 }; deferred.start(); try await wait { FileManager.default.fileExists(atPath:marker.path) }; deferred.cancel()
        let gatePids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; precondition(gatePids.count == 2); try Data().write(to:release); kill(gatePids[1],SIGTERM); try await wait { !deferred.busy }; precondition(deferred.success && deferredCloses == 0 && deferred.confirmingCancellation); answer?(true); answer?(true); precondition(deferredCloses == 1 && !deferred.cancelled)
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout, afterIndex = try Data(contentsOf:root.appendingPathComponent(".git/index")); precondition(head == afterHead && index == afterIndex && MenuIcon.explore.image() != nil)
        print("Export: actual whole/scoped ZIP contents across captured policies, retained owner/immutable destination/scope, once close-before-Explore, overwrite No/pre-presentation cancellation, failure/options recovery, owned No/Yes cancellation and atomic old ZIP/temporary cleanup, fresh export/deferred confirmation. Hidden progress host; no displayed UI/Finder reveal or standard preference writes.")
    }
}
