import AppKit
import TurtleGitCore

@main struct ReferenceLogActionsVerification {
    @MainActor static func wait(_ busy: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while busy() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!busy(), "Native load timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "RefLog QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        for message in ["First café: α", "Second review: 🐢", "Third newest"] {
            try Data(message.utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: message)
        }
        _ = try await repo.run(["reset", "--soft", "HEAD"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let model = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD")
        model.reload(); try await wait { model.busy }; precondition(model.error == nil && model.entries.count == 4)
        let entries = model.entries, newest = entries[0], older = entries[2]
        precondition(entries[0].hash == entries[1].hash && entries[0].id != entries[1].id)
        var opened: [String] = []; model.onLog = { opened.append($0) }
        model.showLog([older.id]); precondition(opened == [older.hash])
        model.showLog([]); model.showLog([newest.id, older.id]); model.showLog(["invalid"]); precondition(opened.count == 1)
        model.activateRows([newest.id, older.id]); precondition(opened.last == newest.hash && opened.count == 2)
        model.busy = true; model.showLog([older.id]); model.activateRows([older.id]); model.busy = false; precondition(opened.count == 2)
        let suite = "TurtleGit.RefLogActions.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let log = LogWindowModel(repository: repo, access: nil, labelDefaults: preferences)
        defer { log.invalidate() }
        log.search = "no matching text"; log.useDates = true
        ReferenceLogWindowModel.configureRevisionLog(log, revision: older.hash); log.reload()
        try await wait { log.busy || log.loadingActions }
        precondition(log.error == nil && log.endRevision == older.hash && log.selected == [older.hash] && !log.showWorkingTree && !log.allBranches && log.historyPaths.isEmpty && log.search.isEmpty && !log.useDates)
        precondition(log.entries.first?.hash == older.hash && !log.entries.contains { $0.hash == newest.hash || $0.hash.isEmpty })
        let duplicateIds = Set([entries[0].id, entries[1].id])
        precondition(model.clipboardText(duplicateIds, format: .hashes) == newest.hash + "\r\n" + newest.hash)
        let ids = Set([newest.id, older.id]), fixedDates = HistoryDateSettings(useSystemLocale: false)
        precondition(model.clipboardText(ids, format: .hashes) == newest.hash + "\r\n" + older.hash)
        let messages = model.clipboardText(ids, format: .messages)!
        precondition(messages == "* reset: moving to HEAD\r\n\r\n* commit: Second review: 🐢\r\n\r\n")
        let full = model.clipboardText(ids, format: .full, dates: fixedDates)!
        precondition(full.hasPrefix("Revision: " + newest.hash + "\r\nDate: ") && full.contains("\r\nMessage: reset: moving to HEAD\r\nRevision: " + older.hash) && full.hasSuffix("\r\nMessage: commit: Second review: 🐢\r\n"))
        let dateLines = full.components(separatedBy: "\r\n").filter { $0.hasPrefix("Date: ") }
        precondition(dateLines.count == 2 && dateLines.allSatisfy { $0.range(of: #"^Date: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil })
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        model.copy(ids, format: .messages, pasteboard: board); precondition(board.string(forType: .string) == messages)
        model.copy([], format: .full, pasteboard: board); precondition(board.string(forType: .string) == messages)
        model.busy = true; model.copy(ids, format: .hashes, pasteboard: board); model.busy = false; precondition(board.string(forType: .string) == messages)
        precondition(model.clipboardText([], format: .hashes) == nil && model.clipboardText(["invalid"], format: .full) == nil)
        let choosing = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD", selecting: true)
        choosing.reload(); try await wait { choosing.busy }; var accepted: [String] = [], navigated = 0
        choosing.onChoose = { accepted.append($0.hash) }; choosing.onLog = { _ in navigated += 1 }
        choosing.activateRows([older.id]); precondition(accepted == [older.hash] && navigated == 0)
        choosing.activateRows([newest.id, older.id]); precondition(accepted.count == 1)
        let endHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let endIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), endConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), endFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(head == endHead && index == endIndex && config == endConfig && file == endFile)
        print("RefLog actions: guarded single Log and first-selected activation, real selected immutable revision-scoped Log without working tree/newer commits, chooser acceptance retained, Full data/SHA-1/Messages ordered CRLF Unicode payloads including duplicate hashes, shared fixed date format, private pasteboard and empty/busy preservation, byte-exact HEAD/index/config/worktree passed; no displayed UI or general clipboard mutation")
    }
}
