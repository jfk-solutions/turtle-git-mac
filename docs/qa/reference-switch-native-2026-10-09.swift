import AppKit
import Darwin
import TurtleGitCore

@main struct ReferenceSwitchVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func find<T: NSView>(_ type: T.Type, _ view: NSView, label: String) -> T? {
        if let result = view as? T, result.accessibilityLabel() == label { return result }
        for child in view.subviews { if let result = find(type, child, label: label) { return result } }; return nil
    }
    @MainActor static func wait(_ windows: [NSWindow], _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }; if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Timed out")
    }
    @MainActor static func main() async { do { try await verify() } catch { print("FAIL: \(error)"); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.ReferenceSwitch.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        print("PREFERENCES: " + suite)
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        prefs.set(false, forKey: "SwitchToTagNewBranch"); prefs.set(false, forKey: "SwitchToCommitNewBranch")
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Switch context QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.run(["commit", "-m", "base"])
        let hash = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["tag", "release"]); _ = try await repo.run(["-c", "tag.gpgsign=false", "tag", "-a", "annotated", "-m", "tag"])
        for ref in ["refs/remotes/origin/main", "refs/notes/custom"] { _ = try await repo.run(["update-ref", ref, hash]) }
        _ = try await repo.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        let blob = try await repo.run(["hash-object", "-w", "file"]).text.trimmingCharacters(in: .newlines); _ = try await repo.run(["update-ref", "refs/custom/blob", blob])
        let nfc = "refs/heads/Café", nfd = "refs/heads/Cafe\u{301}"
        _ = try await repo.run(["pack-refs", "--all", "--prune"])
        let packed = root.appendingPathComponent(".git/packed-refs"); var contents = try String(contentsOf: packed, encoding: .utf8)
        contents = contents.replacingOccurrences(of: " sorted", with: "") + hash + " " + nfc + "\n" + hash + " " + nfd + "\n"
        try Data(contents.utf8).write(to: packed)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, config = try Data(contentsOf: root.appendingPathComponent(".git/config")), index = try Data(contentsOf: root.appendingPathComponent(".git/index")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let browser = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs/heads/main", preferences: prefs, onChoose: { _ in })
        defer { browser.close() }; let window = browser.window!
        var configured = 0; browser.model.configureSwitch = { child in
            configured += 1
            child.configureReferencePicker = { model in model.onLog = { _ in } }
            child.presentPicker = { parent, _ in parent.makeFirstResponder(nil); return true }
            child.model.onPostAction = { _, _ in }
        }
        browser.presentSwitch = { parent, _ in parent.makeFirstResponder(nil); return true }
        browser.model.load(); try await wait([window]) { !browser.model.busy && browser.model.snapshot != nil }
        func select(_ reference: String) async throws {
            let choice = browser.model.snapshot!.initialSelection(reference); browser.model.folder = choice.folder; browser.model.selected = choice.reference
            try await wait([window]) { browser.model.chosen?.name == GitReferenceName(reference) }
        }
        func invoke() throws {
            guard let table = find(NSTableView.self, window.contentView!, label: "References"), let menu = table.menu else { throw Failure(description: "Current native menu missing") }
            menu.delegate?.menuNeedsUpdate?(menu)
            guard let command = menu.items.first(where: { $0.title == "Switch/Checkout to this…" }), command.isEnabled, command.image != nil, command.target != nil else { throw Failure(description: "Original Switch icon/menu missing") }
            _ = (command.target as? NSObject)?.perform(command.action!)
        }
        for (ref, target, create) in [("refs/heads/main", CheckoutTarget.branch, false), ("refs/remotes/origin/main", .branch, true), ("refs/remotes/origin/HEAD", .branch, true), ("refs/tags/release", .tag, false), ("refs/notes/custom", .commit, false), (nfc, .branch, false), (nfd, .branch, false)] {
            try await select(ref); try invoke()
            guard let child = browser.switchDialog else { throw Failure(description: "Owned Switch absent") }
            try await wait([window, child.window!]) { !child.model.busy && !child.model.references.isEmpty }
            try require(child.model.options.target == target && GitReferenceName.equal(child.model.revision, ref) && child.model.options.createBranch == create, "Canonical preset/role/private preference defaults")
            try require(child.model.repository === repo && child.model.onPostAction != nil, "Same repository/configuration hook")
            if target != .commit {
                let label = target == .tag ? "Switch tag revision" : "Switch branch revision"
                guard let popup = find(NSPopUpButton.self, child.window!.contentView!, label: label) else { throw Failure(description: "Native revision popup missing") }
                let rows = target == .tag ? child.model.tags : child.model.branches
                try require(rows.indices.contains(popup.indexOfSelectedItem) && GitReferenceName.equal(rows[popup.indexOfSelectedItem].name, ref), "Native exact selected popup")
            } else {
                guard let field = find(NSTextField.self, child.window!.contentView!, label: "Switch commit revision") else { throw Failure(description: "Native commit field missing") }
                try require(field.stringValue == ref, "Native commit preset")
            }
            try require(browser.model.hasChild && !browser.model.canAccept && !browser.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Parent/close/Quit lock")
            let count = configured; browser.showSwitch(); browser.selectTracking(); browser.model.load(); browser.editDescription()
            try require(configured == count && browser.switchDialog === child && !browser.model.busy, "Duplicate/competing gates")
            child.model.close(); try require(browser.switchDialog == nil && !browser.model.hasChild, "Cancel releases owned child")
        }
        for reference in ["refs/tags/annotated", "refs/custom/blob"] {
            try await select(reference); try require(!browser.model.canSwitch, "Noncommit gate"); browser.showSwitch(); try require(browser.switchDialog == nil, "Noncommit child rejected")
        }
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = ReferenceBrowserWindowController(repository: GitRepository(root: bareRoot, executable: repo.executable), access: nil, initial: "refs/heads/main", preferences: prefs, onChoose: { _ in }); defer { bare.close() }
        bare.model.load(); try await wait([bare.window!]) { !bare.model.busy && bare.model.snapshot != nil }; try require(bare.model.bare && !bare.model.canSwitch, "Bare Switch gate"); bare.showSwitch(); try require(bare.switchDialog == nil, "Bare child rejected"); bare.close()
        try await select("refs/heads/main"); browser.presentSwitch = { _, _ in false }; browser.showSwitch(); try require(browser.switchDialog == nil && !browser.model.hasChild, "Rejected presentation cleanup")
        browser.presentSwitch = { parent, _ in parent.makeFirstResponder(nil); return true }; browser.showSwitch()
        guard let forced = browser.switchDialog else { throw Failure(description: "Forced child absent") }; try await wait([window, forced.window!]) { !forced.model.busy }
        forced.model.browse(.branch); guard let nested = forced.referencePicker else { throw Failure(description: "Nested full browser absent") }
        try await wait([window, forced.window!, nested.window!]) { !nested.model.busy && nested.model.snapshot != nil }
        browser.close(); try require(browser.model.closed && browser.switchDialog == nil && forced.referencePicker == nil && nested.model.closed, "Forced parent/nested picker cleanup")
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; try require(head == after && config == Data(contentsOf: root.appendingPathComponent(".git/config")) && index == Data(contentsOf: root.appendingPathComponent(".git/index")) && file == Data(contentsOf: root.appendingPathComponent("file")), "Opening/cancelling routes leaves repository unchanged")
        print("PHASE: Complete browser-owned checkout and progress acknowledgements")
        let transactionRoot = root.appendingPathComponent("transaction")
        try FileManager.default.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
        let transaction = GitRepository(root: transactionRoot, executable: repo.executable)
        _ = try await transaction.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Transaction QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await transaction.run(["config", key, value]) }
        let transactionFile = transactionRoot.appendingPathComponent("file")
        try Data("older\n".utf8).write(to: transactionFile); try await transaction.stage(["file"]); _ = try await transaction.run(["commit", "-m", "older"])
        let older = try await transaction.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await transaction.run(["branch", "older"])
        try Data("main\n".utf8).write(to: transactionFile); try await transaction.stage(["file"]); _ = try await transaction.run(["commit", "-m", "main"])
        for policy in 0...2 {
            _ = try await transaction.run(["checkout", "main"]); prefs.set(policy, forKey: "AutoCloseGitProgress")
            var chosen: String?, choices = 0, changes = 0, switched = 0, post: SwitchPostAction?, previous: String?, ended: (() -> Void)?
            let parent = ReferenceBrowserWindowController(repository: transaction, access: nil, initial: "refs/heads/older", preferences: prefs) { chosen = $0; choices += 1 }; defer { parent.close() }
            parent.presentSwitch = { owner, _ in owner.makeFirstResponder(nil); return true }
            parent.model.configureSwitch = { child in
                child.model.onChanged = { _ in changes += 1 }; child.model.onSwitched = { _ in switched += 1 }
                child.model.onPostAction = { action, branch in post = action; previous = branch }
                child.presentProgress = { owner, progressWindow, completed in
                    owner.makeFirstResponder(nil)
                    guard let controller = progressWindow.delegate as? SwitchProgressWindowController else { return false }
                    controller.onClosed = completed; ended = completed; return true
                }
            }
            parent.model.load(); try await wait([parent.window!]) { !parent.model.busy && parent.model.chosen != nil }
            parent.showSwitch(); guard let child = parent.switchDialog else { throw Failure(description: "Transaction Switch missing") }
            try await wait([parent.window!, child.window!]) { !child.model.busy && !child.model.references.isEmpty }
            child.model.checkout(); child.model.branchRevision = "refs/heads/main"; child.model.options.overwriteChanges = true; child.model.checkout()
            try await wait([parent.window!, child.window!]) { changes == 1 }
            let branch = try await transaction.branch(), actualHead = try await transaction.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
            try require(branch == "older" && actualHead == older && Data(contentsOf: transactionFile) == Data("older\n".utf8), "Owned route did not checkout captured target")
            if policy < 2 {
                guard let progress = child.progressController else { throw Failure(description: "Owned progress controller missing") }
                defer { progress.close() }
                try require(progress.model.success && progress.model.reference == "refs/heads/older" && !progress.model.options.overwriteChanges && child.model.busy && parent.model.hasChild && switched == 0, "Captured options/acknowledgement lock differs")
                try require(!parent.windowShouldClose(parent.window!) && !child.windowShouldClose(child.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Completed progress escaped parent/close/Quit locks")
                if policy == 1 { progress.model.perform(.pull) } else { progress.model.close() }
            }
            try await wait([parent.window!, child.window!]) { parent.switchDialog == nil }
            try require(changes == 1 && switched == 1 && !parent.model.hasChild && !child.model.busy && child.model.progress == nil && child.progressController == nil, "Progress acknowledgement did not release owned route")
            ended?(); child.model.checkout(); try require(switched == 1 && changes == 1, "Duplicate progress completion or checkout")
            if policy == 1 { try require(post == .pull && previous == "main", "Owned post-action lost previous branch") }
            try require(parent.model.snapshot?.currentBranch == "refs/heads/main", "Browser unexpectedly reloaded after Switch")
            parent.model.currentBranch(); try await wait([parent.window!]) { parent.model.closed }
            try require(chosen == "refs/heads/older" && choices == 1, "Current Branch did not read completed checkout")
        }
        print("PHASE: Rejected owned progress presentation")
        _ = try await transaction.run(["checkout", "main"]); prefs.set(0, forKey: "AutoCloseGitProgress")
        let rejected = SwitchWindowController(repository: transaction, access: nil, preferences: prefs); defer { rejected.close() }
        rejected.presentProgress = { _, _, _ in false }; rejected.model.load(revision: "refs/heads/older")
        try await wait([rejected.window!]) { !rejected.model.busy }; rejected.model.checkout()
        try await wait([rejected.window!]) { !rejected.model.busy }
        let retained = try await transaction.branch()
        try require(retained == "main" && rejected.model.progress == nil && rejected.progressController == nil && rejected.model.error == nil, "Rejected progress leaked ownership or performed checkout")
        rejected.close()
        print("PHASE: Forced parent close during each initial metadata read")
        for command in ["for-each-ref", "branch"] {
            let helper = root.appendingPathComponent("slow-metadata-" + command), marker = URL(fileURLWithPath: helper.path + ".started"), arm = URL(fileURLWithPath: helper.path + ".armed"), release = URL(fileURLWithPath: helper.path + ".release")
            let quoted = "'" + repo.executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let script = """
            #!/bin/sh
            if [ "${4-}" = \(command) ] && [ -f "$0.armed" ] && [ ! -f "$0.release" ]; then
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.started"
              wait "$task_child"
            fi
            exec \(quoted) "$@"
            """
            try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let slow = GitRepository(root: transactionRoot, executable: helper)
            let parent = ReferenceBrowserWindowController(repository: slow, access: nil, initial: "refs/heads/older", preferences: prefs) { _ in }; defer { parent.close() }
            parent.presentSwitch = { owner, _ in owner.makeFirstResponder(nil); return true }
            parent.model.load(); try await wait([parent.window!]) { !parent.model.busy && parent.model.chosen != nil }
            try Data().write(to: arm); parent.showSwitch()
            guard let child = parent.switchDialog else { throw Failure(description: "Slow owned Switch missing") }
            var pids: [Int32] = []
            defer { try? Data().write(to: release); for pid in pids where kill(pid, 0) == 0 { _ = kill(pid, SIGTERM) } }
            try await wait([parent.window!, child.window!]) { FileManager.default.fileExists(atPath: marker.path) }
            pids = try String(contentsOf: marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
            try require(pids.count == 2 && pids.allSatisfy { kill($0, 0) == 0 } && child.model.busy && child.model.references.isEmpty, "Metadata read was not live or published partial catalog")
            let options = child.model.options, draft = child.model.commitRevision
            parent.close()
            try await wait([child.window!]) { pids.allSatisfy { kill($0, 0) != 0 } }
            for _ in 0..<30 { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(parent.model.closed && parent.switchDialog == nil && !parent.model.hasChild && !child.model.busy && child.model.references.isEmpty && child.model.error == nil && child.model.commitRevision == draft && child.model.options.target == options.target && child.model.branchRevision.isEmpty, "Closed metadata read published late")
        }
        try require(NSApplication.shared.windows.allSatisfy { !$0.isVisible }, "No displayed windows")
        print("PASS: actual Switch context icon/owned controller, canonical roles/native fields/private defaults/Unicode, bare/type gates, parent/close/Quit/duplicate/cancel/reject/forced nested cleanup; real captured checkout and acknowledgement with all three policies, owned post-action, live Current Branch, rejected progress and cancelled live initial catalog/branch reads. Original open/cancel fixture unchanged; transaction mutations confined to private repository.")
    }
}
