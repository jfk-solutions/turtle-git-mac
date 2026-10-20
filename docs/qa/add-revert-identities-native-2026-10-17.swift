// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct AddRevertIdentitiesVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String) throws {if !condition {throw Failure(description:message)}}
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else {return []};return [root]+root.subviews.flatMap {views($0)}}
    @MainActor static func wait(_ window:NSWindow?,line:Int = #line,_ ready:()->Bool) async throws {
        var settled = 0
        for _ in 0..<2000 {try await Task.sleep(nanoseconds:10_000_000);window?.contentView?.layoutSubtreeIfNeeded();settled = ready() ? settled+1:0;if settled == 2 {return}}
        throw Failure(description:"Add/Revert identity wait at \(line)")
    }
    @MainActor static func capture(_ window:NSWindow,prefix:String) async throws {
        guard let folder = ProcessInfo.processInfo.environment["TURTLEGIT_ADD_REVERT_IDENTITY_CAPTURE"] else {return}
        guard #available(macOS 14.4,*) else {throw Failure(description:"Owned capture unavailable")}
        window.alphaValue = 1;window.orderFront(nil);defer {window.alphaValue = 0}
        for (theme,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let owned = content.windows.first(where:{$0.windowID == CGWindowID(window.windowNumber)}) else {throw Failure(description:"Owned window unavailable")}
            let config = SCStreamConfiguration();config.width = Int(window.frame.width*2);config.height = Int(window.frame.height*2);config.showsCursor = false;config.ignoreShadowsSingleWindow = true;config.includeChildWindows = false
            let pixels = try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            guard let data = NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure(description:"Image encoding failed")}
            try data.write(to:URL(fileURLWithPath:folder).appendingPathComponent(prefix+"-"+name+".png"))
        }
    }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do {try await verify();print("PASS Add/Revert identities: exact checked/highlighted paths, native checkbox bulk rules, captured menu epochs/focus, refresh/retirement and unchanged HEAD/index")}
        catch {fputs("Add/Revert identities failed: \(error)\n",stderr);exit(1)}
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]),repo = GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Path Selection QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","true")] {_ = try await repo.run(["config",key,value])}
        let a = "café.txt",b = "cafe\u{301}.txt"
        let blob = try await repo.run(["hash-object","-w","--stdin"],input:Data("base\n".utf8)).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-index","-z","--index-info"],input:Data([a,b].map {"100644 \(blob)\t\($0)\0"}.joined().utf8))
        _ = try await repo.commit(message:"paired index paths")
        try Data("working\n".utf8).write(to:root.appendingPathComponent(a))
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".git/lfs"),withIntermediateDirectories:true)
        let head = try await repo.run(["rev-parse","HEAD"]).stdout,stage = try await repo.run(["ls-files","--stage","-z"]).stdout,workingBytes = try Data(contentsOf:root.appendingPathComponent(a))
        let suite = "TurtleGit.AddRevertIdentity."+UUID().uuidString,prefs = UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"RememberFileListPosition");defer {prefs.removePersistentDomain(forName:suite)}
        let add = AddWindowController(repository:repo,access:nil,defaults:prefs),model = add.model
        defer {add.close()};add.window!.alphaValue = 0;add.window!.orderFront(nil);model.setScope([a,b]);model.reload()
        try await wait(add.window) {!model.busy && model.entries.count == 2}
        guard let table = views(add.window?.contentView).compactMap({$0 as? NSTableView}).first,let coordinator = NativeListSelection.originalDelegate(of:table) as? AddFileTable.Coordinator else {throw Failure(description:"Native Add list unavailable")}
        try await wait(add.window) {table.numberOfRows == 2}
        func addIndex(_ path:String)->Int {coordinator.rows.firstIndex {GitReferenceName.equal($0.path,path)}!}
        func addButton(_ path:String)->NSButton? {views(add.window?.contentView).compactMap {$0 as? NSButton}.first {$0.accessibilityLabel().map {GitReferenceName.equal($0,"Add "+path)} == true}}
        model.checked = [];model.highlighted = []
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integer:addIndex(a)))
        try await wait(add.window) {model.highlighted.count == 1 && model.highlighted.contains(a) && addButton(b)?.isEnabled == true}
        addButton(b)!.performClick(nil)
        try await wait(add.window) {model.checked.count == 1 && model.checked.contains(b) && !model.checked.contains(a)}
        try require(model.highlighted.contains(a),"Add checkbox moved highlighted alias")
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet([addIndex(a),addIndex(b)]))
        try await wait(add.window) {model.highlighted.count == 2}
        addButton(a)!.performClick(nil);try await wait(add.window) {model.checked.count == 2}
        addButton(b)!.performClick(nil);try await wait(add.window) {model.checked.isEmpty}
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integer:addIndex(b)))
        try await wait(add.window) {model.highlighted.count == 1 && model.highlighted.contains(b)}
        var logs:[String] = [];model.onLog = {logs.append($0)}
        let menu = table.menu!
        coordinator.prepareContext(row:addIndex(b),column:table.column(withIdentifier:.init("path")));coordinator.menuNeedsUpdate(menu)
        let logItem = menu.items.first {$0.title == "Show log"}!
        try require(!logItem.isHidden && logItem.isEnabled,"Add history menu missing")
        NSApp.sendAction(logItem.action!,to:logItem.target,from:logItem)
        try require(logs.count == 1 && GitReferenceName.equal(logs[0],b),"Add menu normalized target")
        NSApp.sendAction(logItem.action!,to:logItem.target,from:logItem);try require(logs.count == 1,"Add menu dispatched twice")
        coordinator.menuNeedsUpdate(menu)
        model.highlighted = [a];model.selectionMark = a
        NSApp.sendAction(logItem.action!,to:logItem.target,from:logItem)
        model.highlighted = [b];model.selectionMark = b
        NSApp.sendAction(logItem.action!,to:logItem.target,from:logItem)
        try require(logs.count == 1,"Selection-away/return revived captured Add menu")
        // Exercise an actual enum-payload menu command through the captured native dispatcher.
        var lockTargets:[String] = []
        model.onLFSOperation = {paths,locked in if locked {lockTargets = paths};return false}
        coordinator.prepareContext(row:addIndex(b),column:table.column(withIdentifier:.init("path")));coordinator.menuNeedsUpdate(menu)
        guard let lock = menu.items.first(where:{$0.representedObject as? LFSLockMenuAction == .lock}) else {throw Failure(description:"Captured LFS menu missing")}
        try require(lock.isEnabled && !lock.isHidden,"Captured LFS menu disabled")
        NSApp.sendAction(lock.action!,to:lock.target,from:lock)
        try require(lockTargets.count == 1 && GitReferenceName.equal(lockTargets[0],b),"Captured menu lost enum payload or exact target")
        model.checked = [b];model.reload()
        try await wait(add.window) {!model.busy && model.checked.count == 1 && model.checked.contains(b) && model.highlighted.contains(b) && table.selectedRowIndexes == IndexSet(integer:addIndex(b))}
        try await capture(add.window!,prefix:"add-path-selection")
        coordinator.prepareContext(row:addIndex(b),column:table.column(withIdentifier:.init("path")));coordinator.menuNeedsUpdate(menu)
        add.close();NSApp.sendAction(logItem.action!,to:logItem.target,from:logItem)
        try require(logs.count == 1,"Retired Add dispatched a captured menu")
        let revert = RevertWindowController(repository:repo,access:nil,preferences:prefs),plan = revert.model
        defer {revert.close()};revert.window!.alphaValue = 0;revert.window!.orderFront(nil);plan.setScope(["."])
        try await wait(revert.window) {!plan.busy && plan.entries.count == 2}
        guard let revertTable = views(revert.window?.contentView).compactMap({$0 as? NSTableView}).first else {throw Failure(description:"Revert native table unavailable")}
        func revertIndex(_ path:String)->Int {plan.rows.firstIndex {GitReferenceName.equal($0.path,path)}!}
        func revertButton(_ path:String)->NSButton? {views(revert.window?.contentView).compactMap {$0 as? NSButton}.first {$0.accessibilityLabel().map {GitReferenceName.equal($0,"Revert "+path)} == true}}
        try await wait(revert.window) {revertTable.numberOfRows == 2 && revertButton(b)?.isEnabled == true}
        plan.checked = [];plan.highlighted = []
        CommitFileInteraction.replaceSelection(in:revertTable,with:IndexSet(integer:revertIndex(a)))
        try await wait(revert.window) {plan.highlighted.count == 1 && plan.highlighted.contains(a)}
        revertButton(b)!.performClick(nil)
        try await wait(revert.window) {plan.checked.count == 1 && plan.checked.contains(b) && !plan.checked.contains(a)}
        try require(plan.highlighted.contains(a),"Revert checkbox moved highlighted alias")
        CommitFileInteraction.replaceSelection(in:revertTable,with:IndexSet([revertIndex(a),revertIndex(b)]))
        try await wait(revert.window) {plan.highlighted.count == 2}
        revertButton(a)!.performClick(nil);try await wait(revert.window) {plan.checked.count == 2}
        revertButton(b)!.performClick(nil);try await wait(revert.window) {plan.checked.isEmpty}
        guard let probe = views(revert.window?.contentView).compactMap({$0 as? CommitFileInteraction.Probe}).first else {throw Failure(description:"Revert focus adapter missing")}
        probe.focusedPath?.wrappedValue = b
        let focusMenu = plan.commands.fileMenu(plan.highlighted,mark:b)
        probe.focusedPath?.wrappedValue = a
        var dispatched = false;plan.commands.withFileMenu(focusMenu) {dispatched = true}
        try require(!dispatched,"Canonical-only Revert focus change retained menu")
        CommitFileInteraction.replaceSelection(in:revertTable,with:IndexSet(integer:revertIndex(b)))
        try await wait(revert.window) {plan.highlighted.count == 1 && plan.highlighted.contains(b)}
        let captured = plan.commands.fileMenu(plan.highlighted,mark:b)
        plan.commands.withFileMenu(captured) {dispatched = true};try require(dispatched,"Live Revert menu refused exact selection");dispatched = false
        plan.highlighted = [a];plan.commands.withFileMenu(captured) {dispatched = true};try require(!dispatched,"Revert canonical replacement retained menu")
        try await wait(revert.window) {revertTable.selectedRowIndexes == IndexSet(integer:revertIndex(a))}
        CommitFileInteraction.replaceSelection(in:revertTable,with:IndexSet(integer:revertIndex(b)))
        try await wait(revert.window) {plan.highlighted.count == 1 && plan.highlighted.contains(b)}
        plan.checked = [b];plan.reload()
        try await wait(revert.window) {!plan.busy && plan.checked.count == 1 && plan.checked.contains(b) && plan.highlighted.count == 1 && plan.highlighted.contains(b) && revertTable.selectedRowIndexes == IndexSet(integer:revertIndex(b))}
        try await capture(revert.window!,prefix:"revert-path-selection")
        let late = plan.commands.fileMenu(plan.highlighted,mark:b),lateButton = revertButton(b)!,checked = plan.checked
        revert.close();plan.commands.withFileMenu(late) {dispatched = true};lateButton.performClick(nil)
        try require(!dispatched && plan.checked == checked,"Retired Revert callback changed captured selection")
        let finalHead = try await repo.run(["rev-parse","HEAD"]).stdout,finalStage = try await repo.run(["ls-files","--stage","-z"]).stdout
        try require(head == finalHead && stage == finalStage && Data(contentsOf:root.appendingPathComponent(a)) == workingBytes,"Native selection changed Git or working bytes")
    }
}
