// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore
@testable import TurtleGitMac

struct SynchronizationRevisionListVerification {
    @MainActor static func settle(_ condition: () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Sync revision list did not settle")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func table(_ window: NSWindow) -> NSTableView {
        window.contentView!.layoutSubtreeIfNeeded()
        return descendants(window.contentView!).compactMap { $0 as? NSTableView }.first { $0.tableColumn(withIdentifier: .init("actions")) != nil }!
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main", "--template="])
        for (key,value) in [("user.name","Revision QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false"),("bugtraq.url","https://example.invalid/%BUGID%"),("bugtraq.message","Issue %BUGID%") ] { _ = try await repo.run(["config",key,value]) }
        for name in ["modify.txt","rename.txt","delete.txt"] { try Data((name + "\n").utf8).write(to: root.appendingPathComponent(name)) }
        try await repo.stage(["."]); _ = try await repo.commit(message:"Base")
        let base = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["commit","--allow-empty","-m","A second revision for selection tests"])
        try Data("modified\n".utf8).write(to: root.appendingPathComponent("modify.txt"))
        try Data("added\n".utf8).write(to: root.appendingPathComponent("added.txt"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("rename.txt"),to: root.appendingPathComponent("renamed.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("delete.txt"))
        try await repo.stage(["."]); _ = try await repo.commit(message:"Review colored refs and action icons\n\nDetails on a second line\nIssue 42")
        _ = try await repo.run(["tag","-a","v1.0","-m","Annotated tag"])
        _ = try await repo.run(["remote","add","origin",root.appendingPathComponent("no-server.git").path])
        _ = try await repo.run(["update-ref","refs/remotes/origin/main",base])
        _ = try await repo.run(["config","branch.main.remote","origin"]); _ = try await repo.run(["config","branch.main.merge","refs/heads/main"])
        let refs = try await repo.run(["show-ref"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index")), config = try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let suite = "TurtleGit.Sync.Revisions.QA." + UUID().uuidString, preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        preferences.set(false,forKey:"UseSystemLocaleForDates"); DialogGeometry.install(preferences:preferences)
        let owner = SynchronizationWindowController(repository:repo,access:nil,preferences:preferences), window = owner.window!, model = owner.model
        owner.showWindow(nil); defer { owner.close() }
        try await settle { !model.busy && model.outgoing != nil }
        let entry = model.historyEntries.first!
        model.requestHistoryActions(entry)
        try await settle { model.historyActions[entry.hash] != nil }
        precondition(model.historyActions[entry.hash] == [.modified,.added,.deleted,.replaced])
        let native = table(window), coordinator = native.delegate as! SynchronizationHistoryTable.Coordinator
        let clipboard = NSPasteboard(name: .init("TurtleGit.Sync.Clipboard.QA." + UUID().uuidString))
        defer { clipboard.releaseGlobally() }
        model.historyPasteboard = clipboard
        func copyItem(_ title: String) -> NSMenuItem {
            precondition(native.menu?.delegate === coordinator, "Revision menu lost its coordinator")
            native.menu!.delegate?.menuNeedsUpdate?(native.menu!)
            guard let item = native.menu!.items.first?.submenu?.items.first(where: { $0.title == title }) else {
                preconditionFailure("Missing clipboard command \(title); selected rows \(native.selectedRowIndexes); menu \(native.menu!.items.map(\.title))")
            }
            return item
        }
        func invoke(_ item: NSMenuItem) { precondition(item.isEnabled && NSApplication.shared.sendAction(item.action!,to:item.target,from:item)) }
        native.selectRowIndexes(IndexSet(integersIn:0..<2),byExtendingSelection:false)
        let rows = model.historyEntries
        precondition(rows.count == 2)
        let capturedHashes = copyItem("Hashes")
        native.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        invoke(capturedHashes); precondition(clipboard.string(forType:.string) == rows.map(\.hash).joined(separator:"\n"), "Menu payload must preserve the captured selection")
        native.selectRowIndexes(IndexSet(integersIn:0..<2),byExtendingSelection:false)
        for (kind,expected) in [(SynchronizationHistoryCopy.authors, rows.map { "\($0.author) <\($0.email)>" }.joined(separator:"\n")),(.authorNames,rows.map(\.author).joined(separator:"\n")),(.authorEmails,rows.map(\.email).joined(separator:"\n")),(.subjects,LogEntry.historyClipboard(rows,subjectsOnly:true)),(.messages,LogEntry.historyClipboard(rows,subjectsOnly:false))] {
            invoke(copyItem(kind.rawValue)); precondition(clipboard.string(forType:.string) == expected)
        }
        precondition(!native.menu!.items.first!.submenu!.items.contains { $0.title == "Tag/branch names" })
        native.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        invoke(copyItem("Tag/branch names")); precondition(clipboard.string(forType:.string)?.contains("refs/tags/v1.0\r\n") == true)
        (native as! HistoryTableView).contextReference = (0,"refs/tags/v1.0")
        invoke(copyItem("Tag/branch names")); precondition(clipboard.string(forType:.string) == "v1.0")
        (native as! HistoryTableView).contextReference = nil
        for kind in [SynchronizationHistoryCopy.detailsWithoutPaths,.details] {
            invoke(copyItem(kind.rawValue)); try await settle { !model.busy }
            let text = clipboard.string(forType:.string)!
            precondition(text.contains("Revision: " + entry.hash) && text.contains("Tag info: refs/tags/v1.0"))
            precondition(text.contains("modify.txt") == (kind == .details))
        }
        precondition(native.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue } == ["graph","actions","message","author","date","bugs"])
        func cell(_ id: String) -> NSTableCellView { coordinator.tableView(native, viewFor:native.tableColumn(withIdentifier:.init(id)),row:0) as! NSTableCellView }
        let actions = cell("actions")
        precondition(actions.toolTip == "Modified, Added/copied, Deleted, Replaced/renamed")
        precondition(descendants(actions).compactMap { $0 as? NSImageView }.filter { $0.image != nil }.count == 4)
        let message = cell("message").textField!
        precondition(NSFontManager.shared.traits(of: message.font!).contains(.boldFontMask), "The shared painter must retain HEAD's bold font")
        precondition(message.cell is LogReferenceTextCell && message.stringValue.contains("v1.0") && message.stringValue.contains("main"))
        var labels: [HistoryReferenceLabel] = []
        message.attributedStringValue.enumerateAttribute(.logReference,in:NSRange(location:0,length:message.attributedStringValue.length)) { value,_,_ in if let style = value as? LogReferenceStyle { labels.append(style.label) } }
        precondition(labels.contains { $0.kind == .annotatedTag } && labels.contains { $0.hasTracking })
        precondition(cell("date").textField!.stringValue == HistoryDateSettings.load(defaults:preferences).format(entry.date))
        precondition(cell("bugs").textField!.stringValue == "42")
        preferences.set(true,forKey:"RelativeTimes"); precondition(cell("date").textField!.toolTip == HistoryDateSettings.load(defaults:preferences).format(entry.date,absolute:true))
        preferences.set(true,forKey:"DrawTagsBranchesOnRightSide"); preferences.set(true,forKey:"FullCommitMessageOnLogLine")
        precondition(cell("message").textField!.stringValue.hasPrefix(entry.logLine(fullMessage:true)))
        preferences.set(false,forKey:"DrawTagsBranchesOnRightSide"); preferences.set(false,forKey:"FullCommitMessageOnLogLine")
        let hashItem = coordinator.headerMenu().items.first { ($0.representedObject as? String) == "hash" }!
        coordinator.toggleColumn(hashItem); precondition(!native.tableColumn(withIdentifier:.init("hash"))!.isHidden)
        precondition(preferences.bool(forKey:SynchronizationHistoryColumns.key(incoming:false,id:"hash")))
        coordinator.resetColumns(); precondition(native.tableColumn(withIdentifier:.init("hash"))!.isHidden)
        // Incoming lists use the same renderer but independent column preferences.
        model.finishPatchImport(oldHead:base); try await settle { !model.busy && model.incomingCommits != nil }
        let incoming = table(window), incomingCoordinator = incoming.delegate as! SynchronizationHistoryTable.Coordinator
        incomingCoordinator.toggleColumn(incomingCoordinator.headerMenu().items.first { ($0.representedObject as? String) == "hash" }!)
        precondition(preferences.bool(forKey:SynchronizationHistoryColumns.key(incoming:true,id:"hash")))
        precondition(!SynchronizationHistoryColumns.visible("hash",incoming:false,preferences:preferences))
        incomingCoordinator.resetColumns()
        if CommandLine.arguments.count > 3 {
            let output = URL(fileURLWithPath:CommandLine.arguments[3]); try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            for (tab,name) in [(0,"outgoing"),(4,"incoming")] {
                model.tab = tab
                for (size,suffix) in [(NSSize(width:1080,height:640),""),(NSSize(width:860,height:500),"-minimum")] {
                    window.setContentSize(size)
                    for (theme,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
                        window.appearance = NSAppearance(named:appearance); window.contentView!.layoutSubtreeIfNeeded(); window.contentView!.displayIfNeeded()
                        try await Task.sleep(nanoseconds:250_000_000)
                        guard let capture = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(window.windowNumber),[.boundsIgnoreFraming,.bestResolution]) else { preconditionFailure("Capture unavailable") }
                        let bitmap = NSBitmapImageRep(cgImage:capture)
                        try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("sync-" + name + "-" + theme + suffix + ".png"))
                    }
                }
            }
        }
        // A slow action query is owned by this model and cannot publish after close.
        let helper = root.deletingLastPathComponent().appendingPathComponent("action-helper-" + UUID().uuidString)
        let marker = helper.appendingPathExtension("pid")
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let script = "#!/bin/sh\nfor arg in \"$@\"; do\n if [ \"$arg\" = diff-tree ]; then\n  echo $$ > " + quoted(marker.path) + "\n  /bin/sleep 600 &\n  wait\n  exit 0\n fi\ndone\nexec " + quoted(repo.executable.path) + " \"$@\"\n"
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let slow = SynchronizationWindowModel(repository:GitRepository(root:root,executable:helper),access:nil,preferences:preferences)
        defer { slow.invalidate(); try? FileManager.default.removeItem(at:helper); try? FileManager.default.removeItem(at:marker) }
        slow.requestHistoryActions(entry); slow.requestHistoryActions(entry)
        try await settle { FileManager.default.fileExists(atPath:marker.path) }
        let pid = Int32(try String(contentsOf:marker).trimmingCharacters(in:.whitespacesAndNewlines))!
        defer { if kill(pid,0) == 0 { kill(-pid,SIGTERM) } }
        slow.invalidate()
        try await settle { kill(pid,0) != 0 && errno == ESRCH }
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(slow.historyActions.isEmpty && slow.historyActionFailures.isEmpty)
        try FileManager.default.removeItem(at:marker)
        try Data(script.replacingOccurrences(of:"= diff-tree",with:"= show").utf8).write(to:helper)
        let copying = SynchronizationWindowModel(repository:GitRepository(root:root,executable:helper),access:nil,preferences:preferences)
        copying.historyPasteboard = clipboard; clipboard.clearContents(); clipboard.setString("retain on cancellation",forType:.string)
        defer { copying.invalidate() }
        copying.copyHistory([entry],kind:.details)
        try await settle { FileManager.default.fileExists(atPath:marker.path) }
        let copyPID = Int32(try String(contentsOf:marker).trimmingCharacters(in:.whitespacesAndNewlines))!
        defer { if kill(copyPID,0) == 0 { kill(-copyPID,SIGTERM) } }
        copying.invalidate(); try await settle { kill(copyPID,0) != 0 && errno == ESRCH }
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(!copying.busy && clipboard.string(forType:.string) == "retain on cancellation")
        let finalRefs = try await repo.run(["show-ref"]).stdout, finalIndex = try Data(contentsOf:root.appendingPathComponent(".git/index")), finalConfig = try Data(contentsOf:root.appendingPathComponent(".git/config"))
        precondition(refs == finalRefs && index == finalIndex && config == finalConfig)
        owner.close(); precondition(model.closed && !model.busy && !window.isVisible)
        print("PASS: native Sync source columns, original action icons, annotated/current/tracking ref labels, issue IDs, date/full-message settings, independent column toggles/reset, both lists/themes/sizes, clipboard menus/captured multi-selection/source text formats/full metadata/pointed names, owned action and clipboard cancellation/late-callback fencing and unchanged Git state")
    }
}
@_cdecl("turtlegit_history_main") func bootstrap() -> Int32 {
    Task { @MainActor in
        do { try await SynchronizationRevisionListVerification.main(); exit(0) }
        catch { print(error); exit(1) }
    }
    NSApplication.shared.run(); return 0
}
