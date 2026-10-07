import AppKit
import SwiftUI
import Combine
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
@MainActor func verifyNativeRepeatedAndOmittedReferences(_ repo: GitRepository, editor: URL?) async throws {
    let help = try await repo.run(["rebase", "-h"], successfulExitCodes: 0...129).text
    guard help.contains("update-refs") else { print("Native repeated/omitted references: Git runtime lacks update-refs; feature check skipped."); return }
    _ = try await repo.run(["checkout", "-b", "native-repeat-reference-source"])
    let firstPath = "native-reference-original 雪\n.txt", secondPath = "native-reference-second.txt"
    try Data("first reference\n".utf8).write(to: repo.root.appendingPathComponent(firstPath)); try await repo.stage([firstPath]); _ = try await repo.commit(message: "Native original first")
    let first = try await repo.rebaseCommit("HEAD"); _ = try await repo.run(["branch", "native-repeat-first-ref", first.hash])
    try Data("second reference\n".utf8).write(to: repo.root.appendingPathComponent(secondPath)); try await repo.stage([secondPath]); _ = try await repo.commit(message: "Native original second")
    let second = try await repo.rebaseCommit("HEAD"); _ = try await repo.run(["branch", "native-repeat-second-ref", second.hash]); _ = try await repo.run(["config", "rebase.updateRefs", "true"])
    let model = RebaseWindowModel(repository: repo, access: nil); model.editorExecutable = editor; model.load(upstream: "target"); try await settle(model)
    model.addCommits([first.hash]); try await settle(model)
    let duplicate = first.hash + ":1"; precondition(Set(model.entries.map(\.id)) == [first.hash, second.hash, duplicate])
    model.setAction(.skip, ids: [duplicate]); model.selection = [duplicate]; model.move(up: false, toEnd: true)
    model.setAction(.edit, ids: [first.hash]); model.selection = [first.hash]; model.move(up: true, toEnd: true)
    precondition(model.plan?.entries.map(\.id) == [duplicate, second.hash, first.hash])
    model.request("start"); precondition(model.confirmation != nil); model.confirmation = nil; model.execute("start"); try await settle(model)
    precondition(model.state?.isEditPause == true && model.state?.currentStep == 3 && model.state?.stoppedEntryID == first.hash)
    let reopened = RebaseWindowModel(repository: repo, access: nil); reopened.editorExecutable = editor; reopened.load(); try await settle(reopened)
    precondition(reopened.selection == [first.hash] && reopened.state?.stoppedEntryID == first.hash)
    reopened.amendMessage = "Native approved original occurrence"; reopened.request("continue"); try await settle(reopened); precondition(reopened.finished)
    let head = try await repo.rebaseCommit("HEAD"), parent = try await repo.rebaseCommit("HEAD^"), firstRef = try await repo.rebaseCommit("native-repeat-first-ref"), secondRef = try await repo.rebaseCommit("native-repeat-second-ref")
    precondition(firstRef.hash == head.hash && secondRef.hash == parent.hash && head.subject == "Native approved original occurrence" && parent.subject == "Native original second")
    _ = try await repo.run(["config", "--unset", "rebase.updateRefs"]); _ = try await repo.run(["checkout", "target"])
    let equivalentPath = "native-equivalent-reference.txt", retainedPath = "native-retained-reference.txt"
    _ = try await repo.run(["checkout", "-b", "native-omitted-reference-source"])
    try Data("equivalent native\n".utf8).write(to: repo.root.appendingPathComponent(equivalentPath)); try await repo.stage([equivalentPath]); _ = try await repo.commit(message: "Native source equivalent")
    let equivalent = try await repo.rebaseCommit("HEAD"); _ = try await repo.run(["branch", "native-equivalent-ref", equivalent.hash])
    try Data("retained native\n".utf8).write(to: repo.root.appendingPathComponent(retainedPath)); try await repo.stage([retainedPath]); _ = try await repo.commit(message: "Native retained source")
    let retained = try await repo.rebaseCommit("HEAD"); _ = try await repo.run(["branch", "native-retained-ref", retained.hash]); _ = try await repo.run(["checkout", "target"])
    _ = try await repo.run(["cherry-pick", "--no-commit", equivalent.hash]); _ = try await repo.commit(message: "Native upstream equivalent identity")
    let destination = try await repo.rebaseCommit("HEAD"); _ = try await repo.run(["checkout", "native-omitted-reference-source"]); _ = try await repo.run(["config", "rebase.updateRefs", "true"])
    let omitted = RebaseWindowModel(repository: repo, access: nil); omitted.editorExecutable = editor; omitted.load(upstream: "target"); try await settle(omitted)
    precondition(omitted.plan?.entries.first?.action == .skip); omitted.setAction(.edit, ids: [retained.hash]); omitted.request("start"); precondition(omitted.confirmation != nil); omitted.confirmation = nil; omitted.execute("start"); try await settle(omitted)
    precondition(omitted.state?.isEditPause == true && omitted.state?.currentStep == 2 && omitted.state?.stoppedEntryID == retained.hash && omitted.output.contains("skipped previously applied commit"))
    let approval = RebaseWindowModel(repository: repo, access: nil); approval.editorExecutable = editor; approval.load(); try await settle(approval); approval.amendMessage = "Native approved retained source"; approval.request("continue"); try await settle(approval); precondition(approval.finished)
    let completed = try await repo.rebaseCommit("HEAD"), omittedRef = try await repo.rebaseCommit("native-equivalent-ref"), retainedRef = try await repo.rebaseCommit("native-retained-ref")
    precondition(completed.parents == [destination.hash] && retainedRef.hash == completed.hash && omittedRef.hash == equivalent.hash)
    _ = try await repo.run(["config", "--unset", "rebase.updateRefs"]); _ = try await repo.run(["checkout", "target"])
    print("Actual native repeated/omitted references: Add duplicate IDs, Skip and end moves, original occurrence Edit/reopening, original ref associations, omitted patch-equivalent ref unchanged and retained ref updated passed. Prompts injected.")
}
@MainActor func verifyLogIntegration(_ repo: GitRepository, revisions: [LogEntry], editor: URL) async throws {
    let log = LogWindowModel(repository: repo, access: nil); log.entries = revisions; log.graph = CommitGraph.layout(revisions); log.selected = [revisions[0].hash]; log.currentBranch = "target"
    log.bare = try await repo.isBare(); log.currentBranch = try await repo.branch()
    var merges: [String] = [], rebases: [String] = []
    log.onMergeRevision = { merges.append($0) }; log.onRebaseRevision = { rebases.append($0) }
    func wait() async throws {
        let deadline = Date().addingTimeInterval(30)
        while log.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!log.busy)
    }
    let head = try await repo.rebaseCommit("HEAD"), index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    _ = try await repo.run(["tag", "integration-tag", revisions[0].hash])
    var historyOptions = HistoryOptions(); historyOptions.allBranches = true
    let referenceRows = try await repo.history(options: historyOptions)
    log.entries[0].references = referenceRows.first { $0.hash == revisions[0].hash }!.references.sorted { $0.name.hasPrefix("refs/tags/") && !$1.name.hasPrefix("refs/tags/") }
    let host = NSHostingView(rootView: RevisionTable(model: log)); host.frame = NSRect(x: 0, y: 0, width: 1040, height: 300); host.layoutSubtreeIfNeeded()
    guard let table = findTable(host), let coordinator = table.delegate as? RevisionTable.Coordinator, let menu = table.menu else { fatalError("Integration menu unavailable") }
    coordinator.menuNeedsUpdate(menu)
    for title in [log.integrationTitle(.merge), log.integrationTitle(.rebase)] { guard let item = menu.items.first(where: { $0.title == title }) else { fatalError("Missing integration menu: \(title), available=\(log.integrationAvailable), bare=\(log.bare)") }; precondition(item.isEnabled && item.image != nil) }
    var exports: [String] = []
    log.onExportRevision = { exports.append($0) }; coordinator.menuNeedsUpdate(menu)
    guard let exportItem = menu.items.first(where: { $0.title == "Export this version…" }) else { fatalError("Export menu missing") }
    precondition(exportItem.isEnabled && exportItem.image != nil)
    coordinator.exportRevision(); precondition(exports == ["refs/tags/integration-tag"])
    log.busy = true; coordinator.exportRevision(); precondition(exports.count == 1); log.busy = false
    let exportModel = ExportWindowModel(repository: repo, access: nil)
    func settleExport() async throws {
        let deadline = Date().addingTimeInterval(30)
        while exportModel.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!exportModel.busy && exportModel.error == nil)
    }
    exportModel.load(revision: exports[0]); try await settleExport()
    precondition(exportModel.target == .tag && exportModel.revision == exports[0] && exportModel.wholeProject)
    let archive = repo.root.appendingPathComponent("native-export.zip")
    exportModel.destination = archive.path; exportModel.export(); try await settleExport()
    precondition(exportModel.exported == archive && FileManager.default.fileExists(atPath: archive.path))
    let originalArchive = try Data(contentsOf: archive)
    exportModel.confirmOverwrite = { _ in false }; exportModel.export(); try await settleExport()
    let keptArchive = try Data(contentsOf: archive)
    precondition(exportModel.exported == nil && keptArchive == originalArchive)
    exportModel.load(revision: revisions.last!.hash); try await settleExport(); precondition(exportModel.target == .commit)
    exportModel.confirmOverwrite = { _ in true }; exportModel.export(); try await settleExport()
    precondition(exportModel.exported == archive)
    try FileManager.default.removeItem(at: archive)
    let archiveIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    precondition(archiveIndex == index)
    precondition(ExportWindowModel.directoryScope(root: repo.root, paths: ["."]) == "")
    precondition(ExportWindowModel.directoryScope(root: repo.root, paths: []) == "")
    precondition(ExportWindowModel.directoryScope(root: repo.root, paths: ["missing"]) == "")
    let scopeDirectory = "native-export-directory 雪"
    try FileManager.default.createDirectory(at: repo.root.appendingPathComponent(scopeDirectory), withIntermediateDirectories: false)
    precondition(ExportWindowModel.directoryScope(root: repo.root, paths: [scopeDirectory]) == scopeDirectory)
    precondition(ExportWindowModel.directoryScope(root: repo.root, paths: [scopeDirectory, "."]) == "")
    try FileManager.default.removeItem(at: repo.root.appendingPathComponent(scopeDirectory))
    let controller = ExportWindowController(repository: repo, access: nil, revision: "HEAD")
    let controllerDeadline = Date().addingTimeInterval(30)
    while controller.model.busy && Date() < controllerDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!controller.model.busy && controller.model.error == nil && controller.model.target == .head)
    guard let exportWindow = controller.window else { fatalError("Export window missing") }
    exportWindow.contentView?.layoutSubtreeIfNeeded()
    precondition(!exportWindow.isVisible && !controller.activeOperation && controller.windowShouldClose(exportWindow))
    controller.model.busy = true; precondition(controller.activeOperation && !controller.windowShouldClose(exportWindow)); controller.model.busy = false
    controller.model.load(revision: "refs/heads/main")
    let branchDeadline = Date().addingTimeInterval(30)
    while controller.model.busy && Date() < branchDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!controller.model.busy && controller.model.error == nil && controller.model.target == .branch)
    var exportClosed = false; controller.onClosed = { exportClosed = true }; controller.close()
    precondition(exportClosed)
    print("Native Export controller: hidden real dialog, HEAD/Branch presets, root/subdirectory scope normalization, busy-close guard and owned-window cleanup passed.")
    print("Native Log Export icon/handoff, tag/hash presets, ZIP creation and overwrite Cancel/Replace passed.")
    coordinator.mergeRevision(); try await wait(); precondition(log.error == nil && merges == ["refs/tags/integration-tag"])
    coordinator.rebaseRevision(); try await wait(); precondition(log.error == nil && rebases == ["main"])
    let mergeModel = MergeWindowModel(repository: repo, access: nil); mergeModel.load(revision: merges[0])
    let mergeDeadline = Date().addingTimeInterval(30); while mergeModel.busy && Date() < mergeDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!mergeModel.busy && mergeModel.error == nil && mergeModel.target == .tag && mergeModel.revision == merges[0])
    for (preset, target) in [("refs/heads/main", CheckoutTarget.branch), (revisions.last!.hash, .commit)] {
        mergeModel.load(revision: preset)
        let deadline = Date().addingTimeInterval(30); while mergeModel.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!mergeModel.busy && mergeModel.error == nil && mergeModel.target == target && mergeModel.revision == preset)
    }

    _ = try await repo.run(["update-ref", "refs/tags/integration-tag", revisions.last!.hash])
    coordinator.mergeRevision(); try await wait(); precondition(merges.last == "refs/heads/main")
    log.selected = [revisions.last!.hash]; log.requestIntegration(.rebase); try await wait(); precondition(rebases.last == revisions.last!.hash)
    log.selected = [revisions[0].hash, revisions[2].hash]; precondition(!log.integrationAvailable)
    log.selected = [revisions[0].hash]; log.entries[0].isHead = true; precondition(!log.integrationAvailable); log.entries[0].isHead = false
    log.bare = true; precondition(!log.canIntegrate(.merge)); log.bare = false
    log.mergeActive = true; precondition(!log.canIntegrate(.rebase)); log.mergeActive = false
    _ = try await repo.run(["update-ref", "refs/stash", revisions[0].hash])
    let stashRows = try await repo.history(options: historyOptions)
    log.entries[0].references = stashRows.first { $0.hash == revisions[0].hash }!.references
    precondition(!log.integrationAvailable); log.entries[0].references = []
    _ = try await repo.run(["update-ref", "-d", "refs/stash"])
    let count = merges.count; log.requestIntegration(.merge); log.selected = [revisions[2].hash]; try await wait(); precondition(merges.count == count)
    log.selected = [head.hash]; log.requestIntegration(.merge); try await wait(); precondition(log.error?.contains("already HEAD") == true && merges.count == count); log.error = nil
    _ = try await repo.run(["merge", "--no-commit", "--no-ff", "side"])
    log.selected = [revisions[0].hash]; log.requestIntegration(.rebase); try await wait(); precondition(log.error?.contains("active Merge or Rebase") == true); log.error = nil
    _ = try await repo.run(["merge", "--abort"])
    var plan = try await repo.cherryPickPlan(revisions: [revisions[2].hash]); plan.entries[0].action = .edit
    let paused = try await repo.startRebase(plan, editorExecutable: editor, fromLog: true); precondition(paused.state.active)
    log.requestIntegration(.merge); try await wait(); precondition(log.error?.contains("active Merge or Rebase") == true); log.error = nil
    let recovered = RebaseWindowModel(repository: repo, access: nil); recovered.load(); try await settle(recovered)
    precondition(!recovered.completionFromLog) // Cherry Pick origin is deliberately not a normal Log Rebase.
    _ = try await repo.abortRebase()
    var settings = RebaseOptions(); settings.branch = "target"; settings.upstream = "side"
    var normal = try await repo.rebasePlan(settings); precondition(!normal.entries.isEmpty, "Normal Log-origin fixture has no replay entries"); normal.entries[0].action = .edit
    let logPause = try await repo.startRebase(normal, editorExecutable: editor, fromLog: true); precondition(logPause.state.active)
    let logOrigin = RebaseWindowModel(repository: repo, access: nil); logOrigin.editorExecutable = editor; logOrigin.load(); try await settle(logOrigin)
    precondition(logOrigin.completionFromLog && !logOrigin.completionAfterFetch)
    logOrigin.execute("continue"); try await settle(logOrigin)
    precondition(logOrigin.finished && logOrigin.completedSuccessfully && logOrigin.completionActions.isEmpty)
    _ = try await repo.run(["reset", "--hard", head.hash])
    let after = try await repo.rebaseCommit("HEAD"), afterIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    precondition(after.hash == head.hash && afterIndex == index)
    _ = try await repo.run(["tag", "-d", "integration-tag"])
    print("Actual native Log integration: original menu titles/icons/selectors, Merge/tag and Rebase/local-branch presets, moved-ref and hash fallback, native Merge model preset, stale/multiple/HEAD/stash/bare/busy-state guards, fresh active Merge/Rebase rejection and unchanged HEAD/index passed. Handoffs injected.")
}

@MainActor func verifyNativeRebaseMenus(_ repo: GitRepository, editor: URL?, revisions: [LogEntry]) async throws {
    let model = RebaseWindowModel(repository: repo, access: nil); model.editorExecutable = editor; model.load(cherryPick: revisions.map(\.hash)); try await settle(model)
    let log = model.revisionMenuLog, one = Set([revisions[0].hash]), pair = Set([revisions[1].hash, revisions[2].hash])
    let board = NSPasteboard(name: .init("org.turtlegit.qa.rebase." + UUID().uuidString)); log.clipboard = board; defer { board.releaseGlobally() }
    var compared: [(ComparisonRevision, ComparisonRevision)] = [], routed: [String] = [], patch: FormatPatchPreset?, diff: Data?, alternate = false, noteChanged = false
    log.onCompare = { compared.append(($0, $1)) }; model.onShowRevisionLog = { routed.append("log " + $0) }; log.onBrowseRepository = { routed.append("browse " + $0) }
    log.onCreateReference = { routed.append(($0 ? "tag " : "branch ") + $1) }; log.onPush = { routed.append("push " + $0) }; log.onFormatPatch = { patch = $0 }
    log.onUnifiedDiff = { diff = $0; alternate = $1 }; log.onRevisionChanged = { _ in noteChanged = true }
    for command in RebaseRevisionCommand.allCases { precondition(command.icon.contextImage() != nil) }
    let excluded = ["Reset current branch to this…", "Switch/Checkout to this…", "Revert change by this commit", "Cherry Pick this commit…"]
    precondition(!RebaseRevisionCommand.allCases.contains { excluded.contains($0.rawValue) })
    let host = NSHostingView(rootView: RebaseDialog(model: model)); host.frame = NSRect(x: 0, y: 0, width: 1040, height: 720); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
    for command in [RebaseRevisionCommand.log, .browse, .branch, .tag, .push] { model.performRevisionMenu(command, ids: one) }
    precondition(routed == ["log ", "browse ", "branch ", "tag ", "push "].map { $0 + revisions[0].hash })
    model.performRevisionMenu(.compare, ids: one); precondition(compared.last?.0 == .revision(revisions[0].parents[0]) && compared.last?.1 == .revision(revisions[0].hash))
    model.performRevisionMenu(.workingTree, ids: one); precondition(compared.last?.0 == .revision(revisions[0].hash) && compared.last?.1 == .workingTree)
    model.performRevisionMenu(.compare, ids: pair); precondition(compared.last?.0 == .revision(revisions[2].hash) && compared.last?.1 == .revision(revisions[1].hash))
    precondition(!model.canPerformRevisionMenu(.workingTree, ids: pair) && !model.canPerformRevisionMenu(.branch, ids: pair))
    log.bare = true; precondition(!model.canPerformRevisionMenu(.workingTree, ids: one)); log.bare = false
    let root = revisions.last!, rootID = Set([root.hash])
    model.performRevisionMenu(.compare, ids: rootID); precondition(compared.last?.0 == .emptyTree && compared.last?.1 == .revision(root.hash))
    model.performRevisionMenu(.unified, ids: rootID, alternate: true)
    let diffDeadline = Date().addingTimeInterval(30)
    while log.busy && Date() < diffDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!log.busy && log.error == nil && alternate && String(decoding: diff!, as: UTF8.self).contains("base.txt"))
    for (command, expected) in [(RebaseRevisionCommand.hashes, root.hash), (.authors, root.author + " <" + root.email + ">"), (.authorNames, root.author), (.authorEmails, root.email), (.subjects, root.subject), (.messages, root.message)] {
        model.performRevisionMenu(command, ids: rootID); precondition(board.string(forType: .string) == expected)
    }
    model.performRevisionMenu(.details, ids: rootID)
    let clipboardDeadline = Date().addingTimeInterval(30)
    while log.copyingDetails && Date() < clipboardDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!log.copyingDetails && log.error == nil && board.string(forType: .string)!.contains("base.txt"))
    let before = try await repo.rebaseCommit("HEAD"), index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    model.performRevisionMenu(.notes, ids: rootID)
    let noteDeadline = Date().addingTimeInterval(30)
    while log.loadingNote && Date() < noteDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!log.loadingNote && log.error == nil && log.noteRequest != nil)
    log.noteText = "Native Rebase menu note 雪"; log.saveNote()
    let saveDeadline = Date().addingTimeInterval(30)
    while log.savingNote && Date() < saveDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    let stored = try await repo.editableCommitNote(revision: root.hash), after = try await repo.rebaseCommit("HEAD"), afterIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    precondition(log.noteError == nil && log.noteRequest == nil && noteChanged && stored.text.contains("Native Rebase menu note 雪") && after.hash == before.hash && afterIndex == index)
    for exact in ["\n # literal note 雪  \n\n", ""] {
        _ = try await repo.saveCommitNote(stored, text: exact)
        let reloaded = try await repo.editableCommitNote(revision: root.hash)
        precondition(reloaded.text == exact)
    }
    let routeCount = routed.count; model.busy = true; model.performRevisionMenu(.branch, ids: one); precondition(routed.count == routeCount); model.busy = false
    model.performRevisionMenu(.branch, ids: ["missing-row"]); precondition(routed.count == routeCount)
    log.busy = true; precondition(!model.canPerformRevisionMenu(.hashes, ids: one)); log.busy = false
    let noncontiguous = Set([revisions[0].hash, revisions[2].hash, revisions[3].hash]); precondition(model.revisionMenuPatchPreset(noncontiguous) == nil)
    let contiguous = Set(revisions.prefix(3).map(\.hash)); model.performRevisionMenu(.patch, ids: contiguous)
    precondition(patch?.selection == .range(from: revisions[2].hash + "~1", to: revisions[0].hash))
    model.addCommits([root.hash]); try await settle(model)
    let duplicate = Set([root.hash, root.hash + ":1"]); precondition(model.revisionMenuRows(duplicate).count == 2)
    model.performRevisionMenu(.compare, ids: duplicate); precondition(compared.last?.0 == .revision(root.hash) && compared.last?.1 == .revision(root.hash))
    model.performRevisionMenu(.hashes, ids: duplicate); precondition(board.string(forType: .string) == root.hash + "\n" + root.hash)
    _ = try await repo.run(["checkout", "main"]); _ = try await repo.run(["commit", "--allow-empty", "-m", "Native menu active Edit"])
    let edit = try await repo.rebaseCommit("HEAD"); _ = try await repo.run(["checkout", "target"])
    let active = RebaseWindowModel(repository: repo, access: nil); active.editorExecutable = editor; active.load(cherryPick: [edit.hash]); try await settle(active); active.setAction(.edit, ids: [edit.hash]); active.request("start"); try await settle(active)
    active.revisionMenuLog.onCompare = { compared.append(($0, $1)) }
    precondition(active.active && !active.editable && active.canPerformRevisionMenu(.compare, ids: [edit.hash]))
    active.performRevisionMenu(.compare, ids: [edit.hash]); precondition(compared.last?.1 == .revision(edit.hash)); active.execute("abort"); try await settle(active)
    let progress = RebaseWindowModel(repository: repo, access: nil); progress.editorExecutable = editor
    progress.load(cherryPick: [edit.hash]); try await settle(progress)
    progress.addCommits([edit.hash, edit.hash]); try await settle(progress)
    let progressIDs = progress.plan!.entries.map(\.id)
    progress.setAction(.skip, ids: [progressIDs[1]]); progress.setAction(.edit, ids: [progressIDs[2]])
    progress.request("start"); try await settle(progress)
    precondition(progress.active && progress.replayRows.map(\.id) == progressIDs)
    precondition(progress.replayRows.map(\.progress) == [.completed, .completed, .current])
    precondition(progress.replayRows.map(\.action) == [.pick, .skip, .edit])
    let reopened = RebaseWindowModel(repository: repo, access: nil); reopened.editorExecutable = editor
    reopened.load(); try await settle(reopened)
    precondition(reopened.entries.map(\.id) == progressIDs.reversed().map { $0 })
    precondition(reopened.replayRows.map(\.progress) == [.completed, .completed, .current])
    precondition(reopened.replayRows.map { reopened.entryNumber($0) } == [1, 2, 3])
    reopened.revisionMenuLog.clipboard = board; reopened.performRevisionMenu(.hashes, ids: [progressIDs[0]])
    precondition(board.string(forType: .string) == edit.hash)
    let progressHost = NSHostingView(rootView: RebaseDialog(model: reopened)); progressHost.frame = NSRect(x: 0, y: 0, width: 1040, height: 720)
    precondition(progressHost.fittingSize.width > 0)
    reopened.execute("continue"); try await settle(reopened)
    precondition(reopened.finished && !reopened.active && reopened.entries.count == 3)
    precondition(reopened.replayRows.allSatisfy { $0.progress == .completed })
    let skipLast = RebaseWindowModel(repository: repo, access: nil); skipLast.editorExecutable = editor
    skipLast.load(cherryPick: [edit.hash]); try await settle(skipLast); skipLast.setAction(.edit, ids: [edit.hash])
    skipLast.execute("start"); try await settle(skipLast); precondition(skipLast.active)
    skipLast.execute("skip"); try await settle(skipLast)
    precondition(skipLast.finished && skipLast.entries.count == 1 && skipLast.entries[0].action == .skip && skipLast.entries[0].progress == .completed)
    let completed = RebaseWindowModel(repository: repo, access: nil); completed.editorExecutable = editor
    var completionRoutes: [String] = [], completionClosed = 0, mailPreset: FormatPatchPreset?
    completed.close = { completionClosed += 1 }
    completed.onCompletedLog = { completionRoutes.append("log") }
    completed.onCompletedPush = { completionRoutes.append("push:" + $0) }
    completed.onCompletedMail = { mailPreset = $0; completionRoutes.append("mail") }
    completed.load(upstream: "main"); try await settle(completed)
    precondition(completed.completionActions.isEmpty && !completed.canPerformCompletionAction(.log))
    completed.execute("start"); try await settle(completed)
    precondition(completed.finished && completed.completedSuccessfully && completed.completionActions == [.log, .restart])
    let completionHead = try await repo.rebaseCommit("HEAD"), completionIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    completed.performCompletionAction(.log); precondition(completionRoutes == ["log"] && completionClosed == 1)
    completed.completionAfterFetch = true
    precondition(completed.completionActions == [.log, .push, .mail, .rebase])
    completed.busy = true; completed.performCompletionAction(.push); precondition(completionRoutes.count == 1); completed.busy = false
    completed.performCompletionAction(.push); precondition(completionRoutes.last == "push:HEAD" && completionClosed == 2)
    completed.performCompletionAction(.mail); precondition(completionRoutes.last == "mail" && completionClosed == 3)
    precondition(mailPreset?.selection == .range(from: completed.options.upstream, to: completed.options.branch))
    let patchController = FormatPatchWindowController(repository: repo, access: nil, preset: mailPreset, sendMail: true)
    precondition(patchController.model.sendMail && patchController.model.mode == .from)
    let patchDeadline = Date().addingTimeInterval(30)
    while patchController.model.busy && Date() < patchDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    patchController.close()
    let completionAfter = try await repo.rebaseCommit("HEAD"), completionAfterIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    precondition(completionAfter.hash == completionHead.hash && completionAfterIndex == completionIndex)
    for action in RebaseCompletionAction.allCases { precondition(action.icon.contextImage() != nil) }
    completed.completedSuccessfully = false; completed.performCompletionAction(.mail); precondition(completionRoutes.count == 3 && completed.completionActions.isEmpty)
    completed.completedSuccessfully = true; completed.performCompletionAction(.rebase); try await settle(completed)
    precondition(!completed.finished && !completed.completedSuccessfully && completed.options.upstream == "main")
    completed.finished = true; completed.completedSuccessfully = true; completed.completionAfterFetch = false
    completed.performCompletionAction(.restart); try await settle(completed)
    precondition(!completed.finished && !completed.completedSuccessfully)
    precondition(skipLast.completionActions.isEmpty) // Cherry Pick does not add upstream's Rebase-only buttons.
    _ = try await repo.run(["commit", "--allow-empty", "-m", "Native completion context recovery"])
    let contextCommit = try await repo.rebaseCommit("HEAD")
    let contextModel = RebaseWindowModel(repository: repo, access: nil); contextModel.editorExecutable = editor
    contextModel.completionAfterFetch = true; contextModel.completionAutoStart = true
    contextModel.load(upstream: "main"); try await settle(contextModel)
    contextModel.ontoEnabled = true; contextModel.options.onto = "main"; contextModel.options.force = true; contextModel.reloadPlan(); try await settle(contextModel)
    let contextPlanDeadline = Date().addingTimeInterval(30)
    while contextModel.plan == nil && Date() < contextPlanDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(contextModel.plan != nil && contextModel.canStart, contextModel.error ?? "Context fixture plan did not load")
    contextModel.setAction(.edit, ids: [contextCommit.hash]); let originalOptions = contextModel.options
    contextModel.execute("start"); try await settle(contextModel)
    precondition(contextModel.active && contextModel.state?.session?.afterFetch == true, "Context fixture active=\(contextModel.active), origin=\(String(describing: contextModel.state?.session?.afterFetch)), canStart=\(contextModel.canStart), error=\(String(describing: contextModel.error)), output=\(contextModel.output), entries=\(String(describing: contextModel.plan?.entries.map { $0.action.rawValue }))")
    let restored = RebaseWindowModel(repository: GitRepository(root: repo.root, executable: repo.executable), access: nil); restored.editorExecutable = editor
    restored.load(); try await settle(restored)
    precondition(restored.active && restored.completionAfterFetch && restored.completionAutoStart && restored.ontoEnabled && restored.options.force)
    precondition(restored.options.branch == originalOptions.branch && restored.options.upstream == "main" && restored.options.onto == "main")
    restored.execute("continue"); try await settle(restored)
    precondition(restored.finished && restored.completionActions == [.log, .push, .mail, .rebase])
    restored.performCompletionAction(.rebase); try await settle(restored)
    precondition(restored.options.upstream == "main" && restored.completionAfterFetch && restored.completionAutoStart && !restored.finished)
    print("Actual native session context: after-Fetch/auto-start, branch/upstream/onto, reopened Edit, successful completion commands and restarted chooser recovered from Git metadata passed.")
    print("Actual native Rebase completion: successful direct/after-Fetch commands, busy/unsuccessful/Cherry Pick guards, Log/Push/mail range handoffs, close ordering, mail-enabled native Format Patch controller, unchanged HEAD/index and restart/reset passed. Hidden views/windows; no mail sent.")
    print("Actual native replay rows: completed/current/pending occurrences, Pick/Skip/Edit actions, reopened ordering/numbering, completed-row clipboard inspection and finished retained list passed. Hidden hosted view.")
    print("Actual native Rebase row commands: original icons/allowed command policy, single/root/merge/two/duplicate revision comparisons, unified diff data and alternate handoff, Log/Browse/Branch/Tag/Push/Format Patch handoffs, isolated clipboard recipes/details, notes save/refresh without HEAD/index changes, busy/stale/bare guards, active Edit inspection and Abort passed. Hidden views; dialog/viewer handoffs injected.")
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
@MainActor func verifyNativeLogParentWorkingComparison(executable: URL) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-log-parent-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = GitRepository(root: root, executable: executable)
    _ = try await repo.run(["init", "--initial-branch=main"])
    _ = try await repo.run(["config", "user.name", "Native QA"]); _ = try await repo.run(["config", "user.email", "native@example.invalid"])
    _ = try await repo.run(["config", "commit.gpgSign", "false"])
    let old = "old 雪\n.txt", new = "new 雪\n.txt"
    let renameBytes = Data((0..<30).map { "rename line \($0)\n" }.joined().utf8)
    try renameBytes.write(to: root.appendingPathComponent(old))
    try Data("base\n".utf8).write(to: root.appendingPathComponent("keep"))
    try Data("removed\n".utf8).write(to: root.appendingPathComponent("deleted"))
    try await repo.stage([old, "keep", "deleted"]); _ = try await repo.commit(message: "A parent subject longer than twenty three characters")
    let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    _ = try await repo.run(["branch", "side"])
    _ = try await repo.run(["mv", "--", old, new]); _ = try await repo.run(["rm", "--", "deleted"])
    try Data("committed change\n".utf8).write(to: root.appendingPathComponent("keep"))
    try await repo.stage(["keep"]); _ = try await repo.commit(message: "rename delete modify")
    let changed = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    let workingBytes = Data([0xff, 13, 10]); try workingBytes.write(to: root.appendingPathComponent("keep"))
    let log = LogWindowModel(repository: repo, access: nil); defer { log.invalidate() }
    log.clipboard = NSPasteboard(name: NSPasteboard.Name("TurtleGit-parent-groups-" + UUID().uuidString))
    defer { log.clipboard.releaseGlobally() }
    func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition())
    }
    log.reload(); try await until { !log.busy }; log.select([changed])
    try await until { log.files.count == 3 && log.parentMetadata[changed] != nil }
    precondition(log.fileParentComparisonTitle(Set(log.files.map(\.id)))?.contains("A parent subject lon...") == true && log.fileParentComparisonTitle(Set(log.files.map(\.id)))?.contains(String(base.prefix(8))) == true)
    var requests: [(ComparisonRevision, ComparisonRevision, [String])] = []
    log.onFileCompare = { requests.append(($0, $1, $2)) }
    let ids = Set([new, "keep", "deleted"])
    let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    precondition(log.canCompareFilesWithParent(ids)); log.compareFiles(ids, parentWorkingTree: true)
    let request = requests.last!; precondition(request.0 == .revision(base) && request.1 == .workingTree && Set(request.2) == ids)
    let snapshot = try await repo.revisionFileComparison(from: request.0, to: request.1, paths: request.2)
    let kept = try await repo.comparisonFile(snapshot, path: "keep")
    let renamed = try await repo.comparisonFile(snapshot, path: new)
    let deleted = try await repo.comparisonFile(snapshot, path: "deleted")
    precondition(kept.base.bytes == Data("base\n".utf8) && kept.destination.bytes == workingBytes)
    precondition(renamed.base.bytes == renameBytes && renamed.destination.bytes == renameBytes && snapshot.files.contains { $0.path == new && $0.oldPath == old })
    precondition(deleted.base.bytes == Data("removed\n".utf8) && deleted.destination.bytes.isEmpty)
    let unchangedIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    let unchangedHead = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    precondition(unchangedIndex == index && unchangedHead == changed)
    let count = requests.count
    log.busy = true; log.compareFiles(ids, parentWorkingTree: true); log.busy = false
    log.bare = true; log.compareFiles(ids, parentWorkingTree: true); log.bare = false
    log.compareFiles(["absent"], parentWorkingTree: true)
    log.select([base]); precondition(log.fileParentComparisonTitle(Set(log.files.map(\.id))) == nil); log.compareFiles(ids, parentWorkingTree: true)
    log.select([""]); precondition(log.fileParentComparisonTitle(Set(log.files.map(\.id))) == nil); log.compareFiles(ids, parentWorkingTree: true)
    log.selected = [base, changed]; log.compareFiles(ids, parentWorkingTree: true)
    precondition(requests.count == count)
    // A real merge retains the parent corresponding to the currently listed first-parent files.
    _ = try await repo.run(["restore", "--", "keep"]); _ = try await repo.run(["switch", "side"])
    try Data("side\n".utf8).write(to: root.appendingPathComponent("side-file"))
    try await repo.stage(["side-file"]); _ = try await repo.commit(message: "side")
    _ = try await repo.run(["switch", "main"]); _ = try await repo.run(["merge", "--no-ff", "side", "-m", "merge side"])
    let merge = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    log.reload(); try await until { !log.busy }; log.select([merge])
    try await until { log.files.contains { $0.path == "side-file" } && log.parentMetadata[merge]?.count == 2 }
    let sideIDs = Set(log.files.filter { $0.path == "side-file" }.map(\.id))
    log.compareFiles(sideIDs, parentWorkingTree: true); precondition(requests.last?.0 == .revision(changed))
    precondition(log.fileTableRows.filter { $0.header != nil }.count == 2)
    let secondParentDeleted = log.files.first { $0.path == "deleted" && $0.parentIndex == 1 }!
    let secondParentKept = log.files.first { $0.path == "keep" && $0.parentIndex == 1 }!
    let pair = try await repo.historicalFilePairComparison(revision: merge, files: [secondParentDeleted, secondParentKept])
    let pairDocument = try await repo.comparisonFile(pair, path: "keep")
    precondition(pair.from == .revision(log.revision!.parents[1]) && pairDocument.base.bytes == Data("removed\n".utf8))
    // Build a second real merge with the same modified path in both parent groups.
    _ = try await repo.run(["branch", "duplicate-side"])
    try Data("left\n".utf8).write(to: root.appendingPathComponent("keep")); try await repo.stage(["keep"]); _ = try await repo.commit(message: "left")
    let left = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    _ = try await repo.run(["switch", "duplicate-side"])
    try Data("right\n".utf8).write(to: root.appendingPathComponent("keep")); try await repo.stage(["keep"]); _ = try await repo.commit(message: "right")
    let right = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    _ = try await repo.run(["switch", "main"]); _ = try await repo.run(["merge", "--no-ff", "duplicate-side", "-m", "duplicates"], successfulExitCodes: 0...1)
    try Data("merged\n".utf8).write(to: root.appendingPathComponent("keep")); try await repo.stage(["keep"]); _ = try await repo.commit(message: "resolved duplicates")
    let duplicateMerge = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    log.reload(); try await until { !log.busy }; log.select([duplicateMerge])
    try await until { log.files.count == 2 && log.parentMetadata[duplicateMerge]?.count == 2 }
    let duplicates = Set(log.files.map(\.id)); precondition(duplicates.count == 2 && log.files.allSatisfy { $0.path == "keep" })
    precondition(log.fileTableRows.count == 4 && log.fileTableRows.filter { $0.header != nil }.count == 2)
    log.fileTableSelection.wrappedValue = Set(log.fileTableRows.map(\.id)); precondition(log.selectedFiles == duplicates)
    log.filterPaths = "missing"; precondition(log.fileTableRows.isEmpty); log.filterPaths = ""
    let rightID = log.files.first { $0.parentIndex == 1 }!.id
    precondition(log.fileParentComparisonTitle([rightID])?.contains(String(right.prefix(8))) == true)
    var batches: [[(ComparisonRevision, ComparisonRevision, [String])]] = []
    log.onFileComparisons = { batches.append($0) }
    log.compareFiles(duplicates); precondition(batches.last!.map { $0.0 } == [.revision(left), .revision(right)] && batches.last!.allSatisfy { $0.1 == .revision(duplicateMerge) && $0.2 == ["keep"] })
    log.compareFiles(duplicates, parentWorkingTree: true); precondition(batches.last!.allSatisfy { $0.1 == .workingTree })
    for request in batches.first! {
        let snapshot = try await repo.revisionFileComparison(from: request.0, to: request.1, paths: request.2)
        let document = try await repo.comparisonFile(snapshot, path: "keep")
        precondition(document.base.bytes == Data((request.0 == .revision(left) ? "left\n" : "right\n").utf8) && document.destination.bytes == Data("merged\n".utf8))
    }
    precondition(!log.canCompareFilePair(duplicates))
    var patch = Data(); log.onUnifiedDiff = { patch = $0; _ = $1 }
    log.selectedFileDiff(duplicates); try await until { !log.busy }
    let text = String(decoding: patch, as: UTF8.self)
    precondition(text.contains("-left") && text.contains("-right") && text.components(separatedBy: "+merged").count == 3)
    log.copyFiles(duplicates, information: .relativePaths); precondition(log.clipboard.string(forType: .string) == "keep\nkeep")
    let mergeCount = batches.count; log.invalidate(); log.compareFiles(duplicates, parentWorkingTree: true)
    precondition(!log.canCompareFilesWithParent(duplicates) && batches.count == mergeCount)
    print("Native grouped merge file list: duplicate occurrence identities, two headers, nonselectable headers/filtering, parent-specific menu title, batch base/working comparison bytes, duplicate unified patches, raw clipboard paths and parent-2 deleted pair passed. Root viewer callback injected; no windows shown.")
    print("Native Log parent-working comparison: parent subject/hash title, pinned first-parent routing, real renamed/deleted/raw working bytes via root comparison engine, unchanged HEAD/index, root/working/multi/empty/busy/bare/invalidated refusal and real merge first-parent mapping passed. Root viewer handoff injected; no windows shown.")
}

@MainActor func verifyNativeLogUnifiedViewerRouting(executable: URL) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-log-viewer-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = GitRepository(root: root, executable: executable)
    _ = try await repo.run(["init", "--initial-branch=main"])
    _ = try await repo.run(["config", "user.name", "Native QA"]); _ = try await repo.run(["config", "user.email", "native@example.invalid"])
    _ = try await repo.run(["config", "commit.gpgSign", "false"])
    let path = "viewer 雪\n.txt"
    try Data("committed\n".utf8).write(to: root.appendingPathComponent(path))
    try await repo.stage([path]); _ = try await repo.commit(message: "initial")
    let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    try Data("changed\n".utf8).write(to: root.appendingPathComponent(path))
    let log = LogWindowModel(repository: repo, access: nil); defer { log.invalidate() }
    func wait() async throws {
        let deadline = Date().addingTimeInterval(30)
        while log.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!log.busy)
    }
    log.reload(); try await wait(); log.select([""])
    let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    let saved = UnifiedDiffViewerPreferences.load(); defer { saved.save() }
    // Invalid configuration exercises the real selection path without opening an application.
    let invalid = UnifiedDiffViewerPreferences(enabled: true, applicationPath: "invalid viewer")
    invalid.save(); log.diff(); try await wait()
    precondition(log.error == UnifiedDiffViewerFailure.application.localizedDescription && log.unifiedWindow == nil && UnifiedDiffApplication.activeRequests == 0)
    log.error = nil
    UnifiedDiffViewerPreferences(enabled: false, applicationPath: "invalid viewer").save()
    log.diff(alternate: true); try await wait()
    precondition(log.error == UnifiedDiffViewerFailure.application.localizedDescription && log.unifiedWindow == nil)
    log.error = nil; invalid.save()
    let useExternal = try await UnifiedDiffApplication.openExternal(Data(), alternate: true)
    precondition(!useExternal) // Shift inverts enabled external selection to built-in.
    var handoffs = 0, patch = Data(), alternate = false
    log.onUnifiedDiff = { patch = $0; alternate = $1; handoffs += 1 }
    log.diff(path: path, alternate: true); try await wait()
    let expected = try await repo.run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", head, "--", path]).stdout
    precondition(handoffs == 1 && alternate && patch == expected)
    // Change selection before the asynchronous Git read resumes: all routes drop stale handoffs.
    let before = handoffs
    log.diff(); log.selected = [head]; try await wait(); precondition(handoffs == before)
    log.diff(); log.selected = [""]; try await wait(); precondition(handoffs == before)
    log.selectedFileDiff([path]); log.selected = [head]; try await wait(); precondition(handoffs == before)
    log.select([""]); log.diff(); log.invalidate(); try await wait()
    precondition(log.isInvalidated && handoffs == before && log.error == nil && log.unifiedWindow == nil)
    log.diff(); log.selectedFileDiff([path]); precondition(!log.busy && handoffs == before)
    let finalIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
    let finalHead = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    let finalBytes = try Data(contentsOf: root.appendingPathComponent(path))
    precondition(finalIndex == index && finalHead == head && finalBytes == Data("changed\n".utf8))
    print("Native Log unified viewer routing: whole working-tree external selection and disabled+Shift validation, enabled+Shift built-in choice, exact literal-path patch and alternate handoff, stale working/revision/selected-file reads and invalidated-model refusal passed. Invalid viewer path prevents application launch; successful viewer handoff injected; HEAD/index/working bytes preserved.")
}

@MainActor func verifyNativeLogDeferredRefresh(executable: URL) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-log-refresh-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = GitRepository(root: root, executable: executable)
    _ = try await repo.run(["init", "--initial-branch=main"])
    _ = try await repo.run(["config", "user.name", "Native QA"]); _ = try await repo.run(["config", "user.email", "native@example.invalid"])
    _ = try await repo.run(["config", "commit.gpgSign", "false"])
    func commit(_ value: String) async throws -> String {
        try Data((value + "\n").utf8).write(to: root.appendingPathComponent("file"))
        try await repo.stage(["file"]); _ = try await repo.commit(message: value)
        return try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    }
    let initial = try await commit("initial")
    let log = LogWindowModel(repository: repo, access: nil); defer { log.invalidate() }
    func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition())
    }
    log.reload(); try await until { !log.busy && log.entries.contains { $0.hash == initial } }; log.select([""])
    var starts = 0
    let subscription = log.$busy.dropFirst().sink { if $0 { starts += 1 } }; defer { subscription.cancel() }
    var gate: CheckedContinuation<Void, Never>?
    log.onUnifiedDiff = { _, _ in await withCheckedContinuation { gate = $0 } }
    defer { gate?.resume() }
    func release() { let pending = gate; gate = nil; pending?.resume() }
    log.diff(); try await until { log.busy && gate != nil }
    let updated = try await commit("updated while viewer handoff waits")
    for _ in 0..<5 { log.requestRepositoryRefresh() }
    precondition(starts == 1 && log.busy && !log.entries.contains { $0.hash == updated })
    release(); try await until { !log.busy && log.entries.contains { $0.hash == updated } }
    precondition(starts == 2 && log.error == nil)
    let beforeIdle = starts
    for _ in 0..<5 { log.requestRepositoryRefresh() }
    try await until { starts > beforeIdle && !log.busy }; precondition(starts == beforeIdle + 1)
    // A direct user reload consumes an already queued repository refresh.
    let manualHead = try await commit("manual reload consumes pending")
    let beforeManual = starts
    log.requestRepositoryRefresh(); log.reload()
    try await until { !log.busy && log.entries.contains { $0.hash == manualHead } }
    precondition(starts == beforeManual + 1)
    // Closing before the deferred task starts cancels that task.
    let beforeClose = starts
    log.requestRepositoryRefresh(); log.invalidate()
    try await Task.sleep(nanoseconds: 20_000_000)
    precondition(log.isInvalidated && starts == beforeClose && !log.busy)
    log.reload(); try await until { !log.busy }; log.select([""])
    // Closing with a real operation held also clears its deferred refresh.
    log.diff(); try await until { log.busy && gate != nil }
    let afterClosed = try await commit("closed model must not revive")
    log.requestRepositoryRefresh(); let beforeHeldClose = starts; log.invalidate(); release()
    try await until { !log.busy }; try await Task.sleep(nanoseconds: 20_000_000)
    precondition(log.isInvalidated && starts == beforeHeldClose && !log.entries.contains { $0.hash == afterClosed })
    print("Native deferred Log refresh: real unified-diff handoff held while HEAD advances, busy and idle notifications coalesce to one reload, latest HEAD appears after release, direct reload consumes queued work, close cancels queued and busy refresh without reviving retained model passed. Handoff gate injected; no windows shown.")
}

@MainActor func verifyNativeLogWorkingConflicts(executable: URL) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-log-conflict-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = GitRepository(root: root, executable: executable)
    _ = try await repo.run(["init", "--initial-branch=main"])
    _ = try await repo.run(["config", "user.name", "Native QA"]); _ = try await repo.run(["config", "user.email", "native@example.invalid"])
    _ = try await repo.run(["config", "commit.gpgSign", "false"])
    let first = "-conflict 雪\n[*].txt", second = "second.txt", normal = "normal.txt"
    for path in [first, second, normal] { try Data("base\n".utf8).write(to: root.appendingPathComponent(path)) }
    try await repo.stage([first, second, normal]); _ = try await repo.commit(message: "base")
    _ = try await repo.run(["checkout", "-b", "side"])
    for path in [first, second] { try Data("theirs\n".utf8).write(to: root.appendingPathComponent(path)) }
    try await repo.stage([first, second]); _ = try await repo.commit(message: "theirs")
    _ = try await repo.run(["checkout", "main"])
    for path in [first, second] { try Data("mine\n".utf8).write(to: root.appendingPathComponent(path)) }
    try await repo.stage([first, second]); _ = try await repo.commit(message: "mine")
    let head = try await repo.run(["rev-parse", "HEAD"]).stdout
    let log = LogWindowModel(repository: repo, access: nil); defer { log.invalidate() }
    var requests: [(RepositoryAction, [String])] = [], comparisons: [[String]] = []
    log.onConflictAction = { requests.append(($0, $1)) }; log.onFileCompare = { _, _, paths in comparisons.append(paths) }
    func waitLog() async throws {
        let deadline = Date().addingTimeInterval(30)
        while log.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!log.busy)
    }
    func refreshLog() async throws { log.reload(); try await waitLog(); precondition(log.error == nil); log.select([""]) }
    for action in [RepositoryAction.editConflict, .resolveCurrent, .resolveMine, .resolveTheirs] { precondition(action.icon.contextImage() != nil) }
    for choice in [ResolveChoice.current, .mine, .theirs] {
        _ = try await repo.run(["reset", "--hard", "main"])
        let merge = try await repo.run(["merge", "--no-edit", "side"], successfulExitCodes: 0...1); precondition(merge.exitCode == 1)
        try Data("unrelated index\n".utf8).write(to: root.appendingPathComponent(normal)); try await repo.stage([normal])
        try Data("unrelated working\n".utf8).write(to: root.appendingPathComponent(normal))
        try await refreshLog(); precondition(log.workingConflictPaths([first, second, normal]).count == 2 && !log.conflictRebase)
        let initialFiles = log.files, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let otherIndex = try await repo.run(["ls-files", "--stage", "-z", "--", normal]).stdout
        precondition(log.canWorkingConflict(.editConflict, ids: [first]) && !log.canWorkingConflict(.editConflict, ids: [first, second]))
        log.primaryFileAction([first]); try await waitLog(); precondition(requests.last?.0 == .editConflict && requests.last?.1 == [first])
        if choice == .current {
            let editor = TextConflictWindowController(repository: repo, access: nil, path: first)
            var editorClosed = false; editor.onClosed = { editorClosed = true }; defer { if !editorClosed { editor.close() } }
            editor.model.load()
            let deadline = Date().addingTimeInterval(30)
            while editor.model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(!editor.model.busy && editor.model.error == nil && editor.model.document?.entry.path == first && editor.window?.isVisible == false)
            editor.close(); precondition(editorClosed)
        }
        log.primaryFileAction([normal]); precondition(comparisons.last == [normal])
        for action in [RepositoryAction.resolveCurrent, .resolveMine, .resolveTheirs] {
            log.requestWorkingConflict(action, ids: [first, normal]); try await waitLog(); precondition(requests.last?.0 == action && requests.last?.1 == [first])
        }
        log.requestWorkingConflict(.resolveCurrent, ids: [first, second]); try await waitLog(); precondition(Set(requests.last!.1) == Set([first, second]))
        let requestCount = requests.count
        log.busy = true; log.requestWorkingConflict(.editConflict, ids: [first]); precondition(requests.count == requestCount); log.busy = false
        log.requestWorkingConflict(.editConflict, ids: [first]); log.selected = [String(decoding: head, as: UTF8.self).trimmingCharacters(in: .newlines)]; try await waitLog(); precondition(requests.count == requestCount)
        log.select([""]); log.invalidate(); log.requestWorkingConflict(.resolveCurrent, ids: [first]); precondition(requests.count == requestCount)
        try await refreshLog()
        log.bare = true; log.requestWorkingConflict(.resolveMine, ids: [first]); precondition(requests.count == requestCount); log.bare = false
        let marker = root.appendingPathComponent(".git/rebase-merge")
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        log.requestWorkingConflict(.resolveMine, ids: [first]); try await waitLog(); precondition(log.error != nil && requests.count == requestCount)
        try FileManager.default.removeItem(at: marker); log.error = nil
        let guardedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")); precondition(guardedIndex == index)
        if choice == .current { try Data("selected current\n".utf8).write(to: root.appendingPathComponent(first)) }
        let action: RepositoryAction = choice == .current ? .resolveCurrent : choice == .mine ? .resolveMine : .resolveTheirs
        log.requestWorkingConflict(action, ids: [first, normal]); try await waitLog(); precondition(requests.last?.0 == action && requests.last?.1 == [first])
        let resolver = ResolveWindowModel(repository: repo, access: nil, paths: requests.last!.1, quick: action.resolveChoice)
        var confirmation: (ResolveChoice, [ConflictEntry])?
        resolver.confirm = { confirmation = ($0, $1) }; resolver.onChanged = { _ in log.reload() }
        resolver.load(); let deadline = Date().addingTimeInterval(30)
        while resolver.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(resolver.error == nil && confirmation?.0 == choice && confirmation?.1.map(\.path) == [first])
        resolver.apply(confirmation!.1, using: confirmation!.0)
        let applyDeadline = Date().addingTimeInterval(30)
        while resolver.busy && Date() < applyDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try await waitLog(); precondition(!resolver.busy && resolver.error == nil && log.files.first { $0.path == first }?.action != "U")
        let expected = choice == .current ? "selected current\n" : choice == .mine ? "mine\n" : "theirs\n"
        let saved = try Data(contentsOf: root.appendingPathComponent(first)); precondition(saved == Data(expected.utf8))
        let otherAfter = try await repo.run(["ls-files", "--stage", "-z", "--", normal]).stdout, headAfter = try await repo.run(["rev-parse", "HEAD"]).stdout
        let normalAfter = try Data(contentsOf: root.appendingPathComponent(normal)), remaining = try await repo.conflicts()
        precondition(otherAfter == otherIndex && headAfter == head && normalAfter == Data("unrelated working\n".utf8) && remaining.map(\.path) == [second])
        log.files = initialFiles; let staleCount = requests.count
        log.requestWorkingConflict(.resolveCurrent, ids: [first]); try await waitLog(); precondition(log.error != nil && requests.count == staleCount); log.error = nil
    }
    _ = try await repo.run(["reset", "--hard", "main"])
    let rebase = try await repo.run(["rebase", "side"], successfulExitCodes: 0...1); precondition(rebase.exitCode == 1)
    try await refreshLog(); precondition(log.conflictRebase && log.canWorkingConflict(.resolveTheirs, ids: [first]))
    log.requestWorkingConflict(.resolveMine, ids: [first]); try await waitLog(); precondition(requests.last?.0 == .resolveMine)
    let resolver = ResolveWindowModel(repository: repo, access: nil, paths: [first], quick: .mine)
    var rebaseEntries: [ConflictEntry] = []; resolver.confirm = { choice, entries in precondition(choice == .mine); rebaseEntries = entries }
    resolver.load(); let deadline = Date().addingTimeInterval(30)
    while resolver.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(resolver.rebase && !rebaseEntries.isEmpty)
    resolver.apply(rebaseEntries, using: .mine); let applyDeadline = Date().addingTimeInterval(30)
    while resolver.busy && Date() < applyDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    let rebasedBytes = try Data(contentsOf: root.appendingPathComponent(first)); precondition(resolver.error == nil && rebasedBytes == Data("theirs\n".utf8))
    _ = try await repo.run(["rebase", "--abort"])
    print("Native Log working conflicts: single primary Edit and hidden text editor, mixed/multi Resolve callbacks with original icons, fresh-stage and rebase-caption checks, busy/bare/selection/invalidation refusal, real Current/Mine/Theirs resolutions preserving unrelated index/work bytes and HEAD, injected completion Log refresh, stale resolved refusal and real rebase stage-2 mapping passed. Root dispatch/confirmations injected; owned editor closed.")
}

@MainActor func verifyNativeBisect(executable: URL) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitBisectNative-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = GitRepository(root: root, executable: executable)
    _ = try await repo.run(["init", "-b", "main"])
    _ = try await repo.run(["config", "user.name", "Bisect Native QA"])
    _ = try await repo.run(["config", "user.email", "bisect@example.invalid"])
    _ = try await repo.run(["config", "commit.gpgsign", "false"])
    let unbornLog = LogWindowModel(repository: repo, access: nil)
    unbornLog.reload()
    let unbornDeadline = Date().addingTimeInterval(30)
    while unbornLog.busy && Date() < unbornDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!unbornLog.busy && unbornLog.error == nil && unbornLog.entries.count == 1 && unbornLog.entries[0].hash.isEmpty && !unbornLog.bisectActive)
    unbornLog.invalidate()
    var hashes: [String] = []
    for step in 0...7 {
        if step == 0 {
            try Data("[submodule \"fixture\"]\n\tpath = fixture\n\turl = ./fixture\n".utf8).write(to: root.appendingPathComponent(".gitmodules"))
            try await repo.stage([".gitmodules"])
        } else if step == 4 {
            _ = try await repo.run(["rm", "--", ".gitmodules"])
        }
        try Data("step \(step)\n".utf8).write(to: root.appendingPathComponent("change"))
        try await repo.stage(["change"]); _ = try await repo.commit(message: "step \(step)")
        hashes.append(try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines))
    }
    func wait(_ model: BisectWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy)
    }
    let controller = BisectWindowController(repository: repo, access: nil); defer { controller.close() }
    let model = controller.model; try await wait(model)
    precondition(!model.hasSubmodules)
    guard let window = controller.window else { fatalError("Bisect window missing") }
    window.contentView?.layoutSubtreeIfNeeded()
    func combos(_ view: NSView) -> [NSComboBox] { (view as? NSComboBox).map { [$0] } ?? view.subviews.flatMap(combos) }
    let fields = window.contentView.map(combos) ?? []
    precondition(fields.count == 2 && fields.allSatisfy { $0.objectValues.contains { ($0 as? String) == "main" } })
    precondition(model.good.isEmpty && model.bad == "main" && !model.canStart && !window.isVisible)
    for operation in BisectOperation.allCases { precondition(operation.icon.image() != nil) }
    model.good = hashes[0]; model.bad = "HEAD"; precondition(model.canStart)
    model.busy = true; precondition(controller.activeOperation && !controller.windowShouldClose(window)); model.busy = false
    let dirty = Data("dirty tracked bytes".utf8), untracked = Data("keep untracked".utf8)
    try dirty.write(to: root.appendingPathComponent("change")); try untracked.write(to: root.appendingPathComponent("untracked"))
    var prompts = 0
    model.confirmStash = { prompts += 1; return false }; model.start(); try await wait(model)
    precondition(model.error == nil && prompts == 1 && model.state?.active == false)
    let keptDirty = try Data(contentsOf: root.appendingPathComponent("change")); precondition(keptDirty == dirty)
    let noStash = try await repo.run(["rev-parse", "--verify", "refs/stash"], successfulExitCodes: 0...128); precondition(noStash.exitCode != 0)
    model.confirmStash = { prompts += 1; return true }; model.start(); try await wait(model)
    precondition(model.error == nil && prompts == 2 && model.state?.active == true && window.contentLayoutRect.height >= 440)
    precondition(model.hasSubmodules)
    do { let keptUntracked = try Data(contentsOf: root.appendingPathComponent("untracked")); precondition(keptUntracked == untracked) }
    let stash = try await repo.run(["show", "stash:change"]).stdout; precondition(stash == dirty)
    let reopened = BisectWindowController(repository: repo, access: nil); defer { reopened.close() }
    try await wait(reopened.model); precondition(reopened.model.state?.active == true && reopened.model.state?.originalRevision == "main")
    var submoduleUpdates = 0
    reopened.model.onSubmoduleUpdate = { submoduleUpdates += 1 }
    func checkSubmoduleAction() {
        let present = FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitmodules").path)
        precondition(reopened.model.hasSubmodules == present)
        let allowed = present && reopened.model.lastExitCode == 0
        precondition(reopened.model.canUpdateSubmodules == allowed)
        let before = submoduleUpdates
        reopened.model.updateSubmodules(); precondition(submoduleUpdates == before + (allowed ? 1 : 0))
        reopened.model.busy = true; reopened.model.updateSubmodules(); precondition(submoduleUpdates == before + (allowed ? 1 : 0))
        reopened.model.busy = false
    }
    // load alone has no successful progress result; it must not launch Update.
    precondition(reopened.model.hasSubmodules && !reopened.model.canUpdateSubmodules)
    reopened.model.updateSubmodules(); precondition(submoduleUpdates == 0)
    for _ in 0..<10 {
        if reopened.model.state?.firstBadCommit != nil { break }
        let current = hashes.firstIndex(of: reopened.model.state!.head)!
        reopened.model.perform(current >= 4 ? .bad : .good); try await wait(reopened.model); precondition(reopened.model.error == nil)
        checkSubmoduleAction()
    }
    precondition(reopened.model.state?.firstBadCommit == hashes[4]); reopened.model.perform(.reset); try await wait(reopened.model)
    precondition(reopened.model.state?.active == false && reopened.model.state?.head == hashes[7])
    checkSubmoduleAction(); precondition(!reopened.model.hasSubmodules)
    reopened.model.good = hashes[0]; reopened.model.bad = "HEAD"; reopened.model.start(); try await wait(reopened.model)
    checkSubmoduleAction(); precondition(reopened.model.hasSubmodules)
    reopened.model.perform(.skip, revisions: Array(hashes[1...6])); try await wait(reopened.model)
    precondition(reopened.model.lastExitCode != 0 && reopened.model.error != nil && reopened.model.canPerform(.reset) && !reopened.model.canPerform(.good))
    checkSubmoduleAction()
    reopened.model.error = nil; reopened.model.perform(.reset); try await wait(reopened.model); precondition(reopened.model.error == nil)
    checkSubmoduleAction()
    _ = try await repo.run(["bisect", "start", "--term-good=old", "--term-bad=new", hashes[7], hashes[0]])
    reopened.model.load(); try await wait(reopened.model)
    precondition(reopened.model.title(.good) == "Bisect old" && reopened.model.title(.bad) == "Bisect new")
    reopened.model.perform(.good, revisions: [hashes[1]]); try await wait(reopened.model); precondition(reopened.model.error == nil)
    reopened.model.perform(.reset); try await wait(reopened.model)
    // Finder requests must refresh state, then classify the checked-out commit.
    _ = try await repo.startBisect(good: hashes[0], bad: "HEAD")
    let candidate = try await repo.bisectState().head
    reopened.model.load(requireStart: true); try await wait(reopened.model)
    precondition(reopened.model.error == BisectFailure.active.localizedDescription)
    let unchangedCandidate = try await repo.bisectState().head; precondition(unchangedCandidate == candidate)
    reopened.model.error = nil
    reopened.model.load(operation: .good); try await wait(reopened.model)
    precondition(reopened.model.error == nil && reopened.model.state?.log.contains("git bisect good " + candidate) == true)
    reopened.model.load(operation: .reset); try await wait(reopened.model); precondition(reopened.model.state?.active == false)
    let afterReset = try await repo.bisectState()
    reopened.model.load(operation: .bad); try await wait(reopened.model)
    precondition(reopened.model.error == BisectFailure.inactive.localizedDescription && reopened.model.state?.active == false)
    let afterStale = try await repo.bisectState(); precondition(afterStale.head == afterReset.head && !afterStale.active)
    reopened.model.error = nil
    print("Native Finder Bisect dispatch: fresh active Start refusal, current-commit Good after load, Reset handoff and stale ended-session Bad refusal preserve HEAD/state passed.")
    precondition(submoduleUpdates > 0)
    print("Native Bisect submodule progress: checkout adds/removes .gitmodules, Start/classification/Reset refresh availability, failed result and busy callback guards passed. Update callback injected; dialog handoff not activated.")
    // Actual Log menu construction and selected-revision handoff.
    let log = LogWindowModel(repository: repo, access: nil)
    defer { log.invalidate() }
    log.endRevision = "main"
    var requests: [LogBisectRequest] = []
    log.onBisect = { requests.append($0) }
    func waitLog() async throws {
        let deadline = Date().addingTimeInterval(30)
        while log.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!log.busy)
    }
    log.reload(); try await waitLog()
    log.selected = [hashes[0], hashes[7]]
    let host = NSHostingView(rootView: RevisionTable(model: log)); host.frame = NSRect(x: 0, y: 0, width: 1040, height: 300); host.layoutSubtreeIfNeeded()
    guard let table = findTable(host), let coordinator = table.delegate as? RevisionTable.Coordinator, let menu = table.menu else { fatalError("Bisect Log menu missing") }
    func menuItem(_ command: LogBisectCommand) -> NSMenuItem? {
        coordinator.menuNeedsUpdate(menu); return menu.items.first { $0.title == command.title }
    }
    precondition(menuItem(.start)?.image != nil && menuItem(.start)?.isEnabled == true && menuItem(.start)?.target === coordinator)
    coordinator.bisectStart(); try await waitLog()
    precondition(requests.count == 1 && requests[0].good == hashes[0] && requests[0].bad == "refs/heads/main" && requests[0].operation == nil && requests[0].revisions.isEmpty)
    reopened.model.load(good: requests[0].good, bad: requests[0].bad, requireStart: true); try await wait(reopened.model)
    precondition(reopened.model.good == hashes[0] && reopened.model.bad == "refs/heads/main" && reopened.model.canStart)
    log.busy = true; precondition(menuItem(.start)?.isEnabled == false); coordinator.bisectStart(); precondition(requests.count == 1); log.busy = false
    log.mergeActive = true; precondition(menuItem(.start) == nil); log.mergeActive = false
    log.bare = true; precondition(menuItem(.start) == nil); log.bare = false
    coordinator.bisectStart(); log.selected = [hashes[1]]; try await waitLog(); precondition(requests.count == 1)
    log.selected = [hashes[0], hashes[7]]
    // First-ref preset falls back to the selected commit if that ref moved.
    _ = try await repo.run(["tag", "log-bisect-preset", hashes[7]])
    log.reload(); try await waitLog(); log.selected = [hashes[0], hashes[7]]
    let tip = log.entries.firstIndex { $0.hash == hashes[7] }!
    log.entries[tip].references.sort { $0.name.hasPrefix("refs/tags/") && !$1.name.hasPrefix("refs/tags/") }
    _ = try await repo.run(["tag", "-f", "log-bisect-preset", hashes[6]])
    coordinator.bisectStart(); try await waitLog(); precondition(requests.count == 2 && requests.last?.bad == hashes[7])
    _ = try await repo.run(["tag", "-d", "log-bisect-preset"])
    _ = try await repo.startBisect(good: hashes[0], bad: "main")
    coordinator.bisectStart(); try await waitLog(); precondition(requests.count == 2 && log.error == BisectFailure.active.localizedDescription)
    log.error = nil; log.reload(); try await waitLog(); precondition(log.bisectActive)
    log.selected = [hashes[7]]; precondition(menuItem(.good) == nil && menuItem(.bad) == nil && menuItem(.skip) == nil)
    log.selected = [hashes[1]]
    for command in [LogBisectCommand.good, .bad, .skip] { precondition(menuItem(command)?.image != nil && menuItem(command)?.isEnabled == true) }
    precondition(menuItem(.start) == nil)
    reopened.model.observeLog(log); reopened.model.observeLog(log)
    let bisectPicker = LogWindowController(repository: repo, access: nil, onChoose: { _ in })
    defer { bisectPicker.close() }
    bisectPicker.model.endRevision = "main"; bisectPicker.model.reload()
    func waitPicker() async throws {
        let deadline = Date().addingTimeInterval(30)
        while bisectPicker.model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!bisectPicker.model.busy)
    }
    try await waitPicker(); reopened.model.observeLog(bisectPicker.model)
    var transient: LogWindowModel? = LogWindowModel(repository: repo, access: nil, selecting: true)
    weak var weakTransient = transient
    reopened.model.observeLog(transient!); transient = nil; precondition(weakTransient == nil)
    coordinator.bisectGood(); try await waitLog()
    precondition(requests.count == 3 && requests.last?.operation == .good && requests.last?.revisions == [hashes[1]])
    reopened.model.load(operation: requests.last!.operation, revisions: requests.last!.revisions); try await wait(reopened.model)
    precondition(reopened.model.error == nil && reopened.model.state?.log.contains("git bisect good " + hashes[1]) == true)
    try await waitLog(); try await waitPicker()
    for refreshed in [log, bisectPicker.model] {
        precondition(refreshed.entries.first { $0.hash == hashes[1] }?.references.contains { $0.name.hasPrefix("refs/bisect/good-") } == true)
        precondition(refreshed.entries.first { $0.isHead }?.hash == reopened.model.state?.head)
    }
    log.selected = [hashes[2], hashes[5]]
    precondition(menuItem(.good) == nil && menuItem(.bad) == nil && menuItem(.skip)?.isEnabled == true)
    coordinator.bisectSkip(); try await waitLog()
    precondition(requests.count == 4 && requests.last?.operation == .skip && requests.last?.revisions == [hashes[5], hashes[2]])
    reopened.model.load(operation: requests.last!.operation, revisions: requests.last!.revisions); try await wait(reopened.model)
    precondition(reopened.model.error == nil)
    for hash in [hashes[2], hashes[5]] { precondition(reopened.model.state?.log.contains("git bisect skip " + hash) == true) }
    try await waitLog(); try await waitPicker()
    for hash in [hashes[2], hashes[5]] {
        precondition(bisectPicker.model.entries.first { $0.hash == hash }?.references.contains { $0.name.hasPrefix("refs/bisect/skip-") } == true)
    }
    log.selected = [hashes[6]]
    coordinator.bisectBad(); try await waitLog(); precondition(requests.count == 5 && requests.last?.operation == .bad && requests.last?.revisions == [hashes[6]])
    reopened.model.load(operation: requests.last!.operation, revisions: requests.last!.revisions); try await wait(reopened.model)
    precondition(reopened.model.error == nil && reopened.model.state?.log.contains("git bisect bad " + hashes[6]) == true)
    // A menu built before another caller marks the selected commit must refuse it.
    try await waitLog(); try await waitPicker()
    precondition(bisectPicker.model.entries.first { $0.hash == hashes[6] }?.references.contains { $0.name == "refs/bisect/bad" } == true)
    bisectPicker.close(); precondition(bisectPicker.model.isInvalidated)
    log.selected = [hashes[4]]
    _ = try await repo.run(["update-ref", "refs/bisect/skip-" + hashes[4], hashes[4]])
    coordinator.bisectGood(); try await waitLog(); precondition(requests.count == 5 && log.error != nil)
    reopened.model.perform(.reset); try await wait(reopened.model)
    try await waitLog()
    precondition(!log.bisectActive && log.entries.first { $0.isHead }?.hash == hashes[7])
    precondition(log.entries.allSatisfy { !$0.references.contains { $0.name.hasPrefix("refs/bisect/") } })
    precondition(bisectPicker.model.isInvalidated && !bisectPicker.model.busy)
    // Recreate a stale cached menu independently of the automatic refresh.
    log.bisectActive = true
    log.error = nil; coordinator.bisectBad(); try await waitLog()
    precondition(requests.count == 5 && log.error == BisectFailure.inactive.localizedDescription)
    let logResetState = try await repo.bisectState(); precondition(!logResetState.active && logResetState.head == hashes[7])
    // Working-tree row rendering, comparison and current-commit operations.
    log.error = nil; log.reload(); try await waitLog(); log.select([""])
    precondition(log.selectedWorkingTree && log.entries.first?.hash == "" && log.entries.first?.parents == [hashes[7]])
    precondition(log.revision == nil && !log.canEditNotes && !log.canCherryPick && !log.integrationAvailable && log.formatPatchPreset == nil)
    log.showUnversionedFiles = true; log.updateWorkingFiles(); precondition(log.files.contains { $0.path == "untracked" && $0.status == "Unversioned" })
    log.showUnversionedFiles = false; log.updateWorkingFiles(); precondition(log.files.isEmpty)
    var comparisons: [(ComparisonRevision, ComparisonRevision)] = [], comparedPaths: [String] = [], commits = 0
    log.onCompare = { comparisons.append(($0, $1)) }; log.onFileCompare = { _, _, paths in comparedPaths = paths }; log.onCommit = { commits += 1 }
    coordinator.menuNeedsUpdate(menu)
    precondition(menu.items.first { $0.title == "Commit…" }?.image != nil && menuItem(.reset) == nil)
    coordinator.commitWorkingTree(); precondition(commits == 1)
    var workingCommands: [RepositoryAction] = []
    log.onWorkingCommand = { workingCommands.append($0) }
    func workingItem(_ action: RepositoryAction) -> NSMenuItem? {
        coordinator.menuNeedsUpdate(menu); return menu.items.first { $0.representedObject as? String == action.rawValue }
    }
    for action in [RepositoryAction.stash, .stashPop, .stashList, .pull, .fetch] {
        guard let item = workingItem(action) else { fatalError("Missing working-tree command \(action)") }
        precondition(item.isEnabled && item.image != nil && item.target === coordinator)
        coordinator.workingCommand(item); try await waitLog(); precondition(workingCommands.last == action)
    }
    precondition(workingItem(.submoduleUpdate) == nil)
    let commandCount = workingCommands.count
    log.busy = true; log.requestWorkingCommand(.fetch); precondition(workingCommands.count == commandCount && workingItem(.fetch)?.isEnabled == false); log.busy = false
    log.requestWorkingCommand(.fetch); log.selected = [hashes[1]]; try await waitLog(); precondition(workingCommands.count == commandCount)
    log.select([""])
    try Data((hashes[7] + "\n").utf8).write(to: root.appendingPathComponent(".git/MERGE_HEAD"))
    log.requestWorkingCommand(.pull); try await waitLog(); precondition(log.error != nil && workingCommands.count == commandCount)
    log.error = nil; log.reload(); try await waitLog(); log.select([""])
    precondition(workingItem(.pull) == nil && workingItem(.stash) == nil && workingItem(.fetch)?.isEnabled == true)
    log.requestWorkingCommand(.fetch); try await waitLog(); precondition(workingCommands.last == .fetch && workingCommands.count == commandCount + 1)
    try FileManager.default.removeItem(at: root.appendingPathComponent(".git/MERGE_HEAD"))
    log.reload(); try await waitLog(); log.select([""])
    let stashRef = try await repo.run(["rev-parse", "refs/stash"]).text.trimmingCharacters(in: .newlines)
    _ = try await repo.run(["update-ref", "-d", "refs/stash"])
    log.requestWorkingCommand(.stashPop); try await waitLog(); precondition(log.error != nil && workingCommands.count == commandCount + 1)
    log.error = nil; log.reload(); try await waitLog(); log.select([""])
    precondition(workingItem(.stashPop) == nil && workingItem(.stashList) == nil)
    _ = try await repo.run(["update-ref", "refs/stash", stashRef])
    try Data("[submodule \"fixture\"]\n\tpath = fixture\n\turl = ./fixture\n".utf8).write(to: root.appendingPathComponent(".gitmodules"))
    log.reload(); try await waitLog(); log.select([""])
    guard let submoduleItem = workingItem(.submoduleUpdate) else { fatalError("Missing Submodule Update") }
    precondition(submoduleItem.image != nil && submoduleItem.isEnabled)
    coordinator.workingCommand(submoduleItem); try await waitLog(); precondition(workingCommands.last == .submoduleUpdate)
    let beforeStaleSubmodule = workingCommands.count
    try FileManager.default.removeItem(at: root.appendingPathComponent(".gitmodules"))
    log.requestWorkingCommand(.submoduleUpdate); try await waitLog(); precondition(log.error != nil && workingCommands.count == beforeStaleSubmodule)
    log.error = nil
    var stashHistory = HistoryOptions(); stashHistory.allBranches = true
    log.entries = try await repo.history(options: stashHistory); log.graph = CommitGraph.layout(log.entries); log.selected = [stashRef]
    precondition(log.selectedIsStash && workingItem(.stashPop)?.isEnabled == true && workingItem(.stashList)?.isEnabled == true && workingItem(.fetch) == nil)
    log.reload(); try await waitLog(); log.select([""])
    print("Native working-tree repository menus: original icons/targets, Stash Save/Pop/List and Pull/Fetch handoffs, Submodule Update presence, merge hides Save/Pull while Fetch remains, busy/selection guards, fresh Merge/stash/config disappearance refusal and selected stash-row Pop/List passed. Handoffs injected; no network or stash pop executed.")
    coordinator.compare(); precondition(comparisons.last?.0 == .revision(hashes[7]) && comparisons.last?.1 == .workingTree)
    log.selected = ["", hashes[0]]; coordinator.compare(); precondition(comparisons.last?.0 == .revision(hashes[0]) && comparisons.last?.1 == .workingTree)
    let savedWorking = try Data(contentsOf: root.appendingPathComponent("change"))
    try Data("native working-row diff\n".utf8).write(to: root.appendingPathComponent("change"))
    log.reload(); try await waitLog(); log.select([""])
    precondition(log.files.contains { $0.path == "change" && $0.status == "Modified" })
    log.compareFiles(["change"]); precondition(comparedPaths == ["change"])
    var workingPatch = Data(), selectedWorkingAlternate = false; log.onUnifiedDiff = { bytes, alternate in workingPatch = bytes; selectedWorkingAlternate = alternate }
    coordinator.showDiff(); try await waitLog(); precondition(String(decoding: workingPatch, as: UTF8.self).contains("+native working-row diff"))
    workingPatch = Data(); log.selectedFileDiff(["change"], alternate: true); try await waitLog()
    precondition(selectedWorkingAlternate && String(decoding: workingPatch, as: UTF8.self).contains("+native working-row diff"))
    log.showUnversionedFiles = true; log.updateWorkingFiles(); workingPatch = Data()
    log.selectedFileDiff(["untracked"]); precondition(!log.busy && workingPatch.isEmpty)
    log.showUnversionedFiles = false; log.updateWorkingFiles()
    print("Native selected working-file unified diff: tracked selection produces actual patch bytes, alternate handoff retained, unversioned selection refused without opening viewer passed. Handoff injected.")
    log.window = window
    let workingCopyPath = "copy :(glob)* 雪\n.bin", workingCopyURL = root.appendingPathComponent(workingCopyPath)
    let workingCopyBytes = Data([0xff, 0, 13, 10])
    try workingCopyBytes.write(to: workingCopyURL)
    let workingCopyFolder = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-log-copy-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: workingCopyFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workingCopyFolder) }
    let workingSaveURL = workingCopyFolder.appendingPathComponent("saved.bin")
    log.showUnversionedFiles = true; log.reload(); try await waitLog(); log.select([""])
    var workingOpened: [(URL, HistoricalOpenAction)] = [], workingSavePath: String?, workingExportPaths: [String] = []
    log.presentWorkingOpen = { workingOpened.append(($0, $1)) }
    log.presentWorkingSave = { workingSavePath = $0 }; log.presentWorkingExport = { workingExportPaths = $0 }
    let copyIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), copyHead = try await repo.run(["rev-parse", "HEAD"]).stdout
    for action in [HistoricalOpenAction.open, .openWith, .alternativeEditor] {
        log.openHistoricalFile([workingCopyPath], action: action); try await waitLog()
        precondition(log.error == nil && workingOpened.last?.0 == workingCopyURL && workingOpened.last?.1 == action)
    }
    log.saveHistoricalFile([workingCopyPath]); precondition(workingSavePath == workingCopyPath)
    log.copyWorkingFiles([workingCopyPath], to: workingSaveURL, save: true); try await waitLog()
    let savedWorkingCopy = try Data(contentsOf: workingSaveURL); precondition(savedWorkingCopy == workingCopyBytes)
    log.chooseHistoricalExport([workingCopyPath, "change", "untracked"])
    precondition(Set(workingExportPaths) == Set([workingCopyPath, "change", "untracked"]))
    log.copyWorkingFiles(workingExportPaths, to: workingCopyFolder, save: false); try await waitLog()
    let exportedWorkingCopy = try Data(contentsOf: workingCopyFolder.appendingPathComponent(workingCopyPath))
    let exportedUntracked = try Data(contentsOf: workingCopyFolder.appendingPathComponent("untracked"))
    let exportedTracked = try Data(contentsOf: workingCopyFolder.appendingPathComponent("change"))
    precondition(log.error == nil && exportedWorkingCopy == workingCopyBytes && exportedUntracked == untracked && exportedTracked == Data("native working-row diff\n".utf8))
    let headFile = try await repo.historicalFile(revision: "HEAD", path: "change")
    var blameRequests: [(String, String)] = [], workingFileLogRequests = 0
    log.onBlame = { blameRequests.append(($0, $1)) }; log.onFileLog = { _, _ in workingFileLogRequests += 1 }
    precondition(log.canBlameFile(["change"]) && !log.canBlameFile([workingCopyPath]) && !log.canBlameFile(["change", workingCopyPath]))
    log.fileLog([workingCopyPath]); precondition(workingFileLogRequests == 0)
    log.fileLog(["change"]); precondition(workingFileLogRequests == 1)
    log.blameFile(["change"]); try await waitLog()
    precondition(log.error == nil && blameRequests.last?.0 == "change" && blameRequests.last?.1 == hashes[7])
    let blameController = BlameWindowController(repository: repo, access: nil, path: "change", revision: blameRequests.last!.1, options: GitBlameOptions())
    var blameClosed = false; blameController.onClosed = { blameClosed = true }
    defer { if !blameClosed { blameController.close() } }
    let blameDeadline = Date().addingTimeInterval(30)
    while blameController.model.busy && Date() < blameDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!blameController.model.busy && blameController.model.error == nil && blameController.model.snapshot?.contents == headFile.bytes)
    precondition(blameController.model.snapshot?.contents != Data("native working-row diff\n".utf8) && blameController.window?.isVisible == false)
    blameController.close(); precondition(blameClosed)
    _ = try await repo.run(["update-ref", "HEAD", hashes[6]])
    log.blameFile(["change"]); try await waitLog(); precondition(blameRequests.last?.1 == hashes[6])
    _ = try await repo.run(["update-ref", "HEAD", hashes[7]])
    let blameCount = blameRequests.count
    log.blameFile(["change"]); log.selected = [hashes[7]]; try await waitLog(); precondition(blameRequests.count == blameCount)
    log.blameFile(["change"]); precondition(blameRequests.last?.1 == hashes[7] && blameRequests.count == blameCount + 1)
    log.select([""])
    let guardedBlameCount = blameRequests.count
    var workingPairPaths: [String] = [], preparedPairs: [(PreparedFileComparisonMark, PreparedFileComparisonMark)] = []
    log.onWorkingFilePairCompare = { workingPairPaths = $0 }
    log.onPreparedFileCompare = { preparedPairs.append(($0, $1)) }
    let pairIDs = Set(["change", workingCopyPath]), pairOrder = log.visibleFiles.filter { pairIDs.contains($0.id) }.map(\.path)
    precondition(log.canCompareFilePair(pairIDs)); log.compareFilePair(pairIDs); precondition(workingPairPaths == pairOrder)
    let actualPair = try await repo.workingFilePairComparison(paths: workingPairPaths)
    let pairDocument = try await repo.comparisonFile(actualPair, path: workingPairPaths[1])
    let pairBytes = ["change": Data("native working-row diff\n".utf8), workingCopyPath: workingCopyBytes]
    precondition(pairDocument.base.bytes == pairBytes[workingPairPaths[0]] && pairDocument.destination.bytes == pairBytes[workingPairPaths[1]])
    try FileManager.default.removeItem(at: root.appendingPathComponent("change"))
    log.blameFile(["change"]); try await waitLog(); precondition(log.error != nil && blameRequests.count == guardedBlameCount); log.error = nil
    log.compareFilePair(pairIDs); let deletedPair = try await repo.workingFilePairComparison(paths: workingPairPaths)
    let deletedDocument = try await repo.comparisonFile(deletedPair, path: workingPairPaths[1])
    let deletedBytes = ["change": headFile.bytes, workingCopyPath: workingCopyBytes]
    precondition(deletedDocument.base.bytes == deletedBytes[workingPairPaths[0]] && deletedDocument.destination.bytes == deletedBytes[workingPairPaths[1]])
    precondition(deletedPair.from == .revision(hashes[7]) || deletedPair.to == .revision(hashes[7]))
    try Data("native working-row diff\n".utf8).write(to: root.appendingPathComponent("change"))
    log.markForComparison([workingCopyPath]); precondition(log.comparisonMark?.revision == "" && log.comparisonMark?.label(for: workingCopyPath) == "Working tree")
    log.compareWithMarkedFile(["change"]); precondition(preparedPairs.last?.0.path == workingCopyPath && preparedPairs.last?.1.revision == "")
    let preparedWorking = try await repo.preparedPathComparison(from: .workingTree, fromPath: workingCopyPath, to: .workingTree, toPath: "change")
    let preparedWorkingDocument = try await repo.comparisonFile(preparedWorking, path: "change")
    precondition(preparedWorkingDocument.base.bytes == workingCopyBytes && preparedWorkingDocument.destination.bytes == Data("native working-row diff\n".utf8))
    log.selected = [hashes[7]]; log.markForComparison(["change"]); log.select([""]); log.compareWithMarkedFile([workingCopyPath])
    precondition(preparedPairs.last?.0.revision == hashes[7] && preparedPairs.last?.1.revision == "")
    let mixed = try await repo.preparedPathComparison(from: .revision(hashes[7]), fromPath: "change", to: .workingTree, toPath: workingCopyPath)
    let mixedDocument = try await repo.comparisonFile(mixed, path: workingCopyPath)
    precondition(mixedDocument.base.bytes == headFile.bytes && mixedDocument.destination.bytes == workingCopyBytes)
    log.markForComparison([workingCopyPath]); log.selected = [hashes[7]]; log.compareWithMarkedFile(["change"])
    precondition(preparedPairs.last?.0.revision == "" && preparedPairs.last?.1.revision == hashes[7])
    let reverseMixed = try await repo.preparedPathComparison(from: .workingTree, fromPath: workingCopyPath, to: .revision(hashes[7]), toPath: "change")
    let reverseMixedDocument = try await repo.comparisonFile(reverseMixed, path: "change")
    precondition(reverseMixedDocument.base.bytes == workingCopyBytes && reverseMixedDocument.destination.bytes == headFile.bytes)
    log.select([""])
    let preparedCount = preparedPairs.count, retainedMark = log.comparisonMark?.path
    workingPairPaths = []
    let openedCount = workingOpened.count
    workingSavePath = nil; workingExportPaths = []; log.busy = true
    log.openHistoricalFile([workingCopyPath], action: .open); log.saveHistoricalFile([workingCopyPath]); log.chooseHistoricalExport([workingCopyPath])
    log.copyWorkingFiles([workingCopyPath], to: workingSaveURL, save: true)
    log.compareFilePair(pairIDs); log.markForComparison(["change"]); log.compareWithMarkedFile(["change"])
    log.blameFile(["change"]); precondition(!log.canBlameFile(["change"]) && blameRequests.count == guardedBlameCount)
    precondition(workingPairPaths.isEmpty && preparedPairs.count == preparedCount && log.comparisonMark?.path == retainedMark)
    precondition(workingOpened.count == openedCount && workingSavePath == nil && workingExportPaths.isEmpty); log.busy = false
    log.openHistoricalFile([workingCopyPath], action: .open); log.selected = [hashes[7]]; try await waitLog()
    precondition(workingOpened.count == openedCount); log.select([""])
    let deleted = CommitFile.parse(names: Data("D\0deleted-copy\0".utf8), statistics: Data())[0]
    let module = CommitFile.parse(names: Data("M\0module-copy\0".utf8), statistics: Data(), raw: Data(":160000 160000 old new M\0module-copy\0".utf8))[0]
    let added = CommitFile.parse(names: Data("A\0added-copy\0".utf8), statistics: Data())[0]
    log.files += [deleted, module, added]
    for path in [deleted.path, module.path, added.path, workingCopyPath] { precondition(!log.canBlameFile([path])); log.blameFile([path]) }
    precondition(blameRequests.count == guardedBlameCount)
    log.markForComparison([deleted.path]); log.compareWithMarkedFile([module.path]); log.compareFilePair([module.path, workingCopyPath])
    precondition(log.comparisonMark?.path == retainedMark && preparedPairs.count == preparedCount && workingPairPaths.isEmpty)
    log.saveHistoricalFile([deleted.path]); log.openHistoricalFile([module.path], action: .open)
    log.chooseHistoricalExport([workingCopyPath, deleted.path, module.path])
    precondition(workingSavePath == nil && workingOpened.count == openedCount && workingExportPaths == [workingCopyPath])
    try FileManager.default.removeItem(at: workingCopyURL)
    log.openHistoricalFile([workingCopyPath], action: .open); try await waitLog(); precondition(log.error != nil && workingOpened.count == openedCount)
    log.error = nil
    let copyAfterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), copyAfterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
    precondition(copyAfterIndex == copyIndex && copyAfterHead == copyHead)
    log.invalidate(); workingSavePath = nil; workingExportPaths = []
    log.saveHistoricalFile([workingCopyPath]); log.chooseHistoricalExport([workingCopyPath]); log.copyWorkingFiles([workingCopyPath], to: workingSaveURL, save: true)
    log.compareFilePair(pairIDs); log.markForComparison(["change"]); log.compareWithMarkedFile(["change"])
    log.blameFile(["change"]); precondition(!log.canBlameFile(["change"]) && blameRequests.count == guardedBlameCount)
    precondition(workingPairPaths.isEmpty && preparedPairs.count == preparedCount && log.comparisonMark?.path == retainedMark)
    precondition(!log.busy && workingSavePath == nil && workingExportPaths.isEmpty)
    log.showUnversionedFiles = false; log.reload(); try await waitLog(); log.select([""])
    print("Native working-file Open/Open With/editor handoffs use actual disk URL; Save As/export preserve raw working bytes and unversioned selection, tracked bytes, HEAD/index, busy/selection/invalidation guards, deleted/submodule exclusions and stale missing-file refusal passed. Panels and application launches injected.")
    print("Native working-file pair/prepared comparison: list-order routing, real raw-byte working/working and historical/working comparisons in both directions, missing working side uses pinned HEAD, working mark label, busy/invalidation and deleted/submodule guards passed. Root viewer handoffs injected.")
    do {
        let unbornRoot = root.appendingPathComponent("blame-unborn")
        _ = try await repo.run(["init", "--initial-branch=main", unbornRoot.path])
        let unbornRepository = GitRepository(root: unbornRoot, executable: repo.executable)
        try Data("new\n".utf8).write(to: unbornRoot.appendingPathComponent("new")); _ = try await unbornRepository.run(["add", "--", "new"])
        let unbornLog = LogWindowModel(repository: unbornRepository, access: nil); unbornLog.onBlame = { _, _ in fatalError("Unborn Blame handoff") }
        unbornLog.reload(); let unbornDeadline = Date().addingTimeInterval(30)
        while unbornLog.busy && Date() < unbornDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        unbornLog.select([""]); precondition(!unbornLog.busy && unbornLog.error == nil && unbornLog.selectedWorkingTree && unbornLog.workingTreeSnapshot?.entry.parents.isEmpty == true && !unbornLog.canBlameFile(["new"]))
        unbornLog.blameFile(["new"]); unbornLog.invalidate(); try FileManager.default.removeItem(at: unbornRoot)
    }
    print("Native working-row Blame: fresh pinned HEAD handoff, hidden actual viewer displays committed bytes rather than edits, moved HEAD and historical selection, missing working-file refusal, added/unversioned/deleted/submodule/unborn/busy/selection/invalidation guards and unversioned Show Log exclusion passed. Root handoff injected; owned viewer closed.")
    try savedWorking.write(to: root.appendingPathComponent("change"))
    reopened.model.load(good: hashes[0], bad: hashes[7], requireStart: true); try await wait(reopened.model)
    reopened.model.start(); try await wait(reopened.model); try await waitLog()
    log.select([""])
    for command in [LogBisectCommand.good, .bad, .skip, .reset] { precondition(menuItem(command)?.image != nil && menuItem(command)?.isEnabled == true) }
    log.busy = true; let prior = requests.count; coordinator.bisectReset(); precondition(requests.count == prior && menuItem(.reset)?.isEnabled == false); log.busy = false
    for command in [LogBisectCommand.skip, .good, .bad] {
        log.select([""])
        let candidate = reopened.model.state!.head
        log.requestBisect(command); try await waitLog()
        precondition(requests.last?.operation == command.operation && requests.last?.revisions.isEmpty == true)
        reopened.model.load(operation: requests.last!.operation, revisions: requests.last!.revisions); try await wait(reopened.model); try await waitLog()
        precondition(reopened.model.error == nil && reopened.model.state?.log.contains("git bisect " + command.operation!.rawValue + " " + candidate) == true)
    }
    log.select([""]); coordinator.bisectReset(); try await waitLog()
    precondition(requests.last?.operation == .reset && requests.last?.revisions.isEmpty == true)
    reopened.model.load(operation: .reset); try await wait(reopened.model); try await waitLog()
    precondition(!log.bisectActive && log.workingTreeSnapshot?.entry.parents == [hashes[7]])
    log.showWorkingTree = false; log.reload(); try await waitLog(); precondition(log.entries.allSatisfy { !$0.hash.isEmpty })
    log.showWorkingTree = true; log.reload(); try await waitLog(); precondition(log.entries.first?.hash.isEmpty == true)
    precondition(bisectPicker.model.entries.allSatisfy { !$0.hash.isEmpty })
    print("Native working-tree Log row: top/HEAD linkage, unversioned toggle, tracked details, Commit callback, whole and mixed-revision/file comparisons, real unified patch, no commit-only routes, active current-commit Skip/Good/Bad and Reset, busy guard and show/hide passed. Handoffs injected; advanced working-file actions pending.")
    print("Native Log Bisect revision commands: actual menu icons/targets, two-row Bad/Good order, ref/hash and moved-ref presets, busy/bare/merge/selection guards, active Start refusal, marked-row exclusion, selected Good/Bad and literal multi-Skip execution, stale mark/ended-session refusal passed. Handoff injected; activated menus pending.")
    print("Native Bisect picker refresh: real hidden picker and source Log refresh HEAD/Good/Skip/Bad references without manual reload; Reset clears session/marks; closed retained picker stays invalidated and weak observers release models. Root handoff injected.")
    let branch = try await repo.branch(); precondition(branch == "main")
    do { let keptUntracked = try Data(contentsOf: root.appendingPathComponent("untracked")); precondition(keptUntracked == untracked) }
    var closed = false; reopened.onClosed = { closed = true }; reopened.close(); precondition(closed && !window.isVisible)
    print("Native Bisect: real hidden two-combo dialog, defaults/icons, Stash Abort/accept with exact saved bytes and untracked preservation, fresh session reopening, regression classification/Reset, ambiguous Skip recovery, custom labels and owned-window cleanup passed. Prompt replies injected.")
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
    if ProcessInfo.processInfo.environment["TURTLEGIT_NATIVE_REFERENCE_ONLY"] == "1" { try await verifyNativeSquashReferenceUpdates(repo, editor: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TurtleGitMac")); try await verifyNativeRepeatedAndOmittedReferences(repo, editor: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TurtleGitMac")); return }
    try await verifyNativeBisect(executable: repo.executable)
    try await verifyNativeLogWorkingConflicts(executable: repo.executable)
    try await verifyNativeLogDeferredRefresh(executable: repo.executable)
    try await verifyNativeLogUnifiedViewerRouting(executable: repo.executable)
    try await verifyNativeLogParentWorkingComparison(executable: repo.executable)
    try await verifyLogIntegration(repo, revisions: [merge, parent, side, base], editor: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TurtleGitMac"))
    if ProcessInfo.processInfo.environment["TURTLEGIT_NATIVE_MENUS_ONLY"] == "1" { try await verifyNativeRebaseMenus(repo, editor: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TurtleGitMac"), revisions: [merge, parent, side, base]); return }
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
    precondition(reopened.entries.map(\.id) == [merge.hash, side.hash] && !reopened.canStart)
    precondition(reopened.replayRows.map(\.progress) == [.completed, .current])
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
    precondition(adding.selection == [empty.hash + ":1"] && adding.entries.map(\.id) == [empty.hash + ":1", empty.hash])
    let reopenedDuplicate = RebaseWindowModel(repository: GitRepository(root: root, executable: git), access: nil)
    reopenedDuplicate.load(); try await settle(reopenedDuplicate)
    precondition(reopenedDuplicate.entries.map(\.id) == [empty.hash + ":1", empty.hash])
    precondition(reopenedDuplicate.replayRows.map(\.progress) == [.completed, .current])
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
    try await verifyNativeRepeatedAndOmittedReferences(repo, editor: model.editorExecutable)
    try await verifyNativeRebaseMenus(repo, editor: model.editorExecutable, revisions: [merge, parent, side, base])



}
@main struct Receiver { @MainActor static func main() async throws { try await verify() } }
