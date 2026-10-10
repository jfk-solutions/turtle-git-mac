import AppKit
import SwiftUI
import TurtleGitCore

@main struct RollupVerification {
    struct Failure: Error { let description: String }
    @MainActor static func graphCell(_ table: NSTableView, row: Int) async throws -> GraphCell {
        for _ in 0..<20 { table.window?.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "graph" }),
              let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? GraphCell else {
            throw Failure(description: "Native graph cell missing")
        }
        guard cell.isAccessibilityElement(), cell.accessibilityRole() == .image else { throw Failure(description: "Graph is not exposed as an accessible image") }
        return cell
    }
    @MainActor static func wait(_ model: LogWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil, model.error ?? "History did not finish")
    }
    @MainActor static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = table(in: child) { return table } }
        return nil
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Rollup QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        var hashes: [String] = []
        for index in 0..<6 {
            try Data("\(index)".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "c\(index)")
            hashes.append(try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines))
        }
        _ = try await repo.run(["tag", "root", hashes[0]]); _ = try await repo.run(["tag", "boundary", hashes[2]])
        let paths = [".git/index", ".git/config", ".git/HEAD", "file"]
        let before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let suite = "TurtleGit.Rollup.QA." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        // Model-specific visibility defaults are private; no avatar requests.
        defaults.set(false, forKey: "EnableGravatar")
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: defaults, historyRegexExecutable: helper)
        defer { model.invalidate() }
        model.showWorkingTree = false; model.search = ""; model.searchRegex = false
        model.reload(); try await wait(model)
        precondition(model.entries.count == 6 && model.canToggleRollup && model.rollupTitle == "Collapse")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentViewController = NSHostingController(rootView: LogDialog(model: model)); window.contentView?.layoutSubtreeIfNeeded()
        guard let table = table(in: window.contentView!), let menu = table.menu else { preconditionFailure("Native revision menu missing") }
        let initialCell = try await graphCell(table, row: 0)
        precondition(initialCell.accessibilityLabel() == "Commit, 1 parent, graph lane 1, expanded")
        let rootCell = try await graphCell(table, row: 5)
        precondition(rootCell.accessibilityLabel() == "Root commit, 0 parents, graph lane 1, expanded")
        menu.delegate?.menuNeedsUpdate?(menu)
        let fullCollapse = menu.indexOfItem(withTitle: "Collapse"); precondition(fullCollapse >= 0)
        menu.performActionForItem(at: fullCollapse); try await wait(model)
        let collapsedCell = try await graphCell(table, row: 0)
        precondition(collapsedCell.accessibilityLabel() == "Commit, 1 parent, graph lane 1, collapsed")
        precondition(model.entries.map(\.hash) == [hashes[5],hashes[2],hashes[1],hashes[0]], "Full-view Collapse must preserve labels and show regular rows after an expanded label boundary")
        model.toggleHistoryLabel(.tags); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5]], "Full-view label changes with forced states must reload the projection")
        model.toggleHistoryLabel(.tags); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5],hashes[2],hashes[1],hashes[0]])
        model.select([hashes[5]]); menu.delegate?.menuNeedsUpdate?(menu)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Expand")); try await wait(model)
        let expandedCell = try await graphCell(table, row: 0)
        precondition(expandedCell.accessibilityLabel() == "Commit, 1 parent, graph lane 1, expanded")
        precondition(model.entries.count == 6 && !model.graph[0].collapsed)
        model.toggleHistoryWalk(.compressed); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5],hashes[2],hashes[0]] && model.rollupTitle == "Expand")
        menu.delegate?.menuNeedsUpdate?(menu)
        let expand = menu.indexOfItem(withTitle: "Expand"); precondition(expand >= 0 && expand < menu.indexOfItem(withTitle: "Copy to clipboard"))
        menu.performActionForItem(at: expand); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5], hashes[4], hashes[3], hashes[2], hashes[0]])
        precondition(model.rollupTitle == "Collapse" && !model.graph[0].collapsed && model.entries[0].parents == [hashes[4]])
        model.select([hashes[4]]); model.toggleRollup(); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5], hashes[4], hashes[2], hashes[0]], "Forced mid-segment collapse did not hide the next ordinary parent")
        model.toggleRollup(); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5], hashes[4], hashes[3], hashes[2], hashes[0]], "Reversing override did not restore inherited expansion")
        model.select([hashes[5]])
        menu.delegate?.menuNeedsUpdate?(menu); menu.performActionForItem(at: menu.indexOfItem(withTitle: "Collapse")); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5], hashes[2], hashes[0]])
        model.select([hashes[2]]); model.toggleRollup(); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5], hashes[2], hashes[1], hashes[0]])
        model.select([hashes[1]]); precondition(model.rollupTitle == "Collapse"); model.toggleRollup(); try await wait(model)
        precondition(model.rollupInfo[hashes[1]]?.forced == true)
        model.select([hashes[5], hashes[2]]); precondition(!model.canToggleRollup)
        model.search = "c"; model.reload(); try await wait(model); precondition(!model.canToggleRollup)
        model.search = "["; model.searchRegex = true; model.reload(); try await wait(model); model.select([hashes[5]])
        precondition(model.canToggleRollup, "Invalid regex did not retain source inactive-filter behavior")
        model.busy = true; precondition(!model.canToggleRollup); model.toggleRollup(); model.busy = false
        model.invalidate(); precondition(!model.canToggleRollup)
        // The upstream Advanced preference is captured when a Log is opened.
        defaults.set(true, forKey: "LogIncludeBoundaryCommits")
        let boundaries = LogWindowModel(repository: repo, access: nil, labelDefaults: defaults, historyRegexExecutable: helper)
        defer { boundaries.invalidate() }
        boundaries.showWorkingTree = false; boundaries.search = ""; boundaries.searchRegex = false
        boundaries.revisionRange = HistoryRevisionRange(from: hashes[3], to: hashes[5])
        boundaries.reload(); try await wait(boundaries)
        precondition(boundaries.entries.map(\.hash) == [hashes[5],hashes[4],hashes[3]])
        precondition(boundaries.entries.map(\.isBoundary) == [false,false,true])
        precondition(boundaries.entries.last?.parents == [hashes[2]] && boundaries.graph.last!.lanes.contains { $0.isBoundary })
        let boundaryCell = GraphCell(); boundaryCell.parentCount = boundaries.entries.last!.parents.count; boundaryCell.graph = boundaries.graph.last!
        precondition(boundaryCell.accessibilityLabel()?.contains("boundary, 1 parent") == true)
        // Representative native cells use Core-projected merge/fork metadata;
        // this checks accessibility descriptions, not additional topology math.
        let kindEntries = [LogEntry(hash: "merge", author: "", date: "", subject: "", parents: ["a", "b"]),
                           LogEntry(hash: "a", author: "", date: "", subject: "", parents: ["root"]),
                           LogEntry(hash: "b", author: "", date: "", subject: "", parents: ["root"]),
                           LogEntry(hash: "root", author: "", date: "", subject: "")]
        let kindGraph = CommitGraph.layout(kindEntries)
        let kindCell = GraphCell(); kindCell.parentCount = 2; kindCell.graph = kindGraph[0]
        precondition(kindCell.accessibilityLabel() == "Merge commit, 2 parents, graph lane 1, expanded")
        kindCell.parentCount = 0; kindCell.graph = kindGraph[3]
        precondition(kindCell.accessibilityLabel()?.hasPrefix("Branch point, 0 parents") == true)
        kindCell.workingTree = true
        precondition(kindCell.accessibilityLabel()?.hasPrefix("Working tree,") == true)
        kindCell.graph = nil
        precondition(!kindCell.isAccessibilityElement() && kindCell.accessibilityLabel() == nil)
        defaults.set(false, forKey: "LogIncludeBoundaryCommits")
        let ordinary = LogWindowModel(repository: repo, access: nil, labelDefaults: defaults, historyRegexExecutable: helper)
        defer { ordinary.invalidate() }
        ordinary.showWorkingTree = false; ordinary.search = ""; ordinary.searchRegex = false
        ordinary.revisionRange = boundaries.revisionRange; ordinary.reload(); try await wait(ordinary)
        precondition(ordinary.entries.map(\.hash) == [hashes[5],hashes[4]] && !ordinary.entries.contains { $0.isBoundary })
        let searched = LogWindowModel(repository: repo, access: nil, labelDefaults: defaults, historyRegexExecutable: helper)
        defer { searched.invalidate() }; searched.showWorkingTree = false; searched.searchFields = .messages; searched.searchRegex = false; searched.search = "c3"
        searched.reload(); try await wait(searched)
        let fullOptions = HistoryOptions(); let full = try await repo.history(options: fullOptions)
        precondition(searched.entries.map(\.hash) == [hashes[3]] && searched.entries[0].parents == [hashes[2]])
        precondition(searched.graph[0].lanes == CommitGraph.layout(full)[2].lanes && !searched.canToggleRollup)
        searched.search = ""; searched.reload(); try await wait(searched); searched.toggleHistoryWalk(.compressed); try await wait(searched)
        searched.select([hashes[5]]); searched.toggleRollup(); try await wait(searched)
        searched.search = "c3 +c1"; searched.reload(); try await wait(searched)
        precondition(searched.entries.map(\.hash) == [hashes[3]], "Search-hidden HEAD expansion must still reveal its ordinary matching ancestor; collapsed label must still hide its parent")
        searched.search = "^c[13]"; searched.searchRegex = true; searched.reload(); try await wait(searched)
        precondition(searched.entries.map(\.hash) == [hashes[3]] && !searched.canToggleRollup)
        searched.search = "["; searched.reload(); try await wait(searched)
        precondition(searched.entries.map(\.hash) == [hashes[5],hashes[4],hashes[3],hashes[2],hashes[0]] && searched.canToggleRollup)
        searched.search = ""; searched.searchRegex = false; searched.toggleHistoryWalk(.compressed); try await wait(searched)
        let graphHost = NSHostingView(rootView: RevisionTable(model: searched, savesColumnLayout: false).defaultAppStorage(defaults))
        let graphWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        graphWindow.isReleasedWhenClosed = false; graphWindow.contentView = graphHost; defer { graphWindow.close() }
        for _ in 0..<20 { graphHost.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
        let graphTable = Self.table(in: graphHost)!, graphColumn = graphTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("graph"))!
        let graphIndex = graphTable.tableColumns.firstIndex(of: graphColumn)!
        let oldCell = graphTable.view(atColumn: graphIndex, row: 0, makeIfNecessary: true) as! GraphCell
        var boundaryEntries = searched.entries; boundaryEntries[0].isBoundary = true
        let newGraph = CommitGraph.layout(boundaryEntries); precondition(newGraph[0] != oldCell.graph)
        searched.graph = newGraph
        for _ in 0..<20 { graphHost.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
        let updatedCell = graphTable.view(atColumn: graphIndex, row: 0, makeIfNecessary: true) as! GraphCell
        precondition(updatedCell.graph == newGraph[0], "Same visible identities must still reload changed native graph snapshots")
        searched.setPathScope(["file"]); try await wait(searched); precondition(searched.canFollowRenames)
        let originalHidden = graphColumn.isHidden
        searched.toggleHistoryWalk(.followRenames); try await wait(searched)
        for _ in 0..<20 { graphHost.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(graphColumn.isHidden)
        let header = graphTable.headerView!.menu!; header.delegate?.menuNeedsUpdate?(header)
        precondition(!header.item(withTitle: "Graph")!.isEnabled)
        searched.toggleHistoryWalk(.followRenames); try await wait(searched)
        for _ in 0..<20 { graphHost.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(graphColumn.isHidden == originalHidden)
        print("Native search retains hidden lanes and rollup inheritance, literal/regex/invalid activity guards, same-identity graph refresh and Follow graph hide/restore; parent and repository preservation passed")
        let after = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }; precondition(before == after)
        print("Native graph accessibility: real table cells expose image role, ordinary/root parent/lane metadata and collapsed/expanded transitions; actual boundary and representative merge/fork/working/cleared cells describe state. Existing rollup menus, masks, searches, graph refresh and parent preservation passed; repository unchanged. No physical VoiceOver or external AX-client acceptance claimed.")
    }
}
