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
@MainActor func findRebaseProbe(_ view: NSView) -> RebaseListInteraction.Probe? {
    if let probe = view as? RebaseListInteraction.Probe { return probe }
    return view.subviews.compactMap { findRebaseProbe($0) }.first
}
@MainActor func settleCommit(_ model: CommitWindowModel) async throws {
    let deadline = Date().addingTimeInterval(30)
    while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!model.busy && model.error == nil, model.error ?? "Commit timed out")
}
@MainActor func verifyNativeSplit(_ repo: GitRepository, editor: URL?) async throws {
    _ = try await repo.run(["checkout", "-b", "native-split-source"])
    for name in ["native-split-left.txt", "native-split-right.txt"] { try Data(name.utf8).write(to: repo.root.appendingPathComponent(name)) }
    try await repo.stage(["native-split-left.txt", "native-split-right.txt"]); _ = try await repo.commit(message: "Native split source")
    let source = try await repo.rebaseCommit("HEAD")
    try Data("future\n".utf8).write(to: repo.root.appendingPathComponent("native-split-future.txt")); try await repo.stage(["native-split-future.txt"]); _ = try await repo.commit(message: "Native split future")
    let future = try await repo.rebaseCommit("HEAD"); _ = try await repo.run(["checkout", "target"])
    let parent = RebaseWindowModel(repository: repo, access: nil); parent.editorExecutable = editor
    parent.load(cherryPick: [future.hash, source.hash]); try await settle(parent)
    parent.setAction(.edit, ids: [source.hash]); parent.request("start"); try await settle(parent)
    precondition(parent.state?.stoppedAction == .edit && parent.canSplit && parent.tab == 1)
    let editHost = NSHostingView(rootView: RebaseDialog(model: parent)); editHost.frame = NSRect(x: 0, y: 0, width: 1040, height: 720); editHost.layoutSubtreeIfNeeded()
    precondition(editHost.fittingSize.width > 0)
    var children: [CommitWindowModel] = []
    func install(_ owner: RebaseWindowModel) {
        owner.chooseAnotherSplit = { false }
        owner.showSplitSelection = { [weak owner] split, text in
            guard let owner else { return }
            let child = CommitWindowModel(repository: repo, access: nil); children.append(child)
            var committed = false
            child.onCommitted = { _ in committed = true }
            child.close = { [weak owner] in owner?.splitSelectionClosed(committed: committed) }
            child.confirmCancel = { choose in choose(true) }
            child.loadReplaySplit(split, message: text)
        }
    }
    install(parent); parent.splitCommit = true; parent.request("continue"); try await settle(parent)
    precondition(parent.selectingSplit && !parent.canSplit && children.count == 1)
    let first = children[0]; try await settleCommit(first)
    precondition(first.replaySplit?.parts == 0 && first.amend && first.amendToParent && first.showWholeProject)
    precondition(Set(first.entries.map(\.path)).isSuperset(of: ["native-split-left.txt", "native-split-right.txt"]))
    let firstHost = NSHostingView(rootView: CommitDialog(model: first)); firstHost.frame = NSRect(x: 0, y: 0, width: 1000, height: 760); firstHost.layoutSubtreeIfNeeded(); precondition(firstHost.fittingSize.width > 0)
    first.stagingEnabled = false; first.checked = ["native-split-left.txt"]; first.message = "Native split left"
    precondition(first.canCommit); first.commit(.push); precondition(!first.busy) // Post actions blocked in this mode.
    first.commit(); try await settleCommit(first); try await settle(parent)
    precondition(children.count == 2 && parent.selectingSplit && parent.state?.split?.parts == 1)
    let second = children[1]; try await settleCommit(second); precondition(!second.amend && second.replaySplit?.parts == 1)
    second.cancel()
    let deadline = Date().addingTimeInterval(30)
    while parent.selectingSplit && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    try await settle(parent); precondition(!parent.selectingSplit && parent.active && parent.state?.split?.parts == 1)
    let reopened = RebaseWindowModel(repository: repo, access: nil); reopened.editorExecutable = editor; install(reopened)
    reopened.load(); try await settle(reopened); precondition(reopened.splitCommit && reopened.isCherryPick && reopened.canSplit)
    reopened.request("continue"); try await settle(reopened); precondition(children.count == 3)
    let resumed = children[2]; try await settleCommit(resumed); precondition(!resumed.amend && resumed.replaySplit?.parts == 1)
    resumed.stagingEnabled = false; resumed.checked = ["native-split-right.txt"]; resumed.message = "Native split right"; precondition(resumed.canCommit)
    resumed.commit(); try await settleCommit(resumed); try await settle(reopened)
    precondition(reopened.finished && !reopened.active && !reopened.selectingSplit)
    let log = try await repo.run(["log", "-3", "--format=%s"]).text
    precondition(log == "Native split future\nNative split right\nNative split left\n")
    print("Actual native Split: multiline Edit host, first parent-based full Commit selection, post-action guard, automatic remaining-part dialog, Cancel/reopened normal part, metadata identity and final Continue/future replay passed. Sheets and answers injected; no displayed gestures.")
}
@MainActor func verifyNativeRecoveryFiles(_ repo: GitRepository, editor: URL?) async throws {
    let path = "native recovery 雪\n.txt", clean = "native-recovery-clean.txt"
    try Data("base-recovery\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "recovery base")
    let base = try await repo.rebaseCommit("HEAD")
    _ = try await repo.run(["checkout", "-b", "native-recovery-source"])
    try Data("from-replay\n".utf8).write(to: repo.root.appendingPathComponent(path)); try Data("clean replay\n".utf8).write(to: repo.root.appendingPathComponent(clean))
    try await repo.stage([path, clean]); _ = try await repo.commit(message: "recovery source")
    let source = try await repo.rebaseCommit("HEAD")
    _ = try await repo.run(["checkout", "target"])
    try Data("from-onto\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "recovery onto")
    let destination = try await repo.rebaseCommit("HEAD")
    let model = RebaseWindowModel(repository: repo, access: nil); model.editorExecutable = editor
    model.load(cherryPick: [source.hash]); try await settle(model); model.setAction(.edit, ids: [source.hash]); model.request("start")
    let deadline = Date().addingTimeInterval(30)
    while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!model.busy && model.error != nil && model.fileRecovery && model.tab == 0 && !model.canSplit)
    model.error = nil
    precondition(model.conflicts.map(\.path) == [path] && Set(model.conflictRows.map(\.path)) == [path, clean])
    let host = NSHostingView(rootView: RebaseConflictFiles(model: model)); host.frame = NSRect(x: 0, y: 0, width: 1000, height: 300); host.layoutSubtreeIfNeeded()
    guard let table = findTable(host) else { fatalError("Actual Conflict Files table unavailable") }
    precondition(table.numberOfRows == 2 && table.tableColumns.count == 5)
    model.compareConflicts([path]); try await settle(model); precondition(model.conflictPatch?.contains("base-recovery") == true); model.conflictPatch = nil
    var edited: [String] = [], resolve: ResolveWindowModel?
    model.onConflictAction = { action, paths in
        if action == .editConflict { edited = paths; return }
        let receiver = ResolveWindowModel(repository: repo, access: nil, paths: paths, quick: action.resolveChoice); resolve = receiver
        receiver.confirm = { [weak receiver] choice, entries in DispatchQueue.main.async { receiver?.apply(entries, using: choice) } }
        receiver.onChanged = { _ in model.refreshState() }; receiver.load()
    }
    model.conflictAction(.editConflict, ids: [path]); precondition(edited == [path])
    edited = []; model.conflictAction(.editConflict, ids: [path, clean]); precondition(edited.isEmpty)
    model.conflictAction(.resolveTheirs, ids: [path])
    let resolvedDeadline = Date().addingTimeInterval(30)
    while (!model.conflicts.isEmpty || model.busy || resolve?.busy == true) && Date() < resolvedDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(resolve?.error == nil && model.error == nil && model.conflicts.isEmpty && model.fileRecovery && !model.canSplit)
    precondition(Set(model.conflictRows.map(\.path)) == [path, clean])
    let resolvedText = try String(contentsOf: repo.root.appendingPathComponent(path), encoding: .utf8); precondition(resolvedText == "from-replay\n")
    let reopened = RebaseWindowModel(repository: repo, access: nil); reopened.editorExecutable = editor; reopened.load(); try await settle(reopened)
    precondition(reopened.fileRecovery && !reopened.canSplit && Set(reopened.conflictRows.map(\.path)) == [path, clean])
    reopened.request("continue"); try await settle(reopened); precondition(reopened.finished && !reopened.active && !reopened.fileRecovery)
    let preserved = try await repo.rebaseCommit(destination.hash); precondition(preserved.subject == "recovery onto")
    let ancestor = try await repo.run(["merge-base", "--is-ancestor", base.hash, "HEAD"]); precondition(ancestor.exitCode == 0)
    print("Actual Conflict Files: five-column native table with conflicted/clean rows, original base diff, single Edit route, actual quick Resolve replayed-side semantics and refresh, resolved-row retention/reopening, Split blocked before application and final Continue passed. Editor/confirmation routing injected.")
}
@MainActor func verifyListInteraction(_ repo: GitRepository, revisions: [String]) async throws {
    let model = RebaseWindowModel(repository: repo, access: nil)
    model.load(cherryPick: revisions); try await settle(model)
    let original = model.entries.map(\.id), snapshot = model.plan!
    precondition(original.count == 4)
    model.selection = [original[1], original[2]]; model.move(up: true)
    precondition(model.entries.map(\.id) == [original[1], original[2], original[0], original[3]])
    model.move(up: false); precondition(model.entries.map(\.id) == original)
    model.selection = [original[0], original[2]]; model.move(up: false)
    precondition(model.entries.map(\.id) == [original[1], original[0], original[3], original[2]])
    model.move(up: true); precondition(model.entries.map(\.id) == original)
    model.selection = [original[0], original[2]]; model.move(up: true)
    precondition(model.entries.map(\.id) == original) // Boundary blocks the entire move.
    model.selection = [original[1], original[3]]; model.move(up: true, toEnd: true)
    precondition(model.entries.map(\.id) == [original[1], original[3], original[0], original[2]])
    model.move(up: false, toEnd: true)
    precondition(model.entries.map(\.id) == [original[0], original[2], original[1], original[3]])
    precondition(model.selection == [original[1], original[3]])
    model.plan = snapshot; model.selection = Set(original)
    model.cycleActions(); precondition(model.entries.allSatisfy { $0.action == .skip })
    model.cycleActions(); precondition(model.entries.allSatisfy { $0.action == .edit })
    model.cycleActions(); precondition(model.entries.dropLast().allSatisfy { $0.action == .squash } && model.entries.last?.action == .pick)
    model.cycleActions(); precondition(model.entries.dropLast().allSatisfy { $0.action == .pick } && model.entries.last?.action == .skip)
    model.plan = snapshot; model.selection = []
    let host = NSHostingView(rootView: RebaseDialog(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    guard let table = findTable(host), let probe = findRebaseProbe(host) else { fatalError("Actual Rebase list/probe unavailable") }
    precondition(window.makeFirstResponder(table))
    table.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false)
    func event(_ key: String, flags: NSEvent.ModifierFlags = [], number: Int? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: number ?? window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
    }
    precondition(probe.observe(event("s")) == nil)
    precondition(model.entries[1].action == .skip && model.entries[2].action == .skip && model.entries[0].action == .pick)
    precondition(probe.observe(event(" ")) == nil && model.entries[1].action == .edit)
    precondition(probe.observe(event("q")) == nil && model.entries[1].action == .squash)
    precondition(probe.observe(event("e")) == nil && model.entries[1].action == .edit)
    precondition(probe.observe(event("p")) == nil && model.entries[1].action == .pick)
    precondition(probe.observe(event("u", flags: .shift)) == nil)
    precondition(model.entries.map(\.id) == [original[1], original[2], original[0], original[3]])
    try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
    precondition(table.selectedRowIndexes == IndexSet([0, 1]) && model.selection == [original[1], original[2]])
    for flags: NSEvent.ModifierFlags in [.command, .control, .option] { precondition(probe.observe(event("s", flags: flags)) != nil) }
    precondition(probe.observe(event("s", number: 0)) != nil)
    precondition(probe.observe(event("z")) != nil)
    model.busy = true; precondition(probe.observe(event("s")) != nil); model.busy = false
    model.options.preserveMerges = true; precondition(probe.observe(event("s")) != nil); model.options.preserveMerges = false
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 25)); host.addSubview(field)
    precondition(window.makeFirstResponder(field)); precondition(probe.observe(event("s")) != nil)
    precondition(!window.isVisible)
    print("Actual Rebase list interaction: contiguous/noncontiguous moves, boundary no-op, stable end moves, selection IDs, action cycles, P/S/Q/E/Space/Shift-U, table focus and modifier/window/busy/Preserve guards passed. Events injected; no displayed keyboard acceptance.")
}
@MainActor func verify() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let preference = "CherrypickAddCherryPickedFrom", saved = UserDefaults.standard.object(forKey: "CherrypickAddCherryPickedFrom")
    let savedSquashDate = UserDefaults.standard.object(forKey: "SquashDate")
    UserDefaults.standard.set(false, forKey: preference)
    defer {
        if let saved { UserDefaults.standard.set(saved, forKey: preference) } else { UserDefaults.standard.removeObject(forKey: preference) }
        if let savedSquashDate { UserDefaults.standard.set(savedSquashDate, forKey: "SquashDate") } else { UserDefaults.standard.removeObject(forKey: "SquashDate") }
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
    try await verifyListInteraction(repo, revisions: [merge.hash, parent.hash, side.hash, base.hash])

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
    let beforeEmpty = try await repo.rebaseCommit("HEAD")
    let emptyPatch = RebaseWindowModel(repository: repo, access: nil); emptyPatch.editorExecutable = model.editorExecutable
    emptyPatch.load(cherryPick: [side.hash]); try await settle(emptyPatch)
    emptyPatch.request("start")
    let emptyDeadline = Date().addingTimeInterval(30)
    while emptyPatch.busy && Date() < emptyDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!emptyPatch.busy && emptyPatch.error != nil && emptyPatch.active)
    precondition(emptyPatch.state?.conflicts.isEmpty == true && emptyPatch.state?.stoppedCommit == side.hash)
    precondition(emptyPatch.selection == [side.hash])
    emptyPatch.error = nil; emptyPatch.execute("skip"); try await settle(emptyPatch)
    precondition(emptyPatch.finished && !emptyPatch.active)
    let afterEmpty = try await repo.rebaseCommit("HEAD"); precondition(afterEmpty.hash == beforeEmpty.hash)
    print("Actual empty-patch recovery: already-applied change stops with original selected ID and no conflicts; native Skip finishes with target HEAD unchanged.")

    _ = try await repo.run(["checkout", "-b", "native-squash-source"])
    var squashCommits: [LogEntry] = []
    for (name, date) in [("one", "2001-01-01T01:02:03+02:00"), ("two", "2002-02-02T02:03:04-03:00")] {
        let path = "native-squash-" + name + ".txt"
        try Data(name.utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.run(["commit", "-m", "Squash " + name + "\n\n# literal source 雪"], environmentOverrides: ["GIT_AUTHOR_DATE": date, "GIT_AUTHOR_NAME": "Author " + name, "GIT_AUTHOR_EMAIL": name + "@example.invalid"])
        squashCommits.append(try await repo.rebaseCommit("HEAD"))
    }
    _ = try await repo.run(["checkout", "target"])
    UserDefaults.standard.set(1, forKey: "SquashDate")
    let squash = RebaseWindowModel(repository: repo, access: nil); squash.editorExecutable = model.editorExecutable
    squash.load(cherryPick: squashCommits.reversed().map(\.hash)); try await settle(squash)
    precondition(squash.plan?.options.squashDate == .latest)
    squash.setAction(.squash, ids: [squashCommits[1].hash]); squash.request("start"); try await settle(squash)
    precondition(squash.active && !squash.finished && squash.state?.squashMessage != nil && squash.tab == 1 && squash.error == nil)
    precondition(squash.amendMessage.contains("Squash one") && squash.amendMessage.contains("Squash two") && squash.amendMessage.contains("# literal source 雪"))
    precondition(squash.selection == [squashCommits[1].hash])
    let splitDateState = try await repo.beginRebaseSplit()
    let splitDateModel = CommitWindowModel(repository: repo, access: nil)
    splitDateModel.loadReplaySplit(splitDateState, message: squash.amendMessage); try await settleCommit(splitDateModel)
    let selectedDate = splitDateModel.authorDate
    splitDateModel.dateChanged(); try await Task.sleep(nanoseconds: 100_000_000)
    precondition(splitDateModel.authorDate == selectedDate && ISO8601DateFormatter().string(from: selectedDate) == ISO8601DateFormatter().string(from: ISO8601DateFormatter().date(from: squashCommits[1].date)!))
    try await repo.cancelUnstartedRebaseSplit()
    let squashReopened = RebaseWindowModel(repository: GitRepository(root: root, executable: git), access: nil)
    squashReopened.editorExecutable = model.editorExecutable; squashReopened.load(); try await settle(squashReopened)
    precondition(squashReopened.isCherryPick && squashReopened.tab == 1 && squashReopened.amendMessage == squash.amendMessage)
    let squashHost = NSHostingView(rootView: RebaseDialog(model: squashReopened)); squashHost.frame = NSRect(x: 0, y: 0, width: 1040, height: 720); squashHost.layoutSubtreeIfNeeded()
    func findEditor(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        return view.subviews.compactMap { findEditor($0) }.first
    }
    guard let editor = findEditor(squashHost) else { fatalError("Actual multiline squash editor unavailable") }
    precondition(editor.string == squashReopened.amendMessage)
    let approved = "Native combined 雪\n\n# literal approved\nDetails"
    squashReopened.amendMessage = approved; squashReopened.request("continue"); try await settle(squashReopened)
    precondition(squashReopened.finished && !squashReopened.active)
    let combined = try await repo.rebaseCommit("HEAD")
    precondition(combined.author == squashCommits[0].author && combined.email == squashCommits[0].email && combined.date == squashCommits[1].date)
    let approvedText = try await repo.run(["log", "-1", "--format=%B"]).text
    precondition(approvedText == approved + "\n")
    print("Actual native squash: Advanced SquashDate captured, editor pause without error alert, original selected identity, reopened Cherry Pick/multiline editor, exact Unicode/comment message approval, first author/latest date and Continue passed.")
    try await verifyNativeSplit(repo, editor: model.editorExecutable)
    try await verifyNativeRecoveryFiles(repo, editor: model.editorExecutable)



}
@main struct Receiver { @MainActor static func main() async throws { try await verify() } }
