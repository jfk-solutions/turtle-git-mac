// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct ComparisonWorkflowVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func views(_ root:NSView?) -> [NSView] { guard let root else { return [] }; return [root]+root.subviews.flatMap { views($0) } }
    @MainActor static func wait(_ window:NSWindow?,line:Int = #line,_ ready:()->Bool) async throws {
        var settled = 0
        for _ in 0..<2500 { try await Task.sleep(nanoseconds:10_000_000);window?.contentView?.layoutSubtreeIfNeeded();settled = ready() ? settled+1:0;if settled == 2 { return } }
        throw Failure(description:"Comparison wait at \(line)")
    }
    @MainActor static func capture(_ window:NSWindow) async throws {
        guard let folder = ProcessInfo.processInfo.environment["TURTLEGIT_COMPARISON_WORKFLOW_CAPTURE"] else { return }
        guard #available(macOS 14.4,*) else { throw Failure(description:"Owned capture unavailable") }
        window.alphaValue = 1;window.orderFront(nil);defer { window.alphaValue = 0 }
        for (theme,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let owned = content.windows.first(where:{$0.windowID == CGWindowID(window.windowNumber)}) else { throw Failure(description:"Owned window unavailable") }
            let config = SCStreamConfiguration();config.width = Int(window.frame.width*2);config.height = Int(window.frame.height*2);config.showsCursor = false;config.ignoreShadowsSingleWindow = true;config.includeChildWindows = false
            let pixels = try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            guard let bytes = NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else { throw Failure(description:"Capture encoding") }
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent("comparison-workflow-"+name+".png"))
        }
    }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do { try await verify();print("PASS Comparison workflow: compared-range Log, native option states/ownership, exact native file selection/completion/copy/compare/cache targets, captured menus, owned list/blob/export choosers, cancellation/retirement and unchanged HEAD/index") }
        catch { fputs("Comparison workflow failed: \(error)\n",stderr);exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]),repo = GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Comparison QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","true")] { _ = try await repo.run(["config",key,value]) }
        let a = "café.txt",b = "cafe\u{301}.txt",paths = [a,b]
        func install(_ text:String) async throws {
            let blob = try await repo.run(["hash-object","-w","--stdin"],input:Data(text.utf8)).text.trimmingCharacters(in:.newlines)
            _ = try await repo.run(["update-index","-z","--index-info"],input:Data(paths.map {"100644 \(blob)\t\($0)\0"}.joined().utf8))
        }
        try await install("base\n");_ = try await repo.commit(message:"paired base")
        let base = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try await install("changed\n");_ = try await repo.commit(message:"paired change")
        let tip = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let ra = "refs/tags/café",rb = "refs/tags/cafe\u{301}"
        let records = [(ra,base),(rb,tip)].sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
        try Data(("# pack-refs with: sorted\n" + records.map { $0.1+" "+$0.0+"\n" }.joined()).utf8).write(to:root.appendingPathComponent(".git/packed-refs"))
        let index = try Data(contentsOf:root.appendingPathComponent(".git/index")),head = try await repo.run(["rev-parse","HEAD"]).stdout
        let suite = "TurtleGit.ComparisonWorkflow."+UUID().uuidString,prefs = UserDefaults(suiteName:suite)!,clipboard = NSPasteboard.withUniqueName()
        defer { prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally() }
        for key in ["EnableLogCache","EnableGravatar","LogIncludeWorkingTreeChanges"] { prefs.set(false,forKey:key) }
        let owner = RevisionComparisonWindowController(repository:repo,access:nil,from:.revision(ra),to:.revision(rb),preferences:prefs,savesGeometry:false),model = owner.model
        defer { owner.close() };owner.window!.alphaValue = 0;owner.window!.orderFront(nil);model.clipboard = clipboard
        try await wait(owner.window) { !model.busy && model.visibleFiles.count == 2 }
        try require(model.error == nil && model.snapshot?.from == .revision(base) && model.snapshot?.to == .revision(tip),"Selector normalized a packed reference")
        try require(GitPathSet(model.completionNames).contains("café") && GitPathSet(model.completionNames).contains("cafe\u{301}"),"Completion names collapsed Unicode references")
        guard let probe = views(owner.window?.contentView).compactMap({$0 as? CommitFileInteraction.Probe}).first,
              let table = views(owner.window?.contentView).compactMap({$0 as? NSTableView}).first(where:{$0.tableColumns.count == 5}) else { throw Failure(description:"Missing native comparison table") }
        try await wait(owner.window) { table.numberOfRows == 2 }
        func select(_ ids:GitPathSet) async throws {
            try await wait(owner.window) {
                let rows = model.visibleFiles
                return probe.itemIDs?.map({GitReferenceName($0)}) == rows.map({GitReferenceName($0.path)}) && GitPathSet(table.selectedRowIndexes.compactMap {rows.indices.contains($0) ? rows[$0].path:nil}) == model.selection
            }
            let indexes = IndexSet(model.visibleFiles.enumerated().compactMap { ids.contains($0.element.path) ? $0.offset:nil })
            CommitFileInteraction.replaceSelection(in:table,with:indexes)
            try await wait(owner.window) { model.selection == ids && table.selectedRowIndexes == indexes }
        }
        try await select([a]);let stale = model.captureFileMenu([a])
        try await select([b]);try require(!model.claimFileMenu(stale),"File menu survived canonical-only selection change")
        model.copyPaths([b]);try require(Data((clipboard.string(forType:.string) ?? "").utf8) == Data((b+"\t\n").utf8),"Clipboard retargeted canonical neighbor")
        try await select(GitPathSet(paths))
        var compared:[String] = [];model.openComparedFile = {_,file in compared.append(file.path)}
        model.compare(paths);try await wait(owner.window) {!model.busy}
        try require(GitPathSet(compared) == GitPathSet(paths) && compared.count == 2,"Comparison dispatch dropped a selected spelling")
        model.openComparedFile = nil;model.compare(paths)
        try await wait(owner.window) {!model.busy && model.comparisonWindows.count == 2 && model.comparisonWindows.values.allSatisfy {!$0.model.busy && !$0.model.filtering}}
        try require(GitPathSet(model.comparisonWindows.values.map {$0.model.path}) == GitPathSet(paths),"Real viewer cache reused the canonical neighbor")
        try require(model.comparisonWindows.values.allSatisfy {$0.model.document?.base.bytes == Data("base\n".utf8) && $0.model.document?.destination.bytes == Data("changed\n".utf8)},"Real viewer opened wrong historical contents")
        Array(model.comparisonWindows.values).forEach {$0.close()};try await wait(owner.window) {model.comparisonWindows.isEmpty}
        let foreign = RevisionComparisonWindowModel(repository:repo,access:nil,from:.revision(base),to:.revision(tip),preferences:prefs)
        foreign.snapshot = model.snapshot;foreign.selection = GitPathSet(paths)
        let context = model.captureFileMenu(paths);try require(!foreign.claimFileMenu(context),"A different model claimed the popup")
        try require(model.claimFileMenu(context) && !model.claimFileMenu(context),"Popup was not consumed once")
        let focus = model.captureFileMenu(paths);model.focusedFile = b;try require(!model.claimFileMenu(focus),"Focus change retained old menu")
        let sorted = model.captureFileMenu(paths);model.sortOrder = [KeyPathComparator(\CommitFile.sortPath,order:.reverse)];try require(!model.claimFileMenu(sorted),"Sort change retained old menu")
        let filtered = model.captureFileMenu(paths);model.filter = "missing";model.filter = "";try require(!model.claimFileMenu(filtered),"Filter away/back revived old menu")
        foreign.invalidate()
        // Toolbar history is the actual compared range, including both pinned endpoints.
        model.log();try await wait(owner.window) {owner.rangeLogs.values.contains {!$0.model.busy && $0.model.revisionRange?.from == base && $0.model.revisionRange?.to == tip}}
        let history = owner.rangeLogs.values.first!
        try require(history.model.entries.map(\.hash) == [tip],"Show log opened all destination history instead of base..tip")
        history.close();try await wait(owner.window) {owner.rangeLogs.isEmpty && LogWindowModel.activeHistoryLoads == 0}
        // CMenuButton's caption and main-segment action retain the chosen picker.
        guard let selector = views(owner.window?.contentView).compactMap({$0 as? NSSegmentedControl}).first(where:{$0.identifier?.rawValue == "Comparison.RevisionPicker.base"}),
              let selectorTarget = selector.target as? ComparisonRevisionPicker.Coordinator else {throw Failure(description:"Missing native revision split selector")}
        let choices = selectorTarget.makeMenu()
        try require(choices.items.map(\.title) == ["RefBrowse","Log","RefLog"] && selector.label(forSegment:0) == "RefBrowse","Source revision selector labels/order wrong")
        choices.performActionForItem(at:1);try await wait(owner.window) {owner.logPicker?.model.busy == false}
        try require(model.basePickerAction == .log && owner.window?.attachedSheet === owner.logPicker?.window,"Split-selector menu failed to open owned Log")
        owner.logPicker!.model.close();try await wait(owner.window) {owner.logPicker == nil && owner.window?.attachedSheet == nil}
        try await wait(owner.window) {views(owner.window?.contentView).compactMap({$0 as? NSSegmentedControl}).contains {$0.identifier?.rawValue == "Comparison.RevisionPicker.base" && $0.isEnabled && $0.label(forSegment:0) == "Log"} && model.canChangeColumns}
        let repeatedSelector = views(owner.window?.contentView).compactMap {$0 as? NSSegmentedControl}.first {$0.identifier?.rawValue == "Comparison.RevisionPicker.base"}!
        let repeatedTarget = repeatedSelector.target as! ComparisonRevisionPicker.Coordinator
        // AppKit momentary controls ignore setSelected(_:forSegment:). Inject
        // the segment into their actual dispatcher instead of changing tracking.
        repeatedTarget.activateSegment(0,from:repeatedSelector)
        try await wait(owner.window) {owner.logPicker?.model.busy == false}
        owner.logPicker!.model.close();try await wait(owner.window) {owner.logPicker == nil && owner.window?.attachedSheet == nil}
        model.basePickerAction = .browse
        // Actual native Diff Options hierarchy, checkbox state and one-use target.
        let options = ComparisonDiffOptionsControl.Coordinator();options.model = model
        let menu = options.makeMenu()
        try require(menu.items.map(\.title) == ["Ignore space at end of line","Ignore space changes","Ignore all spaces","Ignore blank lines","","Common ancestor"],"Source Diff Options order/separator wrong")
        try require(menu.items.filter {!$0.isSeparatorItem}.allSatisfy {$0.state == .off && $0.image != nil},"Native option states/artwork wrong")
        menu.performActionForItem(at:0);try await wait(owner.window) {!model.busy}
        try require(model.options.ignoreSpaceAtEnd && options.makeMenu().items[0].state == .on,"Native option did not check/reload")
        menu.performActionForItem(at:1);try require(!model.options.ignoreSpaceChange,"Stale option command survived reload")
        options.makeMenu().performActionForItem(at:0);try await wait(owner.window) {!model.busy}
        // Save list keeps captured order/endpoints through the owned operation.
        let listURL = root.appendingPathComponent("selected-list.txt")
        model.chooseFileList = {listURL};let selected = [b]
        model.saveList(selected);try await wait(owner.window) {!model.busy && FileManager.default.fileExists(atPath:listURL.path)}
        try require(Data(contentsOf:listURL) == Data(ComparisonFileList.savedList(model.visibleFiles.filter {GitReferenceName.equal($0.path,b)},from:.revision(base),to:.revision(tip)).utf8),"Saved list changed target or endpoints")
        var answer:CheckedContinuation<URL?,Never>?
        model.chooseFileList = {await withCheckedContinuation {answer = $0}}
        try await select([a]);model.saveList([a]);try await wait(owner.window) {answer != nil}
        try require(RevisionComparisonWindowModel.activeFileOperations == 1,"Save-list preparation lost operation ownership")
        model.selection = [b];answer!.resume(returning:root.appendingPathComponent("late-list.txt"));answer = nil
        try await wait(owner.window) {!model.busy}
        try require(!FileManager.default.fileExists(atPath:root.appendingPathComponent("late-list.txt").path) && model.error == nil,"Changed selection wrote a stale list")
        // The real native Save, Export and Open With sheets reuse one owner.
        try await select([b]);model.saveRevisionFile([b])
        do {try await wait(owner.window) {owner.fileActionPresenter?.filePanels.currentPanel?.sheetParent === owner.window}}
        catch {throw Failure(description:"Save panel did not attach: busy=\(model.busy), error=\(model.error ?? "nil"), selected=\(model.nativeSelection), panel=\(owner.fileActionPresenter?.filePanels.currentPanel != nil), sheet=\(owner.window?.attachedSheet != nil), visible=\(owner.window?.isVisible == true), sheets=\(owner.window?.sheets.count ?? -1), panelVisible=\(owner.fileActionPresenter?.filePanels.currentPanel?.isVisible == true), modal=\(NSApp.modalWindow != nil)") }
        let save = owner.fileActionPresenter!.filePanels.currentPanel!
        try require(!owner.windowShouldClose(owner.window!) && model.busy,"Native Save panel lost busy/close gate")
        owner.fileActionPresenter!.filePanels.receive(save,response:.cancel);owner.fileActionPresenter!.filePanels.receive(save,response:.OK)
        try await wait(owner.window) {!model.busy && owner.window?.attachedSheet == nil}
        model.exportFiles([a]);try await wait(owner.window) {owner.fileActionPresenter?.filePanels.currentPanel?.sheetParent === owner.window}
        model.cancelFileAction();try await wait(owner.window) {!model.busy && owner.window?.attachedSheet == nil}
        try await capture(owner.window!)
        model.openRevisionFile([b],action:.openWith);try await wait(owner.window) {owner.fileActionPresenter?.filePanels.currentPanel?.sheetParent === owner.window}
        let pending = owner.fileActionPresenter!.filePanels.currentPanel!,last = model.captureFileMenu([b])
        owner.close();owner.fileActionPresenter!.filePanels.receive(pending,response:.OK)
        try await wait(nil) {RevisionComparisonWindowModel.activeFileOperations == 0}
        try require(model.closed && !model.claimFileMenu(last) && model.error == nil,"Retired chooser/menu escaped owner")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout == head,"Compare changed HEAD")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"Read-only/cancelled comparison changed index")
    }
}
