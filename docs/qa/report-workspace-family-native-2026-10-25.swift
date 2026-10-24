// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func reportFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect {rect}
    @objc func reportOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));reportOrder(mode,relativeTo:number)}
}
@MainActor @main enum ReportWorkspaceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws {if !condition {throw Failure(description:"Report \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else {throw Failure(description:message)};return value}
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func wait(_ window:NSWindow?=nil,line:Int = #line,_ condition:()->Bool)async throws {
        for _ in 0..<3000 {window?.contentView?.layoutSubtreeIfNeeded();if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Report timeout \(line)")
    }
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.Report."+UUID().uuidString,prefs:UserDefaults
        var root:URL {base.appendingPathComponent("repository")}
        var repo:GitRepository!,owners:[NSWindowController]=[],head="",index=Data(),config=Data()
        let paths=["alpha.txt","beta.txt","zeta.txt"]
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"Autocompletion");prefs.set(true,forKey:"ShowListBackgroundImage");prefs.set(false,forKey:"FullRowSelect");prefs.set(1,forKey:"HintStagingMode");prefs.set(1,forKey:"CommitMergeHint")}
        func prepare()async throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Report QA"),("user.email","report@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            for path in paths {try Data("base\n".utf8).write(to:root.appendingPathComponent(path))}
            try await repo.stage(["."]);_=try await repo.commit(message:"Report base")
            for path in paths {try Data("historical\n".utf8).write(to:root.appendingPathComponent(path))}
            try await repo.stage(["."]);_=try await repo.commit(message:"Report changed")
            head=try await repo.rebaseCommit("HEAD").hash
            for path in paths {try Data("working\n".utf8).write(to:root.appendingPathComponent(path))}
            index=try Data(contentsOf:root.appendingPathComponent(".git/index"));config=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        }
        func own<T:NSWindowController>(_ owner:T)->T {owners.append(owner);owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil);return owner}
        func preserved()async throws {
            let current=try await repo.rebaseCommit("HEAD").hash
            try require(current==head,"Report actions changed HEAD")
            try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Report selection changed index")
            try require(try Data(contentsOf:root.appendingPathComponent(".git/config"))==config,"Report styling changed config")
            for path in paths {try require(try Data(contentsOf:root.appendingPathComponent(path))==Data("working\n".utf8),"Report changed working bytes")}
        }
        func clean()async {
            for owner in owners {if let window=owner.window,let child=window.attachedSheet {window.endSheet(child,returnCode:.abort);child.close()};owner.close()};owners=[]
            for _ in 0..<3000 {if ReportWorkspaceVerification.drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            FileListDrag.discardAll();prefs.removePersistentDomain(forName:suite)
        }
    }
    static func drained()->Bool {CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileOperations==0 && StatusWindowModel.activeOperations==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0 && LogWindowModel.activeFileOpenReads==0 && LogWindowModel.activeWorkingCommandReads==0 && LogWindowModel.activeReferenceReads==0 && FileListDrag.activeLoads==0}
    static func probe(_ owner:NSWindowController)async throws->CommitFileInteraction.Probe {
        try await wait(owner.window){views(owner.window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}.contains{$0.nativeTable != nil && $0.rows.compactMap(\.entry).count==3}}
        return try unwrap(views(owner.window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}.first{$0.nativeTable != nil && $0.rows.compactMap(\.entry).count==3},"Actual report adapter absent")
    }
    static func check(_ adapter:CommitFileInteraction.Probe,_ owner:NSWindowController,expected:[String])async throws->NSTableView {
        try await wait(owner.window){adapter.rows.compactMap{$0.entry?.path}==expected && adapter.nativeTable?.style == .fullWidth && adapter.nativeTable?.usesAlternatingRowBackgroundColors==false}
        let table=try unwrap(adapter.nativeTable,"Actual report table missing")
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            owner.window?.appearance=NSAppearance(named:appearance)
            try await wait(owner.window){table.style == .fullWidth && !table.usesAlternatingRowBackgroundColors}
        }
        try require(table.numberOfRows==3 && table.tableColumns.count>=5,"Report columns/rows disappeared")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try require(table.selectedRowIndexes==IndexSet(integer:0),"Native report highlight failed")
        try require(table.rect(ofRow:0).width >= table.bounds.width-2,"Report row is not full width")
        return table
    }
    static func detach(_ adapter:CommitFileInteraction.Probe,table:NSTableView)throws {
        let selected=table.selectedRowIndexes,beforeRows=table.numberOfRows
        let beforeDelegate=table.delegate.map{String(describing:type(of:$0))} ?? "nil"
        adapter.stopObserving()
        print("Report detach: rows \(beforeRows)->\(table.numberOfRows); selection \(Array(selected))->\(Array(table.selectedRowIndexes)); delegate \(beforeDelegate)->\(table.delegate.map{String(describing:type(of:$0))} ?? "nil"); style \(table.style.rawValue); alternating \(table.usesAlternatingRowBackgroundColors)");fflush(stdout)
        try require(table.style == .fullWidth && !table.usesAlternatingRowBackgroundColors,"Detaching interactions changed the framework-owned bordered report appearance")
        // Dismantling restores the framework delegate and retires interactions;
        // its discarded native highlight is no longer the live model selection.
        try require(adapter.workingDragSelection()==nil && adapter.watermark==nil,"Detached report adapter retained file interactions or artwork")
    }
    static func commit(_ c:Context)async throws {
        let owner=c.own(CommitWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),defaults:c.prefs)),model=owner.model
        print("Report commit: loading actual owner");fflush(stdout)
        model.confirmCancel={$0(true)};model.reload()
        try await wait(owner.window){!model.busy && model.fileListAvailable && model.entries.count==3}
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        print("Report commit: sorting displayed rows");fflush(stdout)
        model.setFileSortOrder([CommitFileSort(column:.path,order:.reverse)])
        let adapter=try await probe(owner),table=try await check(adapter,owner,expected:Array(c.paths.reversed()))
        print("Report commit: independent checkbox/highlight");fflush(stdout)
        model.checked=GitPathSet(["beta.txt"])
        table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)
        try await wait(owner.window){model.selection==GitPathSet(["zeta.txt","alpha.txt"])}
        try require(model.checked==GitPathSet(["beta.txt"]),"Report highlighting changed checked commit membership")
        try await wait(owner.window){views(table).compactMap{$0 as? NSButton}.contains{$0.accessibilityLabel()=="Include beta.txt" && $0.isEnabled && $0.state == .on}}
        let checkbox=try unwrap(views(table).compactMap{$0 as? NSButton}.first{$0.accessibilityLabel()=="Include beta.txt"},"Actual beta checkbox missing")
        try require(NSApp.sendAction(checkbox.action!,to:checkbox.target,from:checkbox),"Actual native checkbox action refused")
        try await wait(owner.window){model.checked.isEmpty}
        try require(table.selectedRowIndexes==IndexSet([0,2]) && model.selection==GitPathSet(["zeta.txt","alpha.txt"]),"Checking an unhighlighted row changed native highlighted files")
        let drag=try unwrap(adapter.workingDragSelection(),"Report adapter lost outbound selected files")
        try require(drag.paths==["zeta.txt","alpha.txt"] && drag.fileURLs.count==2,"Sorted native selection was not used by drag")
        print("Report commit: detach and replacement");fflush(stdout)
        try detach(adapter,table:table)
        let replacement=c.own(CommitWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),defaults:c.prefs));replacement.model.confirmCancel={$0(true)};replacement.model.reload()
        try await wait(replacement.window){!replacement.model.busy && replacement.model.fileListAvailable}
        let next=try await probe(replacement)
        try await wait(replacement.window){next.nativeTable?.style == .fullWidth && next.nativeTable?.usesAlternatingRowBackgroundColors==false}
        try require(table.style == .fullWidth && !table.usesAlternatingRowBackgroundColors,"Replacement adapter changed retired table appearance")
    }
    static func status(_ c:Context)async throws {
        let owner=c.own(StatusWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),defaults:c.prefs)),model=owner.model
        model.reload();try await wait(owner.window){!model.busy && model.files.count==3}
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        model.setSortOrder([StatusFileSort(column:.path,order:.reverse)])
        let adapter=try await probe(owner),table=try await check(adapter,owner,expected:Array(c.paths.reversed()))
        try await wait(owner.window){adapter.watermark?.image != nil && adapter.watermark?.artworkRect != nil}
        try require(adapter.watermark?.hitTest(.zero)==nil,"Report watermark intercepts input")
        table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)
        try await wait(owner.window){model.selection==GitPathSet(["zeta.txt","alpha.txt"])}
        let drag=try unwrap(adapter.workingDragSelection(),"Report status drag unavailable")
        try require(drag.paths==["zeta.txt","alpha.txt"],"Report status sort/selection lost")
        try detach(adapter,table:table)
    }
    static func log(_ c:Context)async throws {
        let owner=c.own(LogWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),labelDefaults:c.prefs,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false)),model=owner.model
        model.showWorkingTree=false;model.reload()
        try await wait(owner.window){!model.busy && model.entries.contains{$0.hash==c.head}}
        model.select([c.head])
        try await wait(owner.window){!model.busy && model.files.count==3}
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        model.setChangedFileSort([LogChangedFileSort(column:.path,order:.reverse)])
        let adapter=try await probe(owner),table=try await check(adapter,owner,expected:Array(c.paths.reversed()))
        table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)
        try await wait(owner.window){model.selectedFiles==GitPathSet(["zeta.txt","alpha.txt"])}
        let drag=try unwrap(model.captureFileDrag(["zeta.txt","alpha.txt"]),"Historical report drag unavailable")
        try require(drag.paths==["zeta.txt","alpha.txt"] && drag.revision == .revision(c.head),"Report historical drag lost revision/order")
        try detach(adapter,table:table)
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let pairs=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.reportFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.reportOrder(_:relativeTo:))))]
        for(a,b)in pairs {if let a,let b {method_exchangeImplementations(a,b)}}
        defer {for(a,b)in pairs.reversed(){if let a,let b {method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do {
            try await c.prepare()
            switch CommandLine.arguments[3] {case "commit":try await commit(c);case "log":try await log(c);case "status":try await status(c);case "workspace":try await WorkspaceOwnerVerification.workspace(root:c.base,git:c.git);case "retirement":try await WorkspaceOwnerVerification.retirement(root:c.base,git:c.git);default:throw Failure(description:"Unknown report case")}
            try await c.preserved();await c.clean()
            try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Report owners/workers did not drain")
            print("PASS: report workspace "+CommandLine.arguments[3]);fflush(stdout)
        } catch {await c.clean();fputs("Report workspace failed: \(error)\n",stderr);exit(1)}
    }
}
