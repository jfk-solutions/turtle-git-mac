// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct SyncFileListVerification {
    struct Failure:Error,LocalizedError,CustomStringConvertible {let description:String;var errorDescription:String?{description}}
    @MainActor static var owners:[NSWindowController]=[]
    static func require(_ condition:Bool,_ message:String)throws {if !condition{throw Failure(description:message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    @MainActor static func wait(_ window:NSWindow?=nil,line:Int = #line,_ condition:()->Bool)async throws {
        for _ in 0..<1200 {window?.contentView?.layoutSubtreeIfNeeded();if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Sync file-list timeout at \(line)")
    }
    @MainActor static func own(_ controller:NSWindowController){owners.append(controller);if let window=controller.window{window.alphaValue=0;window.setFrameOrigin(.init(x:-24000,y:-24000));window.orderFront(nil)}}
    static func fixture(_ root:URL,_ git:URL)async throws->(GitRepository,String,String) {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Sync List QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_ = try await repo.run(["config",key,value])}
        for (path,text) in [("rename old.txt","rename unchanged\n"),("kind.txt","ordinary file\n"),("change.txt","base\n")] {try Data(text.utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage(["rename old.txt","kind.txt","change.txt"]);_ = try await repo.commit(message:"base list")
        let base=String(decoding:try await repo.run(["rev-parse","HEAD"]).stdout,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        let remote=root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-origin.git")
        _ = try await repo.run(["clone","--bare","--template=","--",root.path,remote.path])
        _ = try await repo.run(["remote","add","origin",remote.path]);_ = try await repo.run(["fetch","origin"])
        _ = try await repo.run(["branch","--set-upstream-to=origin/main","main"])
        try FileManager.default.moveItem(at:root.appendingPathComponent("rename old.txt"),to:root.appendingPathComponent("renamed 雪.txt"))
        try FileManager.default.removeItem(at:root.appendingPathComponent("kind.txt"));try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("kind.txt").path,withDestinationPath:"change.txt")
        for (path,text) in [("change.txt","changed\nsecond\n"),("literal\tline\nname.swift","literal source\n"),("-leading.txt","added\n")] {try Data(text.utf8).write(to:root.appendingPathComponent(path))}
        _ = try await repo.run(["add","-A","--"])
        _ = try await repo.run(["update-index","--add","--cacheinfo","160000",base,"private module"])
        let blob=String(decoding:try await repo.run(["rev-parse",base+":change.txt"]).stdout,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        // These historical names coexist in Git even on a normalizing macOS FS.
        let canonical=["caf\u{e9}.txt","cafe\u{301}.txt"]
        _ = try await repo.run(["update-index","-z","--index-info"],input:Data(canonical.map{"100644 \(blob)\t\($0)\0"}.joined().utf8))
        _ = try await repo.commit(message:"outgoing list changes")
        let head=String(decoding:try await repo.run(["rev-parse","HEAD"]).stdout,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        let tree=try await repo.run(["ls-tree","-rz","--name-only",head]).stdout
        let rawNames=tree.split(separator:0).map{Array($0)}
        try require(canonical.allSatisfy{rawNames.contains(Array($0.utf8))},"Raw historical fixture tree did not retain both UTF8 path spellings: "+rawNames.map{String(describing:$0)}.joined(separator:","))
        return(repo,base,head)
    }
    @MainActor static func prepared(_ repo:GitRepository,_ old:String,_ new:String,_ prefs:UserDefaults)async throws->SynchronizationWindowController {
        let owner=SynchronizationWindowController(repository:repo,access:nil,preferences:prefs);own(owner)
        let model=owner.model;model.sshSettings.enabled=false
        try await wait(owner.window){!model.busy && model.outgoing != nil && !model.hasPendingInlineWork}
        let incoming=try await repo.synchronizationIncoming(from:new,to:old)
        model.incomingComparison.snapshot=incoming.comparison
        try require(model.comparison.snapshot?.files.contains{$0.oldPath=="rename old.txt" && $0.path=="renamed 雪.txt"}==true,"Actual outgoing snapshot lost rename provenance")
        try require(model.comparison.snapshot?.files.contains{$0.path=="private module" && $0.isSubmodule}==true,"Actual outgoing snapshot lost gitlink")
        return owner
    }
    @MainActor static func key(_ window:NSWindow,_ text:String,_ code:UInt16,_ flags:NSEvent.ModifierFlags=[] )throws->NSEvent {
        try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code),"Native list key event")
    }
    @MainActor static func nativeTable(_ owner:SynchronizationWindowController,_ incoming:Bool)async throws->SynchronizationFileNativeTable {
        let id="TurtleGit.Sync.Files."+(incoming ? "In":"Out")
        try await wait(owner.window){views(owner.window?.contentView).compactMap{$0 as? SynchronizationFileNativeTable}.contains{$0.identifier?.rawValue==id}}
        let table=try unwrap(views(owner.window?.contentView).compactMap{$0 as? SynchronizationFileNativeTable}.first{$0.identifier?.rawValue==id},"Native Sync list missing: "+id)
        // A prohibited receiver cannot own a physical key window. Substitute
        // only the exact owner query; actual native first responder is required.
        table.keyOwnerQuery={ [weak window=owner.window] candidate in candidate === window }
        try require(owner.window?.makeFirstResponder(table)==true,"Native list did not take responder ownership")
        return table
    }
    @MainActor static func invoke(_ menu:NSMenu,_ id:String)throws {
        func find(_ menu:NSMenu)->NSMenuItem? {
            for item in menu.items {if item.identifier?.rawValue==id{return item};if let submenu=item.submenu,let found=find(submenu){return found}}
            return nil
        }
        let item=try unwrap(find(menu),"Native list action missing: "+id)
        try require(item.isEnabled,"Native list action unexpectedly disabled: "+id)
        if let action=item.action {_ = NSApp.sendAction(action,to:item.target,from:item)} else {throw Failure(description:"Native list action has no selector")}
    }
    @MainActor static func lists(_ repo:GitRepository,_ old:String,_ new:String,_ prefs:UserDefaults)async throws {
        let owner=try await prepared(repo,old,new,prefs),model=owner.model
        let initialHead=try await repo.run(["rev-parse","HEAD"]).stdout,initialIndex=try await repo.run(["write-tree"]).stdout
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        let literal="literal\tline\nname.swift"
        for incoming in [false,true] {
            model.tab=incoming ? 5:1
            let state=incoming ? model.incomingFileList:model.outgoingFileList
            state.clipboard=board
            let table=try await nativeTable(owner,incoming)
            try await wait(owner.window){table.numberOfRows==state.rows.count && table.numberOfRows>=6}
            try require(table.tableColumns.map{$0.identifier.rawValue}==["Path","Extension","Status","Lines added","Lines removed"],"Source default Sync columns/order")
            try require(table.allowsMultipleSelection && table.headerView != nil,"Native selection/header missing")
            let row=try unwrap(state.rows.firstIndex{$0.path==literal},"Literal Git row missing")
            table.scrollRowToVisible(row);table.layoutSubtreeIfNeeded()
            let pathColumn=try unwrap(table.tableColumns.firstIndex{$0.identifier.rawValue=="Path"},"Rendered Path column missing")
            let rendered=try unwrap(table.view(atColumn:pathColumn,row:row,makeIfNecessary:true) as? NSTableCellView,"Actual literal Path cell missing")
            rendered.layoutSubtreeIfNeeded()
            let label=try unwrap(rendered.textField,"Actual literal Path label missing")
            let labelRect=label.convert(label.bounds,to:rendered)
            let cellGeometryValid=labelRect.height<=table.rowHeight+0.5 && label.fittingSize.height<=table.rowHeight+0.5 && rendered.bounds.insetBy(dx:-1,dy:-1).contains(labelRect)
            let geometryDiagnostic="labelRect=\(labelRect) cellBounds=\(rendered.bounds) fitting=\(label.fittingSize) rowHeight=\(table.rowHeight) font=\(String(describing:label.font)) fontHeight=\((label.font?.ascender ?? 0)-(label.font?.descender ?? 0)+(label.font?.leading ?? 0)) maxLines=\(label.maximumNumberOfLines) singleLine=\(label.cell?.usesSingleLineMode ?? false) wraps=\(label.cell?.wraps ?? false) scrollable=\(label.cell?.isScrollable ?? false)"
            if !cellGeometryValid {print("Literal cell geometry: "+geometryDiagnostic);try await capture(try unwrap(owner.window,"Cell failure capture owner"),incoming ? "sync-incoming-cell-failure":"sync-outgoing-cell-failure")}
            try require(cellGeometryValid,"Literal filename rendered multiple lines or escaped native row: "+geometryDiagnostic)
            try require(label.toolTip?.utf8.elementsEqual(literal.utf8)==true,"Single-line display lost full literal-path tooltip")
            table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
            try await wait(owner.window){state.selection.contains(literal)}
            let coordinator=try unwrap(table.dataSource as? SynchronizationFiles.Coordinator,"Actual Sync list coordinator missing")
            try invoke(coordinator.rowMenu(row:row,column:1),"Sync.Files.copy.column")
            try require(board.string(forType:.string)==".swift\n","Clicked Extension clipboard changed source value")
            let oneUse=coordinator.rowMenu(row:row,column:0)
            try invoke(oneUse,"Sync.Files.copy.relativePaths")
            try require(board.string(forType:.string)==literal+"\n","Relative clipboard split/normalized literal Git filename")
            board.clearContents();board.setString("private consumed receipt",forType:.string)
            try invoke(oneUse,"Sync.Files.copy.relativePaths")
            try require(board.string(forType:.string)=="private consumed receipt","Native copy menu receipt reused")
            try invoke(coordinator.rowMenu(row:row,column:0),"Sync.Files.copy.fullPaths")
            try require(board.string(forType:.string)==repo.root.appendingPathComponent(literal).path+"\n","Full path clipboard changed literal selection")
            try invoke(coordinator.rowMenu(row:row,column:0),"Sync.Files.copy.names")
            try require(board.string(forType:.string)==literal+"\n","Filename clipboard changed literal leaf")
            try invoke(coordinator.rowMenu(row:row,column:0),"Sync.Files.copy.all")
            let all=board.string(forType:.string) ?? ""
            try require(all.hasPrefix("Path\tExtension\tStatus\tLines added\tLines removed\n") && all.contains(literal+"\t.swift\t"),"Copy all omitted source columns or literal path")
            var compared:[String]=[],alternates:[Bool]=[]
            let child=incoming ? model.incomingComparison:model.comparison
            child.openComparedFile={snapshot,file in
                if snapshot.from.label == (incoming ? new:old) && snapshot.to.label == (incoming ? old:new){compared.append(file.path);alternates.append(ComparisonToolInvocation.capture)}
            }
            table.keyDown(with:try key(try unwrap(owner.window,"List owner missing"),"\r",36))
            try await wait(owner.window){compared.count==1 && RevisionComparisonWindowModel.activeFileOperations==0}
            try require(compared==[literal],"Actual native Return compared wrong snapshot/path")
            let canonical=["caf\u{e9}.txt","cafe\u{301}.txt"]
            try require(canonical.allSatisfy{wanted in state.rows.contains{GitReferenceName.equal($0.path,wanted)}},"Canonical-equivalent historical rows collapsed; snapshot UTF8="+state.rows.map{String(describing:Array($0.path.utf8))}.joined(separator:","))
            let canonicalRows=canonical.compactMap{wanted in state.rows.firstIndex{GitReferenceName.equal($0.path,wanted)}}
            try require(canonicalRows.count==2 && canonicalRows[0] != canonicalRows[1],"Canonical-equivalent paths share native row")
            table.selectRowIndexes(IndexSet(canonicalRows),byExtendingSelection:false)
            try await wait(owner.window){state.selection.count==2}
            compared=[]
            table.keyDown(with:try key(try unwrap(owner.window,"Canonical list owner"),"\r",36))
            try await wait(owner.window){compared.count==2 && RevisionComparisonWindowModel.activeFileOperations==0}
            let displayedCanonical=state.rows.filter{file in canonical.contains{GitReferenceName.equal($0,file.path)}}.map(\.path)
            try require(compared.map{Array($0.utf8)}==displayedCanonical.map{Array($0.utf8)},"Explicit native order collapsed/reordered canonical Git rows")
            table.selectRowIndexes(IndexSet(integer:canonicalRows[1]),byExtendingSelection:false)
            try await wait(owner.window){state.selection.count==1}
            compared=[]
            table.keyDown(with:try key(try unwrap(owner.window,"Single canonical owner"),"\r",36))
            try await wait(owner.window){compared.count==1 && RevisionComparisonWindowModel.activeFileOperations==0}
            try require(compared[0].utf8.elementsEqual(canonical[1].utf8),"Selecting one canonical row dispatched its peer")
            // Shared consumer default-nil API must retain its existing order.
            compared=[]
            child.compare(GitPathSet([literal,"change.txt"]))
            try await wait(owner.window){compared.count==2 && RevisionComparisonWindowModel.activeFileOperations==0}
            let defaultOrder=child.visibleFiles.filter{[literal,"change.txt"].contains($0.path)}.map(\.path)
            try require(compared==defaultOrder,"Default-nil shared comparison order changed")
            table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
            try await wait(owner.window){state.selection.contains(literal) && state.selection.count==1}
            compared=[];alternates=[]
            table.keyDown(with:try key(try unwrap(owner.window,"Shift list owner"),"\r",36,.shift))
            try await wait(owner.window){compared.count==1 && RevisionComparisonWindowModel.activeFileOperations==0}
            try require(compared==[literal] && alternates==[true],"Native Shift Return lost alternate route")
            let clicked=try unwrap(state.rows.firstIndex{$0.path=="change.txt"},"Doubleclick source row missing")
            table.clickedRowQuery={ [weak table] candidate in candidate === table ? clicked:-1 }
            compared=[];alternates=[]
            try ComparisonToolInvocation.$alternate.withValue(false) {
                let action=try unwrap(table.doubleAction,"Actual native double action missing")
                _ = NSApp.sendAction(action,to:table.target,from:table)
            }
            try await wait(owner.window){compared.count==1 && RevisionComparisonWindowModel.activeFileOperations==0}
            try require(compared==["change.txt"] && alternates==[false],"Native doubleclick used selected row instead of actual clicked row")
            table.clickedRowQuery={$0.clickedRow}
            table.sortDescriptors=[NSSortDescriptor(key:"Path",ascending:false)]
            try await wait(owner.window){state.sortColumn == .path && !state.ascending}
            let descending=state.rows.map(\.path)
            let sortedRows=state.rows.indices.filter{state.rows[$0].path==literal || state.rows[$0].path=="change.txt"}
            table.selectRowIndexes(IndexSet(sortedRows),byExtendingSelection:false)
            try await wait(owner.window){state.selection.count==2 && state.selection.contains(literal) && state.selection.contains("change.txt")}
            let selectedDescending=state.rows.filter{$0.path==literal || $0.path=="change.txt"}.map(\.path)
            try require(selectedDescending != defaultOrder,"Sorted dispatch fixture did not differ from shared default order")
            compared=[];alternates=[]
            table.keyDown(with:try key(try unwrap(owner.window,"Sorted multi-file owner"),"\r",36))
            try await wait(owner.window){compared.count==2 && RevisionComparisonWindowModel.activeFileOperations==0}
            try require(compared==selectedDescending,"Sorted multi-file Return ignored captured displayed order")
            table.sortDescriptors=[NSSortDescriptor(key:"Path",ascending:true)]
            try await wait(owner.window){state.sortColumn == .path && state.ascending}
            try require(descending.map{Array($0.utf8)}==state.rows.reversed().map{Array($0.path.utf8)},"Native header sort did not reverse exact row order")
            // The source reset question is owned and waits for real dismissal.
            try invoke(coordinator.headerMenu(),"Sync.Files.column.Lines added")
            var resetAlert:NSAlert?
            state.presentResetQuestion={parent,alert,completion in
                resetAlert=alert;alert.window.alphaValue=0
                alert.beginSheetModal(for:parent,completionHandler:completion)
            }
            try invoke(coordinator.headerMenu(),"Sync.Files.columns.reset")
            try await wait(owner.window){resetAlert?.window.sheetParent != nil}
            resetAlert?.buttons[1].performClick(nil)
            try await wait(owner.window){!state.hasPendingQuestion && owner.window?.attachedSheet==nil}
            try require(!state.columns.visible.contains(.added),"Actual No reset discarded column draft")
            resetAlert=nil
            try invoke(coordinator.headerMenu(),"Sync.Files.columns.reset")
            try await wait(owner.window){resetAlert?.window.sheetParent != nil}
            resetAlert?.buttons[0].performClick(nil)
            try await wait(owner.window){!state.hasPendingQuestion && owner.window?.attachedSheet==nil}
            try require(state.columns.visible.contains(.removed),"Actual Yes reset did not restore source columns")
            // Source columns/layout are independent for incoming and outgoing.
            try invoke(coordinator.headerMenu(),"Sync.Files.column.Lines removed")
            try await wait(owner.window){table.tableColumns.first{$0.identifier.rawValue=="Lines removed"}?.isHidden==true}
            if !incoming {try require(model.incomingFileList.columns.visible.contains(.removed),"Sync list layout leaked to opposite direction")}
            state.saveLayout(order:[.status,.path,.fileExtension,.added,.removed],widths:[.path:377])
            try require(state.columns.order.first == .status && state.columns.widths[.path]==377,"Native list layout was not captured")
            try await capture(try unwrap(owner.window,"List capture owner"),incoming ? "sync-incoming-files":"sync-outgoing-files")
        }
        owner.window?.close()
        let reopened=try await prepared(repo,old,new,prefs)
        try require(reopened.model.outgoingFileList.columns.widths[.path]==377 && reopened.model.incomingFileList.columns.widths[.path]==377,"Sync column layout did not persist across actual owner reopen")
        try require(!reopened.model.outgoingFileList.columns.visible.contains(.removed) && !reopened.model.incomingFileList.columns.visible.contains(.removed),"Sync hidden column did not persist")
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout,finalIndex=try await repo.run(["write-tree"]).stdout
        try require(finalHead==initialHead && finalIndex==initialIndex,"Read-only list actions changed HEAD/index")
    }
    @MainActor static func ownership(_ repo:GitRepository,_ old:String,_ new:String,_ prefs:UserDefaults)async throws {
        let owner=try await prepared(repo,old,new,prefs),model=owner.model
        model.tab=1
        let state=model.outgoingFileList,board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};state.clipboard=board
        let table=try await nativeTable(owner,false)
        try await wait(owner.window){!state.rows.isEmpty}
        let path="change.txt"
        state.selection=GitPathSet([path])
        func unchanged(_ receipt:SynchronizationFileListState.Receipt,_ message:String)throws {
            board.clearContents();board.setString("private unchanged",forType:.string)
            state.copy(receipt,information:.relativePaths)
            try require(board.string(forType:.string)=="private unchanged",message)
        }
        let coordinator=try unwrap(table.dataSource as? SynchronizationFiles.Coordinator,"Owned list coordinator")
        let oldHeader=coordinator.headerMenu(),visible=state.columns.visible
        let wrongTab=try unwrap(state.capture(GitPathSet([path])),"Initial list receipt")
        model.tab=5;try unchanged(wrongTab,"Wrong-tab receipt reached clipboard")
        model.tab=1
        try invoke(oldHeader,"Sync.Files.column.Lines removed")
        try require(state.columns.visible==visible,"Retained header menu changed returned tab layout")
        let wrongSelection=try unwrap(state.capture(GitPathSet([path])),"Selection receipt")
        state.selection=GitPathSet(["-leading.txt"]);try unchanged(wrongSelection,"Stale selection receipt reached clipboard")
        state.selection=GitPathSet([path])
        let busy=try unwrap(state.capture(GitPathSet([path])),"Busy receipt")
        model.reload()
        try require(model.busy,"Actual Sync refresh did not establish read ownership")
        try unchanged(busy,"Busy projection accepted list action")
        try await wait(owner.window){!model.busy && !model.hasPendingInlineWork && model.comparison.snapshot != nil}
        model.tab=1;state.selection=GitPathSet([path])
        let quit=try unwrap(state.capture(GitPathSet([path])),"Quit receipt")
        model.confirmingQuit=true;try unchanged(quit,"Quit-owned list action accepted")
        model.confirmingQuit=false
        let prior=try unwrap(state.capture(GitPathSet([path])),"Snapshot receipt")
        model.comparison.snapshot=try await repo.synchronizationIncoming(from:new,to:old).comparison
        try unchanged(prior,"Replaced snapshot receipt accepted")
        model.comparison.snapshot=try await repo.synchronizationIncoming(from:old,to:new).comparison
        state.selection=GitPathSet([path])
        let sheetReceipt=try unwrap(state.capture(GitPathSet([path])),"Sheet receipt")
        let sheet=NSWindow(contentRect:.init(x:0,y:0,width:180,height:90),styleMask:[.titled],backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
        owner.window?.beginSheet(sheet,completionHandler:nil);try unchanged(sheetReceipt,"Owned sheet admitted list action")
        owner.window?.endSheet(sheet,returnCode:.cancel);sheet.close();try await wait{sheet.sheetParent==nil}
        var resetReply:((NSApplication.ModalResponse)->Void)?
        state.presentResetQuestion={parent,alert,completion in
            alert.window.alphaValue=0;resetReply=completion
        }
        state.setColumn(.removed,visible:false)
        let last=try unwrap(state.capture(GitPathSet([path])),"Close receipt")
        state.resetColumns()
        try await wait(owner.window){resetReply != nil}
        let columnsBeforeClose=state.columns
        owner.window?.close()
        resetReply?(.alertFirstButtonReturn);resetReply=nil
        try await wait{!model.hasPendingInlineWork}
        try require(state.columns==columnsBeforeClose,"Late reset confirmation changed retired owner layout")
        try unchanged(last,"Closed owner retained executable list receipt")
        table.keyDown(with:try key(try unwrap(owner.window,"Closed list owner"),"\r",36))
        try require(RevisionComparisonWindowModel.activeFileOperations==0,"Closed native list started comparison")
    }
    @MainActor static func capture(_ window:NSWindow,_ name:String)async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_FILE_CAPTURES"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned compositor capture unavailable")}
        let alpha=window.alphaValue,appearance=window.appearance
        defer{window.alphaValue=alpha;window.appearance=appearance}
        window.alphaValue=1;window.orderFront(nil)
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:150_000_000)
            let content=try await SCShareableContent.currentProcess,owned=try unwrap(content.windows.first{$0.windowID==CGWindowID(window.windowNumber)},"Owned capture window missing")
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            let bytes=try unwrap(NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]),"Capture encoding")
            let filename=name+"-"+suffix+".png";try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent(filename));print("Owned capture: \(filename) \(pixels.width)x\(pixels.height)")
        }
    }
    @MainActor static func cleanup()async->Bool {
        for owner in owners.reversed(){if let window=owner.window{if let child=window.attachedSheet{window.endSheet(child,returnCode:.abort);child.close()};window.close()}}
        for window in NSApp.windows{window.orderOut(nil);window.close()}
        for _ in 0..<1200 {if SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowModel.activePushWorkflows==0 && RevisionComparisonWindowModel.activeFileOperations==0 && FileListComparisonSession.activeOperations==0{return true};try? await Task.sleep(nanoseconds:10_000_000)}
        return false
    }
    @MainActor static func main()async {
        NSApp.setActivationPolicy(.prohibited);var failure:Error?
        do {
            let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
            for name in CommandLine.arguments.dropFirst(3) {
                let (repo,old,new)=try await fixture(base.appendingPathComponent(name),git)
                let suite="TurtleGit.SyncFileList."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
                defer{prefs.removePersistentDomain(forName:suite)}
                prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"TGitAutoLoadSSHKey")
                switch name {case "lists":try await lists(repo,old,new,prefs);case "ownership":try await ownership(repo,old,new,prefs);default:throw Failure(description:"Unknown Sync file-list case")}
                print("PASS Sync file-list case: "+name)
            }
        } catch{failure=error}
        if !(await cleanup()),failure==nil{failure=Failure(description:"Owned Sync list workers did not drain")}
        if let failure{fputs("Sync file lists failed: \(failure)\n",stderr);exit(1)}
        print("PASS Sync file lists: "+CommandLine.arguments.dropFirst(3).joined(separator:", ")+"; all owned windows/workers closed")
    }
}
