import AppKit
import Vision
import TurtleGitCore

@main struct RebaseColumnsVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description:message) } }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func cellText(_ view: NSView) throws -> String {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(description:"No native cell bitmap") }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let pixels = bitmap.cgImage else { throw Failure(description:"No native cell pixels") }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage:pixels,options:[:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator:"\n")
    }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Rebase columns did not settle at \(line)")
    }
    @MainActor static func settle(_ owner: RebaseWindowController) async throws -> RebaseColumnLayout.Probe {
        var probe: RebaseColumnLayout.Probe?
        try await wait {
            owner.window!.contentView!.layoutSubtreeIfNeeded()
            probe = descendants(owner.window!.contentView!).compactMap { $0 as? RebaseColumnLayout.Probe }.first
            probe?.configure()
            return !owner.model.busy && owner.model.entries.count == 2 && probe?.table?.numberOfRows == 2
        }
        return probe!
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Rebase columns failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.accessory); NSApp.finishLaunching()
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Committer QA"),("user.email","committer@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"])
        _ = try await repo.run(["commit","-m","base"],environmentOverrides:["GIT_AUTHOR_NAME":"Author QA","GIT_AUTHOR_EMAIL":"author@example.invalid","GIT_AUTHOR_DATE":"2026-10-12T10:00:00+0200","GIT_COMMITTER_DATE":"2026-10-13T11:00:00+0200"])
        _ = try await repo.run(["commit","--allow-empty","-m","second"])
        let commits=try await repo.history(), hashes=commits.map(\.hash)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.RebaseColumns.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        prefs.set(false,forKey:"UseSystemLocaleForDates"); prefs.set(false,forKey:"RelativeTimes")
        prefs.set(true,forKey:"LogFontForLogCtrl"); prefs.set("Menlo",forKey:"LogFontName"); prefs.set(18,forKey:"LogFontSize")
        let global=UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("Rebase.Columns.") }
        let owner=RebaseWindowController(repository:repo,access:nil,preferences:prefs); defer { owner.close() }
        owner.window!.alphaValue = 1; owner.window!.orderBack(nil)
        owner.model.load(cherryPick:hashes); let probe=try await settle(owner), table=probe.table!
        try require(table.tableColumns.count == 12 && table.tableColumns.filter { !$0.isHidden }.count == 6,"Source default/extra columns wrong")
        let menu=probe.headerMenu(); try require(menu.items.dropFirst(2).map(\.title) == Array(RebaseColumnLayout.Probe.names.prefix(10)),"Header menu lost source order")
        let email=menu.item(withTitle:"Email")!; probe.toggle(email)
        try require(prefs.bool(forKey:"Rebase.Columns.Visible.Email"),"Email visibility not saved")
        let emailColumn=table.tableColumns[6]; emailColumn.width=330; table.moveColumn(6,toColumn:0); probe.persistLayout()
        try require(prefs.stringArray(forKey:"Rebase.Columns.Order")?.first == "Email","Reorder not saved")
        let reopened=RebaseWindowController(repository:repo,access:nil,preferences:prefs); defer { reopened.close() }
        reopened.model.load(cherryPick:hashes); let restored=try await settle(reopened)
        try require(restored.table!.tableColumns.first?.width == 330 && restored.table!.tableColumns.first?.isHidden == false,"Reopened width/order/visibility not restored")
        // Show the distinct committer/date values through actual AppKit text cells.
        for name in ["Commit Name","Commit Email","Commit Date"] { probe.toggle(probe.headerMenu().item(withTitle:name)!) }
        table.layoutSubtreeIfNeeded()
        try require(owner.model.entries.contains { $0.commit.email == "author@example.invalid" && $0.commit.committerEmail == "committer@example.invalid" },"Raw independent identities missing")
        let committerColumn = table.tableColumns.firstIndex { $0.identifier.rawValue == "Commit Email" }!
        table.tableColumns[committerColumn].width = 500; probe.persistLayout()
        let committerRow = owner.model.entries.firstIndex { $0.commit.email == "author@example.invalid" && $0.commit.committerEmail == "committer@example.invalid" }!
        table.scrollColumnToVisible(committerColumn); table.scrollRowToVisible(committerRow)
        var cell: NSTableCellView?
        try await wait {
            owner.window!.contentView!.layoutSubtreeIfNeeded(); table.layoutSubtreeIfNeeded()
            cell = table.view(atColumn: committerColumn, row: committerRow, makeIfNecessary: true) as? NSTableCellView
            return cell?.textField?.stringValue == "committer@example.invalid" && (cell?.bounds.height ?? 0) > 10
        }
        let text = try cellText(cell!)
        try require(text.contains("committer@example.invalid"),"Native committer pixels missing: " + text)
        // Native values remain attached to identifiers after order/visibility changes.
        for name in ["Author", "Email", "Commit Name", "Commit Email"] {
            if let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == name }), !table.tableColumns[index].isHidden {
                let view = table.view(atColumn: index, row: committerRow, makeIfNecessary: true) as? NSTableCellView
                try require(view?.textField?.stringValue.isEmpty == false, "Native value missing after reordering: " + name)
                try require(view?.textField?.accessibilityLabel() == name, "Native column accessibility label missing")
            }
        }
        guard let native = table as? RebaseReplayNativeTable, let coordinator = native.owner else { throw Failure(description: "Replay list is not a native report table") }
        let selected = owner.model.entries[committerRow].id
        table.selectRowIndexes(IndexSet(integer: committerRow), byExtendingSelection: false)
        try require(owner.model.selection == [selected], "Native selection lost occurrence identity")
        let rowMenu = coordinator.menu(ids: [selected], alternate: false)
        let edit = rowMenu.item(withTitle: "Edit")!, skip = rowMenu.item(withTitle: "Skip")!
        try require(edit.isEnabled && edit.image != nil && NSApp.sendAction(edit.action!, to: edit.target, from: edit), "Native action menu failed")
        try require(owner.model.entries.first { $0.id == selected }?.action == .edit, "Column work broke action editing")
        _ = NSApp.sendAction(skip.action!, to: skip.target, from: skip)
        try require(owner.model.entries.first { $0.id == selected }?.action == .edit, "Consumed popup applied a second command")
        let actionColumn = table.tableColumns.firstIndex { $0.identifier.rawValue == "REBASE" }!
        try await wait {
            table.layoutSubtreeIfNeeded()
            let cell = table.view(atColumn: actionColumn, row: committerRow, makeIfNecessary: true) as? NSTableCellView
            return cell?.textField?.stringValue == "Edit"
        }
        let actionCell = table.view(atColumn: actionColumn, row: committerRow, makeIfNecessary: true) as! NSTableCellView
        try require(actionCell.imageView?.image != nil && actionCell.textField?.font?.pointSize == 18, "Native icon/private Log font missing")
        prefs.set(false, forKey: "ShowAppContextMenuIcons")
        let plain = coordinator.menu(ids: [selected], alternate: false)
        try require(plain.items.allSatisfy { $0.image == nil && ($0.submenu?.items.allSatisfy { $0.image == nil } ?? true) }, "Native replay popup ignored icon preference")
        prefs.removeObject(forKey: "ShowAppContextMenuIcons")
        owner.model.busy=true; probe.toggle(email); try require(prefs.bool(forKey:"Rebase.Columns.Visible.Email"),"Busy header accepted action"); owner.model.busy=false
        probe.resetLayout(); try require(prefs.stringArray(forKey:"Rebase.Columns.Order")?.first == "REBASE" && table.tableColumns.filter { !$0.isHidden }.count == 6,"Reset did not restore default layout")
        let heldMenu = coordinator.menu(ids: [selected], alternate: false), heldPick = heldMenu.item(withTitle: "Pick")!
        reopened.close(); owner.close(); probe.toggle(email)
        _ = NSApp.sendAction(heldPick.action!, to: heldPick.target, from: heldPick)
        try require(owner.model.entries.first { $0.id == selected }?.action == .edit, "Retired native menu changed replay plan")
        try await wait { RebaseWindowModel.activeColumnReads == 0 }
        try require(prefs.object(forKey:"Rebase.Columns.Visible.Email") == nil,"Closed owner changed visibility")
        let after=UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("Rebase.Columns.") }
        try require(NSDictionary(dictionary:global).isEqual(to:after),"Private layout changed global preferences")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(afterHead==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"Column/edit-plan UI changed HEAD/index")
        print("Rebase columns: source defaults/metadata header entries, native committer cells, private width/order/visibility reopen, action selection, Reset and busy/closed refusal passed. Owned windows closed; HEAD/index/global prefs preserved.")
    }
}
