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
    @MainActor static func checkHighlights(repo: GitRepository, prefs: UserDefaults) async throws {
        let regexHelper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_QA_REGEX"]!)
        for (full, fields, query, regex, expectedTerm) in [
            (false, HistorySearchFields([.subject, .referenceNames]), "line +main", false, "line"),
            (false, HistorySearchFields.messages, "first", false, ""),
            (true, HistorySearchFields.messages, "body", false, "body"),
            (true, HistorySearchFields.messages, "body|second", true, "body"),
            (true, HistorySearchFields.messages, "(?<=body) 雪", true, "")
        ] {
            prefs.set(full, forKey: "FullCommitMessageOnLogLine")
            let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs, historyRegexExecutable: regexHelper)
            model.search = query; model.searchFields = fields; model.searchRegex = regex; model.searchCaseSensitive = false
            model.showWorkingTree = false; model.reload()
            for _ in 0..<1500 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(!model.busy && model.error == nil, "Real history highlight reload must finish")
            let window = host(RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs), ordered: false)
            defer { window.close(); model.invalidate() }
            try await settle(window.contentView!)
            let field = message(window), value = field.attributedStringValue
            let heading = (value.string as NSString).range(of: "first line")
            precondition(heading.location != NSNotFound)
            let entry = model.entries[0]
            let ranges = model.searchHighlights[entry.hash]?["message"] ?? []
            if expectedTerm.isEmpty { precondition(!model.shouldHighlightMessage(entry) || ranges.isEmpty) }
            else {
                let term = (value.string as NSString).range(of: expectedTerm, options: [], range: NSRange(location: heading.location, length: value.length - heading.location))
                precondition(term.location != NSNotFound)
                let color = value.attribute(.foregroundColor, at: term.location, effectiveRange: nil) as! NSColor
                NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                    let channels = color.usingColorSpace(.sRGB)!
                    precondition(abs(channels.redComponent - 200.0/255) < 0.001 && channels.greenComponent == 0 && channels.blueComponent == 0)
                }
                precondition(value.attribute(.backgroundColor, at: heading.location, effectiveRange: nil) == nil, "Matches use foreground only")
            }
            let label = (value.string as NSString).range(of: "main")
            precondition(label.location != NSNotFound && value.attribute(.backgroundColor, at: label.location, effectiveRange: nil) is NSColor, "Reference badge styling retained")
            precondition(field.maximumNumberOfLines == 1 && !model.selected.isEmpty)
            // Update same-identity rows and verify stale colors disappear.
            model.searchHighlights = [:]; try await settle(window.contentView!)
            let cleared = message(window).attributedStringValue
            let oldMatch = expectedTerm.isEmpty ? heading : (value.string as NSString).range(of: expectedTerm, options: [], range: NSRange(location: heading.location, length: value.length - heading.location))
            precondition(cleared.attribute(.foregroundColor, at: oldMatch.location, effectiveRange: nil) == nil)
        }
    }
    @MainActor static func checkHighlightColumns(repo: GitRepository, prefs: UserDefaults) async throws {
        let entry = try await repo.history()[0]
        let ranges = try LogSearchHighlights.prepare([entry], query: "Message +example +" + String(entry.hash.prefix(6)), regex: false, caseSensitive: false, fields: [.authors, .emails, .revisions], fullMessage: false, labeled: [entry.hash], executable: nil)
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        model.busy = true; model.entries = [entry]; model.graph = CommitGraph.layout([entry]); model.searchHighlights = ranges; model.revisionActions[entry.hash] = []
        let window = host(RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs), ordered: false)
        defer { window.close(); model.invalidate() }
        try await settle(window.contentView!)
        let table = descendants(window.contentView!).compactMap { $0 as? NSTableView }.first!
        for column in table.tableColumns { column.isHidden = false }
        table.reloadData(); try await settle(window.contentView!)
        for name in ["author", "committer", "email", "committerEmail", "hash"] {
            let index = table.tableColumns.firstIndex { $0.identifier.rawValue == name }!
            let text = (table.view(atColumn: index, row: 0, makeIfNecessary: true) as! NSTableCellView).textField!.attributedStringValue
            for range in ranges[entry.hash]![name]! { precondition(text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) is NSColor) }
        }
        let gated = try LogSearchHighlights.prepare([entry], query: "Message", regex: false, caseSensitive: false, fields: .paths, fullMessage: true, labeled: [], executable: nil)
        precondition(gated.isEmpty)
        let hiddenRefs = try LogSearchHighlights.prepare([entry], query: "first", regex: false, caseSensitive: false, fields: .subject, fullMessage: true, labeled: [], executable: nil)
        precondition(hiddenRefs.isEmpty, "Source suppresses custom message painting when all existing refs are hidden")
        var plain = entry; plain.references = []
        let plainRanges = try LogSearchHighlights.prepare([plain], query: "first", regex: false, caseSensitive: false, fields: .messages, fullMessage: false, labeled: [], executable: nil)
        precondition(plainRanges[entry.hash]?["message"] == [NSRange(location: 0, length: 5)])
        let colors = LogColorSettingsModel(preferences: prefs)
        colors.set(.filterMatch, rgb: [40,80,120]); colors.cancel(); precondition(colors.draft.rgb(.filterMatch) == [200,0,0])
        colors.set(.filterMatch, rgb: [40,80,120]); colors.apply(); precondition(LogColorPreferences.load(prefs).rgb(.filterMatch) == [40,80,120])
        colors.restoreDefaults(); colors.apply(); precondition(LogColorPreferences.load(prefs).rgb(.filterMatch) == [200,0,0])
    }
    @MainActor static func checkReferenceLayout(repo: GitRepository, prefs: UserDefaults) async throws {
        let entries = try await repo.history(), context = try await repo.historyReferenceContext()
        for (right, symbolize) in [(false, false), (true, false), (false, true), (true, true)] {
            prefs.set(right, forKey: "DrawTagsBranchesOnRightSide"); prefs.set(symbolize, forKey: "SymbolizeRefNames")
            prefs.set(false, forKey: "FullCommitMessageOnLogLine")
            let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
            model.busy = true; model.entries = entries; model.graph = CommitGraph.layout(entries); model.referenceContext = context
            for entry in entries { model.revisionActions[entry.hash] = [] }
            let window = host(RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs), ordered: false)
            defer { window.close(); model.invalidate() }
            try await settle(window.contentView!)
            let field = message(window), value = field.attributedStringValue, text = value.string as NSString
            let heading = text.range(of: "first line"), main = text.range(of: "main")
            precondition(heading.location != NSNotFound && main.location != NSNotFound)
            precondition(right ? heading.location < main.location : main.location < heading.location)
            precondition(value.attribute(.backgroundColor, at: main.location, effectiveRange: nil) is NSColor)
            precondition(value.attribute(.backgroundColor, at: heading.location, effectiveRange: nil) == nil)
            precondition(right ? field.toolTip == nil : field.toolTip == "first line")
            if symbolize {
                precondition(text.range(of: "/≡").location != NSNotFound && text.range(of: "origin/main").location == NSNotFound)
                let marker = text.range(of: "\u{FFFC}")
                precondition(marker.location != NSNotFound)
                precondition((value.attribute(.attachment, at: marker.location, effectiveRange: nil) as? NSTextAttachment)?.image != nil)
            } else { precondition(text.range(of: "origin/main").location != NSNotFound) }
            precondition(model.visibleReferenceLabels(for: entries[0]).map { $0.reference.name } == entries[0].references.map(\.name))
            prefs.set(!right, forKey: "DrawTagsBranchesOnRightSide"); prefs.set(!symbolize, forKey: "SymbolizeRefNames")
            precondition(model.drawTagsBranchesOnRightSide == right && model.symbolizeRefNames == symbolize)
        }
        prefs.set(false, forKey: "DrawTagsBranchesOnRightSide"); prefs.set(false, forKey: "SymbolizeRefNames")
        // Source HandleShowLabels redraws ordinary history without re-reading Git.
        prefs.set(true, forKey: "FullCommitMessageOnLogLine")
        let regexHelper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_QA_REGEX"]!)
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs, historyRegexExecutable: regexHelper)
        model.showWorkingTree = false; model.search = "body"; model.searchFields = .messages; model.searchRegex = false; model.reload()
        for _ in 0..<1500 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil)
        let window = host(RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs), ordered: false)
        defer { window.close(); model.invalidate() }
        try await settle(window.contentView!)
        let before = message(window).attributedStringValue
        let body = (before.string as NSString).range(of: "body")
        precondition(before.attribute(.foregroundColor, at: body.location, effectiveRange: nil) is NSColor)
        model.toggleHistoryLabel(.localBranches); model.toggleHistoryLabel(.remoteBranches)
        precondition(!model.busy); try await settle(window.contentView!)
        let hidden = message(window).attributedStringValue, hiddenBody = (hidden.string as NSString).range(of: "body")
        precondition(hidden.attribute(.foregroundColor, at: hiddenBody.location, effectiveRange: nil) == nil)
        model.toggleHistoryLabel(.localBranches); try await settle(window.contentView!)
        let restored = message(window).attributedStringValue, restoredBody = (restored.string as NSString).range(of: "body")
        precondition(restored.attribute(.foregroundColor, at: restoredBody.location, effectiveRange: nil) is NSColor)
    }
    @MainActor static func checkDialogPreferenceControls(prefs: UserDefaults) async throws {
        let controls = [("Symbolize ref names", "SymbolizeRefNames"), ("Draw tag/branch labels on right side", "DrawTagsBranchesOnRightSide"), ("Display subject and body of commit messages", "FullCommitMessageOnLogLine")]
        for (_, key) in controls { prefs.set(false, forKey: key) }
        let window = host(LogDialogSettings().defaultAppStorage(prefs), ordered: false)
        window.setContentSize(NSSize(width: 1200, height: 1800))
        defer { window.close() }
        try await settle(window.contentView!)
        for (title, key) in controls {
            let buttons = descendants(window.contentView!).compactMap { $0 as? NSButton }
            guard let button = buttons.first(where: { $0.title == title || $0.accessibilityLabel() == title }) else {
                let diagnostic = try JSONSerialization.data(withJSONObject: ["missing": title, "buttons": buttons.map { [$0.title, $0.accessibilityLabel() ?? ""] }, "fields": descendants(window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }])
                FileHandle.standardOutput.write(diagnostic); FileHandle.standardOutput.write(Data("\n".utf8))
                preconditionFailure("Actual source preference checkbox must be exposed")
            }
            precondition(button.isEnabled && button.state == .off)
            button.performClick(nil); try await settle(window.contentView!)
            precondition(prefs.bool(forKey: key) && button.state == .on)
            button.performClick(nil); try await settle(window.contentView!)
            precondition(!prefs.bool(forKey: key) && button.state == .off)
        }
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
        _ = try await repo.run(["remote", "add", "origin", repo.root.path])
        _ = try await repo.run(["config", "branch.main.remote", "origin"])
        _ = try await repo.run(["config", "branch.main.merge", "refs/heads/main"])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", "HEAD"])
        let entries = try await repo.history()
        var options = RebaseOptions(); options.upstream = "HEAD^"; options.force = true
        let plan = try await repo.rebasePlan(options); precondition(plan.entries.count == 1)
        let paths = [".git/HEAD", ".git/index", ".git/config", ".git/refs/heads/main", ".git/refs/remotes/origin/main", "file.txt"], before = try paths.map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }
        for enabled in [nil, false, true] as [Bool?] { try await check(enabled, repo: repo, entries: entries, plan: plan, prefs: prefs) }
        try await checkHighlights(repo: repo, prefs: prefs)
        try await checkHighlightColumns(repo: repo, prefs: prefs)
        try await checkReferenceLayout(repo: repo, prefs: prefs)
        try await checkDialogPreferenceControls(prefs: prefs)
        let after = try paths.map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }; precondition(before == after)
        if CommandLine.arguments.contains("--log-blame-only") {
            print("PASS (focused): actual hidden Log/Blame message cells, unset/false/true captured preferences, folding/label styling/one-line cells/selection/metadata preserved, actual Subjects/Messages menu actions match source formatting on private pasteboard, real reload literal/regex highlight cells and reference/full-message gates verified, left/right label order and symbolization attachments/captured choices and label-mask highlight redraw verified; Rebase model preference and read-only plan/selection/action checked, rendered Rebase text UNVERIFIED; unchanged repository bytes, all owned windows closed, no main app or replay operation")
        } else {
            print("PASS: offscreen native Log/Blame/Rebase message text and source captured preferences; unchanged repository bytes, all owned windows closed, no main app or replay operation")
        }
    }
}
