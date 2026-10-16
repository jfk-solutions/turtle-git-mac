import AppKit
import Darwin
import TurtleGitCore

@main struct LogRangeSelectionVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var owners: [LogWindowController] = []
    @MainActor static var helpers: [pid_t] = []
    @MainActor static var marker: URL?
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<3000 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Log range timeout at \(line)")
    }
    @MainActor static func views(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { views($0) } }
    @MainActor static func leaves(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { $0.submenu.map(leaves) ?? ($0.action == nil ? [] : [$0]) } }
    static func stopped(_ pids: [pid_t]) -> Bool { pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
    @MainActor static func cleanup() async {
        owners.forEach { $0.model.invalidate(); $0.close() }
        if let marker, let text = try? String(contentsOf: marker) { helpers += text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) } }
        for pid in Set(helpers) where kill(pid, 0) == 0 { _ = kill(pid, SIGTERM) }
        for _ in 0..<300 { if stopped(helpers) { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        for pid in Set(helpers) where kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
    }
    @MainActor static func main() async {
        do { try await verify(); await cleanup(); try require(stopped(helpers), "Owned helper survived") }
        catch { await cleanup(); fputs("Log range selection failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Range QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        var hashes: [String] = []
        for index in 0...8 {
            let path = index.isMultiple(of: 2) ? (index >= 4 ? "renamed" : "file") : "other"
            if index == 4 { _ = try await repo.run(["mv", "file", "renamed"]) }
            let contents = (1...32).map { "stable context \($0)\n" }.joined() + "row \(index)\n"
            try Data(contents.utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
            _ = try await repo.commit(message: "row \(index) " + (index.isMultiple(of: 2) ? "keep" : "hide"))
            hashes.append(String(decoding: try await repo.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines))
            if [2, 4, 6].contains(index) { _ = try await repo.run(["tag", "mark-\(index)"]) }
        }
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try await repo.run(["write-tree"]).stdout
        let wrapper = root.appendingPathComponent("range-git"), hold = root.appendingPathComponent("range-git.hold"), started = root.appendingPathComponent("range-git.started")
        marker = started
        let quoted = "'" + git.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        if [ "$4" = rev-parse ] && [ "$5" = --verify ] && [ -f "$0.hold" ]; then
          /bin/rm "$0.hold"
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null' USR1
          printf '%s %s\\n' "$$" "$task_child" > "$0.started.tmp"
          /bin/mv "$0.started.tmp" "$0.started"
          wait "$task_child"
        fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let status = try await repo.run(["status", "--porcelain=v1", "-z"]).stdout
        let wrapped = GitRepository(root: root, executable: wrapper)
        let suite = "TurtleGit.LogRangeSelection." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(false, forKey: "EnableGravatar"); prefs.set(false, forKey: "LogIncludeWorkingTreeChanges"); prefs.set(false, forKey: "UseRegexFilter")
        let regex = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let owner = LogWindowController(repository: wrapped, access: nil, labelDefaults: prefs, savesColumnLayout: false, savesGeometry: false, historyRegexExecutable: regex), model = owner.model
        owners.append(owner); owner.window?.alphaValue = 0; owner.window?.orderFront(nil); model.showWorkingTree = false; model.reload()
        try await wait { !model.busy && !model.loadingHistory && model.entries.count == 9 && views(owner.window?.contentView).contains { $0 is HistoryTableView } }
        guard let table = views(owner.window?.contentView).compactMap({ $0 as? HistoryTableView }).first, let coordinator = table.delegate as? RevisionTable.Coordinator, let menu = table.menu else { throw Failure(description: "Native report menu missing") }
        let clipboard = NSPasteboard.withUniqueName(); model.clipboard = clipboard; defer { clipboard.releaseGlobally() }
        var comparisons = 0, patches: [FormatPatchPreset] = [], combined = 0
        model.onCompare = { _, _ in comparisons += 1 }; model.onFormatPatch = { patches.append($0) }; model.onCombineRevisions = { _, _, _ in combined += 1 }
        func ready() async throws { try await wait { !model.busy && !model.loadingHistory && LogWindowModel.activeHistoryLoads == 0 } }
        func choose(_ values: [LogEntry]) {
            let ids = Set(values.map(\.hash)); table.selectRowIndexes(IndexSet(model.entries.indices.filter { ids.contains(model.entries[$0].hash) }), byExtendingSelection: false)
            model.select(ids); coordinator.menuNeedsUpdate(menu)
        }
        func item(_ selector: String) -> NSMenuItem? { leaves(menu).first { $0.action.map(NSStringFromSelector) == selector } }
        func send(_ value: NSMenuItem?) throws { guard let value, let action = value.action else { throw Failure(description: "Missing action") }; _ = NSApp.sendAction(action, to: value.target, from: value) }
        func search(_ value: String) async throws { model.search = value; model.reload(); try await ready(); try require(model.error == nil, "Search failed: " + (model.error ?? "")) }
        choose(Array(model.entries.prefix(3)))
        try require(!model.historyHasHiddenRows && model.continuousRevisionSelection && item("compare") != nil && item("formatPatch") != nil, "Unfiltered continuous commands missing")
        try await wait { item("combineRevisions:")?.isHidden == false && item("combineRevisions:")?.isEnabled == true }
        // Filtering hides raw rows; three adjacent displayed entries do not
        // become a source continuous range. Two and single are explicit exceptions.
        model.selectSearchFields(.subject); try await search("keep")
        try require(model.entries.count == 5 && model.historyHasHiddenRows, "Search did not retain hidden raw-walk count")
        choose(Array(model.entries.prefix(3)))
        try require(!model.continuousHistorySelection && !model.canCompareRevisionSelection && model.formatPatchPreset == nil && item("compare") == nil && item("formatPatch") == nil && item("combineRevisions:") == nil, "Filtered adjacent range exposed hidden-row commands")
        choose(Array(model.entries.prefix(2)))
        try require(!model.continuousHistorySelection && model.canCompareRevisionSelection && model.formatPatchPreset != nil && item("compare") != nil && item("formatPatch") != nil && item("combineRevisions:") == nil, "Source two-row exception or Combine filter gate missing")
        try send(item("formatPatch")); try require(patches.last?.selection == .range(from: model.revisions.last!.hash + "~1", to: model.revisions.first!.hash), "Filtered pair lost inclusive oldest/newest preset")
        choose(Array(model.entries.prefix(1))); try require(model.continuousHistorySelection && model.formatPatchPreset != nil, "Single filtered row must be continuous")
        let filtered = model.entries.map(\.hash)
        model.endRevision = "not-an-existing-revision"; model.reload(); try await ready()
        try require(model.error != nil && model.entries.map(\.hash) == filtered && model.historyHasHiddenRows, "Failed load lost coherent hidden-row snapshot")
        model.endRevision = nil; model.error = nil; try await search("row")
        choose(Array(model.entries.prefix(3))); try require(model.entries.count == 9 && !model.historyHasHiddenRows && model.continuousHistorySelection && item("formatPatch") != nil, "Active all-matching filter incorrectly blocks ranges")
        try await search(""); model.toggleHistoryWalk(.labeled); try await ready()
        try require(model.entries.count >= 4 && model.historyHasHiddenRows, "Labeled graph did not hide raw rows")
        choose(Array(model.entries.prefix(3))); try require(item("compare") == nil && item("formatPatch") == nil && item("combineRevisions:") == nil, "Graph projection fabricated continuous range")
        model.toggleHistoryWalk(.labeled); try await ready()
        // Follow's raw walk is already file-scoped. Unrelated commits absent
        // from that walk do not count as hidden display rows in the source.
        try await search(""); model.setPathScope(["renamed"]); try await ready(); model.toggleHistoryWalk(.followRenames); try await ready()
        try require(model.historyWalk.followRenames && model.entries.count == 5 && !model.historyHasHiddenRows, "Follow walk introduced an unsupported full-history gap restriction: enabled=\(model.historyWalk.followRenames), rows=\(model.entries.count), hidden=\(model.historyHasHiddenRows)")
        choose(Array(model.entries.prefix(3))); try require(model.continuousHistorySelection && item("compare") != nil && item("formatPatch") != nil, "Follow range lost source display continuity")
        model.setPathScope([]); try await ready(); try require(model.entries.count == 9 && !model.historyHasHiddenRows, "Whole-project walk not restored")
        // A retained popup cannot act after the displayed ordering changes,
        // even if its selected hashes/references and load generation are equal.
        let original = model.entries
        choose(Array(original.prefix(2))); let copied = item("copyHashes"), generation = model.contextMenuGeneration
        clipboard.clearContents(); clipboard.setString("sentinel", forType: .string)
        var replaced = original; let moved = replaced.remove(at: 2); replaced.insert(moved, at: 1); model.entries = replaced
        try require(model.contextMenuGeneration == generation, "Fixture changed load/selection generation")
        try send(copied); try require(clipboard.string(forType: .string) == "sentinel", "Old popup survived projection replacement")
        model.entries = original; model.select(Set(original.prefix(2).map(\.hash)))
        // Hold a real Combine ancestry reader through a projection replacement.
        // Its valid old result must not reveal/enable a stale native menu item.
        try Data().write(to: hold); coordinator.menuNeedsUpdate(menu)
        guard let combine = item("combineRevisions:") else { throw Failure(description: "Combine placeholder missing") }
        try await wait { FileManager.default.fileExists(atPath: started.path) }
        helpers = try String(contentsOf: started).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        try require(helpers.count == 2 && HistoryCombineSelectionReader.activeReads > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Held Combine read lost process/Quit lifetime")
        model.entries = replaced; _ = kill(helpers[0], SIGUSR1)
        try await wait { HistoryCombineSelectionReader.activeReads == 0 && stopped(helpers) }
        try require(combine.isHidden && !combine.isEnabled && combined == 0, "Late Combine validation enabled stale projected target")
        try send(combine); try require(combined == 0, "Stale Combine action dispatched")
        coordinator.menuDidClose(menu); owner.close()
        try FileManager.default.removeItem(at: started)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterIndex = try await repo.run(["write-tree"]).stdout, afterStatus = try await repo.run(["status", "--porcelain=v1", "-z"]).stdout
        try require(afterHead == head && afterIndex == index && afterStatus == status && comparisons == 0, "Menu/filter/read workflow changed repository or dispatched comparison")
        print("PASS: Log filtered/labeled/Follow range continuity, single/two exceptions, Format Patch/Compare/Combine menus, failed-load snapshot, projection-bound popup/ancestry replies and read ownership; owned windows/helpers closed")
    }
}
