// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct ExportStreamingReceiver {
    @MainActor static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ExportStreamingQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(condition(), "Timed out waiting for Export")
    }
    @MainActor static func main() async {
        do { try await check() }
        catch { FileHandle.standardError.write(Data(("Export streaming QA failed: " + error.localizedDescription + "\n").utf8)); exit(1) }
    }
    @MainActor static func check() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.ExportStreaming.QA." + UUID().uuidString
        guard let prefs = UserDefaults(suiteName: suite) else { throw NSError(domain: "QA", code: 1) }
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        prefs.set(0, forKey: "AutoCloseGitProgress"); prefs.set(false, forKey: "ShowGitexeTimings")
        let repository = GitRepository(root: root, executable: git)
        _ = try await repository.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Export QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repository.run(["config", key, value]) }
        try Data("archive bytes\n".utf8).write(to: root.appendingPathComponent("雪.txt"))
        try await repository.stage(["雪.txt"]); _ = try await repository.commit(message: "base")
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        var models: [ExportProgressWindowModel] = [], windows: [ExportProgressWindowController] = []
        do {
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
            let failed = ExportProgressWindowModel(repository: repository, access: nil, outputAccess: nil, revision: "missing", directory: "", destination: root.appendingPathComponent("failure.zip"), preferences: prefs)
            models.append(failed); await failed.run()
            try require(!failed.success && failed.currentWork == "Operation failed" && failed.completionRange != nil, "Failure retains diagnostic and footer")
            let helper = root.appendingPathComponent("slow-git"), marker = root.appendingPathComponent("slow-git.started")
            let quote = "'" + git.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let failureHelper = root.appendingPathComponent("failing-git")
            let failureScript = """
            #!/bin/sh
            if [ "${4-}" = archive ]; then
              printf 'fatal: archive fixture failure\\n' >&2
              exit 17
            fi
            exec \(quote) "$@"
            """
            try Data(failureScript.utf8).write(to: failureHelper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failureHelper.path)
            let commandFailure = ExportProgressWindowModel(repository: GitRepository(root: root, executable: failureHelper), access: nil, outputAccess: nil, revision: "HEAD", directory: "", destination: root.appendingPathComponent("command-failure.zip"), preferences: prefs)
            models.append(commandFailure); await commandFailure.run()
            try require(!commandFailure.success && commandFailure.currentWork == "git did not exit cleanly (exit code 17)" && commandFailure.output.components(separatedBy: "fatal: archive fixture failure").count == 2, "Streamed failure appears once with actual exit code")
            let script = """
            #!/bin/sh
            if [ "${4-}" = archive ]; then
              for task_arg in "$@"; do
                case "$task_arg" in --output=*) printf 'partial zip' > "${task_arg#--output=}";; esac
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
            for pendingQuestion in [false, true] {
                prefs.set(pendingQuestion, forKey: "ConfirmKillProcess")
                let target = root.appendingPathComponent("preserved.zip"), original = Data("existing ZIP".utf8)
                try original.write(to: target)
                let owner = ExportWindowModel(repository: slowRepository, access: nil, preferences: prefs)
                owner.destination = target.path; owner.confirmOverwrite = { _ in true }
                var result: ExportProgressWindowModel?, controller: ExportProgressWindowController?
                var answer: ((Bool) -> Void)?
                owner.onProgress = { value in
                    result = value; models.append(value)
                    let child = ExportProgressWindowController(model: value); controller = child; windows.append(child)
                    child.onClosed = { owner.finish(value) }
                    value.confirmCancellation = { answer = $0 }
                }
                owner.export()
                try await wait { result?.output.contains("waiting") == true }
                guard let result, let controller else { throw NSError(domain: "QA", code: 1) }
                try require(result.busy && result.currentWork == "Exporting" && result.percentage == 42, "Output appears before archive exits")
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
                try require(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".TurtleGitArchive-") }, "No partial ZIP remains")
                try FileManager.default.removeItem(at: marker)
            }
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
            let unstarted = ExportProgressWindowModel(repository: repository, access: nil, outputAccess: nil, revision: "HEAD", directory: "", destination: root.appendingPathComponent("never.zip"), preferences: prefs)
            models.append(unstarted); var cleaned = 0; unstarted.onAbandonedCompletion = { cleaned += 1 }; unstarted.invalidate(); await unstarted.run(); await unstarted.run()
            try require(!unstarted.busy && unstarted.cancelled && cleaned == 1 && !FileManager.default.fileExists(atPath: unstarted.destination.path), "Pre-start abandonment resolves once without spawning Git")
            let after = try await repository.run(["rev-parse", "HEAD"]).stdout
            try require(after == head && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index, "HEAD and index unchanged")
        } catch {
            models.forEach { $0.invalidate() }; windows.forEach { $0.window?.close() }
            let end = Date().addingTimeInterval(20)
            while models.contains(where: \.busy) && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
            throw error
        }
        windows.forEach { $0.window?.close() }
        print("Export real ZIP/live output, styled footer/copy, failure, forced-close cancellation/child reaping, pending-confirmation fencing and pre-start abandonment passed; hidden native receivers only.")
    }
}
