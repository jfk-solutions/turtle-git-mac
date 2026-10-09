import AppKit
import SwiftUI
import TurtleGitCore

@main struct ReferenceBrowserVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func find<T: NSView>(_ type: T.Type, _ view: NSView, label: String? = nil) -> T? {
        if let result = view as? T, label == nil || result.accessibilityLabel() == label { return result }
        for child in view.subviews { if let result = find(type, child, label: label) { return result } }; return nil
    }
    @MainActor static func wait(_ windows: [NSWindow], _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }; if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Timed out")
    }
    static func phase(_ message: String) { print("PHASE: " + message); fflush(stdout) }
    @MainActor static func main() async { do { try await verify() } catch { print("FAIL: \(error)"); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.ReferenceBrowser.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Browser QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.run(["commit", "-m", "red fox"])
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let nfc = "refs/heads/Café/leaf", nfd = "refs/heads/Cafe\u{301}/leaf", marked = "refs/tags/\u{301}tag"
        for ref in ["refs/heads/nested/topic2", "refs/heads/nested/topic10", nfc, nfd, marked, "refs/remotes/origin/main", "refs/notes/custom"] { _ = try await repo.run(["update-ref", ref, head]) }
        _ = try await repo.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        _ = try await repo.run(["-c", "tag.gpgsign=false", "tag", "-a", "release", "-m", "blue tag"])
        let blob = try await repo.run(["hash-object", "-w", "file"]).text.trimmingCharacters(in: .newlines); _ = try await repo.run(["update-ref", "refs/custom/blob", blob])
        _ = try await repo.run(["checkout", "-b", "unmerged"]); _ = try await repo.run(["commit", "--allow-empty", "-m", "unmerged green"]); _ = try await repo.run(["checkout", "main"])
        _ = try await repo.run(["config", "branch.main.description", "first\nsecond"])
        // Preserve byte-distinct names on filesystems that alias canonical-equivalent loose paths.
        _ = try await repo.run(["pack-refs", "--all", "--prune"])
        let packed = root.appendingPathComponent(".git/packed-refs")
        var contents = try String(contentsOf: packed, encoding: .utf8)
        let rows = contents.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("^") }
        if !rows.contains(where: { $0.utf8.elementsEqual((head + " " + nfc).utf8) }) { contents += head + " " + nfc + "\n" }
        if !rows.contains(where: { $0.utf8.elementsEqual((head + " " + nfd).utf8) }) { contents += head + " " + nfd + "\n" }
        contents = contents.replacingOccurrences(of: " sorted", with: "")
        try Data(contents.utf8).write(to: packed)
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config")), index = try Data(contentsOf: root.appendingPathComponent(".git/index")), working = try Data(contentsOf: root.appendingPathComponent("file"))
        phase("Actual native tree/table/filter/focus")
        var result: String?, log: String?, browse: String?, compare: String?
        let picker = ReferenceBrowserWindowController(repository: repo, access: nil, initial: nfd, preferences: prefs) { result = $0 }; defer { picker.close() }
        picker.model.onLog = { log = $0 }; picker.model.onBrowse = { browse = $0 }; picker.model.onCompare = { compare = $0 }
        picker.model.load(); let window = picker.window!
        try await wait([window]) { !picker.model.busy && !picker.model.initialFocusPending }
        guard let table = find(NSTableView.self, window.contentView!, label: "References"), let tree = find(NSOutlineView.self, window.contentView!, label: "Reference namespaces"), let split = find(NSSplitView.self, window.contentView!), let search = find(NSSearchField.self, window.contentView!, label: "Filter references") else { throw Failure(description: "Native browser controls missing") }
        try require(!window.isVisible && window.firstResponder === table && !table.allowsMultipleSelection && table.tableColumns.count == 9, "Native table/focus/visibility differs")
        try require(picker.model.selected == GitReferenceName(nfd) && picker.model.folder == "refs/heads/Cafe\u{301}" && table.selectedRow == 0, "NFD selection lost")
        guard let folder = tree.item(atRow: tree.selectedRow) as? ReferenceBrowserNativeView.Folder else { throw Failure(description: "Tree selected folder missing") }
        try require(folder.key == picker.model.folder && !folder.children.contains(where: { $0.key == GitReferenceName(nfd) }), "Tree contains leaf refs or wrong folder")
        try require(abs(split.subviews[0].frame.width - 190) < 2, "Initial namespace width differs")
        func select(_ name: String) async throws {
            guard let snapshot = picker.model.snapshot else { throw Failure(description: "No snapshot") }
            let choice = snapshot.initialSelection(name); picker.model.setFolder(choice.folder); picker.model.selected = choice.reference
            try await wait([window]) { table.selectedRow >= 0 && picker.model.selected == GitReferenceName(name) && table.numberOfRows == picker.model.rows.count }
        }
        picker.model.setFolder("refs/heads/nested")
        try await wait([window]) { table.numberOfRows == 2 && picker.model.rows.map(\.name) == ["topic2", "topic10"] }
        table.delegate?.tableView?(table, didClick: table.tableColumns[0]); try await wait([window]) { picker.model.descending && picker.model.rows.first?.name == "topic10" }
        picker.model.descending = false; picker.model.setFolder("refs/heads")
        picker.model.nested = false; picker.model.nestedChanged()
        try await wait([window]) { !picker.model.busy && table.numberOfRows == 2 }
        try require(prefs.bool(forKey: "RefBrowserIncludeNestedRefs") == false && Set(picker.model.rows.map(\.name)) == ["main", "unmerged"], "Nested scope/persistence differs")
        picker.model.nested = true; picker.model.nestedChanged(); try await wait([window]) { !picker.model.busy && table.numberOfRows == 6 }
        search.stringValue = "nested/topic2"; search.sendAction(search.action!, to: search.target)
        try await wait([window]) { picker.model.query == "nested/topic2" && table.numberOfRows == 1 }
        search.stringValue = ""; search.sendAction(search.action!, to: search.target)
        try await wait([window]) { picker.model.query.isEmpty && table.numberOfRows == 6 }
        picker.model.fields = .authors; picker.model.query = "Browser QA"; try await wait([window]) { table.numberOfRows == 6 }
        picker.model.query = ""; picker.model.fields = ReferenceBrowserWindowModel.allFields
        picker.model.mergeFilter = .unmerged; picker.model.load(); try await wait([window]) { !picker.model.busy && picker.model.snapshot?.references.count == 1 }
        try require(picker.model.snapshot?.references.first?.name == "refs/heads/unmerged", "Unmerged filter differs")
        picker.model.mergeFilter = .merged; picker.model.load(); try await wait([window]) { !picker.model.busy && !(picker.model.snapshot?.references.contains(where: { $0.name == "refs/heads/unmerged" }) ?? true) }
        picker.model.mergeFilter = .all; picker.model.load(); try await wait([window]) { !picker.model.busy && picker.model.snapshot?.references.contains(where: { $0.name == "refs/heads/unmerged" }) == true }
        let mainChoice = picker.model.snapshot!.initialSelection("refs/heads/main")
        picker.model.setFolder(mainChoice.folder); picker.model.selected = mainChoice.reference
        try await wait([window]) { table.selectedRow >= 0 && picker.model.selected == "refs/heads/main" }
        try require(table.tableColumn(withIdentifier: .init("description"))?.isHidden == false && picker.model.rows.first(where: { $0.name == "main" }).map { picker.model.text($0, column: "description") } == "first second", "Heads metadata differs")
        phase("Icon context callbacks and owned Reflog")
        func menu() throws -> NSMenu { guard let menu = table.menu else { throw Failure(description: "No menu") }; menu.delegate?.menuNeedsUpdate?(menu); return menu }
        func invoke(_ title: String) throws { let menu = try menu(); let index = menu.indexOfItem(withTitle: title); try require(index >= 0 && menu.items[index].isEnabled && menu.items[index].image != nil, "Missing enabled icon command: " + title); menu.performActionForItem(at: index) }
        try invoke("Show log"); try invoke("Browse repository"); try invoke("Compare with working tree")
        try require(log == "refs/heads/main" && browse == log && compare == log, "Context lost canonical name")
        picker.presentReflog = { parent, child in parent.makeFirstResponder(nil); return !parent.isVisible && !child.isVisible }
        try invoke("Show Reflog")
        guard let reflog = picker.reflog else { throw Failure(description: "Owned Reflog missing") }
        try await wait([reflog.window!]) { !reflog.model.busy }
        try require(picker.model.hasChild && !picker.model.canAccept && !picker.windowShouldClose(window) && reflog.model.reference == "refs/heads/main", "Reflog ownership/gates differ")
        picker.model.accept(); picker.model.load(); try require(result == nil && !picker.model.busy, "Browser escaped owned child")
        reflog.close(); try require(!picker.model.hasChild && picker.reflog == nil, "Reflog did not release")
        try await select("refs/tags/release"); let tagMenu = try menu()
        try require(tagMenu.indexOfItem(withTitle: "Show log") == -1 && tagMenu.indexOfItem(withTitle: "Show Reflog") == -1 && tagMenu.indexOfItem(withTitle: "Compare with working tree") == -1 && table.tableColumn(withIdentifier: .init("description"))?.isHidden == true, "Annotated-tag type gates differ")
        try await select("refs/custom/blob"); try require(try menu().indexOfItem(withTitle: "Show log") == -1, "Blob got commit command")
        try await select(nfd); picker.model.accept(); try require(GitReferenceName.equal(result ?? "", nfd) && picker.model.closed, "Accepted ref normalization/close differs")
        phase("Reset all-ref handoff/fresh catalog/focus/cancel/locks")
        let owner = ResetWindowController(repository: repo, access: nil, preferences: prefs); defer { owner.close() }
        owner.model.load(); try await wait([owner.window!]) { !owner.model.busy && !owner.model.chooser.busy && !owner.model.initialModeFocusPending }
        owner.model.chooser.commitRevision = "saved commit draft"
        var presentations = 0
        owner.presentReferencePicker = { parent, child in presentations += 1; parent.makeFirstResponder(nil); return !parent.isVisible && !child.isVisible }
        func open() async throws -> ReferenceBrowserWindowController {
            owner.model.chooser.options.target = .branch; owner.model.showReferencePicker()
            guard let child = owner.referencePicker else { throw Failure(description: "Reset reference picker missing") }
            try await wait([child.window!]) { !child.model.busy && child.model.snapshot != nil }; return child
        }
        for (name, target, label) in [(nfd, CheckoutTarget.branch, "Reset branch revision"), (marked, .tag, "Reset tag revision"), ("refs/remotes/origin/HEAD", .branch, "Reset branch revision"), ("refs/notes/custom", .commit, "Reset commit revision")] {
            let child = try await open(); let count = presentations
            try require(owner.model.showingReferencePicker && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Reset parent/Quit gates differ")
            owner.model.showReferencePicker(); owner.model.showModifiedFiles(); owner.model.showCommitPicker(); owner.model.reset(); owner.model.apply(try await repo.prepareReset(to: head, mode: .mixed))
            try require(presentations == count && owner.modifiedComparison == nil && owner.commitPicker == nil && !owner.model.busy && owner.model.progress == nil, "Reset cross-modal locks escaped")
            let choice = child.model.snapshot!.initialSelection(name); child.model.setFolder(choice.folder); child.model.selected = choice.reference; child.model.accept()
            try await wait([owner.window!]) { !owner.model.showingReferencePicker && owner.model.chooser.options.target == target }
            guard let control = find(NSControl.self, owner.window!.contentView!, label: label) else { throw Failure(description: "Parent revision control missing") }
            try await wait([owner.window!]) {
                if owner.window!.firstResponder === control { return true }
                if let editor = (control as? NSTextField)?.currentEditor() { return owner.window!.firstResponder === editor }
                return false
            }
            try require(owner.referencePicker == nil && GitReferenceName.equal(owner.model.chooser.revision, name), "Reset selected revision differs")
            if target != .commit { try require(owner.model.chooser.commitRevision == "saved commit draft", "Unused commit draft overwritten") }
            if name == nfd { guard let popup = control as? NSPopUpButton else { throw Failure(description: "Branch popup missing") }; try require(popup.numberOfItems == owner.model.chooser.branches.count && popup.indexOfSelectedItem == owner.model.chooser.branches.firstIndex(where: { GitReferenceName.equal($0.name, nfd) }) && popup.titleOfSelectedItem?.utf8.elementsEqual("Cafe\u{301}/leaf".utf8) == true && owner.model.chooser.branches.filter { GitReferenceName.equal($0.name, nfc) || GitReferenceName.equal($0.name, nfd) }.count == 2, "Popup Unicode catalog differs") }
        }
        owner.model.chooser.branchRevision = nfd; let canceled = try await open(); canceled.model.cancel()
        try await wait([owner.window!]) { !owner.model.showingReferencePicker }
        try require(owner.model.chooser.options.target == .branch && GitReferenceName.equal(owner.model.chooser.branchRevision, nfd), "Cancel changed branch draft")
        let next = try await open(); canceled.model.finish("refs/heads/main"); try require(owner.referencePicker === next && owner.model.showingReferencePicker, "Stale closed child changed newer picker")
        next.model.cancel(); try await wait([owner.window!]) { !owner.model.showingReferencePicker }
        owner.presentReferencePicker = { _, _ in false }; owner.model.showReferencePicker(); try require(owner.referencePicker == nil && !owner.model.showingReferencePicker, "Rejected presentation retained child")
        owner.presentReferencePicker = { parent, _ in parent.makeFirstResponder(nil); return true }; let final = try await open(); owner.close(); final.model.finish("refs/heads/main")
        try require(owner.referencePicker == nil && !owner.model.showingReferencePicker && final.model.closed && owner.model.referenceFocusRequest == 0, "Forced parent close/late callback retained state")
        owner.model.showReferencePicker(); try require(owner.referencePicker == nil, "Closed parent reopened")
        phase("Bare namespace browser")
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = ReferenceBrowserWindowController(repository: GitRepository(root: bareRoot, executable: git), access: nil, initial: "main", preferences: prefs) { _ in }; defer { bare.close() }
        bare.model.load(); try await wait([bare.window!]) { !bare.model.busy && bare.model.snapshot != nil }
        guard let bareTable = find(NSTableView.self, bare.window!.contentView!, label: "References"), let bareMenu = bareTable.menu else { throw Failure(description: "Bare native controls missing") }
        bareMenu.delegate?.menuNeedsUpdate?(bareMenu); try require(bare.model.bare && bareMenu.indexOfItem(withTitle: "Compare with working tree") == -1, "Bare working-tree command exposed")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try require(head == afterHead && config == Data(contentsOf: root.appendingPathComponent(".git/config")) && index == Data(contentsOf: root.appendingPathComponent(".git/index")) && working == Data(contentsOf: root.appendingPathComponent("file")), "Browser mutated HEAD/config/index/working bytes")
        phase("Current Branch accepts live HEAD, closes once and respects owned picker gates")
        let currentRoot = root.appendingPathComponent("current-branch-fixture")
        _ = try await repo.run(["clone", "--no-hardlinks", root.path, currentRoot.path])
        let currentRepo = GitRepository(root: currentRoot, executable: git)
        _ = try await currentRepo.run(["config", "core.hooksPath", "/dev/null"])
        func checkCurrent(_ repository: GitRepository, expected: String, prepare: (() async throws -> Void)? = nil) async throws {
            var calls = 0, chosen: String?
            let child = ReferenceBrowserWindowController(repository: repository, access: nil, initial: "HEAD", preferences: prefs) { chosen = $0; calls += 1 }; defer { child.close() }
            child.model.load(); try await wait([child.window!]) { !child.model.busy && child.model.snapshot != nil }
            try await prepare?()
            child.model.query = "no-matching-reference"; child.model.refilter()
            try require(child.model.chosen == nil && child.model.canChooseCurrentBranch, "Current Branch incorrectly requires a visible row")
            child.model.hasChild = true; child.model.currentBranch()
            try require(calls == 0 && !child.model.busy, "Current Branch escaped owned child")
            child.model.hasChild = false
            let oldSnapshot = child.model.snapshot
            child.model.currentBranch(); child.model.currentBranch(); child.model.load(); child.model.accept(); child.model.cancel()
            try require(child.model.busy && calls == 0 && !child.windowShouldClose(child.window!), "Current Branch query/duplicate/refresh/close gates escaped")
            try await wait([child.window!]) { child.model.closed }
            try require(calls == 1 && GitReferenceName.equal(chosen ?? "", expected) && child.model.snapshot?.references.count == oldSnapshot?.references.count && !child.window!.isVisible, "Current Branch result/close differs")
            child.model.currentBranch(); child.model.accept(); child.model.cancel()
            try require(calls == 1 && !child.model.busy, "Closed Current Branch completed twice")
        }
        try await checkCurrent(currentRepo, expected: "refs/heads/late/topic") {
            _ = try await currentRepo.run(["branch", "late/topic"])
            _ = try await currentRepo.run(["symbolic-ref", "HEAD", "refs/heads/late/topic"])
        }
        _ = try await currentRepo.run(["checkout", "--detach", head])
        try await checkCurrent(currentRepo, expected: head)
        let unbornRoot = root.appendingPathComponent("current-unborn.git")
        _ = try await repo.run(["init", "--bare", "-b", "unborn/topic", unbornRoot.path])
        try await checkCurrent(GitRepository(root: unbornRoot, executable: git), expected: "refs/heads/unborn/topic")
        try await checkCurrent(GitRepository(root: bareRoot, executable: git), expected: "refs/heads/main")
        var forcedCalls = 0, forcedResult: String?
        let forced = ReferenceBrowserWindowController(repository: currentRepo, access: nil, initial: "HEAD", preferences: prefs) { value in forcedResult = value; forcedCalls += 1 }; defer { forced.close() }
        forced.model.load(); try await wait([forced.window!]) { !forced.model.busy && forced.model.snapshot != nil }
        forced.model.currentBranch(); forced.close()
        for _ in 0..<30 { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(forced.model.closed && !forced.model.busy && forcedCalls == 1 && forcedResult == nil && forced.model.error == nil, "Closed current-branch query published late")
        let trackingOwner = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "main", preferences: prefs) { _ in }; defer { trackingOwner.close() }
        trackingOwner.presentTrackingPicker = { parent, child in parent.makeFirstResponder(nil); return !parent.isVisible && !child.isVisible }
        trackingOwner.model.load(); try await wait([trackingOwner.window!]) { !trackingOwner.model.busy && trackingOwner.model.chosen != nil }
        trackingOwner.selectTracking()
        guard let trackingChild = trackingOwner.trackingPicker else { throw Failure(description: "Tracking picker missing") }
        try await wait([trackingChild.window!]) { !trackingChild.model.busy && trackingChild.model.snapshot != nil }
        trackingChild.model.currentBranch(); try await wait([trackingOwner.window!]) { trackingOwner.trackingPicker == nil }
        try require(!trackingOwner.model.hasChild && !trackingOwner.model.busy && trackingOwner.model.error == nil && config == Data(contentsOf: root.appendingPathComponent(".git/config")), "Tracking picker applied local Current Branch")
        print("PASS: native reference tree and nine-column single-select table, logical sort/filter/nested persistence/merge/current branch/focus, byte-distinct Unicode and annotated-tag/blob/bare menu gates, original context icons/canonical callbacks and owned Reflog; Reset namespace handoff/fresh catalog/input focus/draft/cancel/stale/reject/duplicate/cross-modal/reset/apply/close/Quit/forced-close locks. Unchanged HEAD/config/index/working bytes. Private defaults/fixtures, no ordered windows or actual sheets; physical/signed/full browser parity unverified.")
    }
}
