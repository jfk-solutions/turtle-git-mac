// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct AddListFamilyVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var owners: [AddWindowController] = []
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1800 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Add operation did not settle at fixture line \(line)")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func capture(_ owner: AddWindowController) async throws {
        guard let folder = ProcessInfo.processInfo.environment["TURTLEGIT_ADD_LIST_CAPTURE"], let window = owner.window else { return }
        guard #available(macOS 14.4, *) else { throw Failure(description:"Screen capture unavailable") }
        window.alphaValue = 1; window.makeKeyAndOrderFront(nil); defer { window.alphaValue = 0 }
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named:theme); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds:250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description:"Missing owned Add compositor window") }
            let options = SCStreamConfiguration(); options.width = Int(window.frame.width * window.backingScaleFactor); options.height = Int(window.frame.height * window.backingScaleFactor)
            options.showsCursor = false; options.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow:own),configuration:options)
            try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:folder).appendingPathComponent("add-list-" + suffix + ".png"))
        }
    }
    @MainActor static func main() async {
        do { try await verify(); print("PASS: Add source LFS menus/progress/review/refresh/retirement, persistent columns/reset and marked checkbox keyboard behavior") }
        catch {
            owners.forEach { $0.close() }
            for _ in 0..<1200 { if AddWindowModel.activeOperations == 0 && LFSLocksWindowModel.activeOperations == 0 { break }; try? await Task.sleep(nanoseconds:10_000_000) }
            fputs("Add family failed: \(error)\n",stderr); exit(1)
        }
    }
    @MainActor static func verify() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2]), repository = GitRepository(root:root,executable:git)
        let suite = "TurtleGit.AddList.QA." + UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { owners.forEach { $0.close() }; owners=[]; defaults.removePersistentDomain(forName:suite) }
        defaults.set(true,forKey:"Add.ShowSize")
        _ = try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Add List QA"),("user.email","add@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repository.run(["config",key,value]) }
        for name in ["tracked.txt","other.txt"] { try Data("base\n".utf8).write(to:root.appendingPathComponent(name)) }
        try await repository.stage(["tracked.txt","other.txt"]); _ = try await repository.commit(message:"base")
        try Data("changed\n".utf8).write(to:root.appendingPathComponent("tracked.txt")); try Data("new\n".utf8).write(to:root.appendingPathComponent("new.txt"))
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".git/lfs"),withIntermediateDirectories:true)
        let index = try Data(contentsOf:root.appendingPathComponent(".git/index")), head = try await repository.run(["rev-parse","HEAD"]).stdout
        let model = AddWindowModel(repository:repository,access:nil,defaults:defaults)
        defer { model.invalidate() }
        model.setScope(["tracked.txt","other.txt","new.txt"]); try await model.read()
        try require(model.hasLFS && model.fileColumns.visible == [.path,.fileExtension,.fileSize],"Legacy Add visibility migration")
        let coordinator = AddFileTable.Coordinator(model:model), scroll = coordinator.make(), table = coordinator.table
        let host = NSWindow(contentRect:.init(x:0,y:0,width:760,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        host.isReleasedWhenClosed=false; host.contentView=scroll; defer { host.close() }
        try require(!table.tableColumn(withIdentifier:.init("size"))!.isHidden && table.tableColumn(withIdentifier:.init("date"))!.isHidden,"Initial migrated native columns")
        let extensionItem = table.headerView!.menu!.item(withTitle:"Extension")!
        coordinator.toggleColumn(extensionItem)
        try require(!model.fileColumns.visible.contains(.fileExtension),"Extension header visibility")
        table.moveColumn(table.column(withIdentifier:.init("size")),toColumn:1)
        table.tableColumn(withIdentifier:.init("size"))!.width=137
        coordinator.saveColumnLayout()
        let restored = AddWindowModel(repository:repository,access:nil,defaults:defaults); defer { restored.invalidate() }
        try require(restored.fileColumns.order.first == .fileSize && restored.fileColumns.widths[.fileSize] == 137,"Native column order/width persistence")
        table.moveColumn(0,toColumn:3)
        try require(table.tableColumns.first!.identifier.rawValue == "check","Leading native checkbox stays first")
        model.highlighted=["tracked.txt","other.txt"]; model.selectionMark="tracked.txt"; model.checked=["tracked.txt"]
        coordinator.refresh(); coordinator.toggleSelectedChecks()
        try require(model.checked.isEmpty,"Space follows checked marked row in mixed selection")
        model.checked=["other.txt"]; coordinator.toggleSelectedChecks()
        try require(model.checked == ["tracked.txt","other.txt"],"Space follows unchecked marked row")
        let button=NSButton(checkboxWithTitle:"",target:nil,action:nil); button.identifier = .init("tracked.txt"); button.state = .off; coordinator.toggleRow(button)
        try require(model.checked.isEmpty,"Selected checkbox propagates to selected rows")
        model.highlighted=["other.txt"]; button.state = .on; coordinator.toggleRow(button)
        try require(model.checked == ["tracked.txt"],"Unselected checkbox affects only itself")
        model.highlighted=["tracked.txt","other.txt"]; coordinator.prepareContext(row:coordinator.rows.firstIndex(where:{$0.path=="tracked.txt"})!,column:table.column(withIdentifier:.init("size")))
        try require(coordinator.clipboardText("all").hasPrefix("Size\tPath\n"),"Clipboard follows saved visible native order")
        try require(coordinator.clipboardText("pathsStatus") == StatusListClipboard.text(coordinator.selectedRows.map(\.status),root:root,statistics:[:],copy:.pathsAndStatus),"Shift-copy shares source status rendering")
        coordinator.menuNeedsUpdate(table.menu!)
        let lock=table.menu!.item(withTitle:"LFS Lock")!, unlock=table.menu!.item(withTitle:"LFS Unlock")!
        try require(!lock.isHidden && !unlock.isHidden && lock.image != nil && unlock.image != nil,"Tracked Add LFS menu and original artwork")
        model.selectionMark="new.txt"; model.highlighted=["new.txt"]; coordinator.menuNeedsUpdate(table.menu!)
        try require(lock.isHidden && unlock.isHidden,"Unversioned marked row hides LFS")
        model.highlighted=["tracked.txt"]; model.selectionMark="tracked.txt"
        let snapshot=model.entries, tracked=model.entries.filter{$0.path=="tracked.txt"}
        model.entries.removeAll{$0.path=="tracked.txt"}
        try require(model.lfsActions(tracked,marked:"tracked.txt").isEmpty,"Stale LFS row rejected")
        model.entries=snapshot
        let oid=try await repository.run(["rev-parse","HEAD:other.txt"]).text.trimmingCharacters(in:.newlines)
        let stages="0 " + String(repeating:"0",count:40) + "\tother.txt\n" + (1...3).map { "100644 \(oid) \($0)\tother.txt\n" }.joined()
        _ = try await repository.run(["update-index","--index-info"],input:Data(stages.utf8))
        let conflicted=try await repository.addDialogSelection(paths:["tracked.txt","other.txt"],includeIgnored:false)
        model.entries=conflicted.entries
        try require(!model.lfsActions(conflicted.entries,marked:"tracked.txt").isEmpty && model.lfsActions(conflicted.entries,marked:"other.txt").isEmpty,"Source LFS conflict eligibility follows marked row, not other selected rows")
        try index.write(to:root.appendingPathComponent(".git/index"),options:.atomic); model.entries=snapshot
        try FileManager.default.removeItem(at:root.appendingPathComponent("tracked.txt"))
        try FileManager.default.createDirectory(at:root.appendingPathComponent("tracked.txt"),withIntermediateDirectories:true)
        try require(model.lfsActions(tracked,marked:"tracked.txt").isEmpty,"Filesystem directory replacement rejected before LFS")
        try FileManager.default.removeItem(at:root.appendingPathComponent("tracked.txt")); try Data("changed\n".utf8).write(to:root.appendingPathComponent("tracked.txt"))
        let beforeColumns=model.fileColumns; model.busy=true; model.setColumn(.lastModified,visible:true); coordinator.refresh(); coordinator.menuNeedsUpdate(table.headerView!.menu!)
        try require(model.fileColumns == beforeColumns && !table.allowsColumnReordering && !table.headerView!.menu!.item(withTitle:"Reset columns")!.isEnabled,"Busy column guards")
        model.busy=false; try require(model.beginColumnReset(),"Column reset starts")
        model.finishColumnReset(accepted:false); try require(model.fileColumns==beforeColumns,"Declined reset preserves layout")
        try require(model.beginColumnReset(),"Second column reset starts"); model.finishColumnReset(accepted:true); coordinator.refresh()
        try require(model.fileColumns==AddWindowModel.defaultColumns && table.tableColumns.map(\.identifier.rawValue)==["check","path","ext","date","size"],"Accepted reset restores original native layout")
        let owner=AddWindowController(repository:repository,access:nil,defaults:defaults), value=owner.model
        owners.append(owner); owner.window?.alphaValue=0; value.setScope(["tracked.txt","other.txt","new.txt"]); owner.window?.orderFront(nil); value.reload()
        try await wait { !value.busy && value.canReceiveFileDrop }
        var pulls=0, refreshes=0, requests:[([String],Bool)]=[]
        owner.onPullAfterLFSLock={ pulls += 1 }; value.onLFSChanged={ refreshes += 1 }
        owner.makeLFSOperation={ repo,access in
            let progress=LFSFileOperationController(repository:repo,access:access)
            progress.model.lockChange={ paths,_,report in
                requests.append((paths,true)); let files=paths.map { LFSFileResult(path:$0,success:true,output:"Locked") }; files.forEach(report); return LFSBatchResult(files:files)
            }
            progress.model.change={ paths,force,_,report in
                requests.append((paths,force)); let files=paths.map { LFSFileResult(path:$0,success:force,output:force ? "Unlocked" : "owned by another user") }; files.forEach(report); return LFSBatchResult(files:files)
            }
            return progress
        }
        value.checked.remove("other.txt")
        let selected=value.entries.filter { $0.path=="tracked.txt" || $0.path=="other.txt" }
        value.setLFSLocked(selected,marked:"tracked.txt",locked:true); value.highlighted=["new.txt"]
        try require(value.busy && value.lockingFiles && !owner.windowShouldClose(owner.window!),"LFS parent ownership before queued operation")
        try await wait { owner.lfsOperation?.model.showingProgress == true && owner.lfsOperation?.model.busy == false }
        try require(requests.count==1 && Set(requests[0].0)==["tracked.txt","other.txt"] && pulls==1 && refreshes==0 && value.busy,"Captured LFS paths, successful Pull, retained results review")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"LFS review blocks Quit")
        owner.lfsOperation?.model.finishProgress(); try await wait { !value.busy && owner.lfsOperation==nil }
        try require(refreshes==1 && !value.checked.contains("other.txt"),"Review refresh preserves unchecked rows")
        value.setLFSLocked(value.entries.filter{$0.path=="tracked.txt"},marked:"tracked.txt",locked:false)
        try await wait { owner.lfsOperation?.model.showingProgress==true && owner.lfsOperation?.model.busy==false }
        try require(owner.lfsOperation?.model.results.first?.success==false && pulls==1,"Failed unlock retains result and omits Pull")
        await owner.lfsOperation?.model.unlock(forceRetry:true)
        try require(requests.count==3 && requests.last!.1 && owner.lfsOperation?.model.results.allSatisfy(\.success)==true,"Force retry uses captured selection")
        owner.lfsOperation?.model.finishProgress(); try await wait { !value.busy && owner.lfsOperation==nil }
        try require(refreshes==2,"Exactly one Add refresh per completed review")
        let liveCoordinator=AddFileTable.Coordinator(model:value); _=liveCoordinator.make()
        value.setColumn(.fileSize,visible:true); value.setColumn(.lastModified,visible:true)
        owner.window?.setContentSize(NSSize(width:1000,height:480))
        try await capture(owner)
        value.onResetColumns()
        try await wait { value.resettingColumns && owner.window?.attachedSheet != nil }
        let oldColumns=value.fileColumns
        owner.close(); try require(value.retired && value.fileColumns==oldColumns && owner.window?.attachedSheet==nil,"Forced close tears down reset without acceptance")
        let held=AddWindowController(repository:repository,access:nil,defaults:defaults); owners.append(held); held.model.setScope(["tracked.txt"]); held.window?.alphaValue=0; held.window?.orderFront(nil); held.model.reload()
        try await wait { held.model.canReceiveFileDrop }
        var started=false, settled=false, heldToken:OperationCancellation?, lateReport:(@Sendable (LFSFileResult)->Void)?
        held.makeLFSOperation={ repo,access in
            let progress=LFSFileOperationController(repository:repo,access:access)
            progress.model.lockChange={ paths,token,report in
                started=true; heldToken=token; lateReport=report
                while !token.isCancelled { try? await Task.sleep(nanoseconds:10_000_000) }
                try? await Task.sleep(nanoseconds:100_000_000); settled=true
                return LFSBatchResult(files:[],cancelled:true)
            }; return progress
        }
        held.model.setLFSLocked(held.model.entries,marked:"tracked.txt",locked:true)
        try await wait { started }
        let progress=held.lfsOperation!
        held.close(); try require(heldToken?.isCancelled==true && LFSLocksWindowModel.activeOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired Add LFS work retains cancellation/Quit ownership")
        lateReport?(LFSFileResult(path:"late",success:true,output:"late"))
        try await wait { settled && LFSLocksWindowModel.activeOperations==0 && AddWindowModel.activeOperations==0 }
        try require(progress.model.retired && progress.model.results.isEmpty && held.lfsOperation==nil && pulls==1,"Late retired callbacks do not reopen or publish")
        let finalHead = try await repository.run(["rev-parse","HEAD"]).stdout
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index && finalHead==head,"Add LFS/columns preserve Git index/HEAD")
    }
}
