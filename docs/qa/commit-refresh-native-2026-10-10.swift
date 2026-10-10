import AppKit
import SwiftUI
import TurtleGitCore
import Darwin

@main struct CommitRefreshVerification {
    struct Failure: Error, CustomStringConvertible { var description: String }
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws {
        if !value() { throw Failure(description: "Requirement failed at line \(line)") }
    }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Timed out waiting for Commit refresh")
    }
    @MainActor static func settle() async throws { for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) } }
    @MainActor static func main() async {
        do { try await verify() } catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.CommitRefresh.QA." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), engine = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: engine)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Commit Tests"])
        _ = try await repo.run(["config", "user.email", "commit@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try await repo.stage(["tracked.txt"]); _ = try await repo.commit(message: "base")
        try Data("staged\n".utf8).write(to: root.appendingPathComponent("tracked.txt")); try await repo.stage(["tracked.txt"])
        try Data("working\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        _ = try await repo.status()
        let beforeHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let beforeIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let beforeFile = try Data(contentsOf: root.appendingPathComponent("tracked.txt"))
        // A read that deliberately ignores cancellation must still be fenced.
        for fail in [false, true] {
            let controller = CommitWindowController(repository: repo, access: nil, defaults: prefs)
            let model = controller.model
            var reply: CheckedContinuation<[StatusEntry], Error>?, token: OperationCancellation?
            model.queryCommitStatus = { _, request in
                token = request
                return try await withCheckedThrowingContinuation { reply = $0 }
            }
            model.message = "Preserve draft"
            model.reload(); try await wait { reply != nil }
            let branch = model.branch, entries = model.entries.map(\.path)
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
            try require(token?.isCancelled == true && !model.busy && !model.canCommit && !model.canCancel)
            if fail { reply!.resume(throwing: Failure(description: "Late read error")) }
            else { reply!.resume(returning: StatusEntry.parse(Data("A  late.txt\0".utf8))) }
            reply = nil
            try await settle()
            try require(model.entries.map(\.path) == entries && model.branch == branch && model.message == "Preserve draft" && model.error == nil && !model.busy)
            model.reload(); try await settle(); try require(model.entries.map(\.path) == entries)
            controller.window?.close()
        }
        // Cancel disables immediately while confirmation is pending. No keeps
        // the original read running and its later result remains authoritative.
        do {
            let controller = CommitWindowController(repository: repo, access: nil, defaults: prefs), model = controller.model
            var reply: CheckedContinuation<[StatusEntry], Error>?, token: OperationCancellation?, approve: ((Bool) -> Void)?
            model.queryCommitStatus = { _, request in token = request; return try await withCheckedThrowingContinuation { reply = $0 } }
            model.message = "Retain pending draft"; model.messageOnly = true
            var confirmations = 0, completed: Bool?, notifications = 0
            model.confirmCancel = { confirmations += 1; approve = $0 }
            model.reload(); try await wait { reply != nil }
            let observer = model.objectWillChange.sink { notifications += 1 }
            model.cancel(completion: { completed = $0 })
            try require(model.busy && !model.canCancel && notifications > 0 && confirmations == 1 && token?.isCancelled == false)
            reply!.resume(returning: StatusEntry.parse(Data("MM tracked.txt\0".utf8))); reply = nil
            try await wait { !model.busy }
            try require(model.inputsBlocked && !model.canCancel && !model.canCommit && token?.isCancelled == false && completed == nil)
            model.reload(); try await settle(); try require(reply == nil)
            approve?(false)
            try require(completed == false && model.canCancel && model.canCommit && !model.inputsBlocked && token?.isCancelled == false)
            try require(model.entries.contains { $0.path == "tracked.txt" } && model.message == "Retain pending draft" && model.error == nil)
            model.queryCommitStatus = { try await repo.commitDialogStatus(amendToParent: $0, cancellation: $1) }
            model.reload(); try await wait { !model.busy }
            try require(model.branch == "main" && model.error == nil)
            observer.cancel(); controller.window?.close()
        }
        // Exercise the default production query against an actually running child.
        let wrapper = root.appendingPathComponent("blocked-refresh-git"), marker = root.appendingPathComponent("refresh-child.pid"), flag = root.appendingPathComponent("block-refresh"), metadataFlag = root.appendingPathComponent("block-metadata")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let program = "#!/bin/sh\ncase \"$*\" in *'status --porcelain=v1'*) if test -e " + quote(flag.path) + "; then printf '%s\\n' \"$$\" > " + quote(marker.path) + "; exec /bin/sleep 120; fi ;; *'config user.name'*) if test -e " + quote(metadataFlag.path) + "; then printf '%s\\n' \"$$\" > " + quote(marker.path) + "; exec /bin/sleep 120; fi ;; esac\nexec " + quote(engine.path) + " \"$@\"\n"
        try Data(program.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let blocked = GitRepository(root: root, executable: wrapper)
        for closeDirectly in [false, true] {
            try Data().write(to: flag); try? FileManager.default.removeItem(at: marker)
            let controller = CommitWindowController(repository: blocked, access: nil, defaults: prefs), model = controller.model
            model.message = "Preserve real draft"
            var confirmations = 0, closes = 0, completion: Bool?, duplicate: Bool?, approve: ((Bool) -> Void)?
            model.confirmCancel = { confirmations += 1; approve = $0 }
            controller.onClosed = { closes += 1 }
            model.reload(); try await wait { FileManager.default.fileExists(atPath: marker.path) }
            let child = Int32(try String(contentsOf: marker).trimmingCharacters(in: .newlines))!
            defer { if kill(child, 0) == 0 { kill(child, SIGTERM) } }
            try require(kill(child, 0) == 0 && model.busy && model.canCancel)
            if closeDirectly { controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window)) }
            else {
                model.cancel(completion: { completion = $0 }); model.cancel(completion: { duplicate = $0 })
                try require(duplicate == false && !model.canCancel && confirmations == 1 && kill(child, 0) == 0)
                let declined = approve
                approve?(false)
                try require(completion == false && model.canCancel && model.busy && kill(child, 0) == 0)
                completion = nil; approve = nil
                model.cancel(completion: { completion = $0 })
                try require(confirmations == 2 && approve != nil && kill(child, 0) == 0)
                declined?(true); try require(kill(child, 0) == 0 && completion == nil)
                approve?(true)
            }
            try await wait { kill(child, 0) == -1 && errno == ESRCH && !model.busy }
            try await settle()
            try require(model.error == nil && model.message == "Preserve real draft")
            if closeDirectly { try require(confirmations == 0 && closes == 1 && !model.canCommit) }
            else {
                try require(confirmations == 2 && completion == true && closes == 1 && !model.canCancel)
                // A repeated reply after close cannot invoke another close.
                approve?(true); try require(closes == 1 && completion == true)
            }
            controller.window?.close()
        }
        // The repository actor can queue refresh behind this window's metadata
        // child. Approval cancels that owner too before awaiting the refresh.
        try? FileManager.default.removeItem(at: flag); try? FileManager.default.removeItem(at: marker)
        do {
            let controller = CommitWindowController(repository: blocked, access: nil, defaults: prefs), model = controller.model
            model.message = "Queued refresh draft"
            model.reload(); try await wait { !model.busy }
            try Data().write(to: metadataFlag)
            model.authorChanged(); try await wait { FileManager.default.fileExists(atPath: marker.path) }
            let child = Int32(try String(contentsOf: marker).trimmingCharacters(in: .newlines))!
            defer { if kill(child, 0) == 0 { kill(child, SIGTERM) } }
            try require(model.loadingAuthorIdentity && kill(child, 0) == 0)
            model.reload(); try await settle(); try require(model.busy && model.loadingAuthorIdentity && kill(child, 0) == 0)
            var completed: Bool?, closes = 0, confirmations = 0
            controller.onClosed = { closes += 1 }
            model.confirmCancel = { confirmations += 1; $0(true) }
            model.cancel(completion: { completed = $0 })
            try await wait { kill(child, 0) == -1 && errno == ESRCH && completed != nil }
            try require(completed == true && confirmations == 1 && closes == 1 && !model.busy && !model.loadingAuthorIdentity && model.error == nil && model.message == "Queued refresh draft" && !model.canCommit)
            controller.window?.close()
        }
        for file in [wrapper,marker,flag,metadataFlag] { try? FileManager.default.removeItem(at: file) }
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterFile = try Data(contentsOf: root.appendingPathComponent("tracked.txt"))
        try require(afterHead == beforeHead && afterIndex == beforeIndex && afterFile == beforeFile)
        print("PASS: Commit initial refresh ignores late values/errors after controller close; Cancel confirms before stopping a live status child; No preserves the running read, Yes reaps and closes once; immediate publication, completed-refresh/pending-answer gates and stale-answer/duplicate-cancel guards; declined cancel permits reload; approval reaps own metadata child ahead of queued refresh; late confirmation cannot close twice; HEAD/index/working bytes preserved. " + engine.path)
    }
}
