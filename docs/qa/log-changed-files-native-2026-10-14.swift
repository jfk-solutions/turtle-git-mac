import AppKit
import TurtleGitCore

@main struct LogChangedFilesVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Log file pane timeout at line \(line)")}
    @MainActor static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    @MainActor static func main() async {do {try await verify()}catch {fputs("Log files failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Log Files QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let shared=root.appendingPathComponent("shared.txt");try Data("base\n".utf8).write(to:shared);try await repo.stage(["shared.txt"]);_ = try await repo.commit(message:"base")
        _ = try await repo.run(["switch","-c","feature"])
        try Data("feature\n".utf8).write(to:shared)
        for name in ["file2.txt","file10.txt"] {try Data((name+"\n").utf8).write(to:root.appendingPathComponent(name))}
        try await repo.stage(["."]);_ = try await repo.commit(message:"feature files")
        _ = try await repo.run(["switch","main"]);try Data("main\n".utf8).write(to:shared);try await repo.stage(["shared.txt"]);_ = try await repo.commit(message:"main change")
        _ = try await repo.run(["merge","--no-ff","feature"],successfulExitCodes:0...1)
        try Data("combined\n".utf8).write(to:shared);try await repo.stage(["shared.txt"]);_ = try await repo.commit(message:"merge groups")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.LogFilePane."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        defer {prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"LogIncludeWorkingTreeChanges");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        let controller=LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false),model=controller.model
        defer {controller.close()};model.clipboard=clipboard;model.reload();try await wait {!model.busy && !model.entries.isEmpty};model.select([model.entries[0].hash])
        try await wait {model.fileGroups.count == 2 && model.files.count >= 3}
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait {views(controller.window!.contentView!).contains {$0 is CommitFileInteraction.Probe}}
        let probe=views(controller.window!.contentView!).compactMap {$0 as? CommitFileInteraction.Probe}.first!
        try await wait {probe.groupHeaders?.headings.count == 2}
        let table=probe.groupHeaders!.table!
        try require(table.tableColumns.count == 5 && probe.leadingColumnCount == 0 && probe.itemIDs == model.fileTableRows.map(\.rawID),"Log file table semantic identity/columns missing")
        try require(probe.groupHeaders!.headings.allSatisfy {$0.rect.width == table.visibleRect.width && $0.rect.width > table.tableColumns.first!.width},"Parent headings still constrained to Path column")
        try require(probe.groupHeaders!.hitTest(.zero) == nil,"Heading overlay intercepts pointer events")
        let menu=probe.columnMenu();try require(menu.items.map(\.title) == ["Reset columns","","Extension","Status","Lines added","Lines removed"],"Header menu does not match source five-column mask")
        model.setChangedFileColumn(.removed,visible:false);try await wait {table.tableColumns.first {$0.headerCell.stringValue == "Lines removed"}?.isHidden == true}
        var order=model.changedFileColumns.order;order.removeAll {$0 == .status};order.insert(.status,at:0)
        _ = model.saveChangedFileLayout(order:order,widths:[.path:355]);try await wait {table.tableColumns.first?.headerCell.stringValue == "Status" && abs(table.tableColumns.first {$0.headerCell.stringValue == "Path"}!.width-355)<1}
        let reopened=LogWindowModel(repository:repo,access:nil,labelDefaults:prefs)
        try require(!reopened.changedFileColumns.visible.contains(.removed) && reopened.changedFileColumns.order.first == .status && reopened.changedFileColumns.widths[.path] == 355,"Layout did not persist in supplied private defaults")
        model.setChangedFileSort([LogChangedFileSort(column:.path)]);let rows=model.fileTableRows
        let names=rows.compactMap(\.file).filter {$0.parentIndex == 0}.map(\.path)
        try require(names.firstIndex(of:"file2.txt")! < names.firstIndex(of:"file10.txt")!,"Path sort lost numeric collation")
        let headers=rows.filter {$0.header != nil}.map(\.rawID);model.setChangedFileSort([LogChangedFileSort(column:.path,order:.reverse)])
        try require(model.fileTableRows.filter {$0.header != nil}.map(\.rawID) == headers,"Sort moved files across parent groups")
        let duplicateFiles=model.fileTableRows.compactMap(\.file).filter {$0.path == "shared.txt"}
        try require(duplicateFiles.count == 2 && duplicateFiles[0].id != duplicateFiles[1].id,"Parent-specific file identities collapsed")
        model.fileTableSelection.wrappedValue=Set(model.fileTableRows.map(\.id));try require(model.selectedFiles.count == model.files.count,"Group header was accepted as file selection")
        let ids=duplicateFiles.map(\.id);model.copyChangedFileIDs(ids,column:.path);try require(clipboard.string(forType:.string) == "shared.txt\r\nshared.txt","Duplicate parent rows or copy order lost")
        clipboard.clearContents();clipboard.setString("sentinel",forType:.string);model.copyChangedFileIDs(headers);try require(clipboard.string(forType:.string) == "sentinel","Header-only copy changed clipboard")
        let pathIndex=table.tableColumns.firstIndex {$0.headerCell.stringValue == "Path"}!
        try require(probe.fitColumn(atNativeIndex:pathIndex,useDefault:false),"Native divider content fit refused")
        try require(probe.fitColumn(atNativeIndex:pathIndex,useDefault:true),"Native Shift fit refused");try require(model.changedFileColumns.widths[.path] == nil,"Shift fit did not clear adjusted width")
        // Inject native keys at the actual table; group slots must be skipped.
        controller.window!.makeFirstResponder(table)
        model.focusedChangedFile=nil
        let home=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:115)!
        _ = probe.observe(home);try require(table.selectedRow == 1 && model.focusedChangedFile == probe.itemIDs?[1],"Home landed on a parent heading")
        let end=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:119)!
        _ = probe.observe(end);try require(table.selectedRow == table.numberOfRows-1,"End did not find final file row")
        // Both reset decisions and retired late approval are owned by the model.
        var accepted=0;let before=model.changedFileColumns
        model.resetChangedFileColumns(choose:{false},accepted:{accepted += 1});try await wait {!model.resettingChangedFileColumns};try require(model.changedFileColumns == before && accepted == 0,"No reset changed layout")
        model.resetChangedFileColumns(choose:{true},accepted:{accepted += 1});try await wait {!model.resettingChangedFileColumns};try require(model.changedFileColumns == StatusListColumnSettings() && accepted == 1,"Yes reset did not restore source defaults")
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {controller.window?.appearance=NSAppearance(named:appearance);probe.configureColumns();try require(probe.groupHeaders!.headings.count == 2,"Theme change lost headings")}
        var reply:((Bool)->Void)?;model.resetChangedFileColumns(choose:{await withCheckedContinuation {continuation in reply={continuation.resume(returning:$0)}}},accepted:{accepted += 1})
        try await wait {reply != nil};let saved=model.changedFileColumns;controller.close();reply?(true)
        try await Task.sleep(nanoseconds:30_000_000);try require(model.changedFileColumns == saved && accepted == 1 && probe.groupHeaders == nil,"Retired reset or queued group repaint published")
        reopened.invalidate()
        let after=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"));try require(after == head && afterIndex == index,"List-only workflow changed HEAD/index")
        print("Log changed files: full-width parent headers, exact parent IDs, numeric per-group sorting, native column mask/order/visibility/widths/reopen/fit/reset, injected Home/End, copy ordering/column/header refusal, light/dark and retired reset/overlay fencing passed. Private prefs/clipboard; owned Log closed; HEAD/index preserved.")
    }
}
