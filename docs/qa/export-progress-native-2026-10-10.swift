// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func ExportStreamingReceiverHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(NSPoint(x:-20000,y:-20000));ExportStreamingReceiverHiddenOrder(place,relativeTo:number)
    }
}

@main struct ExportStreamingReceiver {
    @MainActor static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ExportStreamingQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func wait(line:Int = #line,_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(condition(), "Timed out waiting for Export phase=\(phase) waitLine=\(line)")
    }
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
    @MainActor static func main() async {
        do { try await check() }
        catch { FileHandle.standardError.write(Data(("Export streaming QA failed: " + error.localizedDescription + "\n").utf8)); exit(1) }
    }
    @MainActor static func check() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let originalOrder=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hiddenOrder=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.ExportStreamingReceiverHiddenOrder(_:relativeTo:)))!
        method_exchangeImplementations(originalOrder,hiddenOrder);defer{method_exchangeImplementations(originalOrder,hiddenOrder)}
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.ExportStreaming.QA." + UUID().uuidString
        guard let prefs = UserDefaults(suiteName: suite) else { throw NSError(domain: "QA", code: 1) }
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        prefs.set(0, forKey: "AutoCloseGitProgress"); prefs.set(false, forKey: "ShowGitexeTimings")
        DialogGeometry.install(preferences:prefs)
        let repository = GitRepository(root: root, executable: git)
        _ = try await repository.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Export QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repository.run(["config", key, value]) }
        try Data("archive bytes\n".utf8).write(to: root.appendingPathComponent("雪.txt"))
        try await repository.stage(["雪.txt"]); _ = try await repository.commit(message: "base")
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        var models: [ExportProgressWindowModel] = [], windows: [ExportProgressWindowController] = []
        do {
            mark("real archive stream and styled footer")
            let completed = ExportProgressWindowModel(repository: repository, access: nil, outputAccess: nil, revision: "HEAD", directory: "", destination: root.appendingPathComponent("success.zip"), preferences: prefs)
            models.append(completed); await completed.run()
            try require(completed.success && completed.output.contains("雪.txt") && completed.currentWork == "Success" && completed.percentage == 100, "Real verbose archive output and completion")
            guard let footer = completed.completionRange else { throw NSError(domain: "QA", code: 1) }
            try require((completed.output as NSString).substring(with: footer) == "\nSuccess\n", "Captured timing preference and footer")
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            let scroll = SubmoduleProgressTextView.scrollView(preferences: prefs, clipboard: board)
            guard let text = scroll.documentView as? SubmoduleProgressTextView else { throw NSError(domain: "QA", code: 1) }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                text.appearance = NSAppearance(named: appearance)
                text.present(completed.output, completed: true, completionRange: footer, success: true)
                guard let color = text.textStorage?.attribute(.foregroundColor, at: footer.location, effectiveRange: nil) as? NSColor else { throw NSError(domain: "QA", code: 1) }
                try require(color != NSColor.textColor, "Completion uses a source success color instead of ordinary text in both appearances")
            }
            text.copyAllInformation(nil); try require(board.string(forType: .string) == completed.output, "Private Copy all preserves verbose output")
            mark("revision validation failure")
            let failed = ExportProgressWindowModel(repository: repository, access: nil, outputAccess: nil, revision: "missing", directory: "", destination: root.appendingPathComponent("failure.zip"), preferences: prefs)
            models.append(failed); await failed.run()
            try require(!failed.success && failed.currentWork == "Operation failed" && failed.completionRange != nil, "Failure retains diagnostic and footer")
            mark("changed destination refusal and reviewed options recovery")
            let raced=root.appendingPathComponent("raced.zip"),reviewed=Data("reviewed archive bytes".utf8)
            try reviewed.write(to:raced)
            let raceOwner=ExportWindowModel(repository:repository,access:nil,preferences:prefs)
            raceOwner.destination=raced.path;raceOwner.confirmOverwrite={_ in true}
            var raceResult:ExportProgressWindowModel?,attempt=0
            raceOwner.onProgress={value in
                raceResult=value;value.outputClipboard=board;models.append(value);attempt+=1
                value.onAbandonedCompletion={}
                let child=ExportProgressWindowController(model:value);windows.append(child)
                child.onClosed={raceOwner.finish(value)}
                if attempt==1 {value.beforeFinalization={try reviewed.write(to:raced,options:.atomic)}}
            }
            raceOwner.export();try await wait{raceResult?.busy==false}
            guard let rejected=raceResult else{throw NSError(domain:"ExportQA",code:1)}
            try require(rejected.commandFinished && rejected.commandSucceeded && !rejected.success && !rejected.cancelled && !rejected.canExplore && rejected.currentWork=="Operation failed","A successful Git process concealed changed-destination finalization failure")
            try require(rejected.output.contains(FileComparisonEditFailure.changed.localizedDescription) && (try Data(contentsOf:raced))==reviewed,"Byte-identical replacement destination lost its identity or diagnostic")
            rejected.close();try await wait{!raceOwner.busy && !raceOwner.hasPendingWork}
            try require(raceOwner.progress==nil && raceOwner.error==nil,"Changed-target failure did not restore reviewed options")
            raceResult=nil;raceOwner.export();try await wait{raceResult?.busy==false}
            try require(raceResult?.success==true && raceResult?.canExplore==true,"Fresh reviewed Export could not recover after output changed")
            raceResult?.close();try await wait{!raceOwner.busy && !raceOwner.hasPendingWork}
            let helper = root.appendingPathComponent("slow-git"), marker = root.appendingPathComponent("slow-git.started")
            let quote = "'" + git.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let failureHelper = root.appendingPathComponent("failing-git")
            let failureScript = """
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
            if task_archive "$@"; then
              exec 3>"$0.lease"
              printf '%s\\000' "$@" > "$0.arguments"
              printf 'fatal: archive fixture failure\\n' >&2
              exit 17
            fi
            exec \(quote) "$@"
            """
            try Data(failureScript.utf8).write(to: failureHelper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failureHelper.path)
            mark("actual command failure")
            let commandFailure = ExportProgressWindowModel(repository: GitRepository(root: root, executable: failureHelper), access: nil, outputAccess: nil, revision: "HEAD", directory: "", destination: root.appendingPathComponent("command-failure.zip"), preferences: prefs)
            models.append(commandFailure); await commandFailure.run()
            try archiveReceipt(failureHelper,root:repository.root,head:head)
            try require(!commandFailure.success && commandFailure.currentWork == "git did not exit cleanly (exit code 17)" && commandFailure.output.components(separatedBy: "fatal: archive fixture failure").count == 2, "Streamed failure appears once with actual exit code")
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
            if task_archive "$@"; then
              exec 3>"$0.lease"
              printf '%s\\000' "$@" > "$0.arguments"
              for task_arg in "$@"; do
                case "$task_arg" in --output=*) printf 'partial zip' > "${task_arg#--output=}"; printf '%s\\n' "${task_arg#--output=}" > "$0.archive-output";; esac
              done
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.started"
              printf 'warning: waiting\\nExporting: 42%%\\n'
              wait "$task_child"
            fi
            exec \(quote) "$@"
            """
            try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let slowRepository = GitRepository(root: root, executable: helper)
            mark("forced-close stream and confirmation ownership")
            for pendingQuestion in [false, true] {
                prefs.set(pendingQuestion, forKey: "ConfirmKillProcess")
                let target = root.appendingPathComponent("preserved.zip"), original = Data("existing ZIP".utf8)
                try original.write(to: target)
                let owner = ExportWindowModel(repository: slowRepository, access: nil, preferences: prefs)
                owner.destination = target.path; owner.confirmOverwrite = { _ in true }
                var result: ExportProgressWindowModel?, controller: ExportProgressWindowController?
                var answer: ((Bool) -> Void)?
                owner.onProgress = { value in
                    result = value; value.outputClipboard=board; models.append(value)
                    let child = ExportProgressWindowController(model: value); controller = child; windows.append(child)
                    child.onClosed = { owner.finish(value) }
                    value.confirmCancellation = { answer = $0 }
                }
                owner.export()
                try await wait { result?.output.contains("waiting") == true }
                guard let result, let controller else { throw NSError(domain: "QA", code: 1) }
                try require(result.busy && result.currentWork == "Exporting" && result.percentage == 42, "Output appears before archive exits")
                try archiveReceipt(helper,root:repository.root,head:head)
                let pids = try String(contentsOf: marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
                try require(pids.count == 2, "Wrapper and child PID registry")
                if pendingQuestion { result.cancel(); try require(result.confirmingCancellation && answer != nil, "Pending confirmation") }
                controller.window?.close()
                let frozen = result.output
                try await wait { !result.busy && !owner.busy }
                answer?(true); answer?(false)
                try require(owner.progress == nil && result.cancelled && !result.success && result.output == frozen && !result.confirmingCancellation, "Forced close reaps before unlocking, fences late output and confirmation")
                try await wait { pids.allSatisfy { kill($0, 0) != 0 } }
                try require(try Data(contentsOf: target) == original, "Forced close preserves prior ZIP")
                let temporary=URL(fileURLWithPath:try String(contentsOf:URL(fileURLWithPath:helper.path+".archive-output")).trimmingCharacters(in:.newlines))
                try require(temporary.lastPathComponent==target.lastPathComponent && !FileManager.default.fileExists(atPath:temporary.path) && !FileManager.default.fileExists(atPath:temporary.deletingLastPathComponent().path),"No actual partial archive/staging workspace remains")
                try FileManager.default.removeItem(at: marker)
            }
            mark("retired overwrite confirmation")
            let pendingOwner = ExportWindowModel(repository: repository, access: nil, preferences: prefs)
            let pendingDestination = root.appendingPathComponent("pending.zip"), pendingBytes = Data("preserve before start".utf8)
            try pendingBytes.write(to: pendingDestination); pendingOwner.destination = pendingDestination.path
            var overwriteAnswer: CheckedContinuation<Bool, Never>?, presentedAfterClose = false
            pendingOwner.confirmOverwrite = { _ in await withCheckedContinuation { overwriteAnswer = $0 } }
            pendingOwner.onProgress = { _ in presentedAfterClose = true }
            pendingOwner.export(); try await wait { overwriteAnswer != nil }
            pendingOwner.invalidate(); overwriteAnswer?.resume(returning: true); overwriteAnswer = nil
            try await wait { !pendingOwner.busy }; pendingOwner.export()
            try require(!pendingOwner.busy && pendingOwner.progress == nil && !presentedAfterClose && (try Data(contentsOf: pendingDestination)) == pendingBytes, "Closed owner fences late overwrite acceptance and repeat export")
            mark("pre-start abandonment")
            let unstarted = ExportProgressWindowModel(repository: repository, access: nil, outputAccess: nil, revision: "HEAD", directory: "", destination: root.appendingPathComponent("never.zip"), preferences: prefs)
            models.append(unstarted); var cleaned = 0; unstarted.onAbandonedCompletion = { cleaned += 1 }; unstarted.invalidate(); await unstarted.run(); await unstarted.run()
            try require(!unstarted.busy && unstarted.cancelled && cleaned == 1 && !FileManager.default.fileExists(atPath: unstarted.destination.path), "Pre-start abandonment resolves once without spawning Git")
            let after = try await repository.run(["rev-parse", "HEAD"]).stdout
            try require(after == head && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index, "HEAD and index unchanged")
        } catch {
            models.forEach { $0.invalidate() }; windows.forEach { $0.window?.close() }
            let end = Date().addingTimeInterval(20)
            while models.contains(where:{$0.hasPendingWork}) && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
            throw error
        }
        windows.forEach { $0.window?.close() }
        try await wait {ExportWindowModel.activeOperations==0 && ExportProgressWindowModel.activeOperations==0 && ExportProgressWindowController.activeReleases==0 && windows.allSatisfy{!$0.hasPendingWork}}
        try require(NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned Export windows did not close invisibly")
        print("Export real ZIP/live output, styled footer/copy, failure, forced-close cancellation/child reaping, pending-confirmation fencing and pre-start abandonment passed; hidden native receivers only.")
    }
}
