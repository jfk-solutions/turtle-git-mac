import AppKit
import TurtleGitCore

@main struct RemoteManagementOwnedVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    @MainActor static var windows: [NSWindowController] = []
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Remote management timeout at \(line)")
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await verify(); windows.forEach { $0.close() }; windows = [] }
        catch { windows.forEach { $0.close() }; windows = []; fputs("Remote ownership failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Remote Owned QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["tag", "keep"])
        let bare = root.appendingPathComponent("remote.git"); _ = try await repo.run(["clone", "--bare", root.path, bare.path]); _ = try await repo.run(["remote", "add", "origin", bare.path])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.RemoteOwned." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let delegate = TurtleGitApplicationDelegate()
        func quitBlocked() -> Bool { delegate.applicationShouldTerminate(NSApp) == .terminateCancel }

        // One operation owns deletion, each error acknowledgement and the fresh
        // remote reload. No refresh starts behind an unanswered deletion error.
        let model = RemoteTagWindowModel(repository: repo, access: nil, remote: "origin", preferences: prefs)
        model.load(); try await wait { !model.busy && !model.tags.isEmpty }; model.select(["keep"])
        var events: [String] = [], acknowledgement: CheckedContinuation<Void, Never>?
        model.confirm = { tags in events.append("confirm"); return tags == ["keep"] }
        model.remove = { names, _ in events.append("delete"); try require(names == ["keep"], "Deletion changed captured selection"); throw Failure(message: "delete failed") }
        model.query = { _ in events.append("reload"); throw Failure(message: "reload failed") }
        model.acknowledge = { message in events.append(message); await withCheckedContinuation { acknowledgement = $0 } }
        model.delete(); model.delete(); model.load()
        try await wait { acknowledgement != nil }
        try require(events == ["confirm", "delete", "delete failed"] && model.busy && model.phase == nil && RemoteTagWindowModel.activeOperations == 1 && quitBlocked(), "Delete error did not own acknowledgement/Quit")
        let first = acknowledgement; acknowledgement = nil; first?.resume()
        try await wait { acknowledgement != nil }
        try require(events == ["confirm", "delete", "delete failed", "reload", "reload failed"] && model.tags.isEmpty && model.selection.isEmpty && model.busy, "Refresh replaced/overlapped the deletion error")
        let second = acknowledgement; acknowledgement = nil; second?.resume()
        try await wait { !model.busy && RemoteTagWindowModel.activeOperations == 0 }
        model.query = { token in try await repo.remoteTags(remote: "origin", cancellation: token) }
        model.load(); try await wait { !model.busy && model.tags.count == 1 }
        try require(model.error == nil && model.tags[0].name == "keep", "Error recovery did not load remote state")

        // Successful noncooperative reads keep their own permission/quit lifetime
        // after the controller has disappeared, and cannot publish a late list.
        let closing = RemoteTagWindowController(repository: repo, access: nil, remote: "origin", preferences: prefs); windows.append(closing)
        closing.presentProgress = { _, _ in true }
        // Explicit host bounds can trigger onAppear during controller setup.
        // Settle that real initial catalog before injecting a held replacement read.
        try await wait { !closing.model.busy }
        var readReply: CheckedContinuation<[RemoteTag], Error>?
        closing.model.query = { _ in try await withCheckedThrowingContinuation { readReply = $0 } }
        closing.model.load(); try await wait { readReply != nil }
        closing.close()
        try require(closing.model.closed && closing.model.busy && RemoteTagWindowModel.activeOperations == 1 && quitBlocked(), "Closed tag read released its worker lifetime early")
        let rows = try await repo.remoteTags(remote: "origin")
        readReply?.resume(returning: rows); readReply = nil
        try await wait { !closing.model.busy && RemoteTagWindowModel.activeOperations == 0 }
        try require(closing.model.tags.isEmpty && closing.model.error == nil && closing.progressWindow == nil, "Late tag read published into a retired window")

        // Actual controller question relays settle once, use Abort as default,
        // and release their continuation on forced closure before a late Yes.
        let question = RemoteTagWindowController(repository: repo, access: nil, remote: "origin", preferences: prefs); windows.append(question)
        question.presentProgress = { _, _ in true }; question.model.load(); try await wait { !question.model.busy && question.model.tags.count == 1 }; question.model.select(["keep"])
        var reply: ((NSApplication.ModalResponse) -> Void)?, removals = 0, defaultButtons = false
        question.presentQuestion = { alert, _, completion in
            defaultButtons = alert.buttons.map(\.title) == ["Delete", "Abort"] && alert.buttons[1].keyEquivalent == "\r" && alert.buttons[0].keyEquivalent.isEmpty
            reply = completion; return true
        }
        question.model.remove = { _, _ in removals += 1 }
        question.model.delete(); try await wait { reply != nil }; question.close(); reply?(.alertFirstButtonReturn); reply?(.alertFirstButtonReturn)
        try await wait { !question.model.busy && RemoteTagWindowModel.activeOperations == 0 }
        try require(defaultButtons && removals == 0, "Late or duplicate Yes deleted after closure")

        let picker = RemoteReferenceWindowModel(repository: repo, access: nil, remote: "origin")
        picker.query = { _, _ in ["refs/heads/main", "refs/heads/topic"] }
        picker.refresh(); try await wait { !picker.busy }
        var choices: [String] = []; picker.accept = { choices.append($0) }; picker.branch = "refs/heads/literal 雪"; picker.choose(); picker.choose(); picker.refresh()
        try require(choices == ["refs/heads/literal 雪"] && !picker.canAccept && !picker.busy, "Remote picker accepted duplicate callbacks or rewrote editable source value")
        let retiredPicker = RemoteReferenceWindowModel(repository: repo, access: nil, remote: "origin")
        var pickerReply: CheckedContinuation<[String], Error>?
        retiredPicker.query = { _, _ in try await withCheckedThrowingContinuation { pickerReply = $0 } }
        retiredPicker.refresh(); try await wait { pickerReply != nil }; retiredPicker.retire()
        try require(RemoteReferenceWindowModel.activeOperations == 1 && quitBlocked(), "Retired picker read released Quit early")
        pickerReply?.resume(returning: ["late"]); pickerReply = nil
        try await wait { RemoteReferenceWindowModel.activeOperations == 0 }
        try require(retiredPicker.refs.isEmpty && retiredPicker.branch.isEmpty, "Retired picker published a selection")

        let add = AddRemoteWindowModel(repository: repo, access: nil)
        add.name = "captured"; add.url = bare.path
        var saving: CheckedContinuation<Void, Error>?, saved: [RemoteSettings] = [], closes = 0
        add.persist = { settings, _ in saved.append(settings); try await withCheckedThrowingContinuation { saving = $0 } }
        add.close = { closes += 1 }; add.save(); try await wait { saving != nil }; add.name = "later"; add.url = "later"; add.save(); add.requestClose(); add.requestClose()
        try require(add.busy && add.cancelling && !add.canSave && saved.count == 1 && saved[0].name == "captured" && saved[0].url == bare.path && quitBlocked(), "Add Remote lost captured input or cancellation gate")
        saving?.resume(); saving = nil; try await wait { !add.busy && AddRemoteWindowModel.activeOperations == 0 }
        try require(closes == 1 && !add.canSave && !add.cancelling, "Add Remote repeated completion or allowed restart after pending close")
        let realAdd = AddRemoteWindowModel(repository: repo, access: nil); realAdd.name = "created"; realAdd.url = bare.path; realAdd.save(); try await wait { !realAdd.busy }
        let configuration = try await repo.run(["config", "--get", "remote.created.url"])
        let remote = String(decoding: configuration.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        try require(realAdd.error == nil && remote == bare.path, "Real Add Remote did not persist configuration")
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(after == head && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index, "Remote management changed HEAD/index")
        print("PASS: remote tag error/reload ordering, retired worker and question ownership/Quit; remote picker one-use captured selection; Add Remote captured save/cancel and real configuration; unchanged HEAD/index")
    }
}
