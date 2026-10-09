// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@main struct FormatPatchStreamingReceiver {
    @MainActor static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "FormatPatchStreamingQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(condition(), "Timed out waiting for Format Patch")
    }
    @MainActor static func main() async {
        do { try await check() }
        catch { FileHandle.standardError.write(Data(("Format Patch streaming QA failed: " + error.localizedDescription + "\n").utf8)); exit(1) }
    }
    @MainActor static func check() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.FormatPatchStreaming.QA." + UUID().uuidString
        guard let prefs = UserDefaults(suiteName: suite) else { throw NSError(domain: "QA", code: 1) }
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        prefs.set(0, forKey: "AutoCloseGitProgress"); prefs.set(false, forKey: "ShowGitexeTimings")
        let repository = GitRepository(root: root, executable: git)
        _ = try await repository.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Patch QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repository.run(["config", key, value]) }
        for value in ["base", "one", "two"] {
            try Data((value + "\n").utf8).write(to: root.appendingPathComponent("file"))
            try await repository.stage(["file"]); _ = try await repository.commit(message: value)
        }
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        var models: [FormatPatchWindowModel] = [], ownedPIDs: [Int32] = []
        func model(_ repo: GitRepository, _ name: String) async throws -> FormatPatchWindowModel {
            let value = FormatPatchWindowModel(repository: repo, access: nil, preferences: prefs); models.append(value)
            value.load(); try await wait { !value.busy }; value.mode = .number; value.count = 2; value.sendMail = false; value.directory = root.appendingPathComponent(name).path
            return value
        }
        let quote = "'" + git.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        do {
            let real = try await model(repository, "real 雪\npatches")
            var completions = 0; real.onOutputChanged = { _ in completions += 1 }
            real.export(); try await wait { !real.busy }
            try require(real.success && real.progress && real.output.contains("0001-one.patch") && real.output.contains("0002-two.patch") && completions == 1, "Real patches and one completion callback")
            guard let footer = real.completionRange else { throw NSError(domain: "QA", code: 1) }
            try require(real.currentWork == "Success" && real.percentage == 100 && (real.output as NSString).substring(with: footer) == "\nSuccess\n", "Source footer and timing preference")
            let host = NSHostingView(rootView: FormatPatchProgressDialog(model: real)); host.frame = NSRect(x: 0, y: 0, width: 760, height: 430); host.layoutSubtreeIfNeeded()
            try require(host.fittingSize.width >= 650, "Native progress content hosts at source-style size")
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            guard let text = SubmoduleProgressTextView.scrollView(preferences: prefs, clipboard: board).documentView as? SubmoduleProgressTextView else { throw NSError(domain: "QA", code: 1) }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                text.appearance = NSAppearance(named: appearance); text.present(real.output, completed: true, completionRange: footer, success: true)
                guard let color = text.textStorage?.attribute(.foregroundColor, at: footer.location, effectiveRange: nil) as? NSColor else { throw NSError(domain: "QA", code: 1) }
                try require(color != NSColor.textColor, "Source success color under both appearances")
            }
            text.copyAllInformation(nil); try require(board.string(forType: .string) == real.output, "Copy all retains original output")
            real.invalidate()
            let failing = root.appendingPathComponent("failing-git")
            let failureScript = """
            #!/bin/sh
            if [ "${4-}" = format-patch ]; then
              printf 'fatal: patch fixture failure\\n' >&2
              exit 17
            fi
            exec \(quote) "$@"
            """
            try Data(failureScript.utf8).write(to: failing); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failing.path)
            let failure = try await model(GitRepository(root: root, executable: failing), "failure")
            failure.export(); try await wait { !failure.busy }
            try require(!failure.success && failure.progress && failure.currentWork == "git did not exit cleanly (exit code 17)" && failure.output.components(separatedBy: "fatal: patch fixture failure").count == 2, "Streamed failure once with actual exit code")
            failure.finish(); try require(!failure.progress, "Failed acknowledgement returns options")
            let helper = root.appendingPathComponent("slow-git"), marker = root.appendingPathComponent("slow-git.started"), release = root.appendingPathComponent("slow-git.release"), flood = root.appendingPathComponent("slow-git.flood")
            let script = """
            #!/bin/sh
            if [ "${4-}" = format-patch ] && [ ! -f "$0.release" ]; then
              task_previous=''; task_output=''
              for task_arg in "$@"; do
                if [ "$task_previous" = -o ]; then task_output="$task_arg"; fi
                task_previous="$task_arg"
              done
              mkdir -p "$task_output"
              printf 'partial patch bytes' > "$task_output/partial.patch"
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.started"
              printf 'warning: waiting\\nCreating patches: 42%%\\n'
              if [ -f "$0.flood" ]; then
                task_line=0
                while [ "$task_line" -lt 2048 ]; do printf 'warning: bounded output fixture 雪\\n' >&2; task_line=$((task_line+1)); done
              fi
              wait "$task_child"
            fi
            exec \(quote) "$@"
            """
            try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let slowRepository = GitRepository(root: root, executable: helper)
            for question in [false, true] {
                prefs.set(question, forKey: "ConfirmKillProcess")
                let abandoned = try await model(slowRepository, "abandoned-\(question)")
                abandoned.sendMail = true
                var callbacks = 0, answer: ((Bool) -> Void)?
                abandoned.onOutputChanged = { _ in callbacks += 1 }; abandoned.close = { callbacks += 1 }; abandoned.composeMail = { _ in callbacks += 1 }; abandoned.confirmCancellation = { answer = $0 }
                abandoned.export(); try await wait { abandoned.output.contains("waiting") }
                try require(abandoned.busy && abandoned.currentWork == "Creating patches" && abandoned.percentage == 42 && abandoned.canCancel, "Live progress before Git exits")
                let pids = try String(contentsOf: marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }; ownedPIDs += pids
                try require(pids.count == 2, "Owned leader/child registry")
                if question { abandoned.cancelExport(); try require(abandoned.confirmingCancellation && !abandoned.canCancel, "Pending confirmation fences cancellation") }
                abandoned.invalidate(); let frozen = abandoned.output
                try await wait { !abandoned.busy }; answer?(true); answer?(false)
                try require(abandoned.cancelled && !abandoned.success && !abandoned.progress && !abandoned.confirmingCancellation && abandoned.output == frozen && callbacks == 0, "Abandoned owner suppresses late output, refresh, mail and close")
                try await wait { pids.allSatisfy { kill($0, 0) != 0 } }
                try require(try String(contentsOf: URL(fileURLWithPath: abandoned.directory).appendingPathComponent("partial.patch")) == "partial patch bytes", "Source retains partial patch on cancellation")
                try FileManager.default.removeItem(at: marker)
            }
            prefs.set(2, forKey: "AutoCloseGitProgress"); prefs.set(16, forKey: "GitOutputLimitinKiB")
            try Data().write(to: flood)
            let bounded = try await model(slowRepository, "bounded\n雪")
            bounded.sendMail = true
            var attachments: [URL] = [], mailCalls = 0, boundedCallbacks = 0
            bounded.composeMail = { attachments = $0; mailCalls += 1 }; bounded.onOutputChanged = { _ in boundedCallbacks += 1 }
            bounded.export(); bounded.sendMail = false; prefs.set(64, forKey: "GitOutputLimitinKiB")
            try await wait { bounded.output.contains("Output truncated") }
            let pids = try String(contentsOf: marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }; ownedPIDs += pids
            try require(pids.count == 2 && bounded.busy && bounded.output.utf8.count < 17 * 1024 && !bounded.output.contains("�"), "Captured UTF-8-safe visible output limit")
            try Data().write(to: release); kill(pids[1], SIGTERM)
            try await wait { !bounded.busy && !bounded.finishScheduled }
            try require(bounded.success && mailCalls == 1 && boundedCallbacks == 1 && attachments.count == 2 && attachments.allSatisfy { FileManager.default.fileExists(atPath: $0.path) && $0.deletingLastPathComponent().path == URL(fileURLWithPath: bounded.directory).resolvingSymlinksInPath().path }, "Full stdout retains both captured attachments despite log truncation")
            try await wait { pids.allSatisfy { kill($0, 0) != 0 } }
            let early = try await model(repository, "never")
            var earlyCalls = 0; early.onOutputChanged = { _ in earlyCalls += 1 }; early.export(); early.invalidate(); try await wait { !early.busy }; early.export()
            try require(early.cancelled && earlyCalls == 0 && !FileManager.default.fileExists(atPath: early.directory), "Pre-start invalidation prevents Git/output directory")
            let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
            try require(head == afterHead && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index, "HEAD/index unchanged")
        } catch {
            models.forEach { $0.invalidate() }
            let end = Date().addingTimeInterval(20)
            while models.contains(where: \.busy) && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
            throw error
        }
        try await wait { ownedPIDs.allSatisfy { kill($0, 0) != 0 } }
        models.forEach { $0.invalidate() }
        print("Format Patch live output/current work, source-colored completion/copy, exit failure once, abandoned owner/confirmation fencing and child cleanup, bounded UTF-8 output with full captured attachments, pre-start cancellation and unchanged HEAD/index passed; no displayed window or mail service.")
    }
}
