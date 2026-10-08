import AppKit
import SwiftUI
import TurtleGitCore

@main struct FormatPatchProgressVerification {
    @MainActor static func wait(_ condition:@escaping ()->Bool) async throws { let end = Date().addingTimeInterval(30); while !condition() && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }; precondition(condition(),"Format Patch timed out") }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2]), suite = "TurtleGit.FormatPatchProgress.QA." + UUID().uuidString
        let prefs = UserDefaults(suiteName:suite)!; defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        let repo = GitRepository(root:root,executable:git); _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Patch QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        for value in ["base","one","two"] { try Data((value+"\n").utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:value) }
        let base = try await repo.run(["rev-parse","HEAD~2"]).text.trimmingCharacters(in:.newlines), head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        for policy in GitProgressAutoClose.allCases {
            for (number,mode) in [FormatPatchWindowModel.Mode.since,.number,.from].enumerated() {
                prefs.set(0,forKey:"AutoCloseGitProgress")
                let model = FormatPatchWindowModel(repository:repo,access:nil,preferences:prefs); model.load(); try await wait { !model.busy }
                model.mode = mode; model.since = base; model.from = base; model.to = "HEAD"; model.count = 2; model.sendMail = false
                let folder = root.appendingPathComponent("patches-\(policy.rawValue)-\(number)"); model.directory = folder.path
                prefs.set(policy.rawValue,forKey:"AutoCloseGitProgress")
                var events:[String] = []; model.onOutputChanged = { _ in events.append("output") }; model.close = { events.append("close") }; model.composeMail = { _ in preconditionFailure("Unselected mail") }
                model.export(); model.sendMail = true; prefs.set((policy.rawValue+1)%3,forKey:"AutoCloseGitProgress"); model.export()
                try await wait { !model.busy && !model.finishScheduled }
                precondition(model.success && !model.cancelled && events == (policy == .manual ? ["output"] : ["output","close"]))
                let patches = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter { $0.pathExtension == "patch" }.sorted { $0.path < $1.path }; precondition(patches.count == 2)
                if policy == .manual { precondition(model.progress); model.finish(); model.finish(); try await wait { !model.finishScheduled }; precondition(events == ["output","close"]); let host = NSHostingView(rootView:FormatPatchDialog(model:model)); host.frame = NSRect(x:0,y:0,width:680,height:365); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0) }
                model.finish(); precondition(events == ["output","close"])
            }
        }
        // Captured mail after automatic acknowledgement: literal newline output
        // directory, exactly two real file URLs, no actual email service invoked.
        prefs.set(1,forKey:"AutoCloseGitProgress")
        let mail = FormatPatchWindowModel(repository:repo,access:nil,preferences:prefs); mail.load(); try await wait { !mail.busy }; mail.mode = .number; mail.count = 2; mail.directory = root.appendingPathComponent("mail\npatches").path; mail.sendMail = true
        var attachments:[URL] = [], mailCalls = 0; mail.close = { preconditionFailure("Mail closed early") }; mail.composeMail = { attachments = $0; mailCalls += 1 }
        mail.export(); mail.sendMail = false; try await wait { !mail.busy && !mail.finishScheduled }; mail.finish(); precondition(mailCalls == 1 && attachments.count == 2 && attachments.allSatisfy { FileManager.default.fileExists(atPath:$0.path) && $0.deletingLastPathComponent().path == URL(fileURLWithPath:mail.directory).resolvingSymlinksInPath().path })
        let cloneRoot = root.appendingPathComponent("apply-clone"); _ = try await repo.run(["clone","--no-local",root.path,cloneRoot.path]); let clone = GitRepository(root:cloneRoot,executable:git)
        _ = try await clone.run(["config","user.name","Patch QA"]); _ = try await clone.run(["config","user.email","qa@example.invalid"]); _ = try await clone.run(["config","commit.gpgsign","false"]); _ = try await clone.run(["config","core.hooksPath","/dev/null"]); _ = try await clone.run(["checkout","--detach",base]); _ = try await clone.run(["am"]+attachments.sorted { $0.path < $1.path }.map(\.path))
        let expectedTree = try await repo.run(["rev-parse","HEAD^{tree}"]).stdout, appliedTree = try await clone.run(["rev-parse","HEAD^{tree}"]).stdout; precondition(expectedTree == appliedTree)
        prefs.synchronize(); let remembered = FormatPatchWindowModel(repository:repo,access:nil,preferences:UserDefaults(suiteName:suite)!); precondition(remembered.dirs.contains(mail.directory) && remembered.sendMail)
        // Failures remain; acknowledgement returns options and fresh export works.
        prefs.set(2,forKey:"AutoCloseGitProgress")
        let failure = FormatPatchWindowModel(repository:repo,access:nil,preferences:prefs); failure.load(); try await wait { !failure.busy }; failure.mode = .since; failure.since = "no-such-revision"; failure.directory = root.appendingPathComponent("failure").path; failure.sendMail = false
        var failureCloses = 0; failure.close = { failureCloses += 1 }; failure.export(); try await wait { !failure.busy }; precondition(!failure.success && failure.progress && failureCloses == 0); failure.finish(); precondition(!failure.progress && failureCloses == 0); failure.mode = .number; failure.count = 1; failure.export(); try await wait { !failure.busy && !failure.finishScheduled }; precondition(failure.success && failureCloses == 1)
        // Slow owned helper writes a partial file and diagnostic; No/Yes then
        // a fresh export. Cancellation never composes mail or reports success.
        let helper = root.appendingPathComponent("slow-git"), marker = URL(fileURLWithPath:helper.path+".started"), release = URL(fileURLWithPath:helper.path+".release"), partial = root.appendingPathComponent("partial.patch")
        let quoted = "'" + git.path.replacingOccurrences(of:"'",with:"'\\''") + "'", partialQuoted = "'" + partial.path.replacingOccurrences(of:"'",with:"'\\''") + "'"
        let script = """
        #!/bin/sh
        if [ "${4-}" = format-patch ] && [ ! -f "$0.release" ]; then
          printf 'partial bytes' > \(partialQuoted)
          printf 'partial diagnostic\\n'
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started"
          wait "$task_child"
        fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let slowRepo = GitRepository(root:root,executable:helper); prefs.set(true,forKey:"ConfirmKillProcess")
        let slow = FormatPatchWindowModel(repository:slowRepo,access:nil,preferences:prefs); slow.load(); try await wait { !slow.busy }; slow.mode = .number; slow.count = 1; slow.directory = root.appendingPathComponent("slow-output").path; slow.sendMail = true
        slow.composeMail = { _ in preconditionFailure("Cancelled mail") }; slow.export(); try await wait { FileManager.default.fileExists(atPath:marker.path) }
        let pids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; precondition(pids.count == 2)
        slow.confirmCancellation = { $0(false) }; slow.cancelExport(); precondition(slow.busy && !slow.cancelRequested)
        slow.confirmCancellation = { $0(true) }; slow.cancelExport(); try await wait { !slow.busy }; precondition(slow.cancelled && !slow.success && slow.progress && slow.output.contains("partial diagnostic")); try await wait { kill(pids[0],0) != 0 && kill(pids[1],0) != 0 }; let partialBytes = try String(contentsOf:partial); precondition(partialBytes == "partial bytes")
        slow.finish(); try Data().write(to:release); slow.sendMail = false; var retriedCloses = 0; slow.close = { retriedCloses += 1 }; slow.export(); try await wait { !slow.busy && !slow.finishScheduled }; precondition(slow.success && retriedCloses == 1)
        // Delayed confirmation keeps a successful result until answer; a late Yes
        // cannot cancel the already-finished operation or repeat acknowledgement.
        try FileManager.default.removeItem(at:marker); try FileManager.default.removeItem(at:release)
        let deferred = FormatPatchWindowModel(repository:slowRepo,access:nil,preferences:prefs); deferred.load(); try await wait { !deferred.busy }; deferred.mode = .number; deferred.directory = root.appendingPathComponent("deferred").path; deferred.sendMail = false
        var respond:((Bool)->Void)?, deferredCloses = 0; deferred.close = { deferredCloses += 1 }; deferred.confirmCancellation = { respond = $0 }; deferred.export(); try await wait { FileManager.default.fileExists(atPath:marker.path) }; deferred.cancelExport(); precondition(deferred.confirmingCancellation)
        let gatePids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; try Data().write(to:release); kill(gatePids[1],SIGTERM); try await wait { !deferred.busy }; precondition(deferred.success && deferred.progress && deferredCloses == 0); respond?(true); respond?(true); try await wait { !deferred.finishScheduled }; precondition(!deferred.cancelled && deferredCloses == 1)
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout, afterIndex = try Data(contentsOf:root.appendingPathComponent(".git/index")); precondition(head == afterHead && index == afterIndex)
        print("Format Patch: actual Since/Number/Range across captured policies, once acknowledgement, captured mail file URLs and real git am tree equality, private histories, retained failure/fresh export, owned No/Yes cancellation with partial output, delayed confirmation completion. Hidden options host; no displayed UI/email/standard preferences.")
    }
}
