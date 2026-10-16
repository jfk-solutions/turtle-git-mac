import AppKit
import TurtleGitCore

@main struct PrimaryLivePresentationVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func descendants(_ view:NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func capture(_ window:NSWindow,_ name:String) async throws {
        guard let path = ProcessInfo.processInfo.environment["TURTLEGIT_PRIMARY_CAPTURE_DIR"] else { return }
        let folder = URL(fileURLWithPath:path); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        NSApplication.shared.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:350_000_000)
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture"); process.arguments = ["-x","-o","-l",String(window.windowNumber),folder.appendingPathComponent(name + ".png").path]
        try process.run(); process.waitUntilExit(); try require(process.terminationStatus == 0,"Compositor capture failed")
    }
    @MainActor static func main() async {
        do { try await verify() }
        catch { fputs("Primary live presentation failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let captures = ProcessInfo.processInfo.environment["TURTLEGIT_PRIMARY_CAPTURE_DIR"] != nil
        NSApplication.shared.setActivationPolicy(captures ? .accessory : .prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Harbor"), git = URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo = GitRepository(root:root,executable:git), suite = "TurtleGit.PrimaryLive." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        prefs.set(1,forKey:"DialogTitles")
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","TurtleGit Team"),("user.email","demo@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("bugtraq.label","Issue identifiers for the connected project tracker:"),("bugtraq.message","Issue: %BUGID%") ] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("README.md")); try await repo.stage(["README.md"])
        _ = try await repo.run(["commit","-m","Keep familiar native Git dialogs"],environmentOverrides:["GIT_AUTHOR_DATE":"2020-01-01T10:00:00+00:00","GIT_COMMITTER_DATE":"2020-01-01T11:00:00+00:00"])
        try Data("base\nchanged\n".utf8).write(to:root.appendingPathComponent("README.md"))
        let originalHead = try await repo.run(["rev-parse","HEAD"]).stdout, originalIndex = try await repo.run(["write-tree"]).stdout, originalStatus = try await repo.run(["status","--porcelain=v1","-z"]).stdout
        let parameters = #"{"linkText":"Choose issues from the connected project tracker…","issues":[{"id":"12345","summary":"Improve native dialog usability"}]}"#
        try NativeIssueAssociations.save([.init(path:root.path,parameters:parameters)],to:prefs)
        func wait(_ window:NSWindow?,_ condition:()->Bool,line:Int = #line) async throws {
            for _ in 0..<2000 { window?.contentView?.layoutSubtreeIfNeeded(); if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
            throw Failure(description:"Primary live wait at line \(line)")
        }
        let commit = CommitWindowController(repository:repo,access:nil,defaults:prefs); defer { commit.close() }
        commit.window!.alphaValue = captures ? 1 : 0; commit.window!.orderFront(nil); commit.model.reload()
        try await wait(commit.window) { !commit.model.busy && commit.model.nativeIssueProvider != nil }
        commit.model.message = "Improve native Commit and Log presentation"; commit.model.issueID = "12345"
        commit.model.branch = "feature/a-long-current-branch-name-that-remains-selectable-and-copyable-on-macOS"
        try await wait(commit.window) { descendants(commit.window?.contentView).contains { $0.identifier?.rawValue == "Commit destination" } }
        let branchLabel = descendants(commit.window?.contentView).first { $0.identifier?.rawValue == "Commit destination" } as! NSTextField
        try require(branchLabel.isSelectable && !branchLabel.isEditable && branchLabel.stringValue == commit.model.branch && branchLabel.toolTip == commit.model.branch,"Destination lost full branch copy/tooltip")
        let branchBoard = NSPasteboard.withUniqueName(); defer { branchBoard.releaseGlobally() }
        branchLabel.selectText(nil)
        guard let branchEditor = branchLabel.currentEditor() as? NSTextView else { throw Failure(description:"Read-only branch selection did not acquire a field editor") }
        branchEditor.setSelectedRange(NSRange(location:0,length:commit.model.branch.utf16.count))
        branchBoard.declareTypes([.string],owner:nil)
        let wroteBranch = branchEditor.writeSelection(to:branchBoard,types:branchEditor.writablePasteboardTypes)
        try require(wroteBranch && branchBoard.string(forType:.string) == commit.model.branch,"Read-only copy wrote=\(wroteBranch), editor=\(branchEditor.string.debugDescription), selection=\(branchEditor.selectedRange()), types=\(branchEditor.writablePasteboardTypes), selectable=\(branchEditor.isSelectable), clipboard=\(String(describing:branchBoard.string(forType:.string)))")
        commit.model.newBranch = "feature/a-long-new-branch-for-the-connected-project"; commit.model.createBranch = true
        try await wait(commit.window) { descendants(commit.window?.contentView).compactMap { $0 as? CommitNewBranchField.Field }.first?.currentEditor() != nil }
        let branch = descendants(commit.window?.contentView).compactMap { $0 as? CommitNewBranchField.Field }.first!, editor = branch.currentEditor() as! NSTextView
        editor.setSelectedRange(NSRange(location:8,length:0))
        func contains(_ view:NSView) -> Bool { guard let host = commit.window?.contentView else { return false }; return host.bounds.insetBy(dx:-1,dy:-1).contains(view.convert(view.bounds,to:host)) }
        for width in [900.0,1200.0,900.0] {
            commit.window!.setContentSize(NSSize(width:width,height:760))
            try await wait(commit.window) { branch.currentEditor() === editor && contains(branch) }
            try require(editor.selectedRange() == NSRange(location:8,length:0),"Responsive header replaced/refocused the new-branch editor")
            let fields = descendants(commit.window?.contentView).compactMap { $0 as? NSTextField }.filter { $0.stringValue == "12345" }
            try require(!fields.isEmpty && fields.allSatisfy(contains),"Issue field clipped outside the minimum-width Commit window")
        }
        for (appearance,name) in [(NSAppearance.Name.aqua,"commit-header-light"),(.darkAqua,"commit-header-dark")] {
            commit.window!.appearance = NSAppearance(named:appearance); try await capture(commit.window!,name)
        }
        commit.close()
        prefs.set(false,forKey:"LogIncludeWorkingTreeChanges"); prefs.set(true,forKey:"RelativeTimes"); prefs.set(false,forKey:"Log.Column.Visible.actions"); prefs.set(true,forKey:"Log.Column.Visible.committerDate")
        let log = LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false); defer { log.close() }
        log.window!.alphaValue = captures ? 1 : 0; log.window!.orderFront(nil); log.model.reload()
        try await wait(log.window) { !log.model.busy && !log.model.entries.isEmpty && descendants(log.window?.contentView).contains { $0 is HistoryTableView } }
        let table = descendants(log.window?.contentView).compactMap { $0 as? HistoryTableView }.first!, coordinator = table.delegate as! RevisionTable.Coordinator
        try await wait(log.window) { coordinator.dateSettings.relative && coordinator.dateRefreshTimer != nil }
        var now = ISO8601DateFormatter().date(from:"2020-01-01T11:00:30Z")!
        coordinator.dateNow = { now }; table.reloadData(); table.layoutSubtreeIfNeeded()
        let authorColumn = table.column(withIdentifier:.init("date")), committerColumn = table.column(withIdentifier:.init("committerDate"))
        func cell(_ column:Int) -> NSTextField { (table.view(atColumn:column,row:0,makeIfNecessary:true) as! NSTableCellView).textField! }
        let beforeAuthor = cell(authorColumn).stringValue, beforeCommitter = cell(committerColumn).stringValue
        let rows = log.model.entries.map(\.hash), graph = log.model.graph, selection = log.model.selected
        now += 65
        try await wait(log.window) { cell(authorColumn).stringValue != beforeAuthor && cell(committerColumn).stringValue != beforeCommitter }
        try require(cell(authorColumn).stringValue == coordinator.dateSettings.format(log.model.entries[0].date,now:now) && cell(committerColumn).stringValue == coordinator.dateSettings.format(log.model.entries[0].committerDate,now:now),"Live relative dates differ from source formatter")
        try require(cell(authorColumn).toolTip == coordinator.dateSettings.format(log.model.entries[0].date,absolute:true),"Live date refresh lost absolute tooltip")
        try require(log.model.entries.map(\.hash) == rows && log.model.graph == graph && log.model.selected == selection && !log.model.busy,"Clock refresh reloaded history or selection")
        prefs.set(false,forKey:"RelativeTimes"); log.model.objectWillChange.send()
        try await wait(log.window) { !coordinator.dateSettings.relative && coordinator.dateRefreshTimer == nil }
        prefs.set(true,forKey:"LogFontForLogCtrl"); prefs.set("Menlo",forKey:"LogFontName"); prefs.set(18.0,forKey:"LogFontSize"); log.model.objectWillChange.send()
        try await wait(log.window) { coordinator.logFont?.pointSize == 18 && table.rowHeight >= 24 }
        // Choose a private format opposite the user's global setting without changing it.
        prefs.set(!UserDefaults.standard.bool(forKey:"RelativeTimes"),forKey:"RelativeTimes")
        prefs.set(false,forKey:"UseSystemLocaleForDates"); log.model.objectWillChange.send()
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }; log.model.clipboard = board
        let entry = log.model.entries[0]; log.model.selected = [entry.hash]
        let expected = try await repo.commitLogText(revision:entry.hash,includePaths:false,dateSettings:.load(defaults:prefs))
        log.model.copyDetails(includePaths:false)
        try await wait(log.window) { !log.model.copyingDetails && board.string(forType:.string) != nil }
        try require(board.string(forType:.string) == expected,"Copied details ignored the owning Log date preferences")
        coordinator.dateNow = Date.init; coordinator.refreshDateCells(now:Date())
        for (appearance,name) in [(NSAppearance.Name.aqua,"log-live-dates-light"),(.darkAqua,"log-live-dates-dark")] {
            log.window!.appearance = NSAppearance(named:appearance); try await capture(log.window!,name)
        }
        log.close(); try require(coordinator.dateRefreshTimer == nil,"Closed Log retained relative-date timer")
        let retained = cell(authorColumn).stringValue; coordinator.refreshDateCells(now:now + 600)
        try require(cell(authorColumn).stringValue == retained,"Retired clock changed a closed Log")
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout
        let afterIndex = try await repo.run(["write-tree"]).stdout
        let afterStatus = try await repo.run(["status","--porcelain=v1","-z"]).stdout
        try require(afterHead == originalHead && afterIndex == originalIndex && afterStatus == originalStatus,"Presentation changed HEAD/index/working status")
        print("PASS: adaptive Commit destination/provider/issue layout at minimum width, full branch copy and resize focus retention; actual live Log author/committer dates, absolute tooltips, font/preferences, private copied-detail format and timer retirement; HEAD/index/status preserved and owned windows closed")
    }
}
