import AppKit
import SwiftUI
import TurtleGitCore
@testable import TurtleGitMac

@MainActor func settle(_ model: RebaseWindowModel) async throws {
    let deadline = Date().addingTimeInterval(30)
    while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!model.busy, "Native operation timed out")
    precondition(model.error == nil, model.error ?? "")
}
@MainActor func findTable(_ view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    return view.subviews.compactMap { findTable($0) }.first
}
@MainActor func verify() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let preference = "CherrypickAddCherryPickedFrom", saved = UserDefaults.standard.object(forKey: "CherrypickAddCherryPickedFrom")
    UserDefaults.standard.set(false, forKey: preference)
    defer {
        if let saved { UserDefaults.standard.set(saved, forKey: preference) } else { UserDefaults.standard.removeObject(forKey: preference) }
        for window in NSApp.windows { precondition(!window.isVisible); window.close() }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_TEST_GIT"] ?? "/usr/bin/git")
    let repo = GitRepository(root: root, executable: git)
    _ = try await repo.run(["init", "--initial-branch=main"])
    _ = try await repo.run(["config", "user.name", "Native tester"])
    _ = try await repo.run(["config", "user.email", "native@example.invalid"])
    try Data("base\n".utf8).write(to: root.appendingPathComponent("base.txt"))
    try await repo.stage(["base.txt"]); _ = try await repo.commit(message: "base")
    let base = try await repo.rebaseCommit("HEAD")
    _ = try await repo.run(["checkout", "-b", "side"])
    try Data("side\n".utf8).write(to: root.appendingPathComponent("side.txt"))
    try await repo.stage(["side.txt"]); _ = try await repo.commit(message: "Side native parent")
    let side = try await repo.rebaseCommit("HEAD")
    _ = try await repo.run(["checkout", "main"])
    try Data("main\n".utf8).write(to: root.appendingPathComponent("main.txt"))
    try await repo.stage(["main.txt"]); _ = try await repo.commit(message: "Main native parent")
    let parent = try await repo.rebaseCommit("HEAD")
    _ = try await repo.run(["merge", "--no-ff", "--no-edit", "side"])
    let merge = try await repo.rebaseCommit("HEAD")
    _ = try await repo.run(["checkout", "-b", "target", parent.hash])

    let log = LogWindowModel(repository: repo, access: nil)
    log.entries = [merge, parent, side, base]; log.graph = CommitGraph.layout(log.entries); log.bare = false
    var received: [[String]] = []; log.onCherryPick = { received.append($0) }
    log.selected = [side.hash, merge.hash]
    precondition(log.canCherryPick)
    log.request(.cherryPick)
    precondition(received == [[merge.hash, side.hash]] && log.commandRequest == nil)
    let host = NSHostingView(rootView: RevisionTable(model: log)); host.frame = NSRect(x: 0, y: 0, width: 1040, height: 300); host.layoutSubtreeIfNeeded()
    guard let table = findTable(host), let coordinator = table.delegate as? RevisionTable.Coordinator, let menu = table.menu else { fatalError("Actual Log table unavailable") }
    coordinator.menuNeedsUpdate(menu)
    let multi = menu.items.first { $0.title == "Cherry Pick selected commits…" }!
    precondition(multi.isEnabled && multi.image != nil)
    coordinator.cherryPick(); precondition(received.count == 2)
    log.selected = [merge.hash]; coordinator.menuNeedsUpdate(menu)
    let single = menu.items.first { $0.title == "Cherry Pick this commit…" }!
    precondition(single.isEnabled && single.image != nil)
    log.busy = true; precondition(!log.canCherryPick); log.requestCherryPick(); precondition(received.count == 2); log.busy = false
    log.mergeActive = true; precondition(!log.cherryPickAvailable); coordinator.menuNeedsUpdate(menu)
    precondition(!menu.items.contains { $0.title.hasPrefix("Cherry Pick") }); log.mergeActive = false
    log.bare = true; precondition(!log.cherryPickAvailable); log.bare = false
    log.entries[0].isHead = true; precondition(!log.cherryPickAvailable); log.entries[0].isHead = false
    _ = try await repo.run(["update-ref", "refs/stash", merge.hash])
    var historyOptions = HistoryOptions(); historyOptions.allBranches = true
    let stashRows = try await repo.history(options: historyOptions); log.entries[0].references = stashRows.first { $0.hash == merge.hash }!.references
    _ = try await repo.run(["update-ref", "-d", "refs/stash"])
    precondition(log.cherryPickAvailable); log.entries[0].references = []
    log.selected = [merge.hash, parent.hash]; log.entries[1].isHead = true
    precondition(log.cherryPickAvailable); log.entries[1].isHead = false
    log.selected = [base.hash]; precondition(log.canCherryPick)
    print("Actual hosted Log menu: single/multiple/merge/root selection handoff, visible order, icon, busy/bare/first-selected-HEAD/active-merge guards and stash selection passed.")

    let model = RebaseWindowModel(repository: repo, access: nil)
    model.editorExecutable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TurtleGitMac")
    var modeUpdates = 0, changed = 0
    model.onModeChanged = { modeUpdates += 1 }; model.onChanged = { changed += 1 }
    model.load(cherryPick: [merge.hash, side.hash]); try await settle(model)
    precondition(model.operationTitle == "Cherry Pick" && model.startTitle == "Continue" && modeUpdates == 1)
    precondition(model.entries.map(\.id) == [merge.hash, side.hash] && model.canStart)
    precondition(model.entries.map { model.entryNumber($0) } == [2, 1])
    let before = model.plan!.originalCommits
    model.reloadPlan(); precondition(model.plan!.originalCommits == before)
    model.options.addCherryPickedFrom = true; model.updateAttribution()
    precondition(model.plan!.options.addCherryPickedFrom && UserDefaults.standard.bool(forKey: preference))
    model.selection = [merge.hash]; model.move(up: false)
    precondition(model.entries.map(\.id) == [side.hash, merge.hash]); model.move(up: true)
    model.setAction(.squash, ids: [side.hash]); precondition(!model.canStart)
    model.setAction(.skip, ids: [side.hash]); model.setAction(.edit, ids: [merge.hash]); precondition(model.canStart)
    let dialog = NSHostingView(rootView: RebaseDialog(model: model)); dialog.frame = NSRect(x: 0, y: 0, width: 1040, height: 720); dialog.layoutSubtreeIfNeeded()
    precondition(dialog.fittingSize.width > 0 && model.helpURL.absoluteString.hasSuffix("tgit-dug-cherrypick.html"))
    var prompted = 0
    model.chooseMainline = { commit, choices in
        prompted += 1; precondition(commit.hash == merge.hash && choices.count == 2)
        precondition(choices[0].title.contains("Main native parent") && choices[1].title.contains("Side native parent"))
        return nil
    }
    model.request("start"); try await settle(model)
    precondition(prompted == 1 && !model.active && !model.finished && model.confirmation == nil)
    let unchanged = try await repo.rebaseCommit("HEAD"); precondition(unchanged.hash == parent.hash)
    model.chooseMainline = { _, _ in prompted += 1; return 1 }
    model.request("start"); try await settle(model)
    precondition(prompted == 2 && model.active && !model.finished && changed == 1)
    precondition(model.state?.isCherryPick == true && model.state?.stoppedCommit == merge.hash)
    let picked = try await repo.rebaseCommit("HEAD")
    precondition(picked.message.contains("(cherry picked from commit " + merge.hash + ")"))
    let reopened = RebaseWindowModel(repository: GitRepository(root: root, executable: git), access: nil)
    reopened.finished = true
    reopened.load(); try await settle(reopened)
    precondition(!reopened.finished)
    precondition(reopened.isCherryPick && reopened.operationTitle == "Cherry Pick")
    precondition(reopened.entries.map(\.id) == [merge.hash] && !reopened.canStart)
    reopened.execute("continue"); try await settle(reopened)
    precondition(reopened.finished && !reopened.active && reopened.status == "Cherry Pick finished")
    let branch = try await repo.branch(); precondition(branch == "target")
    print("Actual Cherry Pick model/dialog host: order/IDs/actions, attribution persistence, cancel leaves HEAD unchanged, merge parent metadata, Edit, reopened mode and Continue passed. No displayed windows or alerts.")
    let multiplePicker = LogWindowModel(repository: repo, access: nil, selecting: true, selectingMultiple: true)
    multiplePicker.entries = [merge, parent, side]; multiplePicker.selected = [side.hash, merge.hash]
    var chosen: [LogEntry] = []
    multiplePicker.finishMultipleSelection = { chosen = $0 ?? [] }
    precondition(multiplePicker.canAcceptSelection)
    multiplePicker.accept(); precondition(chosen.map(\.hash) == [merge.hash, side.hash])
    chosen = []; multiplePicker.busy = true; multiplePicker.accept(); precondition(chosen.isEmpty)
    multiplePicker.busy = false; multiplePicker.selected = []; precondition(!multiplePicker.canAcceptSelection)
    let singlePicker = LogWindowModel(repository: repo, access: nil, selecting: true)
    singlePicker.entries = multiplePicker.entries; singlePicker.selected = [merge.hash, side.hash]
    precondition(!singlePicker.canAcceptSelection)
    singlePicker.selected = [merge.hash]; var selectedOne: LogEntry?
    singlePicker.finishSelection = { selectedOne = $0 }; singlePicker.accept(); precondition(selectedOne?.hash == merge.hash)

    _ = try await repo.run(["checkout", "side"])
    _ = try await repo.run(["commit", "--allow-empty", "-m", "Repeated native empty"])
    let empty = try await repo.rebaseCommit("HEAD")
    _ = try await repo.run(["checkout", "target"])
    let adding = RebaseWindowModel(repository: repo, access: nil); adding.editorExecutable = model.editorExecutable
    adding.load(cherryPick: [empty.hash]); try await settle(adding)
    precondition(adding.canAdd)
    let addHost = NSHostingView(rootView: RebaseDialog(model: adding)); addHost.frame = NSRect(x: 0, y: 0, width: 1040, height: 720); addHost.layoutSubtreeIfNeeded(); precondition(addHost.fittingSize.width > 0)
    let originalPlan = adding.plan!
    adding.pickingCommits = true; precondition(!adding.canAdd && !adding.canStart)
    adding.finishPickingCommits(nil); precondition(adding.plan!.originalCommits == originalPlan.originalCommits)
    adding.pickingCommits = true; adding.finishPickingCommits([empty.hash]); try await settle(adding)
    precondition(adding.entries.map(\.occurrence) == [1, 0])
    precondition(adding.selection == [adding.entries[0].id] && adding.entries[0].action == .pick)
    adding.options.preserveMerges = true; precondition(!adding.canAdd); adding.options.preserveMerges = false
    adding.setAction(.edit, ids: Set(adding.entries.map(\.id)))
    adding.request("start"); try await settle(adding)
    precondition(adding.active && adding.state?.stoppedEntryID == empty.hash && !adding.canAdd)
    adding.execute("continue"); try await settle(adding)
    precondition(adding.active && adding.state?.stoppedEntryID == empty.hash + ":1")
    precondition(adding.selection == [empty.hash + ":1"] && adding.entries.map(\.id) == [empty.hash + ":1"])
    let reopenedDuplicate = RebaseWindowModel(repository: GitRepository(root: root, executable: git), access: nil)
    reopenedDuplicate.load(); try await settle(reopenedDuplicate)
    precondition(reopenedDuplicate.entries.map(\.id) == [empty.hash + ":1"])
    reopenedDuplicate.execute("continue"); try await settle(reopenedDuplicate)
    precondition(reopenedDuplicate.finished && !reopenedDuplicate.active)
    print("Actual native Add: multiple-picker OK order/busy/empty checks, single-picker regression, cancel preserves plan, repeated Add uses distinct row IDs, active/Preserve Merges guards, repeated Edit/Continue selection and reopening passed.")
    let draftModel = RebaseWindowModel(repository: repo, access: nil)
    draftModel.load(); try await settle(draftModel)
    precondition(draftModel.plan == nil && draftModel.options.upstream.isEmpty && draftModel.canAdd && !draftModel.canStart)
    let draftHost = NSHostingView(rootView: RebaseDialog(model: draftModel)); draftHost.frame = NSRect(x: 0, y: 0, width: 1040, height: 720); draftHost.layoutSubtreeIfNeeded()
    draftModel.addCommits([merge.hash, side.hash]); try await settle(draftModel)
    precondition(draftModel.entries.map { $0.commit.hash } == [merge.hash, side.hash] && !draftModel.canStart && draftModel.canAdd)
    precondition(draftModel.entries.map { draftModel.entryNumber($0) } == [2, 1])
    draftModel.selection = [merge.hash]; draftModel.setAction(.skip)
    precondition(draftModel.entries[0].action == .skip)
    draftModel.move(up: false); precondition(draftModel.entries.map { $0.commit.hash } == [side.hash, merge.hash])
    let preservedDraft = draftModel.entries.map(\.id)
    draftModel.pickingCommits = true; draftModel.finishPickingCommits(nil)
    precondition(draftModel.entries.map(\.id) == preservedDraft)
    draftModel.options.preserveMerges = true; precondition(!draftModel.canAdd); draftModel.options.preserveMerges = false
    draftModel.options.upstream = "missing-upstream"; draftModel.plan = nil; draftModel.draftEntries = []
    draftModel.addCommits([side.hash]); try await settle(draftModel)
    precondition(draftModel.entries.map { $0.commit.hash } == [side.hash] && !draftModel.canStart)
    draftModel.options.upstream = "side"; draftModel.reloadPlan()
    let loadedPlan = Date().addingTimeInterval(30)
    while draftModel.plan == nil && Date() < loadedPlan { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(draftModel.plan != nil && draftModel.draftEntries.isEmpty)
    // Represent a reference reload superseded by opening Add: valid references, no completed plan yet.
    draftModel.plan = nil; draftModel.draftEntries = []
    draftModel.addCommits([empty.hash]); try await settle(draftModel)
    precondition(draftModel.plan?.hasAddedCommits == true && draftModel.entries.first?.commit.hash == empty.hash && draftModel.canStart)
    print("Actual draft Add: enabled without upstream/plan, newest-first draft rows/IDs/actions/order, Cancel/Preserve guards, invalid-reference drafts, valid-reference rebuild and Add during pending reload passed.")


}
@main struct Receiver { @MainActor static func main() async throws { try await verify() } }
