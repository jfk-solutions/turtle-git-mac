// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func listInteractionFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect {rect}
    @objc func listInteractionOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));listInteractionOrder(mode,relativeTo:number)}
}
@MainActor @main enum NativeListInteractionsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws {if !condition{throw Failure(description:"Native list \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func tick()async {await withCheckedContinuation {continuation in DispatchQueue.main.async {continuation.resume()}}}
    static func wait(_ window:NSWindow?,line:Int = #line,_ condition:()->Bool)async throws {
        for _ in 0..<3000 {window?.contentView?.layoutSubtreeIfNeeded();if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Native list timeout \(line)")
    }
    final class Row:NSTableRowView {let marker=UUID()}
    final class Table:NSTableView {
        var callback="",cellReentries:[String]=[],hierarchyReentries:[String]=[]
        override func view(atColumn column:Int,row:Int,makeIfNecessary:Bool)->NSView? {
            if !callback.isEmpty {cellReentries.append(callback)}
            return super.view(atColumn:column,row:row,makeIfNecessary:makeIfNecessary)
        }
        override func addSubview(_ view:NSView,positioned:NSWindow.OrderingMode,relativeTo:NSView?) {
            if !callback.isEmpty {hierarchyReentries.append(callback)}
            super.addSubview(view,positioned:positioned,relativeTo:relativeTo)
        }
        func callbackScope<T>(_ name:String,_ body:()->T)->T {let old=callback;callback=name;defer{callback=old};return body()}
    }
    final class Original:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        var values=["zeta","beta","alpha"],factories=0,added=0,selections=0,displayed=0
        var onDisplay:(()->Void)?
        var created:[Row]=[]
        var reusable:[Row]=[]
        let background=NSColor(srgbRed:0.31,green:0.18,blue:0.45,alpha:1)
        func numberOfRows(in tableView:NSTableView)->Int {values.count}
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            let cell=NSTableCellView(),field=NSTextField(labelWithString:values[row])
            field.frame=NSRect(x:4,y:2,width:180,height:20);cell.textField=field;cell.addSubview(field);return cell
        }
        func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView? {
            factories += 1
            let result=reusable.popLast() ?? Row();result.backgroundColor=background
            if !created.contains(where:{$0 === result}){created.append(result)}
            return result
        }
        func tableView(_ tableView:NSTableView,didAdd rowView:NSTableRowView,forRow row:Int) {added += 1}
        func tableViewSelectionDidChange(_ notification:Notification) {selections += 1}
        func tableView(_ tableView:NSTableView,willDisplayCell cell:Any,for tableColumn:NSTableColumn?,row:Int) {displayed += 1;onDisplay?()}
    }
    @MainActor final class Host {
        let suite="TurtleGit.NativeList."+UUID().uuidString,prefs:UserDefaults
        let table=Table(),original=Original(),window:NSWindow,column=NSTableColumn(identifier:.init("path")),client=NSObject()
        init(fullRow:Bool=false) {
            prefs=UserDefaults(suiteName:suite)!;prefs.set(fullRow,forKey:"FullRowSelect")
            window=NSWindow(contentRect:.init(x:-24000,y:-24000,width:480,height:260),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.alphaValue=0
            table.frame=NSRect(x:0,y:0,width:480,height:220);table.style = .fullWidth;table.usesAlternatingRowBackgroundColors=false;table.rowHeight=24;table.allowsMultipleSelection=true
            column.width=440;table.addTableColumn(column);table.delegate=original;table.dataSource=original
            let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.documentView=table;window.contentView=scroll
            window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();table.reloadData()
        }
        func install(_ client:AnyObject?=nil,preferences:UserDefaults?=nil) {
            NativeListSelection.install(on:table,preferences:preferences ?? prefs,primaryColumn:column,labelText:{[weak original] row in
                guard let original,original.values.indices.contains(row) else{return nil};return original.values[row]
            },client:client ?? self.client)
        }
        func clean() {NativeListSelection.remove(from:table,client:client);window.close();table.delegate=nil;table.dataSource=nil;prefs.removePersistentDomain(forName:suite)}
    }
    static func suppliedRow(_ h:Host,at index:Int)throws->Row {
        let native=try unwrap(h.table.rowView(atRow:index,makeIfNecessary:true),"Native row could not be materialized")
        let receipt=h.original.created.first{$0 === native}
        var current:AnyClass?=object_getClass(native),inheritsOriginal=false,names:[String]=[]
        while let cls=current {
            names.append(NSStringFromClass(cls))
            if ObjectIdentifier(cls)==ObjectIdentifier(Row.self){inheritsOriginal=true}
            current=class_getSuperclass(cls)
        }
        print("Native row receipt: index=\(index), suppliedIdentity=\(receipt != nil), classes=\(names), created=\(h.original.created.count)");fflush(stdout)
        // Acquire the lazy offscreen row explicitly. Exact delegate-supplied
        // identity and the original class chain remain the class receipt.
        try require(inheritsOriginal,"Native row lost its original custom superclass")
        return try unwrap(receipt,"Native row was not supplied by the original custom delegate")
    }
    static func components(_ color:NSColor)->[CGFloat] {
        guard let rgb=color.usingColorSpace(.deviceRGB) else{return []}
        return [rgb.redComponent,rgb.greenComponent,rgb.blueComponent,rgb.alphaComponent]
    }
    static func sameColor(_ lhs:NSColor,_ rhs:NSColor)->Bool {
        let a=components(lhs),b=components(rhs)
        return a.count==4 && b.count==4 && zip(a,b).allSatisfy{abs($0-$1)<0.0001}
    }
    static func callbacks()async throws {
        let h=Host();defer{h.clean()}
        h.table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)
        let baselineNative=try unwrap(h.table.rowView(atRow:0,makeIfNecessary:true),"Undecorated baseline row absent")
        h.window.contentView?.layoutSubtreeIfNeeded()
        let baselineBackground=baselineNative.backgroundColor
        print("Undecorated row background: configured=\(components(h.original.background)), attachedSelected=\(components(baselineBackground)), originalClass=\(String(describing:object_getClass(baselineNative)))");fflush(stdout)
        h.table.deselectAll(nil)
        h.install()
        let proxy=try unwrap(h.table.delegate,"Installed selection delegate missing")
        let factories=h.original.factories,added=h.original.added,selections=h.original.selections
        let returned=h.table.callbackScope("row factory") {proxy.tableView?(h.table,rowViewForRow:0) ?? nil}
        let row=try unwrap(returned,"Original custom row factory was not forwarded")
        h.table.callbackScope("didAdd") {proxy.tableView?(h.table,didAdd:row,forRow:0)}
        h.table.callbackScope("selection") {h.table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)}
        try require(h.original.factories==factories+1 && h.original.added==added+1 && h.original.selections>selections,"Original delegate callbacks were dropped/duplicated")
        try require(h.table.cellReentries.isEmpty && h.table.hierarchyReentries.isEmpty,"Proxy reentered native row/cell construction: \(h.table.cellReentries), \(h.table.hierarchyReentries)")
        try await wait(h.window){h.table.selectionHighlightStyle == .none && NativeListSelection.labelRect(in:h.table,row:0) != nil}
        let selected=h.table.selectedRowIndexes
        try require(selected==IndexSet([0,2]),"Label-only decoration changed semantic multiselection")
        let actual=try suppliedRow(h,at:0)
        let marker=actual.marker
        print("Decorated row background: baseline=\(components(baselineBackground)), selected=\(components(actual.backgroundColor)), sameIdentity=\(actual === baselineNative)");fflush(stdout)
        try require(sameColor(actual.backgroundColor,baselineBackground),"Label-only decoration changed independently measured native row background")
        let label=try unwrap(NativeListSelection.labelRect(in:h.table,row:0),"Measured label highlight absent")
        try require(label.width>0 && label.width<h.table.bounds.width/2,"Label-only highlight expanded across row")
        h.prefs.set(true,forKey:"FullRowSelect");h.install()
        try await wait(h.window){NativeListSelection.usesFullRowSelection(in:h.table)==true && h.table.selectionHighlightStyle != .none}
        try require(h.table.selectedRowIndexes==selected && actual.marker==marker && sameColor(actual.backgroundColor,baselineBackground),"Full-row preference lost custom row identity/color or selection")
        h.prefs.set(false,forKey:"FullRowSelect");h.install();await tick()
        // Exercise actual sort/reload mapping and reuse a previously supplied
        // custom row after removing its old AppKit association.
        h.table.deselectAll(nil);h.original.values.sort();h.table.reloadData();h.window.contentView?.layoutSubtreeIfNeeded()
        try await wait(h.window){h.table.numberOfRows==3 && (h.table.view(atColumn:0,row:0,makeIfNecessary:true) as? NSTableCellView)?.textField?.stringValue=="alpha"}
        let reused=try suppliedRow(h,at:0)
        let actualMarker=reused.marker,reusedBackground=reused.backgroundColor
        print("Reloaded row background: \(components(reusedBackground))");fflush(stdout)
        h.original.values.removeFirst();h.table.removeRows(at:IndexSet(integer:0),withAnimation:[])
        await tick()
        try require(reused.marker==actualMarker && sameColor(reused.backgroundColor,reusedBackground),"Removing a row lost its measured native background")
        h.original.reusable=[reused];h.original.values.append("omega");h.table.insertRows(at:IndexSet(integer:2),withAnimation:[])
        h.window.contentView?.layoutSubtreeIfNeeded();await tick()
        let reinstalled=try unwrap(h.table.rowView(atRow:2,makeIfNecessary:true),"Reused row was not installed")
        try require(reinstalled === reused && sameColor(reused.backgroundColor,baselineBackground),"Row reuse lost original class/measured attached background")
        h.table.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false);await tick()
        try require(NativeListSelection.labelRect(in:h.table,row:2) != nil,"Reused sorted row did not acquire current label mapping")
        NativeListSelection.remove(from:h.table,client:h.client)
        try require(h.table.delegate === h.original && object_getClass(reused).map(ObjectIdentifier.init) == ObjectIdentifier(Row.self),"Removing proxy did not restore original delegate/custom class")
        try require(h.table.selectedRowIndexes==IndexSet(integer:2),"Removing proxy changed native selection")
    }
    static func lifecycle()async throws {
        let h=Host();defer{h.clean()};let next=NSObject()
        let suite="TurtleGit.NativeList.Next."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;prefs.set(true,forKey:"FullRowSelect");defer{prefs.removePersistentDomain(forName:suite)}
        h.install();let old=try unwrap(h.table.delegate,"Old delegate absent")
        h.table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)
        h.install(next,preferences:prefs);let replacement=try unwrap(h.table.delegate,"Replacement delegate absent")
        NativeListSelection.remove(from:h.table,client:h.client)
        try require(h.table.delegate === replacement && NativeListSelection.usesFullRowSelection(in:h.table)==true,"Old client dismantle removed new client's binding")
        await tick();await tick()
        try require(h.table.delegate === replacement && h.table.selectedRowIndexes==IndexSet([0,2]),"Queued old reconciliation disturbed replacement selection")
        let sentinel=NSCell(textCell:"sentinel");sentinel.backgroundStyle = .emphasized
        h.table.callbackScope("stale willDisplay") {old.tableView?(h.table,willDisplayCell:sentinel,for:h.column,row:0)}
        try require(sentinel.backgroundStyle == .emphasized && h.table.delegate === replacement,"Captured stale delegate restyled replacement cell")
        NativeListSelection.remove(from:h.table,client:next)
        h.install();let owner=try unwrap(h.table.delegate,"Rebound owner missing")
        var rebound=false
        h.original.onDisplay={
            guard !rebound else{return};rebound=true
            NativeListSelection.remove(from:h.table,client:h.client);h.install(next,preferences:prefs)
        }
        let during=NSCell(textCell:"replacement during callback");during.backgroundStyle = .emphasized
        h.table.callbackScope("rebind willDisplay") {owner.tableView?(h.table,willDisplayCell:during,for:h.column,row:0)}
        h.original.onDisplay=nil
        try require(rebound && during.backgroundStyle == .emphasized && NativeListSelection.usesFullRowSelection(in:h.table)==true,"Original delegate rebind was overwritten by old callback")
        await tick();await tick()
        try require(h.table.cellReentries.isEmpty && h.table.hierarchyReentries.isEmpty,"Reentrant callbacks queried cells/reordered hierarchy")
        NativeListSelection.remove(from:h.table,client:next)
        try require(h.table.delegate === h.original,"Final matching client failed to restore original delegate")
        h.install()
        try require(NativeListSelection.originalDelegate(of:h.table) === h.original,"Active proxy did not expose its original native delegate")
        let newNative=Original()
        h.table.delegate=newNative
        try require(NativeListSelection.originalDelegate(of:h.table) === newNative,"Delegate getter routed through stale associated owner after native replacement")
        h.install()
        try require(NativeListSelection.originalDelegate(of:h.table) === newNative && h.table.delegate !== newNative,"Reinstallation failed to capture the replacement native delegate")
        NativeListSelection.remove(from:h.table,client:h.client)
        try require(h.table.delegate === newNative,"Removing replacement owner restored stale original delegate")
        h.table.delegate=h.original
        h.install();h.window.close();await tick()
        let retiredDelegate=h.table.delegate
        h.install();await tick()
        try require(h.table.delegate === retiredDelegate && NativeListSelection.usesFullRowSelection(in:h.table)==nil,"Late install revived a closed window owner")
        let newWindow=NSWindow(contentRect:.init(x:-24000,y:-24000,width:480,height:260),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        newWindow.isReleasedWhenClosed=false;newWindow.alphaValue=0;defer{newWindow.close()}
        let scroll=NSScrollView();h.table.removeFromSuperview();scroll.documentView=h.table;newWindow.contentView=scroll;newWindow.orderFront(nil)
        h.install();try await wait(newWindow){NativeListSelection.usesFullRowSelection(in:h.table)==false}
        try require(h.table.delegate !== retiredDelegate && NativeListSelection.originalDelegate(of:h.table) === h.original,"Reparented table did not acquire fresh owned binding")
    }
    static func markerGeometry(_ adapter:CommitFileInteraction.Probe,owner:NSWindowController,indexes:IndexSet)async throws {
        let table=try unwrap(adapter.nativeTable,"Measured table absent")
        @MainActor func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
        @MainActor func pathColumn()->Int? {table.tableColumns.firstIndex{FileListLabels.column(named:$0.title) == .path}}
        @MainActor func check(_ row:Int)throws->Bool {
            guard let column=pathColumn(),let cell=table.view(atColumn:column,row:row,makeIfNecessary:true),
                  let marker=descendants(cell).compactMap({$0 as? NativeListSelectionLabelMarker.Probe}).first(where:{!$0.retired && $0.window === table.window}),
                  marker.bounds.width>0,marker.bounds.height>0,
                  let text=NativeListSelection.labelTextRect(in:table,row:row),let highlight=NativeListSelection.labelRect(in:table,row:row) else{return false}
            let expected=marker.convert(marker.bounds,to:table).intersection(table.frameOfCell(atColumn:column,row:row))
            guard !expected.isNull,expected.width>0 else{return false}
            try require(abs(text.minX-expected.minX)<0.5 && abs(text.minY-expected.minY)<0.5 && abs(text.width-expected.width)<0.5 && abs(text.height-expected.height)<0.5,"Selection text did not use actual SwiftUI Text marker bounds")
            try require(highlight.minX<=expected.minX+0.5 && highlight.maxX>=expected.maxX-0.5,"Selection left original glyphs outside its cover rectangle")
            guard let drawing=NativeListSelection.labelDrawing(in:table,row:row),let font=drawing.cell.font else{return false}
            // Inspect the attributed caption actually drawn in the marker
            // bounds. NSCell title/drawing rectangles were identity mappings on
            // the affected SDK and did not detect its physical truncation.
            let caption=drawing.cell.attributedStringValue
            let captionWidth=(caption.string as NSString).size(withAttributes:[.font:font]).width
            let attributedSize=caption.size()
            let expectedCaption=adapter.rows[row].entry?.path
            try require(expectedCaption.map{caption.string.utf8.elementsEqual($0.utf8)} == true,"Selection caption differs from the actual displayed path")
            var attributesMatch=true
            caption.enumerateAttributes(in:NSRange(location:0,length:caption.length),options:[]){attributes,_,_ in
                guard let actualFont=attributes[.font] as? NSFont,
                      let paragraph=attributes[.paragraphStyle] as? NSParagraphStyle else{attributesMatch=false;return}
                if !actualFont.isEqual(font) || paragraph.alignment != .left || paragraph.lineBreakMode != .byTruncatingTail {attributesMatch=false}
            }
            let diagnostic="caption=\(caption.string), font=\(font), independentWidth=\(captionWidth), attributedSize=\(attributedSize), marker=\(expected), drawing=\(drawing.frame)"
            print("Native attributed label metrics: "+diagnostic);fflush(stdout)
            try require(attributesMatch,"Actual overlay caption lost its explicit font/paragraph layout: "+diagnostic)
            try require(abs(drawing.frame.minX-expected.minX)<0.5 && abs(drawing.frame.minY-expected.minY)<0.5 && abs(drawing.frame.width-expected.width)<0.5 && abs(drawing.frame.height-expected.height)<0.5,"Attributed caption does not draw in the measured Text content frame: "+diagnostic)
            try require(abs(attributedSize.width-captionWidth)<0.5,"Attributed caption layout differs from the independently measured native font span: "+diagnostic)
            try require(drawing.frame.width>=captionWidth-0.5 && drawing.frame.height>=attributedSize.height-0.5,"Actual full path caption lacks sufficient drawable space: "+diagnostic)
            try require(marker.hitTest(.zero)==nil && !marker.isAccessibilityElement(),"Text geometry marker intercepted native input/accessibility")
            return true
        }
        @MainActor func ready()async throws {
            var failure:Error?
            try await wait(owner.window){
                do {return try indexes.allSatisfy{try check($0)}}catch {failure=error;return true}
            }
            if let failure {throw failure}
            for row in indexes {try require(try check(row),"Actual selected path Text marker did not materialize")}
        }
        try await ready()
        let index=try unwrap(pathColumn(),"Actual path column absent"),column=table.tableColumns[index]
        let originalWidth=column.width
        column.width=originalWidth+37
        await tick();owner.window?.contentView?.layoutSubtreeIfNeeded();await tick()
        try await ready()
        if let destination=table.tableColumns.indices.first(where:{$0 != index && !table.tableColumns[$0].isHidden && FileListLabels.column(named:table.tableColumns[$0].title) == .status}) {
            table.moveColumn(index,toColumn:destination)
            await tick();owner.window?.contentView?.layoutSubtreeIfNeeded();await tick()
            try await ready()
            if let current=table.tableColumns.firstIndex(where:{$0 === column}) {table.moveColumn(current,toColumn:index)}
        }
        column.width=originalWidth;await tick();owner.window?.contentView?.layoutSubtreeIfNeeded();await tick()
        try await ready()
        for row in indexes {
            print("Measured native label: row=\(row), text=\(String(describing:NativeListSelection.labelTextRect(in:table,row:row))), cover=\(String(describing:NativeListSelection.labelRect(in:table,row:row)))");fflush(stdout)
        }
    }
    static func captureTables(_ c:ReportWorkspaceVerification.Context)async throws {
        let folder=ProcessInfo.processInfo.environment["TURTLEGIT_LIST_CAPTURE_DIR"].map{URL(fileURLWithPath:$0).appendingPathComponent("receiver-"+String(getpid()))}
        if let folder {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)}
        let commit=c.own(CommitWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),defaults:c.prefs))
        commit.model.confirmCancel={$0(true)};commit.model.reload()
        try await wait(commit.window){!commit.model.busy && commit.model.fileListAvailable}
        let status=c.own(StatusWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),defaults:c.prefs))
        status.model.reload();try await wait(status.window){!status.model.busy && status.model.files.count==3}
        let log=c.own(LogWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),labelDefaults:c.prefs,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false))
        log.model.showWorkingTree=false;log.model.reload()
        try await wait(log.window){!log.model.busy && log.model.entries.contains{$0.hash==c.head}}
        log.model.select([c.head]);try await wait(log.window){!log.model.busy && log.model.files.count==3}
        for (name,owner,fullRow) in [("commit",commit as NSWindowController,false),("status",status as NSWindowController,false),("log",log as NSWindowController,false)] {
            let adapter=try await ReportWorkspaceVerification.probe(owner)
            let table=try unwrap(adapter.nativeTable,"Capture table absent")
            c.prefs.set(fullRow,forKey:"FullRowSelect")
            let indexes=IndexSet(adapter.rows.indices.filter{adapter.rows[$0].entry.map{["alpha.txt","zeta.txt"].contains($0.path)} == true})
            try require(indexes.count==2,"Capture selection omitted alpha/zeta")
            table.selectRowIndexes(indexes,byExtendingSelection:false)
            for (theme,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
                owner.window?.appearance=NSAppearance(named:appearance)
                try await wait(owner.window){NativeListSelection.usesFullRowSelection(in:table)==fullRow && (fullRow ? table.selectionHighlightStyle != .none:table.selectionHighlightStyle == .none)}
                await tick();await tick();owner.window?.contentView?.layoutSubtreeIfNeeded()
                try await markerGeometry(adapter,owner:owner,indexes:indexes)
                let rect=table.visibleRect
                try require(rect.width>100 && rect.height>50 && table.selectedRowIndexes==indexes,"Capture did not realize selected native rows")
                if let folder {
                let bitmap=try unwrap(table.bitmapImageRepForCachingDisplay(in:rect),"Native table bitmap unavailable")
                table.cacheDisplay(in:rect,to:bitmap)
                let bytes=try unwrap(bitmap.representation(using:.png,properties:[:]),"Native table PNG unavailable")
                let file=folder.appendingPathComponent(name+"-"+theme+"-"+(fullRow ? "full-row":"label-only")+".png")
                try require(!FileManager.default.fileExists(atPath:file.path),"Capture would overwrite earlier evidence")
                try bytes.write(to:file,options:.atomic)
                print("Native list capture: "+file.path);fflush(stdout)
                }
            }
            owner.close();c.owners.removeAll{$0 === owner};await tick()
            try require(indexes.allSatisfy{NativeListSelection.labelRect(in:table,row:$0)==nil},"Closed consumer retained a stale marker-driven overlay")
        }
    }
    static func consumers()async throws {
        let c=ReportWorkspaceVerification.Context();DialogGeometry.install(preferences:c.prefs)
        defer{DialogGeometry.install(preferences:.standard)}
        do {
            try await c.prepare();try await ReportWorkspaceVerification.commit(c)
            for owner in c.owners {owner.close()};c.owners=[]
            try await wait(nil){ReportWorkspaceVerification.drained()}
            // Each actual window family shares the same private prepared repo;
            // reopen with fresh context preferences after prior owner teardown.
            try await ReportWorkspaceVerification.status(c)
            for owner in c.owners {owner.close()};c.owners=[]
            try await wait(nil){ReportWorkspaceVerification.drained()}
            try await ReportWorkspaceVerification.log(c);try await captureTables(c);try await c.preserved();await c.clean()
            try require(ReportWorkspaceVerification.drained(),"Actual consumer workers did not drain")
        } catch {await c.clean();throw error}
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let pairs=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.listInteractionFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.listInteractionOrder(_:relativeTo:))))]
        for(a,b)in pairs{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in pairs.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        do {
            switch CommandLine.arguments[3] {case "callbacks":try await callbacks();case "lifecycle":try await lifecycle();case "consumers":try await consumers();default:throw Failure(description:"Unknown native list case")}
            await tick();try require(NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Native list test windows remain visible")
            print("PASS: native list interactions "+CommandLine.arguments[3]);fflush(stdout)
        } catch {fputs("Native list interactions failed: \(error)\n",stderr);exit(1)}
    }
}
