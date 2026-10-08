import AppKit
import SwiftUI
import TurtleGitCore

@main struct LogTableFontVerification {
    @MainActor static func settle(_ host: NSView) async throws {
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = table(in: child) { return table } }
        return nil
    }
    @MainActor static func label(_ table: NSTableView, column: String, row: Int) -> NSTextField {
        let index = table.tableColumns.firstIndex { $0.identifier.rawValue == column }!
        return (table.view(atColumn: index, row: row, makeIfNecessary: true) as! NSTableCellView).textField!
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.LogTableFont.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let repo = GitRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]), executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Font QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "first"]); _ = try await repo.run(["commit", "--allow-empty", "-m", "second"])
        var entries = try await repo.log(); entries[0].isHead = true
        let projection = CommitGraph.project(entries, walk: HistoryWalkOptions())
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        model.busy = true; model.entries = projection.entries; model.graph = projection.graph
        let host = NSHostingView(rootView: RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1080, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close(); model.invalidate() }
        try await settle(host); let list = table(in: host)!
        precondition(list.numberOfRows == 2 && list.rowHeight == 24 && !list.autosaveTableColumns)
        precondition(label(list, column: "author", row: 1).font?.pointSize == 12)
        prefs.set("Menlo", forKey: "LogFontName"); prefs.set(22, forKey: "LogFontSize")
        try await settle(host); precondition(label(list, column: "author", row: 1).font?.pointSize == 12)
        prefs.set(true, forKey: "LogFontForLogCtrl"); try await settle(host)
        let normal = label(list, column: "author", row: 1).font!
        precondition(normal.familyName == "Menlo" && normal.pointSize == 22 && list.rowHeight >= normal.ascender - normal.descender)
        let head = label(list, column: "author", row: 0).font!
        precondition(head.pointSize == 22 && NSFontManager.shared.traits(of: head).contains(.boldFontMask))
        let message = label(list, column: "message", row: 1)
        precondition((message.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 22)
        prefs.set(18, forKey: "LogFontSize"); try await settle(host)
        precondition(label(list, column: "author", row: 1).font?.pointSize == 18)
        prefs.set(false, forKey: "LogFontForLogCtrl"); try await settle(host)
        precondition(list.rowHeight == 24 && label(list, column: "author", row: 1).font?.pointSize == 12)
        print("PASS: actual hidden revision table optional log font default-off, source key enable/live size change/disable, HEAD bold, message attributes and font-aware row height, two real Git rows and graph; column autosave disabled for private fixture, no main app")
    }
}
