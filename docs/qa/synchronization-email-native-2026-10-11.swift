import AppKit
import Darwin
import TurtleGitCore

struct SynchronizationEmailVerification {
    @MainActor static func wait(_ predicate: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<4000 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        preconditionFailure("Sync Email fixture did not settle at line \(line)")
    }
    @MainActor static func run(root: URL, preferences: UserDefaults) async throws {
        for key in ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "EMAIL"] { unsetenv(key) }
        let git = URL(fileURLWithPath: CommandLine.arguments[2]), directory = root.appendingPathComponent("qa-sync-email-雪-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = GitRepository(root: root, executable: git)
        _ = try await source.run(["clone", "--no-hardlinks", "--template=", "--", root.path, directory.path])
        let original = GitRepository(root: directory, executable: git)
        for (key, value) in [("user.name", "Sync Email QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await original.run(["config", key, value]) }
        let base = try await original.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await original.run(["update-ref", "refs/remotes/origin/main", base])
        for name in ["qa-email-first", "qa-email-second"] {
            try Data((name + "\n").utf8).write(to: directory.appendingPathComponent(name)); try await original.stage([name])
            _ = try await original.commit(message: name)
        }
        let head = try await original.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let refs = try await original.run(["show-ref"]).stdout, index = try Data(contentsOf: directory.appendingPathComponent(".git/index")), config = try Data(contentsOf: directory.appendingPathComponent(".git/config"))
        let shim = directory.appendingPathComponent(".git/email-git"), marker = directory.appendingPathComponent(".git/email-pid"), flag = directory.appendingPathComponent(".git/email-stall")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let environment = GitRuntime.environment(executable: git).sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + quote($0.value) }.joined(separator: "\n")
        let script = "#!/bin/sh\n" + environment + "\nif [ -f " + quote(flag.path) + " ]; then\nmode=$(cat " + quote(flag.path) + ")\nfor argument; do\nif [ \"$argument\" = \"$mode\" ]; then\nprintf '%s\\n' \"$$\" > " + quote(marker.path) + "\nwhile :; do sleep 1; done\nfi\ndone\nfi\nexec " + quote(git.path) + " \"$@\"\n"
        let missingTarget=directory.appendingPathComponent(".git/email-missing-target"),captured=directory.appendingPathComponent(".git/email-export-stdout")
        let delivery="if [ \"${mode-}\" = missing-output ]; then\nfor argument; do\nif [ \"$argument\" = format-patch ]; then\n"+quote(git.path)+" \"$@\" > "+quote(captured.path)+"\nstatus=$?\nif [ \"$status\" = 0 ]; then /bin/rm -f -- \"$(cat "+quote(missingTarget.path)+")\"; fi\n/bin/cat "+quote(captured.path)+"\nexit \"$status\"\nfi\ndone\nfi\n"
        let checkedScript=script.replacingOccurrences(of:"for argument; do\n",with:delivery+"for argument; do\n")
        try Data(checkedScript.utf8).write(to: shim); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        let repo = GitRepository(root: directory, executable: shim)
        var mail = EmailConfiguration(preferences: preferences); mail.delivery = .configured
        mail.server = "127.0.0.1"; mail.port = 0; mail.encryption = .none; mail.authenticate = false; mail.save(preferences)
        preferences.set(0, forKey: "AutoCloseGitProgress")
        let owner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
        let model = owner.model
        try await wait { !model.busy && model.outgoing != nil }
        model.remote = "origin"; model.remoteBranch = "main"; model.localBranch = "main"; model.reload()
        try await wait { !model.busy }; precondition(model.canEmailPatch)
        model.confirmingQuit = true; model.emailPatch(); precondition(owner.emailWorkflow == nil); model.confirmingQuit = false
        model.emailPatch(); try await wait { owner.emailWorkflow?.options != nil }
        let cancelled = owner.emailWorkflow!.options!
        precondition(cancelled.window!.sheetParent === owner.window && cancelled.window!.alphaValue == 0 && model.emailingPatches)
        precondition(cancelled.model.rows.count == 2 && !owner.windowShouldClose(owner.window!))
        precondition(SynchronizationWindowModel.activeInlineOperations==0 && !model.busy && model.inlineCompletionSucceeded)
        let missing=cancelled.model.rows[1].file,retained=cancelled.model.rows[0].file,retainedBytes=try Data(contentsOf:retained)
        try Data(missing.path.utf8).write(to:missingTarget)
        let subjects = try cancelled.model.rows.map { try SerialPatch(file: $0.file).subject }
        precondition(subjects == ["[PATCH 1/2] qa-email-first", "[PATCH 2/2] qa-email-second"])
        model.emailPatch(); model.applyPatch(); model.manageRemotes(); precondition(owner.emailWorkflow!.options === cancelled && owner.importPatchController == nil && owner.remoteSettingsController == nil)
        cancelled.model.cancel(); try await wait { owner.emailWorkflow == nil && !model.emailingPatches && owner.window!.attachedSheet == nil }
        model.emailPatch(); try await wait { owner.emailWorkflow?.options != nil }; let submitted = owner.emailWorkflow!.options!
        submitted.model.to = "receiver@example.invalid"; submitted.model.submit()
        try await wait { owner.emailWorkflow?.progress != nil }; let progress = owner.emailWorkflow!.progress!
        try await wait { !progress.model.busy }
        precondition(progress.window!.sheetParent === owner.window && submitted.window!.sheetParent == nil && progress.model.error != nil && model.hasBlockingChild)
        progress.model.close(); try await wait { owner.emailWorkflow == nil && owner.window!.attachedSheet == nil && !model.emailingPatches }
        precondition(model.inlineCommandFinished && model.inlineCompletionSucceeded && model.commandOutput.contains("format-patch") && model.incomingCommits == nil)
        let afterHead = try await original.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines), afterRefs = try await original.run(["show-ref"]).stdout
        let afterIndex = try Data(contentsOf: directory.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: directory.appendingPathComponent(".git/config"))
        precondition(head == afterHead && refs == afterRefs && index == afterIndex && config == afterConfig)
        // Real Git succeeds and reports both files; a concurrent removal of
        // one output must refuse the WHOLE composer, retaining successful Log.
        try Data("missing-output".utf8).write(to:flag)
        model.emailPatch();try await wait{!model.busy && owner.window!.attachedSheet != nil}
        precondition(owner.emailWorkflow==nil && !model.emailingPatches && model.inlineCommandFinished && model.inlineCompletionSucceeded)
        precondition(model.commandOutput.contains(FormatPatchFailure.output.localizedDescription) && SynchronizationWindowModel.activeInlineOperations==0)
        let retainedAfterFailure=try Data(contentsOf:retained);precondition(retainedAfterFailure==retainedBytes)
        let deliveryError=owner.window!.attachedSheet!;owner.window!.endSheet(deliveryError);deliveryError.close()
        try await wait{owner.window!.attachedSheet==nil};try FileManager.default.removeItem(at:flag)
        model.remote = "https://example.invalid/repo"; model.reload(); try await wait { !model.busy }; precondition(!model.canEmailPatch)
        model.remote = "origin"; model.remoteBranch = "missing"; model.reload(); try await wait { !model.busy }; precondition(!model.canEmailPatch)
        _ = try await original.run(["branch", "behind", base]); _ = try await original.run(["update-ref", "refs/remotes/origin/main", head])
        model.remoteBranch = "main"; model.reload(); try await wait { !model.busy }; precondition(!model.canEmailPatch && model.outgoing?.disposition == .upToDate)
        model.localBranch = "behind"; model.remoteBranch = "main"; model.force = false; model.reload(); try await wait { !model.busy }; precondition(!model.canEmailPatch)
        model.force = true; model.reload(); try await wait { !model.busy }; precondition(model.canEmailPatch)
        model.emailPatch(); try await wait { !model.busy && owner.window!.attachedSheet != nil }
        let empty = owner.window!.attachedSheet!; precondition(owner.emailWorkflow == nil && !model.emailingPatches)
        owner.window!.endSheet(empty); empty.close()
        _ = try await original.run(["update-ref", "refs/remotes/origin/main", base]); model.localBranch = "main"; model.reload(); try await wait { !model.busy }
        model.emailPatch(); try await wait { owner.emailWorkflow?.options != nil }
        let forcedOptions = owner.emailWorkflow!.options!, lateSubmit = forcedOptions.model.onSubmit!
        mail.port = 9; mail.save(preferences); try Data("config".utf8).write(to: flag)
        forcedOptions.model.to = "receiver@example.invalid"; forcedOptions.model.submit()
        try await wait { owner.emailWorkflow?.progress != nil && FileManager.default.fileExists(atPath: marker.path) }
        let forcedProgress = owner.emailWorkflow!.progress!, lateClose = forcedProgress.onClosed
        let pid = pid_t(try String(contentsOf: marker).trimmingCharacters(in: .newlines))!
        preferences.set(true, forKey: "ConfirmKillProcess")
        forcedProgress.model.cancel(); try await wait { forcedProgress.window!.attachedSheet != nil && forcedProgress.model.confirmingCancellation }
        let confirmation = forcedProgress.window!.attachedSheet!
        owner.close(); try await wait { kill(pid, 0) == -1 && errno == ESRCH && kill(-pid, 0) == -1 && errno == ESRCH }
        try await wait { !forcedProgress.model.busy }
        precondition(model.closed && !model.emailingPatches && owner.emailWorkflow == nil && owner.window!.attachedSheet == nil && forcedProgress.window!.sheetParent == nil && forcedOptions.window!.isVisible == false)
        precondition(!forcedProgress.model.activeOperation && confirmation.sheetParent == nil && !confirmation.isVisible)
        lateClose(); precondition(owner.emailWorkflow == nil)
        // A delayed submission after forced closure cannot create another child.
        var options = PatchMailOptions(); options.to = "receiver@example.invalid"
        lateSubmit(SendPatchRequest(files: [], options: options, messages: [], delivery: mail)); precondition(owner.emailWorkflow == nil)
        try FileManager.default.removeItem(at: flag); try FileManager.default.removeItem(at: marker)
        let exporting = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        exporting.window!.alphaValue = 0; exporting.showWindow(nil); defer { exporting.close() }
        try await wait { !exporting.model.busy && exporting.model.outgoing != nil }
        exporting.model.remote = "origin"; exporting.model.remoteBranch = "main"; exporting.model.localBranch = "main"; exporting.model.reload(); try await wait { !exporting.model.busy }
        try Data("format-patch".utf8).write(to: flag); exporting.model.emailPatch()
        try await wait { FileManager.default.fileExists(atPath: marker.path) }
        let exportPID = pid_t(try String(contentsOf: marker).trimmingCharacters(in: .newlines))!
        exporting.close(); try await wait { kill(exportPID, 0) == -1 && errno == ESRCH && kill(-exportPID, 0) == -1 && errno == ESRCH }
        precondition(exporting.model.closed && !exporting.model.busy && exporting.emailWorkflow == nil && exporting.window!.attachedSheet == nil)
        print("PASS: Sync Email Patch actual two-commit export, source gates/Force empty alert, owned options Cancel and progress/error dismissal, private captured SMTP settings without public mail, Git state preservation, duplicate/Quit guards and forced export/sender Git/group cleanup with late callback suppression")
    }
}
