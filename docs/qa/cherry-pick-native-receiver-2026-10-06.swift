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
    precondition(model.primaryActionTitle == "Commit")
    precondition(model.conflicts.map(\.path) == [path] && Set(model.conflictRows.map(\.path)) == [path, clean])
    let host = NSHostingView(rootView: RebaseConflictFiles(model: model)); host.frame = NSRect(x: 0, y: 0, width: 1000, height: 300); host.layoutSubtreeIfNeeded()
    guard let table = findTable(host) else { fatalError("Actual Conflict Files table unavailable") }
    precondition(table.numberOfRows == 2 && table.tableColumns.count == 6)
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
    precondition(reopened.checkedConflicts == [path, clean])
    var children: [CommitWindowModel] = []
    func installRecovery(_ owner: RebaseWindowModel) {
        owner.showSplitSelection = { [weak owner] continuation, text in
            guard let owner else { return }
            let child = CommitWindowModel(repository: repo, access: nil); children.append(child)
            var committed = false
            child.onCommitted = { _ in committed = true }
            child.close = { [weak owner] in owner?.splitSelectionClosed(committed: committed) }
            child.confirmCancel = { answer in answer(true) }; child.loadReplaySplit(continuation, message: text)
        }
    }
    installRecovery(reopened); reopened.checkedConflicts = [path]
    let oldHintPreference = UserDefaults.standard.object(forKey: "CommitMessageContainsConflictHint")
    defer { if let oldHintPreference { UserDefaults.standard.set(oldHintPreference, forKey: "CommitMessageContainsConflictHint") } else { UserDefaults.standard.removeObject(forKey: "CommitMessageContainsConflictHint") } }
    UserDefaults.standard.set(false, forKey: "CommitMessageContainsConflictHint")
    reopened.amendMessage = "Native checked recovery\n\n# Conflicts:\n#\tfile\n"
    var hints = 0; reopened.confirmConflictHints = { hints += 1; return false }
    let beforeHints = try await repo.rebaseCommit("HEAD"), beforeHintIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    reopened.request("continue"); try await settle(reopened)
    let afterHints = try await repo.rebaseCommit("HEAD"); precondition(hints == 1 && afterHints.hash == beforeHints.hash && children.isEmpty && reopened.tab == 1)
    let afterHintIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout; precondition(afterHintIndex == beforeHintIndex)
    reopened.confirmConflictHints = { hints += 1; return true }
    reopened.request("continue"); try await settle(reopened)
    precondition(hints == 2)
    let opening = Date().addingTimeInterval(30)
    while children.isEmpty && Date() < opening { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(children.count == 1 && reopened.selectingSplit)
    let partial = try await repo.rebaseCommit("HEAD"), partialFiles = try await repo.files(in: partial)
    precondition(partial.subject == "Native checked recovery" && partial.message.contains("# Conflicts:") && partialFiles.map(\.path) == [path])
    let first = children[0]; try await settleCommit(first)
    precondition(first.amend && !first.amendToParent && first.replaySplit?.conflictRecovery == true)
    first.cancel(); try await settle(reopened)
    let restored = RebaseWindowModel(repository: repo, access: nil); restored.editorExecutable = editor; installRecovery(restored)
    restored.load(); try await settle(restored); precondition(restored.state?.split?.conflictRecovery == true)
    restored.request("continue"); try await settle(restored)
    let nextOpening = Date().addingTimeInterval(30)
    while children.count < 2 && Date() < nextOpening { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(children.count == 2); let next = children[1]; try await settleCommit(next)
    next.stagingEnabled = false; next.checked = [clean]; next.message = "Native complete recovery"; next.commit()
    try await settleCommit(next); try await settle(restored)
    let closing = Date().addingTimeInterval(30)
    while restored.selectingSplit && Date() < closing { try await Task.sleep(nanoseconds: 10_000_000) }
    try await settle(restored); precondition(restored.active && restored.state?.isEditPause == true && restored.tab == 1)
    let beforeSplitCancel = try await repo.rebaseCommit("HEAD"), beforeSplitIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    restored.splitCommit = true; restored.request("continue"); try await settle(restored)
    precondition(children.count == 3 && restored.selectingSplit)
    let cancelledSplit = children[2]; try await settleCommit(cancelledSplit)
    precondition(cancelledSplit.amendToParent && cancelledSplit.replaySplit?.parts == 0 && cancelledSplit.replaySplit?.conflictRecoveryReturn != nil)
    cancelledSplit.cancel(); try await settle(restored)
    let afterSplitCancel = try await repo.rebaseCommit("HEAD"), afterSplitIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    precondition(afterSplitCancel.hash == beforeSplitCancel.hash && afterSplitIndex == beforeSplitIndex && restored.state?.isEditPause == true)
    let afterCancel = RebaseWindowModel(repository: repo, access: nil); afterCancel.editorExecutable = editor; afterCancel.load(); try await settle(afterCancel)
    precondition(afterCancel.state?.split?.conflictRecovery == true && afterCancel.state?.isEditPause == true && afterCancel.canSplit && !afterCancel.splitCommit)
    afterCancel.amendMessage = "Native recovery Edit approved"; afterCancel.request("continue"); try await settle(afterCancel)
    precondition(afterCancel.finished && !afterCancel.active && !afterCancel.fileRecovery)
    let complete = try await repo.rebaseCommit("HEAD"), completeFiles = try await repo.files(in: complete)
    precondition(complete.parents == partial.parents && Set(completeFiles.map(\.path)) == [path, clean] && complete.subject == "Native recovery Edit approved")
    let preserved = try await repo.rebaseCommit(destination.hash); precondition(preserved.subject == "recovery onto")
    let ancestor = try await repo.run(["merge-base", "--is-ancestor", base.hash, "HEAD"]); precondition(ancestor.exitCode == 0)
    print("Actual Conflict Files: six-column checkbox native table with conflicted/clean rows, original base diff, single Edit route, actual quick Resolve replayed-side semantics and refresh, resolved-row retention/reopening, Split blocked before application checked-file commit, unchecked retention, amendment sheet Cancel/reopening, applied Edit approval and final Continue passed. Conflict-hint Abort leaves HEAD/index and child selection unchanged; Ignore continues. Applied conflict Edit survives unstarted Split Cancel with unchanged HEAD/index and reopened multiline approval. Sheets/editor/confirmation routing injected.")
}
@MainActor func verifyNativeSquashConflict(_ repo: GitRepository, editor: URL?) async throws {
    let preference = UserDefaults.standard.object(forKey: "SquashDate")
    defer { if let preference { UserDefaults.standard.set(preference, forKey: "SquashDate") } else { UserDefaults.standard.removeObject(forKey: "SquashDate") } }
    for policy in [RebaseSquashDate.first, .latest, .current] {
        let tag = String(policy.rawValue), path = "squash conflict 雪 " + tag + "\n.txt", firstPath = "squash-first-" + tag + ".txt"
        try Data("base group\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "squash conflict base " + tag)
        _ = try await repo.run(["checkout", "-b", "native-squash-conflict-" + tag])
        try Data("first file\n".utf8).write(to: repo.root.appendingPathComponent(firstPath)); try await repo.stage([firstPath])
        _ = try await repo.run(["commit", "--author", "First Conflict <first@example.test>", "-m", "First conflict group\n\n# literal first"], environmentOverrides: ["GIT_AUTHOR_DATE": "2001-02-03T04:05:06+02:00"])
        let first = try await repo.rebaseCommit("HEAD")
        try Data("source conflict\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.run(["commit", "--author", "Last Conflict <last@example.test>", "-m", "Last conflict group\n\n# literal last"], environmentOverrides: ["GIT_AUTHOR_DATE": "2002-03-04T05:06:07-03:00"])
        let last = try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["checkout", "target"])
        try Data("destination conflict\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "squash destination " + tag)
        let destination = try await repo.rebaseCommit("HEAD")
        UserDefaults.standard.set(policy.rawValue, forKey: "SquashDate")
        let model = RebaseWindowModel(repository: repo, access: nil); model.editorExecutable = editor; model.confirmConflictHints = { true }
        model.load(cherryPick: [last.hash, first.hash]); try await settle(model); model.setAction(.squash, ids: [last.hash]); model.request("start")
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error != nil && model.state?.stoppedAction == .squash && model.fileRecovery && !model.canSplit && model.primaryActionTitle == "Continue")
        precondition(Set(model.conflictRows.map(\.path)) == [path, firstPath] && !model.supportsConflictSelection)
        model.error = nil
        let conflictHost = NSHostingView(rootView: RebaseDialog(model: model)); conflictHost.frame = NSRect(x: 0, y: 0, width: 1040, height: 720); conflictHost.layoutSubtreeIfNeeded(); precondition(conflictHost.fittingSize.width > 0)
        try Data("resolved group\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path])
        let recovered = RebaseWindowModel(repository: repo, access: nil); recovered.editorExecutable = editor; recovered.confirmConflictHints = { true }; recovered.load(); try await settle(recovered)
        precondition(recovered.primaryActionTitle == "Continue" && Set(recovered.conflictRows.map(\.path)) == [path, firstPath])
        recovered.request("continue"); try await settle(recovered)
        precondition(recovered.state?.squashMessage != nil && recovered.tab == 1 && recovered.primaryActionTitle == "Commit")
        precondition(recovered.amendMessage.contains("First conflict group") && recovered.amendMessage.contains("Last conflict group") && recovered.amendMessage.contains("# literal first") && recovered.amendMessage.contains("# literal last"))
        let approval = RebaseWindowModel(repository: repo, access: nil); approval.editorExecutable = editor; approval.confirmConflictHints = { true }; approval.load(); try await settle(approval)
        precondition(approval.primaryActionTitle == "Commit" && approval.state?.squashMessage?.datePolicy == policy)
        let host = NSHostingView(rootView: RebaseDialog(model: approval)); host.frame = NSRect(x: 0, y: 0, width: 1040, height: 720); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        let before = Date().addingTimeInterval(-2), approved = "Native resolved group " + tag + "\n\nUnicode 雪\n# retained approval\n"
        approval.amendMessage = approved; approval.request("continue"); try await settle(approval)
        precondition(approval.finished && approval.primaryActionTitle == "Done")
        let combined = try await repo.rebaseCommit("HEAD")
        precondition(combined.parents == [destination.hash] && combined.author == first.author && combined.email == first.email && combined.message == approved)
        if policy == .first { precondition(combined.date == first.date) }
        else if policy == .latest { precondition(combined.date == last.date) }
        else { precondition(ISO8601DateFormatter().date(from: combined.date)! >= before) }
        let paths = try await repo.files(in: combined); precondition(Set(paths.map(\.path)) == [path, firstPath])
    }
    print("Actual native Squash conflict: whole-group file list, Unicode/newline path, Continue/Commit/Done captions, staged resolution and repeated reopening, multiline/literal-comment approval, first author and first/latest/current dates passed. Hidden hosted views; prompt answers injected.")
}
@MainActor func verifyNativeEmptySquash(_ repo: GitRepository, editor: URL?, repeatedConflicts: Bool = false) async throws {
    _ = try await repo.run(["config", "rebase.updateRefs", "true"])
    let preference = UserDefaults.standard.object(forKey: "SquashDate")
    defer { if let preference { UserDefaults.standard.set(preference, forKey: "SquashDate") } else { UserDefaults.standard.removeObject(forKey: "SquashDate") } }
    for (variant, choice) in [("commit", RebaseEmptyChoice.commit), ("skip", .skip), ("cancel", .cancel)] {
        let name = (repeatedConflicts ? "repeated-" : "") + variant
        let path = "empty squash 雪 " + name + "\n.txt", firstPath = "empty-first-" + name + ".txt", futurePath = "empty-future-" + name + ".txt"
        try Data("base empty\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "empty base " + name)
        _ = try await repo.run(["checkout", "-b", "native-empty-squash-" + name])
        try Data("first empty group\n".utf8).write(to: repo.root.appendingPathComponent(firstPath)); try await repo.stage([firstPath])
        _ = try await repo.run(["commit", "--author", "Empty First <first@example.test>", "-m", "First empty group"], environmentOverrides: ["GIT_AUTHOR_DATE": "2001-02-03T04:05:06+02:00"])
        let first = try await repo.rebaseCommit("HEAD")
        if !repeatedConflicts { _ = try await repo.run(["rm", "--", firstPath]) }; try Data("source empty conflict\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.run(["commit", "--author", "Empty Last <last@example.test>", "-m", "Last empty group"], environmentOverrides: ["GIT_AUTHOR_DATE": "2002-03-04T05:06:07-03:00"])
        let middle = try await repo.rebaseCommit("HEAD")
        var last = middle
        if repeatedConflicts {
            _ = try await repo.run(["rm", "--", firstPath]); try Data("third source conflict\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path])
            _ = try await repo.run(["commit", "--author", "Third Conflict <third@example.test>", "-m", "Third empty group\n\n# literal third"], environmentOverrides: ["GIT_AUTHOR_DATE": "2003-04-05T06:07:08+05:30"])
            last = try await repo.rebaseCommit("HEAD")
        }
        try Data("future after group\n".utf8).write(to: repo.root.appendingPathComponent(futurePath)); try await repo.stage([futurePath]); _ = try await repo.commit(message: "Future after " + name)
        let future = try await repo.rebaseCommit("HEAD"); _ = try await repo.run(["checkout", "target"])
        try Data("destination empty conflict\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "empty destination " + name)
        let destination = try await repo.rebaseCommit("HEAD")
        UserDefaults.standard.set(1, forKey: "SquashDate")
        let model = RebaseWindowModel(repository: repo, access: nil); model.editorExecutable = editor; model.confirmConflictHints = { true }
        model.load(cherryPick: repeatedConflicts ? [future.hash, last.hash, middle.hash, first.hash] : [future.hash, last.hash, first.hash]); try await settle(model); model.setAction(.squash, ids: repeatedConflicts ? [middle.hash, last.hash] : [last.hash]); model.request("start")
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error != nil && model.state?.stoppedAction == .squash); model.error = nil
        try Data("destination empty conflict\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path]); model.refreshState(); try await settle(model)
        model.request("continue")
        if repeatedConflicts {
            let secondDeadline = Date().addingTimeInterval(30)
            while model.busy && Date() < secondDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(!model.busy && model.error != nil)
            precondition(model.state?.squashMessage == nil && model.state?.stoppedEntryID == last.hash && model.state?.conflicts == [path] && model.primaryActionTitle == "Continue" && !model.canSplit)
            model.error = nil
            let second = RebaseWindowModel(repository: repo, access: nil); second.editorExecutable = editor; second.confirmConflictHints = { true }; second.load(); try await settle(second)
            precondition(second.state?.stoppedEntryID == last.hash && second.fileRecovery && !second.supportsConflictSelection)
            try Data("destination empty conflict\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path]); second.refreshState(); try await settle(second)
            second.request("continue"); try await settle(second); precondition(second.state?.squashMessage != nil && second.primaryActionTitle == "Commit")
        } else { try await settle(model); precondition(model.state?.squashMessage != nil && model.primaryActionTitle == "Commit") }
        let approval = RebaseWindowModel(repository: repo, access: nil); approval.editorExecutable = editor; approval.confirmConflictHints = { true }; approval.load(); try await settle(approval)
        if repeatedConflicts {
            for text in ["First empty group", "Last empty group", "Third empty group", "# literal third"] { precondition(approval.amendMessage.contains(text)) }
            precondition(approval.state?.squashMessage?.latestDate == last.date)
        }
        let lock = repo.root.appendingPathComponent(".git/index.lock")
        defer { try? FileManager.default.removeItem(at: lock) }
        var prompts = 0; approval.chooseEmptyResult = {
            prompts += 1
            if choice == .skip { try! Data().write(to: lock) }
            return choice
        }
        let before = try await repo.rebaseCommit("HEAD"), index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        approval.amendMessage = "Native approved empty " + name; approval.request("continue"); try await settle(approval)
        precondition(prompts == 1)
        if choice == .cancel {
            let after = try await repo.rebaseCommit("HEAD"), currentIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
            precondition(approval.active && approval.tab == 1 && approval.amendMessage == "Native approved empty " + name && after.hash == before.hash && currentIndex == index)
            approval.chooseEmptyResult = { prompts += 1; return .commit }; approval.request("continue"); try await settle(approval); precondition(prompts == 2)
        }
        var completed = approval
        if choice == .skip {
            precondition(approval.active && approval.state?.squashMessage?.skipBaseHead == destination.hash && approval.primaryActionTitle == "Continue" && !approval.canSplit)
            try FileManager.default.removeItem(at: lock)
            let retry = RebaseWindowModel(repository: repo, access: nil); retry.editorExecutable = editor; retry.load(); try await settle(retry)
            precondition(retry.primaryActionTitle == "Continue" && retry.state?.squashMessage?.skipBaseHead == destination.hash)
            retry.chooseEmptyResult = { preconditionFailure("Approved Skip must not ask again") }
            retry.request("continue"); try await settle(retry); completed = retry
        }
        precondition(completed.finished && !completed.active)
        let head = try await repo.rebaseCommit("HEAD"), parent = try await repo.rebaseCommit("HEAD^")
        precondition(head.subject == "Future after " + name)
        if choice == .skip { precondition(head.parents == [destination.hash]) }
        else {
            let files = try await repo.files(in: parent)
            precondition(files.isEmpty && parent.parents == [destination.hash] && parent.subject == "Native approved empty " + name && parent.author == first.author && parent.date == last.date)
        }
        precondition(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(firstPath).path))
        let source = try await repo.rebaseCommit("native-empty-squash-" + name); precondition(source.hash == future.hash, "Cherry Pick must not update source branches")
    }
    _ = try await repo.run(["config", "--unset", "rebase.updateRefs"])
    print((repeatedConflicts ? "Actual native repeated Squash conflicts: two conflict stops/reopening, retained middle message and final date; " : "Actual native empty Squash groups: ") + "reopened Commit/Skip/Cancel choices, Cancel retains message/HEAD/index, Commit keeps message-only group with first author/latest date, Skip drops entire group, index-lock failure reopens and retries approved Skip without another prompt, future replay follows the correct parent. Answers injected.")
}
@MainActor func verifyNativeSquashReferenceUpdates(_ repo: GitRepository, editor: URL?) async throws {
    let help = try await repo.run(["rebase", "-h"], successfulExitCodes: 0...129).text
    guard help.contains("update-refs") else { print("Native Rebase reference updates: Git runtime does not advertise update-refs; feature check skipped."); return }
    let preference = UserDefaults.standard.object(forKey: "SquashDate")
    defer { if let preference { UserDefaults.standard.set(preference, forKey: "SquashDate") } else { UserDefaults.standard.removeObject(forKey: "SquashDate") } }
    UserDefaults.standard.set(1, forKey: "SquashDate")
    for (name, choice) in [("commit", RebaseEmptyChoice.commit), ("skip", .skip)] {
        let stem = "native-reference-" + name, path = stem + " 雪\n.txt", firstPath = stem + "-first.txt", prefixPath = stem + "-prefix.txt", futurePath = stem + "-future.txt"
        try Data("reference base\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: stem + " base")
        _ = try await repo.run(["checkout", "-b", stem])
        try Data("prefix\n".utf8).write(to: repo.root.appendingPathComponent(prefixPath)); try await repo.stage([prefixPath]); _ = try await repo.commit(message: stem + " prefix")
        _ = try await repo.run(["branch", stem + "-prefix-ref", "HEAD"])
        try Data("first\n".utf8).write(to: repo.root.appendingPathComponent(firstPath)); try await repo.stage([firstPath]); _ = try await repo.run(["commit", "--author", "Reference First <first@example.test>", "-m", stem + " first"], environmentOverrides: ["GIT_AUTHOR_DATE": "2001-02-03T04:05:06+02:00"])
        let first = try await repo.rebaseCommit("HEAD"); _ = try await repo.run(["branch", stem + "-first-ref", first.hash])
        _ = try await repo.run(["rm", "--", firstPath]); try Data("source reference\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.run(["commit", "--author", "Reference Last <last@example.test>", "-m", stem + " last"], environmentOverrides: ["GIT_AUTHOR_DATE": "2002-03-04T05:06:07-03:00"])
        let last = try await repo.rebaseCommit("HEAD"); _ = try await repo.run(["branch", stem + "-last-ref", last.hash])
        try Data("future\n".utf8).write(to: repo.root.appendingPathComponent(futurePath)); try await repo.stage([futurePath]); _ = try await repo.commit(message: stem + " future")
        _ = try await repo.run(["branch", stem + "-future-ref", "HEAD"]); _ = try await repo.run(["checkout", "target"])
        try Data("destination reference\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: stem + " destination")
        let destination = try await repo.rebaseCommit("HEAD"); _ = try await repo.run(["checkout", stem]); _ = try await repo.run(["config", "rebase.updateRefs", "true"]); _ = try await repo.run(["config", "rebase.abbreviateCommands", choice == .skip ? "true" : "false"])
        let model = RebaseWindowModel(repository: repo, access: nil); model.editorExecutable = editor; model.confirmConflictHints = { true }; model.load(upstream: "target"); try await settle(model)
        model.setAction(.squash, ids: [last.hash]); model.request("start"); precondition(model.confirmation != nil); model.confirmation = nil; model.execute("start")
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error != nil && model.state?.currentStep == 3 && model.state?.total == 4 && model.state?.stoppedEntryID == last.hash); model.error = nil
        try Data("destination reference\n".utf8).write(to: repo.root.appendingPathComponent(path)); try await repo.stage([path]); model.refreshState(); try await settle(model)
        model.request("continue"); try await settle(model); precondition(model.state?.squashMessage?.latestDate == last.date)
        let reopened = RebaseWindowModel(repository: repo, access: nil); reopened.editorExecutable = editor; reopened.confirmConflictHints = { true }; reopened.load(); try await settle(reopened)
        precondition(reopened.primaryActionTitle == "Commit" && reopened.state?.currentStep == 3)
        let host = NSHostingView(rootView: RebaseDialog(model: reopened)); host.frame = NSRect(x: 0, y: 0, width: 1040, height: 720); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        reopened.amendMessage = stem + " approved"; reopened.chooseEmptyResult = { choice }; reopened.request("continue"); try await settle(reopened); precondition(reopened.finished)
        let prefix = try await repo.rebaseCommit(stem + "-prefix-ref"), groupFirst = try await repo.rebaseCommit(stem + "-first-ref"), groupLast = try await repo.rebaseCommit(stem + "-last-ref"), future = try await repo.rebaseCommit(stem + "-future-ref"), head = try await repo.rebaseCommit("HEAD")
        precondition(prefix.parents == [destination.hash] && groupFirst.hash == groupLast.hash && future.hash == head.hash && future.parents == [groupLast.hash])
        if choice == .skip { precondition(groupLast.hash == prefix.hash) }
        else { precondition(groupLast.parents == [prefix.hash] && groupLast.author == first.author && groupLast.date == last.date) }
        _ = try await repo.run(["config", "--unset", "rebase.updateRefs"]); _ = try await repo.run(["config", "--unset", "rebase.abbreviateCommands"]); _ = try await repo.run(["checkout", "target"])
    }
    print("Actual native Rebase reference updates: prefix/group/future branch refs preserved through custom plan, correct commit-step identity despite update-ref commands, reopened empty-group Commit/Skip and first author/latest date passed. Prompts injected.")
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
    if ProcessInfo.processInfo.environment["TURTLEGIT_NATIVE_REFERENCE_ONLY"] == "1" { try await verifyNativeSquashReferenceUpdates(repo, editor: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TurtleGitMac")); return }
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
    var emptyPrompts = 0; emptyPatch.chooseEmptyResult = { emptyPrompts += 1; return .cancel }
    emptyPatch.load(cherryPick: [side.hash]); try await settle(emptyPatch)
    emptyPatch.request("start")
    let emptyDeadline = Date().addingTimeInterval(30)
    while emptyPatch.busy && Date() < emptyDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!emptyPatch.busy && emptyPatch.error == nil && emptyPatch.active && emptyPrompts == 1)
    precondition(emptyPatch.state?.conflicts.isEmpty == true && emptyPatch.state?.stoppedCommit == side.hash)
    precondition(emptyPatch.selection == [side.hash])
    emptyPatch.chooseEmptyResult = { emptyPrompts += 1; return .skip }; emptyPatch.request("continue"); try await settle(emptyPatch)
    precondition(emptyPatch.finished && !emptyPatch.active)
    let afterEmpty = try await repo.rebaseCommit("HEAD"); precondition(afterEmpty.hash == beforeEmpty.hash)
    precondition(emptyPrompts == 2)
    let keepEmpty = RebaseWindowModel(repository: repo, access: nil); keepEmpty.editorExecutable = model.editorExecutable
    var keepPrompts = 0; keepEmpty.chooseEmptyResult = { keepPrompts += 1; return .commit }
    keepEmpty.load(cherryPick: [side.hash]); try await settle(keepEmpty); keepEmpty.request("start"); try await settle(keepEmpty)
    precondition(keepEmpty.finished && !keepEmpty.active && keepPrompts == 1)
    let keptEmpty = try await repo.rebaseCommit("HEAD"), keptFiles = try await repo.files(in: keptEmpty)
    precondition(keptEmpty.parents == [beforeEmpty.hash] && keptFiles.isEmpty && keptEmpty.author == side.author && keptEmpty.date == side.date)
    print("Actual empty-patch choices: automatic Commit/Skip/Cancel receiver, Cancel leaves HEAD unchanged and replay recoverable, Skip retains target HEAD, Commit keeps empty source message/author/date and finishes. Prompt answers injected.")

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
    try await verifyNativeSquashConflict(repo, editor: model.editorExecutable)
    try await verifyNativeEmptySquash(repo, editor: model.editorExecutable)
    try await verifyNativeEmptySquash(repo, editor: model.editorExecutable, repeatedConflicts: true)
    try await verifyNativeSquashReferenceUpdates(repo, editor: model.editorExecutable)



}
@main struct Receiver { @MainActor static func main() async throws { try await verify() } }
