// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

@main struct WorkingSelectionIdentitiesVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ condition:Bool,_ message:String) throws { if !condition { throw Failure(description:message) } }
    @MainActor static func descendants(_ view:NSView?)->[NSView] { guard let view else {return []};return [view]+view.subviews.flatMap {descendants($0)} }
    @MainActor static func wait(_ owner:NSWindow?,line:Int = #line,label:String = "native row identity",_ ready:()->Bool) async throws {
        var settled = 0
        for _ in 0..<2000 {
            try await Task.sleep(nanoseconds:10_000_000)
            owner?.contentView?.layoutSubtreeIfNeeded()
            settled = ready() ? settled + 1 : 0
            if settled == 2 {return}
        }
        throw Failure(description:"Exact native selection wait at \(line): \(label)")
    }
    @MainActor static func main() async { NSApplication.shared.setActivationPolicy(.prohibited);do {try await verify();print("PASS: exact native Commit/Working Tree row IDs, checkbox/highlight/group/menu/refresh identity and owned closure") } catch { fputs("Native exact selection failed: \(error)\n",stderr);exit(1) } }
    @MainActor final class ControlModel:ObservableObject {
        @Published var selection = Set<String>()
    }
    struct ControlRow:Identifiable {let id:String}
    struct ControlView:View {
        @ObservedObject var model:ControlModel
        var body:some View {
            Table([ControlRow(id:"one"),ControlRow(id:"two"),ControlRow(id:"three")],selection:$model.selection) {
                TableColumn("Path") {row in Text(row.id)}
                TableColumn("Status") {row in Text("Modified")}
            }
        }
    }
    @MainActor static func control() async throws {
        let model = ControlModel(), window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = NSHostingView(rootView:ControlView(model:model));window.alphaValue = 0;window.orderFront(nil)
        defer {window.close()}
        try await wait(window) {descendants(window.contentView).compactMap {$0 as? NSTableView}.first?.numberOfRows == 3}
        let table = descendants(window.contentView).compactMap {$0 as? NSTableView}.first!
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integer:0))
        try await wait(window) {model.selection == ["one"]}
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet([0,1]))
        try await wait(window) {model.selection == ["one","two"]}
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integer:1))
        do {try await wait(window) {model.selection == ["two"]}}
        catch {print("Minimal SwiftUI control: native=\(table.selectedRowIndexes), model=\(model.selection)");throw error}
        print("PASS: minimal SwiftUI native multi-to-single control")
    }
    @MainActor static func capture(_ window:NSWindow,prefix:String) async throws {
        guard let folder = ProcessInfo.processInfo.environment["TURTLEGIT_EXACT_SELECTION_CAPTURE"] else {return}
        guard #available(macOS 14.4,*) else {throw Failure(description:"Owned capture unavailable")}
        window.alphaValue = 1;window.orderFront(nil);defer {window.alphaValue = 0}
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let owned = content.windows.first(where:{$0.windowID == CGWindowID(window.windowNumber)}) else {throw Failure(description:"Owned capture window missing")}
            let options = SCStreamConfiguration();options.width = Int(window.frame.width*2);options.height = Int(window.frame.height*2);options.showsCursor = false;options.ignoreShadowsSingleWindow = true;options.includeChildWindows = false
            let pixels = try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:options)
            guard let data = NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure(description:"Capture encoding failed")}
            try data.write(to:URL(fileURLWithPath:folder).appendingPathComponent(prefix+"-"+name+".png"))
        }
    }
    @MainActor static func verify() async throws {
        try await control()
        let root = URL(fileURLWithPath:CommandLine.arguments[1]),git = URL(fileURLWithPath:CommandLine.arguments[2]),repo = GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Exact Selection QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","true"),("tgit.commitstagingsupport","false")] { _ = try await repo.run(["config",key,value]) }
        let plain = ProcessInfo.processInfo.environment["TURTLEGIT_SELECTION_PLAIN"] == "1"
        let a = plain ? "z.txt" : "café.txt",b = plain ? "a.txt" : "cafe\u{301}.txt"
        let blob = try await repo.run(["hash-object","-w","--stdin"],input:Data("base\n".utf8)).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-index","-z","--index-info"],input:Data(([a,b].map {"100644 \(blob)\t\($0)\0"}.joined()).utf8))
        _ = try await repo.commit(message:"paired index paths")
        try Data("unversioned\n".utf8).write(to:root.appendingPathComponent("loose.txt"))
        let head = try await repo.run(["rev-parse","HEAD"]).stdout,stage = try await repo.run(["ls-files","--stage","-z"]).stdout
        let suite = "TurtleGit.ExactSelection.QA."+UUID().uuidString,prefs = UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"AddBeforeCommit");prefs.set(true,forKey:"HintStagingMode");prefs.set(true,forKey:"Commit.SkipCancelConfirmation");prefs.set(true,forKey:"RememberFileListPosition")
        defer { prefs.removePersistentDomain(forName:suite) }
        let commit = CommitWindowController(repository:repo,access:nil,defaults:prefs),model = commit.model
        defer { commit.close() };commit.window!.alphaValue = 0;commit.window!.orderFront(nil);model.reload()
        try await wait(commit.window) { !model.busy && !model.savingPreferences && model.entries.count == 3 }
        guard let table = descendants(commit.window!.contentView).compactMap({$0 as? NSTableView}).first else {throw Failure(description:"Commit native table missing")}
        try await wait(commit.window) { table.numberOfRows == model.visibleFileRowIDs.count && table.numberOfRows >= 3 }
        func index(_ path:String)->Int { model.visibleFileRowIDs.firstIndex {GitReferenceName.equal($0,path)}! }
        func checkbox(_ path:String)->NSButton? {
            descendants(commit.window!.contentView).compactMap {$0 as? NSButton}.first { $0.accessibilityLabel().map {GitReferenceName.equal($0,"Include "+path)} == true }
        }
        model.checked = [];model.selection = []
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integer:index(a)))
        try await wait(commit.window) { model.selection.count == 1 && model.selection.contains(a) && !model.selection.contains(b) }
        try await wait(commit.window) { checkbox(b)?.isEnabled == true }
        checkbox(b)!.performClick(nil)
        try await wait(commit.window) { model.checked.count == 1 && model.checked.contains(b) }
        try require(!model.checked.contains(a) && model.selection.contains(a),"Unhighlighted alias checkbox selected its neighbor")
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet([index(a),index(b)]))
        try await wait(commit.window) {model.selection.count == 2}
        checkbox(a)!.performClick(nil);try await wait(commit.window) {model.checked.count == 2 && checkbox(b)?.state == .on}
        let focusCheckReceipt = model.fileCheckReceipt
        model.focusedFiles["checkbox"] = a
        let focusedMenu = model.fileMenu(model.selection,mark:a)
        model.focusedFiles["checkbox"] = b
        var staleFocusDispatch = false;model.withFileMenu(focusedMenu) {staleFocusDispatch = true}
        try require(!staleFocusDispatch && GitReferenceName.equal(model.focusedFiles["checkbox"] ?? "",b),"Canonical-only focus replacement retained Commit menu")
        try require(model.fileCheckReceipt == focusCheckReceipt,"Pointer focus retired unchanged Commit checkbox row/policy receipt")
        checkbox(b)!.performClick(nil)
        do {try await wait(commit.window,label:"immediate checkbox action after exact focus change") {model.checked.isEmpty && checkbox(a)?.state == .off && checkbox(b)?.state == .off && model.selection.count == 2 && table.selectedRowIndexes.count == 2}}
        catch {
            print("Checkbox focus diagnostic: checked=\(model.checked.map {Array($0.utf8)}), selected=\(model.selection.map {Array($0.utf8)}), native=\(table.selectedRowIndexes), states=\(checkbox(a)?.state.rawValue ?? -99)/\(checkbox(b)?.state.rawValue ?? -99), enabled=\(checkbox(b)?.isEnabled == true), currentReceipt=\(model.fileCheckReceipt == focusCheckReceipt), available=\(model.fileListAvailable)")
            throw error
        }
        let policyReceipt=model.fileCheckReceipt
        model.doNotAutoselectSubmodules.toggle();model.doNotAutoselectSubmodules.toggle()
        let exactB=model.entries.first {GitReferenceName.equal($0.path,b)}!
        model.setFileChecked(exactB,files:model.visibleEntries,highlighted:model.selection,checked:true,receipt:policyReceipt)
        try require(model.checked.isEmpty,"Old checkbox receipt revived after a submodule policy round trip")
        let quitReceipt=model.fileCheckReceipt
        model.confirmingQuit=true;model.confirmingQuit=false
        model.setFileChecked(exactB,files:model.visibleEntries,highlighted:model.selection,checked:true,receipt:quitReceipt)
        try require(model.checked.isEmpty,"Old checkbox receipt revived after a Quit ownership round trip")
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integer:index(b)))
        do { try await wait(commit.window) {model.selection.count == 1 && model.selection.contains(b)} }
        catch {
            print("Selection diagnostic: model=\(model.selection.map {Array($0.utf8)}), native=\(table.selectedRowIndexes), requested=\(index(b)), attached=\(table.window != nil)")
            throw error
        }
        model.setFileChecked(model.entries.first {GitReferenceName.equal($0.path,b)}!,files:model.visibleEntries,highlighted:model.selection,checked:true)
        let captured = model.fileMenu(model.selection,mark:b)
        try require(captured.entries.count == 1 && GitReferenceName.equal(captured.mark!.path,b),"Commit menu marked a canonical neighbor")
        var dispatched = false;model.withFileMenu(captured) {dispatched = true}
        try require(dispatched,"Live Commit menu was not dispatchable");dispatched = false
        model.selection = [a]
        try await wait(commit.window) {table.selectedRowIndexes == IndexSet(integer:index(a))}
        model.withFileMenu(captured) {dispatched = true};try require(!dispatched,"Canonical-only selection replacement retained old menu")
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integer:index(b)))
        try await wait(commit.window) {model.selection.count == 1 && model.selection.contains(b)}
        let reloadCheckReceipt=model.fileCheckReceipt
        model.reload();try await wait(commit.window) {!model.busy && model.selection.count == 1 && model.selection.contains(b)}
        try await wait(commit.window) {table.selectedRowIndexes.count == 1 && table.selectedRow == index(b)}
        let refreshedChecks=model.checked
        model.setFileChecked(exactB,files:model.visibleEntries,highlighted:model.selection,checked:false,receipt:reloadCheckReceipt)
        try require(model.checked==refreshedChecks,"Old checkbox receipt survived an actual same-row repository reload")
        try require(model.checkedPathsForCommit.count == 1 && model.checkedPathsForCommit.contains(b) && !model.checkedPathsForCommit.contains(a),"Refresh merged checked aliases")
        try await capture(commit.window!,prefix:"commit-file-selection")
        let status = StatusWindowController(repository:repo,access:nil,defaults:prefs),working = status.model
        defer {status.close()};status.window!.alphaValue = 0;status.window!.orderFront(nil);working.reload()
        try await wait(status.window) {!working.busy && working.visibleFiles.count == 3}
        guard let statusTable = descendants(status.window!.contentView).compactMap({$0 as? NSTableView}).first else {throw Failure(description:"Working Tree native table missing")}
        func statusIndex(_ path:String)->Int {working.tableRows.firstIndex {GitReferenceName.equal($0.row.id,path)}!}
        try await wait(status.window) {statusTable.numberOfRows == working.tableRows.count}
        CommitFileInteraction.replaceSelection(in:statusTable,with:IndexSet(integer:statusIndex(b)))
        try await wait(status.window) {working.selection.count == 1 && working.selection.contains(b) && !working.selection.contains(a)}
        let menu = working.fileMenu(working.selection,mark:b)
        try require(menu.entries.count == 1 && GitReferenceName.equal(menu.mark!.path,b),"Working Tree mark selected wrong spelling")
        working.withFileMenu(menu) {dispatched = true};try require(dispatched,"Live Working Tree menu was not dispatchable");dispatched = false
        working.selection = [a]
        try await wait(status.window) {statusTable.selectedRowIndexes == IndexSet(integer:statusIndex(a))}
        working.withFileMenu(menu) {dispatched = true}
        try require(!dispatched,"Working Tree accepted stale alias menu")
        working.selectGroup(.modified)
        try await wait(status.window) {working.selection.count == 2 && working.selection.contains(a) && working.selection.contains(b)}
        guard let probe = descendants(status.window?.contentView).compactMap({$0 as? CommitFileInteraction.Probe}).first else {throw Failure(description:"Working Tree focus adapter missing")}
        probe.focusedPath?.wrappedValue = a;probe.focusedPath?.wrappedValue = b
        try await wait(status.window) {GitReferenceName.equal(probe.focusedPath?.wrappedValue ?? "",b)}
        try require(GitReferenceName.equal(working.fileMenu(working.selection,mark:probe.focusedPath?.wrappedValue).mark!.path,b),"Native focus binding normalized selected alias")
        CommitFileInteraction.replaceSelection(in:statusTable,with:IndexSet(integer:statusIndex(b)))
        try await wait(status.window) {working.selection.count == 1 && working.selection.contains(b)}
        working.reload();try await wait(status.window) {!working.busy && working.selection.count == 1 && working.selection.contains(b)}
        try await wait(status.window) {statusTable.selectedRowIndexes.count == 1 && statusTable.selectedRow == statusIndex(b)}
        try await capture(status.window!,prefix:"working-tree-file-selection")
        let late = working.fileMenu(working.selection,mark:b);status.close();working.withFileMenu(late) {dispatched = true}
        try require(!dispatched,"Retired Working Tree dispatched captured selection")
        let retiredButton = checkbox(b)!, retainedChecks = model.checked
        commit.close();retiredButton.performClick(nil)
        try require(model.checked == retainedChecks,"Closed Commit checkbox changed retained selection")
        let finalHead = try await repo.run(["rev-parse","HEAD"]).stdout,finalStage = try await repo.run(["ls-files","--stage","-z"]).stdout
        try require(head == finalHead && stage == finalStage,"Native identity checks changed repository contents")
    }
}
