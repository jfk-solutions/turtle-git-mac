import AppKit
import TurtleGitCore

@main struct RemoteTagVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws { for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(message: "Timeout") }
    @MainActor static func outline(_ view: NSView) -> NSOutlineView? { if let value = view as? NSOutlineView { return value }; for child in view.subviews { if let value = outline(child) { return value } }; return nil }
    @MainActor static func table(_ view: NSView) -> NSTableView? { if let value = view as? NSTableView, value.accessibilityLabel() == "Remote tags" { return value }; for child in view.subviews { if let value = table(child) { return value } }; return nil }
    @MainActor static func remoteField(_ view: NSView) -> NSTextField? { if let field = view as? NSTextField, field.accessibilityLabel() == "Remote" { return field }; for child in view.subviews { if let field = remoteField(child) { return field } }; return nil }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Remote tag QA failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        let suite = "TurtleGit.RemoteTags.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Remote QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        for name in ["v2", "v10", "keep"] { _ = try await repo.run(["tag", name]) }; _ = try await repo.run(["tag", "-a", "annotated", "-m", "message"])
        for remote in ["alpha", "zeta"] { let bare = root.appendingPathComponent(remote + ".git"); _ = try await repo.run(["clone", "--bare", root.path, bare.path]); _ = try await repo.run(["remote", "add", remote, bare.path]); _ = try await repo.run(["fetch", remote]) }
        let head = try Data(contentsOf: root.appendingPathComponent(".git/HEAD")), index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let owner = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs", preferences: prefs, picking: false) { _ in }; defer { owner.close() }
        owner.presentRemoteTags = { _, _ in true }; var phases: [String] = []
        owner.configureRemoteTags = { child in child.presentProgress = { [weak child] _, _ in if let phase = child?.model.phase { phases.append(phase.rawValue) }; return true } }
        owner.model.load(); try await wait { !owner.model.busy && owner.model.snapshot != nil }; owner.window!.contentView!.layoutSubtreeIfNeeded()
        guard let menu = outline(owner.window!.contentView!)?.menu else { throw Failure(message: "No folder menu") }
        func update() { owner.window!.contentView!.layoutSubtreeIfNeeded(); menu.delegate?.menuNeedsUpdate?(menu) }
        func invoke(_ title: String) throws { update(); guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { throw Failure(message: "Missing " + title) }; try require(item.isEnabled && NSApplication.shared.sendAction(action, to: item.target, from: item), "Folder dispatch") }
        owner.model.setFolder("refs/tags"); update()
        let remoteItems = menu.items.filter { $0.title.hasPrefix("Delete remote tags on") }; try require(remoteItems.map(\.title) == ["Delete remote tags on \"alpha\"…", "Delete remote tags on \"zeta\"…"] && remoteItems.allSatisfy { $0.image?.name() == MenuIcon.remove.contextImage(defaults: prefs)?.name() }, "Source remote tag menu/order/icons")
        try invoke("Delete remote tags on \"alpha\"…"); guard let child = owner.remoteTagDialog else { throw Failure(message: "No owned remote tag dialog") }; try await wait { !child.model.busy && child.model.tags.count == 4 }
        child.window!.contentView!.layoutSubtreeIfNeeded(); guard let native = table(child.window!.contentView!) else { throw Failure(message: "No native tag table") }
        guard let field = remoteField(child.window!.contentView!) else { throw Failure(message: "No remote field") }; try require(!field.isEditable && field.isSelectable && field.stringValue == "alpha", "Remote field readonly/copy usability")
        try require(native.headerView == nil && native.allowsMultipleSelection && child.model.remote == "alpha" && !child.model.canDelete && child.model.selectAllState == .off && owner.model.hasChild, "Dialog/list defaults")
        native.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); try require(child.model.selectAllState == .mixed && child.model.canDelete, "Partial native selection")
        child.model.selectAll(.mixed); try require(child.model.selection.isEmpty, "Indeterminate cycle did not deselect")
        child.model.selectAll(.on); try require(child.model.selection.count == 4 && child.model.selectAllState == .on, "Select all")
        child.model.select(["v2", "v10"]); var captured: [GitReferenceName] = [], answer: CheckedContinuation<Bool, Never>?
        child.model.confirm = { names in captured = names; return await withCheckedContinuation { answer = $0 } }
        child.model.delete(); try await wait { answer != nil }; try require(captured == ["v2", "v10"] && child.model.busy && !child.windowShouldClose(child.window!) && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Captured selection/close/Quit")
        child.model.load(); child.model.delete(); child.model.selectAll(.off); try require(child.model.selection.count == 2, "Pending request escaped gates")
        let abort = answer; answer = nil; abort?.resume(returning: false); try await wait { !child.model.busy }; try require(child.model.selection.count == 2 && child.model.tags.count == 4, "Abort refreshed or deleted")
        child.model.delete(); try await wait { answer != nil }; let yes = answer; answer = nil; yes?.resume(returning: true); try await wait { !child.model.busy && child.model.tags.count == 2 }
        try require(child.model.selection.isEmpty && child.model.selectAllState == .off && child.progressWindow == nil && owner.remoteTagDialog === child && phases == ["Loading…", "Deleting remote refs…", "Loading…"], "Delete progress/Refresh/owned lifetime")
        let other = try await repo.remoteTags(remote: "zeta"); try require(other.count == 4, "Retargeted other remote")
        child.close(); try require(owner.remoteTagDialog == nil && !owner.model.hasChild, "Owner release")
        owner.model.setFolder("refs/remotes/alpha"); update(); try require(menu.items.contains { $0.title == "Delete remote tags…" } && menu.items.contains { $0.title == "Fetch from \"alpha\"" }, "Remote folder commands")
        owner.model.setFolder("refs/remotes/zeta"); owner.presentFetch = { _, _ in true }; var configuredFetch = 0; owner.model.configureFetch = { _ in configuredFetch += 1 }
        try invoke("Fetch from \"zeta\""); guard let fetch = owner.fetchDialog else { throw Failure(message: "No actual folder Fetch dialog") }; try await wait { !fetch.model.busy }
        try require(configuredFetch == 1 && fetch.model.options.remote == "zeta" && !fetch.model.options.allRemotes && !fetch.model.options.arbitraryURL && owner.model.hasChild, "Actual folder Fetch preset/configuration")
        fetch.close(); try await wait { !owner.model.busy }; try require(owner.fetchDialog == nil && !owner.model.hasChild, "Folder Fetch close/Refresh")
        owner.model.setFolder("refs/remotes/alpha")
        var fetches: [String] = []; owner.model.onFetchFolder = { fetches.append($0) }; try invoke("Fetch from \"alpha\""); try require(fetches == ["alpha"], "Remote folder fetch preset")
        try invoke("Delete remote tags…"); guard let closing = owner.remoteTagDialog else { throw Failure(message: "No remote folder dialog") }; try await wait { !closing.model.busy }; closing.model.select(["keep"]); closing.model.confirm = { _ in await withCheckedContinuation { answer = $0 } }; closing.model.delete(); try await wait { answer != nil }; owner.close(); let late = answer; answer = nil; late?.resume(returning: true); try await Task.sleep(nanoseconds: 100_000_000); let still = try await repo.remoteTags(remote: "alpha"); try require(still.contains { $0.name == "keep" }, "Late Yes deleted")
        for stage in ["ls-remote", "check-ref-format", "push"] {
            let helper = root.appendingPathComponent("slow-" + stage), marker = URL(fileURLWithPath: helper.path + ".started"), pause = URL(fileURLWithPath: helper.path + ".pause"), quoted = "'" + git.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let script = """
            #!/bin/sh
            task_match=false
            for task_argument in "$@"; do
              if [ "$task_argument" = '\(stage)' ]; then task_match=true; fi
            done
            if [ "$task_match" = true ] && [ -f "$0.pause" ]; then
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.started"
              wait "$task_child"
            fi
            exec \(quoted) "$@"
            """
            try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let pending = RemoteTagWindowController(repository: GitRepository(root: root, executable: helper), access: nil, remote: "alpha", preferences: prefs); var ids: [Int32] = []; defer { pending.close(); for pid in ids where kill(pid, 0) == 0 { _ = kill(pid, SIGTERM) } }
            pending.presentProgress = { _, _ in true }; pending.model.confirm = { _ in true }
            if stage == "ls-remote" { try Data().write(to: pause); pending.model.load() } else { pending.model.load(); try await wait { !pending.model.busy }; pending.model.select(["keep"]); try Data().write(to: pause); pending.model.delete() }
            try await wait { FileManager.default.fileExists(atPath: marker.path) }; ids = try String(contentsOf: marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }; try require(ids.count == 2 && ids.allSatisfy { kill($0, 0) == 0 }, "Live remote tag process missing")
            if stage == "push" { pending.progressWindow?.close() } else { pending.close() }
            try await wait { ids.allSatisfy { kill($0, 0) != 0 } }; try await Task.sleep(nanoseconds: 100_000_000)
            try require(pending.model.closed && !pending.model.busy && pending.model.error == nil && pending.progressWindow == nil, "Late remote tag process result")
            print("PASS remote tag forced cleanup: " + stage)
        }
        let after = try await repo.remoteTags(remote: "alpha"); try require(after.contains { $0.name == "keep" }, "Forced deletion completed")
        try require(head == Data(contentsOf: root.appendingPathComponent(".git/HEAD")) && index == Data(contentsOf: root.appendingPathComponent(".git/index")) && config == Data(contentsOf: root.appendingPathComponent(".git/config")) && file == Data(contentsOf: root.appendingPathComponent("file")), "Local repository changed")
        try require(!NSApplication.shared.windows.contains { $0.isVisible }, "QA displayed windows")
        print("PASS remote tag source folder icons/routes, actual list/selection/tri-state, Abort/Delete/Refresh, progress ownership, capture/close/Quit and late/forced process cleanup")
    }
}
