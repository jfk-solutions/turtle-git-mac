// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private actor AdoptionReadGate {
    var token: OperationCancellation?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold(_ token: OperationCancellation) async {
        self.token = token
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func finish() { released = true; continuation?.resume(); continuation = nil }
}
@MainActor @main struct RebaseAdoptionVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String, line: UInt = #line) throws {
        if !value { throw Failure(description: "\(line): \(message)") }
    }
    static var diagnostic: () -> String = { "" }
    static func wait(_ message: String, line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "\(line): \(message); \(diagnostic())")
    }
    static func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    static func ready(_ model: RebaseWindowModel) -> Bool {
        !model.busy && !model.loadingPlan && !model.editingPendingActions && RebaseWindowModel.activePreparationReads == 0 && RebaseWindowModel.activeColumnReads == 0
    }
    static func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    static func metadata(_ root: URL) throws -> [String: Data] {
        let folder = root.appendingPathComponent(".git/rebase-merge")
        return try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("turtlegit-") }.sorted().map { ($0, try bytes(folder.appendingPathComponent($0))) })
    }
    static func stoppedMessages(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["message", "message-squash", "message-fixup"].filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }.map { ($0, try bytes(directory.appendingPathComponent($0))) })
    }
    static func value(_ repository: GitRepository, _ args: [String]) async throws -> String {
        try await repository.run(args).text.trimmingCharacters(in: .newlines)
    }
    @MainActor final class Fixture {
        let root: URL, repository: GitRepository, editor: URL, preferences: UserDefaults, suite: String
        var owners: [RebaseWindowController] = []
        init(_ name: String) throws {
            root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2])); editor = URL(fileURLWithPath: CommandLine.arguments[3])
            suite = "TurtleGit.RebaseAdoption.QA." + UUID().uuidString; preferences = UserDefaults(suiteName: suite)!
            preferences.set(0, forKey: "AutoCloseGitProgress"); preferences.set(false, forKey: "ConfirmKillProcess")
        }
        func finish() { owners.forEach { $0.close() }; preferences.removePersistentDomain(forName: suite) }
        func open() -> RebaseWindowController {
            let owner = RebaseWindowController(repository: repository, access: nil, preferences: preferences)
            owner.window?.alphaValue = 0; owner.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000)); owner.showWindow(nil)
            owner.model.editorExecutable = editor; owners.append(owner); return owner
        }
        func history(structural: Bool) async throws {
            _ = try await repository.run(["init", "-b", "main"])
            for (key, value) in [("user.name", "Adoption QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repository.run(["config", key, value]) }
            func commit(_ name: String) async throws {
                try Data((name + "\n").utf8).write(to: root.appendingPathComponent(name)); try await repository.stage([name]); _ = try await repository.commit(message: name)
            }
            try await commit("base"); _ = try await repository.run(["switch", "-c", "upstream"]); try await commit("upstream")
            if structural { _ = try await repository.run(["switch", "-c", "side", "main"]); try await commit("side") }
            _ = try await repository.run(["switch", "-c", "topic", "main"])
            for name in ["first", "second", "third", "fourth", "fifth"] { try await commit(name) }
            if structural { _ = try await repository.run(["merge", "--no-ff", "--no-edit", "side"]) }
        }
        func pauseExternally(structural: Bool) async throws {
            let sequence = root.appendingPathComponent("external-sequence-editor")
            let source = """
            #!/bin/sh
            /usr/bin/awk 'BEGIN { changed = 0 } !changed && /^pick / { sub(/^pick /, "edit "); changed = 1 } { print }' "$1" > "$1.adoption-fixture"
            /bin/mv "$1.adoption-fixture" "$1"
            """
            try Data(source.utf8).write(to: sequence); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sequence.path)
            let arguments = ["rebase", "-i"] + (structural ? ["--rebase-merges"] : []) + ["upstream"]
            _ = try await repository.run(arguments, environmentOverrides: ["GIT_SEQUENCE_EDITOR": sequence.path, "GIT_EDITOR": "/usr/bin/true"])
            let state = try await repository.rebaseState()
            try require(state.active && state.isEditPause, "raw Git did not pause at edit")
            try require(try metadata(root).isEmpty, "external Git fixture already had TurtleGit identities")
        }
        func pauseLegacy(structural: Bool) async throws {
            let owner = open(), model = owner.model
            model.load(upstream: "refs/heads/upstream", preserveMerges: structural)
            try await wait("legacy initial plan") { ready(model) && model.canStart }
            guard let oldest = model.entries.last?.id else { throw Failure(description: "legacy plan empty") }
            model.setAction(.edit, ids: [oldest]); model.execute("start")
            try await wait("legacy native edit pause") { ready(model) && model.active && model.state?.isEditPause == true }
            owner.close(); try await wait("legacy native owner drained") { !owner.transportBatchWorkPending }
            let identities = root.appendingPathComponent(".git/rebase-merge/turtlegit-replay-identities.json")
            if structural {
                // Older archives had occurrence/hash identities but no optional
                // action member. Removing all native structural IDs would instead
                // corrupt reset-only merge occurrences that Git never records.
                var rows = try JSONSerialization.jsonObject(with: bytes(identities)) as! [[String: Any]]
                for index in rows.indices { rows[index].removeValue(forKey: "action") }
                try JSONSerialization.data(withJSONObject: rows).write(to: identities, options: .atomic)
            } else { try FileManager.default.removeItem(at: identities) }
        }
    }
    static func menu(_ owner: RebaseWindowController, id: String, title: String) async throws -> NSMenuItem {
        owner.model.tab = 0; owner.model.selection = [id]
        var table: RebaseReplayNativeTable?
        try await wait("actual native pending replay menu") {
            table = descendants(owner.window!.contentView!).compactMap { $0 as? RebaseReplayNativeTable }.first
            return table?.owner?.available == true && owner.model.revisionMenuAvailable && ready(owner.model)
        }
        let popup = table!.owner!.menu(ids: [id], alternate: false)
        guard let item = popup.item(withTitle: title), item.isEnabled, item.image != nil, item.action != nil else { throw Failure(description: "native \(title) action/icon unavailable") }
        return item
    }
    static func change(_ owner: RebaseWindowController, id: String, action: RebaseAction, title: String) async throws {
        let item = try await menu(owner, id: id, title: title)
        try require(NSApp.sendAction(item.action!, to: item.target, from: item), "native target/action rejected \(title)")
        try await wait("native adopted \(title) publication") { ready(owner.model) }
        try require(owner.model.error == nil && owner.model.entries.first(where: { $0.id == id })?.action == action, "native \(title) was not durably saved: \(owner.model.error ?? "none"); \(diagnostic())")
    }
    static func verify(structural: Bool) async throws {
        for legacy in [false, true] {
            let fixture = try Fixture((structural ? "structural" : "linear") + (legacy ? "-legacy" : "-external"))
            defer { fixture.finish(); diagnostic = { "" } }
            try await fixture.history(structural: structural)
            if legacy { try await fixture.pauseLegacy(structural: structural) } else { try await fixture.pauseExternally(structural: structural) }
            let repository = fixture.repository, root = fixture.root
            let directory = root.appendingPathComponent(".git/rebase-merge"), todo = directory.appendingPathComponent("git-rebase-todo")
            let index = try bytes(root.appendingPathComponent(".git/index")), originalTodo = try bytes(todo), originalMetadata = try metadata(root)
            let state = try await repository.rebaseState(), stopped = try await repository.rebaseCommit("HEAD"), originalMessage = try stoppedMessages(directory)
            if structural && !legacy {
                let lines = String(decoding: originalTodo, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
                guard let third = lines.firstIndex(where: { $0.hasSuffix(" third") }), third > 0 else { throw Failure(description: "external structural fixture missing future third") }
                try require(lines[third - 1].hasPrefix("pick ") && lines[third - 1].hasSuffix(" second"), "structural Squash fixture crosses an unsupported topology boundary")
            }
            let read = try await repository.rebaseActionEditSnapshot()
            try require(read.requiresAdoption == (!legacy || !structural), "external/legacy adoption classification incorrect")
            try require(read.head == stopped.hash && !read.replay.isEmpty && bytes(todo) == originalTodo && metadata(root) == originalMetadata && bytes(root.appendingPathComponent(".git/index")) == index, "adoption preview mutated repository/todo/metadata")
            let owner = fixture.open(), model = owner.model
            diagnostic = { "legacy=\(legacy), structural=\(structural), active=\(model.active), busy=\(model.busy), error=\(model.error ?? "nil"), entries=\(model.entries.map { $0.commit.subject + ":" + $0.action.rawValue })" }
            model.load()
            try await wait("external/legacy native active session") { ready(model) && model.active && model.canEditPendingActions }
            // A native structural plan preserves the source refusal when a
            // merge's selected first parent has never been replayed. Skip an
            // earlier linear row whose retained descendant supplies that parent.
            let skipSubject=structural ? "fourth":"fifth"
            guard let target = model.entries.first(where: { $0.commit.subject == "third" && $0.progress == .pending })?.id,
                  let skipped = model.entries.first(where: { $0.commit.subject == skipSubject && $0.progress == .pending })?.id else { throw Failure(description: "future adoption targets missing") }
            let ids = model.entries.map(\.id)
            model.amendMessage = "Unapplied current native draft\n"; let draft = model.amendMessage
            for (action, title) in [(RebaseAction.edit, "Edit"), (.squash, "Squash"), (.skip, "Skip"), (.pick, "Pick")] {
                try await change(owner, id: target, action: action, title: title)
                let saved = try await GitRepository(root: root, executable: repository.executable).rebaseActionEditSnapshot()
                try require(!saved.requiresAdoption && saved.replay.first(where: { $0.id == target })?.action == action && saved.head == stopped.hash && model.amendMessage == draft && model.entries.map(\.id) == ids, "adoption/action changed stable rows, stopped commit, or current draft")
                try require(try bytes(root.appendingPathComponent(".git/index")) == index && stoppedMessages(directory) == originalMessage, "future action altered index or stopped message")
            }
            try await change(owner, id: skipped, action: .skip, title: "Skip")
            guard let current = model.entries.first(where: { $0.progress == .current }) else { throw Failure(description: "current adopted occurrence missing") }
            try require(model.revisionActionChoices([current.id]).isEmpty, "current stopped occurrence exposed future action edits")
            owner.close(); try await wait("adopted owner drains before reopen") { !owner.transportBatchWorkPending }
            let reopened = fixture.open(), replay = reopened.model
            replay.load()
            try await wait("durable adopted replay reopened") { ready(replay) && replay.active && replay.canEditPendingActions }
            try require(replay.entries.first(where: { $0.id == target })?.action == .pick && replay.entries.first(where: { $0.id == skipped })?.action == .skip && replay.state?.stoppedEntryID == state.stoppedEntryID, "reopen lost actions or changed current occurrence")
            let beforeContinue = try await repository.rebaseCommit("HEAD")
            try require(beforeContinue.hash == stopped.hash && beforeContinue.message == stopped.message, "adoption amended the current Git commit")
            // The unapplied UI draft was never a Git amendment. Continue from
            // the freshly read actual stopped message through the real native UI.
            replay.execute("continue")
            try await wait("actual adopted native Continue") { ready(replay) && (replay.finished || replay.error != nil || replay.state?.squashMessage != nil) }
            try require(replay.finished && replay.completedSuccessfully && replay.error == nil, "adopted Continue failed: \(replay.error ?? replay.output)")
            let result = try await repository.rebaseCommit("HEAD"), finalState = try await repository.rebaseState()
            try require(!finalState.active && result.parents.count == (structural ? 2 : 1) && !FileManager.default.fileExists(atPath:root.appendingPathComponent(skipSubject).path) && FileManager.default.fileExists(atPath:root.appendingPathComponent("third").path) && (!structural || FileManager.default.fileExists(atPath:root.appendingPathComponent("fifth").path)), "durable adopted action changed topology or ignored final Skip/Pick")
            reopened.close(); try await wait("completed adoption UI drains") { !reopened.transportBatchWorkPending }
        }
        print("PASS: \(structural ? "structural" : "linear") external/legacy adoption, read-only preview, actual native Pick/Edit/Squash/Skip icons and actions, draft/index/HEAD preservation, durable reopen and Continue")
    }
    static func ownership() async throws {
        let fixture = try Fixture("owned-external")
        defer { fixture.finish(); diagnostic = { "" } }
        try await fixture.history(structural: true); try await fixture.pauseExternally(structural: true)
        let repository = fixture.repository, root = fixture.root
        let todo = root.appendingPathComponent(".git/rebase-merge/git-rebase-todo")
        let originalTodo = try bytes(todo), originalIndex = try bytes(root.appendingPathComponent(".git/index")), originalMetadata = try metadata(root)
        let originalHead = try await value(repository, ["rev-parse", "HEAD"])
        let owner = fixture.open(), model = owner.model
        diagnostic = { "retired=\(model.retired), busy=\(model.busy), pending=\(owner.transportBatchWorkPending), preparations=\(RebaseWindowModel.activePreparationReads), error=\(model.error ?? "nil")" }
        model.load(); try await wait("owned external replay loaded") { ready(model) && model.canEditPendingActions }
        guard let pending = model.entries.first(where: { $0.commit.subject == "third" && $0.progress == .pending })?.id else { throw Failure(description: "owned pending target missing") }
        let gate = AdoptionReadGate()
        model.readActionEditSnapshot = { token in
            // Read the actual immutable proposed adoption before holding its
            // receipt. Cancellation must not install any proposal sidecars.
            let snapshot = try await repository.rebaseActionEditSnapshot(cancellation: token)
            await gate.hold(token); try token.check(); return snapshot
        }
        let item = try await menu(owner, id: pending, title: "Edit")
        try require(NSApp.sendAction(item.action!, to: item.target, from: item), "owned native Edit target/action rejected")
        for _ in 0..<3000 { if await gate.token != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let token = await gate.token
        do {
            try require(token != nil && model.editingPendingActions && owner.transportBatchWorkPending && RebaseWindowModel.activePreparationReads > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "adoption preparation lost token/worker/Quit ownership")
            owner.window?.performClose(nil)
            try require(!model.retired && token?.isCancelled == true && owner.transportBatchWorkPending && RebaseWindowModel.activePreparationReads > 0, "normal close did not cancel/drain actual adoption preparation")
            owner.close()
            try require(model.retired && owner.transportBatchWorkPending && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "forced close released held adoption worker")
            await gate.finish()
            try await wait("retired adoption receipt drained") { !owner.transportBatchWorkPending && RebaseWindowModel.activePreparationReads == 0 && RebaseWindowModel.activeColumnReads == 0 }
            let head = try await value(repository, ["rev-parse", "HEAD"])
            try require(head == originalHead && bytes(todo) == originalTodo && bytes(root.appendingPathComponent(".git/index")) == originalIndex && metadata(root) == originalMetadata, "late retired adoption wrote todo/identity/HEAD/index")
        } catch { owner.close(); await gate.finish(); throw error }
        // A fresh owner can still perform a deliberate edit after cancellation;
        // the old attempt must not poison adoption or replay stale action state.
        let fresh = fixture.open(), next = fresh.model
        next.load(); try await wait("fresh owner after cancelled adoption") { ready(next) && next.canEditPendingActions }
        guard let target = next.entries.first(where: { $0.commit.subject == "third" && $0.progress == .pending })?.id else { throw Failure(description: "fresh pending target missing") }
        try await change(fresh, id: target, action: .skip, title: "Skip")
        let saved = try await repository.rebaseActionEditSnapshot()
        try require(saved.replay.first(where: { $0.id == target })?.action == .skip, "cancelled old attempt poisoned fresh adoption")
        fresh.close(); try await wait("fresh adoption owner drains") { !fresh.transportBatchWorkPending }
        let aborted = try await repository.abortRebase()
        try require(!aborted.state.active, "private adopted replay cleanup Abort failed")
        print("PASS: real external structural adoption preparation, normal Cancel/forced-close token ownership, Quit/worker drain, no late metadata/action publication and fresh-owner retry")
    }
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)))!
        let hidden = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.turtleGitRebaseAdoptionOrder(_:relativeTo:)))!
        method_exchangeImplementations(original, hidden); defer { method_exchangeImplementations(original, hidden) }
        switch ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_ADOPTION_CASE"] {
        case "linear": try await verify(structural: false)
        case "structural": try await verify(structural: true)
        case "ownership": try await ownership()
        default: throw Failure(description: "Unknown Rebase adoption case")
        }
        print("PASS: Rebase adoption case completed")
    }
}
private extension NSWindow {
    @objc func turtleGitRebaseAdoptionOrder(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        alphaValue = 0; setFrameOrigin(NSPoint(x: -20000, y: -20000))
        turtleGitRebaseAdoptionOrder(place, relativeTo: otherWin)
    }
}
