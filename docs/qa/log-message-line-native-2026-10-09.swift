import AppKit
import SwiftUI
import TurtleGitCore

// Only test-window placement differs; production views are unchanged.
final class MessageLineOffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@main struct MessageLineVerification {
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func settle(_ view: NSView) async throws {
        for _ in 0..<20 { view.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func host<V: View>(_ view: V, ordered: Bool = true) -> NSWindow {
        let x = (NSScreen.screens.map { $0.frame.maxX }.max() ?? 0) + 2000
        let window = MessageLineOffscreenWindow(contentRect: .init(x: x, y: 0, width: 1200, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: view)
        window.setFrameOrigin(.init(x: x, y: 0))
        precondition(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        if ordered { window.orderBack(nil) }
        precondition(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.displayIfNeeded()
        return window
    }
    @MainActor static func message(_ window: NSWindow) -> NSTextField {
        let list = descendants(window.contentView!).compactMap { $0 as? NSTableView }.first!
        let column = list.tableColumns.firstIndex { $0.identifier.rawValue == "message" }!
        return (list.view(atColumn: column, row: 0, makeIfNecessary: true) as! NSTableCellView).textField!
    }
    @MainActor static func values(_ object: Any, depth: Int = 0) -> [String] {
        guard depth < 40, let element = object as? NSObject else { return [] }
        // SwiftUI's lightweight elements need not adopt the entire protocol.
        // Read only these three documented AppKit accessibility getters.
        func attribute(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
        }
        return [attribute("accessibilityValue") as? String, attribute("accessibilityLabel") as? String].compactMap { $0 }
            + (attribute("accessibilityChildren") as? [Any] ?? []).flatMap { values($0, depth: depth + 1) }
    }
    @MainActor static func check(_ enabled: Bool?, repo: GitRepository, entries: [LogEntry], plan: RebasePlan, prefs: UserDefaults) async throws {
        let focused = CommandLine.arguments.contains("--log-blame-only")
        if let enabled { prefs.set(enabled, forKey: "FullCommitMessageOnLogLine") } else { prefs.removeObject(forKey: "FullCommitMessageOnLogLine") }
        let full = enabled ?? false, expected = full ? "first line continued heading  body 雪 second body line " : "first line"
        let log = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        log.busy = true; log.entries = entries; log.graph = CommitGraph.layout(entries)
        for entry in entries { log.revisionActions[entry.hash] = [] }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TurtleGit.MessageLine.QA." + UUID().uuidString))
        log.clipboard = pasteboard; log.selected = Set(entries.map(\.hash))
        defer { pasteboard.releaseGlobally() }
        let blame = BlameWindowModel(repository: repo, access: nil, path: "file.txt", revision: "HEAD", labelDefaults: prefs)
        blame.historyEntries = entries; blame.selectedLogHashes = [entries[0].hash]
        let rebase = RebaseWindowModel(repository: repo, access: nil, messageDefaults: prefs)
        rebase.plan = plan; rebase.selection = [plan.entries[0].id]
        let logWindow = host(RevisionTable(model: log, savesColumnLayout: false).defaultAppStorage(prefs), ordered: !focused)
        let blameWindow = host(messageLineBlameHistoryView(blame).defaultAppStorage(prefs), ordered: !focused)
        let rebaseWindow = host(RebaseDialog(model: rebase).defaultAppStorage(prefs), ordered: !focused)
        defer { logWindow.close(); blameWindow.close(); rebaseWindow.close(); log.invalidate(); blame.invalidate(); rebase.revisionMenuLog.invalidate() }
        for window in [logWindow, blameWindow, rebaseWindow] { try await settle(window.contentView!) }
        // Hidden AppKit tables lazily create row views. Ask the production
        // data source for its real cells, just as the Log/Blame checks do.
        let rebaseTables = descendants(rebaseWindow.contentView!).compactMap { $0 as? NSTableView }
        var rebaseCells: [NSView] = []
        for table in rebaseTables {
            table.reloadData()
            for row in 0..<table.numberOfRows {
                for column in table.tableColumns.indices {
                    if let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) {
                        rebaseCells.append(cell); cell.layoutSubtreeIfNeeded()
                    }
                }
            }
        }
        try await settle(rebaseWindow.contentView!)
        let logTable = descendants(logWindow.contentView!).compactMap { $0 as? NSTableView }.first!
        let menu = logTable.menu!
        menu.delegate?.menuNeedsUpdate?(menu)
        let copyMenu = menu.items.first { $0.title == "Copy to clipboard" }!.submenu!
        for (title, expectedCopy) in [
            ("Subjects", "* first line\r\n\r\n* root\r\n\r\n"),
            ("Messages", "* first line\r\ncontinued heading\r\n\r\nbody 雪\r\nsecond body line\r\n\r\n* root\r\n\r\n\r\n")
        ] {
            let item = copyMenu.items.first { $0.title == title }!
            precondition(item.isEnabled && item.image != nil)
            precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
            precondition(pasteboard.string(forType: .string) == expectedCopy, title + " actual menu clipboard output differs")
        }
        precondition(log.fullCommitMessageOnLogLine == full && blame.fullCommitMessageOnLogLine == full && rebase.fullCommitMessageOnLogLine == full)
        precondition(message(logWindow).stringValue.hasSuffix(expected) && message(blameWindow).stringValue == expected)
        let label = message(logWindow).attributedStringValue
        precondition(label.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil, "Reference label styling must be retained")
        let rebaseValues = (descendants(rebaseWindow.contentView!) + rebaseCells).flatMap { values($0) }
        if !focused && !rebaseValues.contains(expected) {
            let fields = descendants(rebaseWindow.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
            let tables = rebaseTables.map { ["columns": $0.tableColumns.map(\.title), "rows": $0.numberOfRows] as [String: Any] }
            let diagnostic = try JSONSerialization.data(withJSONObject: ["expected": expected, "accessibility": rebaseValues, "fields": fields, "tables": tables])
            FileHandle.standardOutput.write(diagnostic); FileHandle.standardOutput.write(Data("\n".utf8))
        }
        if !focused { precondition(rebaseValues.contains(expected), "Actual Rebase row must show the configured message line") }
        precondition(message(logWindow).maximumNumberOfLines == 1 && message(blameWindow).maximumNumberOfLines == 1)
        precondition(blame.selectedLogHashes == [entries[0].hash] && rebase.selection == [plan.entries[0].id] && rebase.entries[0].action == plan.entries[0].action)
        prefs.set(!full, forKey: "FullCommitMessageOnLogLine")
        for window in [logWindow, blameWindow, rebaseWindow] { try await settle(window.contentView!) }
        precondition(log.fullCommitMessageOnLogLine == full && blame.fullCommitMessageOnLogLine == full && rebase.fullCommitMessageOnLogLine == full, "Source captures the preference at construction")
        precondition(message(logWindow).stringValue.hasSuffix(expected) && message(blameWindow).stringValue == expected)
        precondition(entries[0].message == "first line\ncontinued heading\n\nbody 雪\nsecond body line\n" && entries[0].subject == "first line continued heading")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.MessageLine.Native.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let repo = GitRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]), executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Message QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("fixture\n".utf8).write(to: repo.root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "root")
        _ = try await repo.run(["commit", "--allow-empty", "-m", "first line\ncontinued heading\n\nbody 雪\nsecond body line\n"])
        let entries = try await repo.history()
        var options = RebaseOptions(); options.upstream = "HEAD^"; options.force = true
        let plan = try await repo.rebasePlan(options); precondition(plan.entries.count == 1)
        let paths = [".git/HEAD", ".git/index", ".git/config", ".git/refs/heads/main", "file.txt"], before = try paths.map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }
        for enabled in [nil, false, true] as [Bool?] { try await check(enabled, repo: repo, entries: entries, plan: plan, prefs: prefs) }
        let after = try paths.map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }; precondition(before == after)
        if CommandLine.arguments.contains("--log-blame-only") {
            print("PASS (focused): actual hidden Log/Blame message cells, unset/false/true captured preferences, folding/label styling/one-line cells/selection/metadata preserved, actual Subjects/Messages menu actions match source formatting on private pasteboard; Rebase model preference and read-only plan/selection/action checked, rendered Rebase text UNVERIFIED; unchanged repository bytes, all owned windows closed, no main app or replay operation")
        } else {
            print("PASS: offscreen native Log/Blame/Rebase message text and source captured preferences; unchanged repository bytes, all owned windows closed, no main app or replay operation")
        }
    }
}
