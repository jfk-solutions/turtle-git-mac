import AppKit
import ObjectiveC
import SwiftUI
import TurtleGitCore

private extension NSWindow {
    @objc func ExportProgressVerificationHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(NSPoint(x:-20000,y:-20000));ExportProgressVerificationHiddenOrder(place,relativeTo:number)
    }
}

@main struct ExportProgressVerification {
    @MainActor static func wait(line:Int = #line,_ condition:@escaping ()->Bool) async throws { let end = Date().addingTimeInterval(30); while !condition() && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }; precondition(condition(),"Export timed out phase=\(phase) waitLine=\(line)") }
    static func unzip(_ file:URL,_ path:String) throws -> Data { let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/unzip"); p.arguments = ["-p",file.path,path]; let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); precondition(p.terminationStatus == 0); return data }
    static func archiveReceipt(_ helper:URL,root:URL,head:Data)throws {
        let packet=try Data(contentsOf:URL(fileURLWithPath:helper.path+".arguments"))
        precondition(packet.count<=65536 && packet.last==0,"Missing bounded NUL archive argv receipt")
        let arguments=try packet.dropLast().split(separator:0,omittingEmptySubsequences:false).map {part->String in
            guard let value=String(data:Data(part),encoding:.utf8) else{throw NSError(domain:"ExportQA.Arguments",code:1)};return value
        }
        // Assert the exact GitRepository command root, which normalizes the
        // command-line fixture's/private/var alias before composing argv.
        precondition(arguments.count==8 && Array(arguments.prefix(4))==["--literal-pathspecs","-C",root.path,"archive"],"Archive argv prefix differs from the captured repository root: \(Array(arguments.prefix(4))) expected \(root.path)")
        precondition(arguments[4].hasPrefix("--output=") && Array(arguments.suffix(3))==["--verbose","--end-of-options",String(decoding:head,as:UTF8.self).trimmingCharacters(in:.newlines)],"Archive wrapper changed forwarded command framing")
    }
    @MainActor static var phase="setup"
    @MainActor static func mark(_ value:String){phase=value;print("Export phase: "+value);fflush(stdout)}
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let originalOrder=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hiddenOrder=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.ExportProgressVerificationHiddenOrder(_:relativeTo:)))!
        method_exchangeImplementations(originalOrder,hiddenOrder);defer{method_exchangeImplementations(originalOrder,hiddenOrder)}
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2]), suite = "TurtleGit.ExportProgress.QA." + UUID().uuidString
        let prefs = UserDefaults(suiteName:suite)!; defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};DialogGeometry.install(preferences:prefs)
        let repo = GitRepository(root:root,executable:git); _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Export QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let child = root.appendingPathComponent("folder"); try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
        try Data("root bytes\n".utf8).write(to:root.appendingPathComponent("file")); try Data("child bytes\n".utf8).write(to:child.appendingPathComponent("child")); try await repo.stage(["file","folder/child"]); _ = try await repo.commit(message:"base")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        mark("real whole/scoped archive and captured autoclose policies")
        for policy in GitProgressAutoClose.allCases {
            for scope in ["","folder"] {
                prefs.set(policy.rawValue,forKey:"AutoCloseGitProgress")
                let url = root.appendingPathComponent("export-\(policy.rawValue)-\(scope.isEmpty ? "whole" : "child").zip")
                let result = ExportProgressWindowModel(repository:repo,access:nil,outputAccess:nil,revision:"HEAD",directory:scope,destination:url,preferences:prefs)
                result.outputClipboard=board
                prefs.set((policy.rawValue+1)%3,forKey:"AutoCloseGitProgress")
                var closes = 0; result.close = { closes += 1 }; result.showInFinder = { _ in preconditionFailure("Automatic Explore") }; await result.run()
                precondition(result.success && !result.cancelled && closes == (policy == .noErrors ? 1 : 0))
                let expected = scope.isEmpty ? "root bytes\n" : "child bytes\n", bytes = try unzip(url,scope.isEmpty ? "file" : "child"); precondition(bytes == Data(expected.utf8))
                let host = NSHostingView(rootView:ExportProgressDialog(model:result)); host.frame = NSRect(x:0,y:0,width:760,height:430); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
            }
        }
        mark("captured options and once-only Explore")
        // Options own result until acknowledgement; captured destination and
        // scope survive later field edits; Explore closes before one handoff.
        prefs.set(0,forKey:"AutoCloseGitProgress")
        let owner = ExportWindowModel(repository:repo,access:nil,directory:"folder",preferences:prefs); owner.load(revision:"HEAD"); try await wait { !owner.busy }; owner.wholeProject = false
        let optionsHost = NSHostingView(rootView:ExportDialog(model:owner)); optionsHost.frame = NSRect(x:0,y:0,width:620,height:360); optionsHost.layoutSubtreeIfNeeded(); precondition(optionsHost.fittingSize.width > 0)
        let captured = root.appendingPathComponent("captured.zip"); owner.destination = root.appendingPathComponent("captured").path
        var result:ExportProgressWindowModel?, ownerOrder:[String] = []
        owner.onProgress = { result = $0; $0.outputClipboard=board }; owner.close = { ownerOrder.append("close") }; owner.export(); try await wait { result != nil }; precondition(!owner.canEditForm); owner.destination = root.appendingPathComponent("wrong.zip").path; owner.wholeProject = true
        try await wait { result?.busy == false }; precondition(owner.busy && owner.exported == nil && result!.destination == captured)
        result!.showInFinder = { url in precondition(url == captured); ownerOrder.append("finder") }; result!.explore(); result!.explore()
        precondition(!owner.busy && owner.progress == nil && owner.exported == captured && ownerOrder == ["close","finder"])
        let scoped = try unzip(captured,"child"); precondition(scoped == Data("child bytes\n".utf8))
        mark("directory rejected before overwrite")
        // Source rejects a directory before showing the overwrite question.
        let directoryZIP = root.appendingPathComponent("directory.zip"); try FileManager.default.createDirectory(at:directoryZIP,withIntermediateDirectories:true)
        let invalidDestination = ExportWindowModel(repository:repo,access:nil,preferences:prefs); invalidDestination.load(revision:"HEAD"); try await wait { !invalidDestination.busy }; invalidDestination.destination = directoryZIP.path
        invalidDestination.onProgress = { _ in preconditionFailure("Directory started progress") }; invalidDestination.confirmOverwrite = { _ in preconditionFailure("Directory asked overwrite") }; invalidDestination.export(); try await wait { !invalidDestination.busy }
        precondition(invalidDestination.error == "You selected a folder.\nChoose an archive file instead." && invalidDestination.progress == nil)
        mark("overwrite No and cancelled acceptance")
        // Existing destination No and cancellation during confirmation preserve
        // bytes and do not start a new result with a fresh cancellation token.
        let existing = root.appendingPathComponent("existing.zip"); try Data("existing bytes".utf8).write(to:existing)
        let no = ExportWindowModel(repository:repo,access:nil,preferences:prefs); no.load(revision:"HEAD"); try await wait { !no.busy }; no.destination = existing.path; no.onProgress = { _ in preconditionFailure("Declined overwrite") }; no.confirmOverwrite = { _ in false }; no.export(); try await wait { !no.busy }
        let unchanged = try Data(contentsOf:existing); precondition(unchanged == Data("existing bytes".utf8))
        var choose:CheckedContinuation<Bool,Never>?
        no.confirmOverwrite = { _ in await withCheckedContinuation { choose = $0 } }; no.export(); try await wait { choose != nil }; no.cancel(); choose!.resume(returning:true); choose = nil; try await wait { !no.busy }; let stillUnchanged = try Data(contentsOf:existing); precondition(stillUnchanged == unchanged)
        mark("failed result and reviewed recovery")
        // Invalid revision failure has no Explore or Retry; failed Close returns
        // options. A newly reviewed export can succeed.
        let failed = ExportWindowModel(repository:repo,access:nil,preferences:prefs); failed.load(revision:"no-such-revision"); try await wait { !failed.busy }; failed.destination = root.appendingPathComponent("failed.zip").path
        var failedResult:ExportProgressWindowModel?; failed.onProgress = { failedResult = $0; $0.outputClipboard=board }; failed.export(); try await wait { failedResult?.busy == false }; precondition(!failedResult!.success && failed.busy); failedResult!.showInFinder = { _ in preconditionFailure("Failed Explore") }; failedResult!.explore(); failedResult!.close(); precondition(!failed.busy && failed.progress == nil && failed.error == nil)
        failed.target = .head; failedResult = nil; failed.export(); try await wait { failedResult?.busy == false }; precondition(failedResult!.success); failedResult!.close()
        mark("actual archive cancellation and atomic cleanup")
        // Slow archive writes to Core's owned replacement workspace. Cancellation preserves
        // a previous destination and removes the partial temporary archive.
        let helper = root.appendingPathComponent("slow-git"), marker = URL(fileURLWithPath:helper.path+".started"), release = URL(fileURLWithPath:helper.path+".release")
        let quoted = "'" + git.path.replacingOccurrences(of:"'",with:"'\\''") + "'"
        let script = """
        #!/bin/sh
        task_archive() {
          while [ "$#" -gt 0 ]; do
            case "$1" in
              -C|-c|--git-dir|--work-tree|--namespace|--config-env) [ "$#" -ge 2 ] || return 1; shift 2 ;;
              --literal-pathspecs|--no-literal-pathspecs|--no-optional-locks|--no-pager) shift ;;
              --git-dir=*|--work-tree=*|--namespace=*|--config-env=*) shift ;;
              *) [ "$1" = archive ]; return ;;
            esac
          done
          return 1
        }
        if task_archive "$@" && [ ! -f "$0.release" ]; then
          exec 3>"$0.lease"
          printf '%s\\000' "$@" > "$0.arguments"
          for task_arg in "$@"; do
            case "$task_arg" in --output=*) printf 'partial zip' > "${task_arg#--output=}"; printf '%s\\n' "${task_arg#--output=}" > "$0.archive-output";; esac
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
        try archiveReceipt(helper,root:repo.root,head:head)
        let pids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; precondition(pids.count == 2)
        slow.confirmCancellation = { $0(false) }; slow.cancel(); precondition(slow.busy && !slow.cancelling)
        slow.confirmCancellation = { $0(true) }; slow.cancel(); try await wait { !slow.busy }; precondition(slow.cancelled && !slow.success && cancelledCloses == 0); try await wait { kill(pids[0],0) != 0 && kill(pids[1],0) != 0 }
        let previous=try Data(contentsOf:existing),temporary=URL(fileURLWithPath:try String(contentsOf:URL(fileURLWithPath:helper.path+".archive-output")).trimmingCharacters(in:.newlines))
        precondition(previous==unchanged && temporary.lastPathComponent==existing.lastPathComponent && !FileManager.default.fileExists(atPath:temporary.path) && !FileManager.default.fileExists(atPath:temporary.deletingLastPathComponent().path))
        try FileManager.default.removeItem(at:marker); try Data().write(to:release)
        let retry = ExportProgressWindowModel(repository:slowRepo,access:nil,outputAccess:nil,revision:"HEAD",directory:"",destination:existing,preferences:prefs); await retry.run(); precondition(retry.success); let replacement = try unzip(existing,"file"); precondition(replacement == Data("root bytes\n".utf8))
        mark("completion during pending cancellation question")
        // Successful completion waits for a pending confirmation before auto-close.
        try FileManager.default.removeItem(at:release)
        let deferred = ExportProgressWindowModel(repository:slowRepo,access:nil,outputAccess:nil,revision:"HEAD",directory:"",destination:root.appendingPathComponent("deferred.zip"),preferences:prefs)
        var answer:((Bool)->Void)?, deferredCloses = 0; deferred.close = { deferredCloses += 1 }; deferred.confirmCancellation = { answer = $0 }; deferred.start(); try await wait { FileManager.default.fileExists(atPath:marker.path) }; deferred.cancel()
        let gatePids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; precondition(gatePids.count == 2); try Data().write(to:release); kill(gatePids[1],SIGTERM); try await wait { !deferred.busy }; precondition(deferred.success && deferredCloses == 0 && deferred.confirmingCancellation); answer?(true); answer?(true); precondition(deferredCloses == 1 && !deferred.cancelled)
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout, afterIndex = try Data(contentsOf:root.appendingPathComponent(".git/index")); precondition(head == afterHead && index == afterIndex && MenuIcon.explore.image() != nil)
        try await wait {ExportWindowModel.activeOperations==0 && ExportProgressWindowModel.activeOperations==0 && ExportProgressWindowController.activeReleases==0}
        precondition(NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil})
        print("Export: actual whole/scoped ZIP contents across captured policies, retained owner/immutable destination/scope, once close-before-Explore, overwrite No/pre-presentation cancellation, failure/options recovery, owned No/Yes cancellation and atomic old ZIP/temporary cleanup, fresh export/deferred confirmation. Hidden progress host; no displayed UI/Finder reveal or standard preference writes.")
    }
}
