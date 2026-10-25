// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import QuartzCore
import TurtleGitCore

private extension NSWindow {
    @objc func rowsFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func rowsOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){
        if self !== CommitReportRowsVerification.captureWindow {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000))}
        rowsOrder(mode,relativeTo:number)
    }
}
@MainActor @main enum CommitReportRowsVerification {
    typealias Context=CommitCheckCategoriesVerification.Context
    struct Failure:Error,CustomStringConvertible{let description:String}
    static weak var captureWindow:NSWindow?
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Report rows \(line): "+message)}}
    static func views(_ view:NSView?)->[NSView] {
        guard let view else{return []}
        // Read the public Objective-C NSArray directly. A lazy bridged
        // [NSView] iteration trapped in the observed diagnostic traversal.
        // Snapshot before recursion so AppKit layout cannot replace its cohort.
        let selector=#selector(getter:NSView.subviews)
        typealias Getter=@convention(c)(AnyObject,Selector)->Unmanaged<NSArray>
        let getter=unsafeBitCast(view.method(for:selector),to:Getter.self)
        let children=getter(view,selector).takeUnretainedValue().copy() as! NSArray
        var result=[view]
        for index in 0..<children.count {
            let object=children.object(at:index) as AnyObject
            guard let native=object as? NSObject,native.isKind(of:NSView.self) else{continue}
            // Validate the public ObjC NSView inheritance contract before
            // representing the copied array element as a view.
            let child=unsafeBitCast(object,to:NSView.self)
            result += views(child)
        }
        return result
    }
    static func wait(_ window:NSWindow?=nil,line:Int = #line,_ predicate:()->Bool)async throws{
        for _ in 0..<3000{window?.contentView?.layoutSubtreeIfNeeded();if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Report rows timeout \(line)")
    }
    static func probe(_ owner:CommitWindowController)async throws->CommitFileInteraction.Probe {
        try await wait(owner.window){views(owner.window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}.contains{probe in probe.nativeTable != nil && probe.rows.map{Data($0.id.utf8)}==owner.model.visibleFileRowIDs.map{Data($0.utf8)}}}
        return views(owner.window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}.first{$0.nativeTable != nil}!
    }
    static func font(_ prefs:UserDefaults)->NSFont{
        prefs.bool(forKey:"LogFontForFileListCtrl") ? MessageEditorFont.resolve(name:prefs.string(forKey:"LogFontName") ?? MessageEditorFont.defaultName,size:prefs.integer(forKey:"LogFontSize")):NSFont.systemFont(ofSize:NSFont.systemFontSize)
    }
    static func ancestors(_ view:NSView)->String {
        var current:NSView?=view,result=[String]()
        for _ in 0..<5 {
            guard let value=current else{break}
            result.append("\(String(cString:object_getClassName(value))) frame=\(value.frame) bounds=\(value.bounds)")
            current=value.superview
        }
        return result.joined(separator:"; ")
    }
    static func verifyGeometry(_ owner:CommitWindowController,_ adapter:CommitFileInteraction.Probe,font:NSFont)async throws {
        guard let table=adapter.nativeTable else{throw Failure(description:"Actual Commit report table absent")}
        try await wait(owner.window){!table.usesAutomaticRowHeights && table.numberOfRows==adapter.rows.count}
        let bold=NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask),metrics=NSLayoutManager()
        let required=max(metrics.defaultLineHeight(for:font),metrics.defaultLineHeight(for:bold))
        let originalSpacing=table.intercellSpacing
        // Acquisition may itself ask SwiftUI to build/size a cell. Finish this
        // phase before awaiting the source's deferred sizing reconciliation.
        let visible=table.rows(in:table.visibleRect)
        if visible.location != NSNotFound {
            for row in visible.location..<min(NSMaxRange(visible),table.numberOfRows) {
                _=table.rowView(atRow:row,makeIfNecessary:true)
                for column in table.tableColumns.indices where !table.tableColumns[column].isHidden {_=table.view(atColumn:column,row:row,makeIfNecessary:true)}
            }
        }
        await flushSizingQueue()
        var alignment=""
        do {try await wait(owner.window) {
            var pending=[String]()
            if table.usesAutomaticRowHeights || table.rowSizeStyle != .custom || table.rowHeight<required {pending.append("height=\(table.rowHeight) required=\(required) auto=\(table.usesAutomaticRowHeights) style=\(table.rowSizeStyle.rawValue)")}
            let visible=table.rows(in:table.visibleRect)
            if visible.location != NSNotFound {
                for row in visible.location..<min(NSMaxRange(visible),table.numberOfRows) {
                    guard let native=table.rowView(atRow:row,makeIfNecessary:false) else{continue}
                    let actual=native.convert(native.bounds,to:table),expected=table.rect(ofRow:row)
                    if abs(actual.minY-expected.minY)>0.5 || abs(actual.height-expected.height)>0.5 {pending.append("row=\(row) native=\(actual) expected=\(expected)")}
                }
            }
            let markers=views(table).compactMap{$0 as? NativeListSelectionLabelMarker.Probe}.filter{!$0.retired && !$0.isHiddenOrHasHiddenAncestor && table.row(for:$0)>=0}
            if markers.isEmpty {pending.append("no realized caption markers")}
            else if !markers.contains(where:{$0.bounds.height+2>=metrics.defaultLineHeight(for:font)}) {pending.append("caption font layout pending: \(markers.map{$0.bounds.height})")}
            alignment=pending.joined(separator:"; ")
            return pending.isEmpty
        }} catch {throw Failure(description:"Report native sizing did not settle: "+alignment)}
        try require(table.rowHeight>=required,"Native row clips configured regular/bold font metrics: height=\(table.rowHeight), required=\(required), rowSizeStyle=\(table.rowSizeStyle.rawValue), effectiveRowSizeStyle=\(table.effectiveRowSizeStyle.rawValue)")
        // From here inspect existing views only; do not create a new cohort and
        // immediately assert against the preceding native sizing projection.
        for row in adapter.rows.indices {
            let frame=table.rect(ofRow:row)
            try require(abs(frame.height-table.rowHeight)<0.5,"Automatic/variable report row survived at \(row): \(frame)")
        }
        // Actual checkbox and icon-bearing content must fit the native row. No
        // expected production height is reconstructed from the helper formula.
        let checks=views(table).compactMap{$0 as? NSButton}.filter{($0.accessibilityLabel() ?? "").hasPrefix("Include ")}
        try require(!checks.isEmpty,"Actual native inclusion checkboxes absent")
        var visibleChecks=0
        for button in checks where !button.isHiddenOrHasHiddenAncestor {
            let frame=button.convert(button.bounds,to:table),row=table.row(for:button)
            if row>=0,NSLocationInRange(row,table.rows(in:table.visibleRect)) {visibleChecks += 1;let rect=table.rect(ofRow:row).insetBy(dx:-1,dy:-0.5);try require(rect.minY<=frame.minY && rect.maxY>=frame.maxY,"Checkbox is vertically clipped by fixed row: label=\(button.accessibilityLabel() ?? "nil") frame=\(frame) row=\(row) rect=\(rect) tableHeight=\(table.rowHeight) font=\(font.fontName)/\(font.pointSize) bounds=\(button.bounds) control=\(String(cString:object_getClassName(button)))")}
        }
        try require(visibleChecks>0,"No actual visible-row checkbox bounds were checked")
        for image in views(table).compactMap({$0 as? NSImageView}) where image.image != nil {
            let frame=image.convert(image.bounds,to:table),row=table.row(for:image)
            if row>=0,NSLocationInRange(row,table.rows(in:table.visibleRect)),!image.isHiddenOrHasHiddenAncestor,frame.height>0 {let rect=table.rect(ofRow:row);try require(frame.minY>=rect.minY-1 && frame.maxY<=rect.maxY+1,"Status icon is clipped by report row")}
        }
        let markers=views(table).compactMap{$0 as? NativeListSelectionLabelMarker.Probe}.filter{!$0.retired}
        try require(!markers.isEmpty,"Actual Commit text geometry markers absent")
        for marker in markers {
            let frame=marker.convert(marker.bounds,to:table),row=table.row(for:marker)
            guard row>=0,NSLocationInRange(row,table.rows(in:table.visibleRect)),!marker.isHiddenOrHasHiddenAncestor,frame.height>0 else{continue}
            let rect=table.rect(ofRow:row)
            try require(frame.height<=required+2,"A Commit caption still occupies multiple lines")
            let fits=frame.minY>=rect.minY-1 && frame.maxY<=rect.maxY+1
            let diagnostic="Text bounds exceed fixed native row: marker=\(frame) row=\(row) rect=\(rect) height=\(table.rowHeight) font=\(font.fontName)/\(font.pointSize) ancestors=\(ancestors(marker))"
            if !fits {do {try await capture(owner,name:"commit-report-failed-text")} catch {fputs("Failed text-bounds capture: \(error)\n",stderr)}}
            try require(fits,diagnostic)
        }
        try require(table.intercellSpacing==originalSpacing,"Geometry checks changed native spacing")
    }
    static let longPath=String(repeating:"long_Unicode_雪_",count:10)+".txt"
    static let controlPath="line\nbreak\tcafe\u{301}.txt"
    static let group="Long group 雪 "+String(repeating:"caption ",count:14)+"\nsecond line"
    static func installLongRows(_ c:Context,_ owner:CommitWindowController)async throws {
        let rows=StatusEntry.parse(Data((" M alpha\0 M "+longPath+"\0 M "+controlPath+"\0?? loose\0").utf8))
        try require(rows.count==4,"Literal path status fixture malformed")
        owner.model.queryCommitStatus={_,_ in rows};owner.model.reload();try await c.settled(owner.model)
        owner.model.changelists=GitChangelists(assignments:[longPath:group,controlPath:group])
        owner.model.hasLFS=true;owner.model.fileColumns.visible=Set(StatusListColumn.allCases)
        owner.model.fileMetadata=[longPath:.init(modificationDate:Date(timeIntervalSince1970:1_000_000_000),size:Int64.max,isDirectory:false)]
        owner.model.lfsOwners=[longPath:"Long owner 雪\n"+String(repeating:"metadata ",count:15)]

        owner.model.setFileSortOrder([CommitFileSort(column:.path,order:.reverse)])
        let adapter=try await probe(owner)
        try await wait(owner.window){adapter.rows.contains{$0.group != nil} && adapter.rows.compactMap(\.entry).count==4}
        guard let table=adapter.nativeTable else{throw Failure(description:"No native table")}
        if let column=table.tableColumns.first(where:{$0.title==NSLocalizedString("Path",comment:"")}) {column.width=column.minWidth}
        try require(adapter.rows.compactMap(\.entry).contains{$0.path.utf8.elementsEqual(controlPath.utf8)},"Native row identity escaped or normalized the literal path")
        let selected=adapter.rows.compactMap(\.entry).filter{$0.path.utf8.elementsEqual(controlPath.utf8) || $0.path.utf8.elementsEqual(longPath.utf8)}
        let copied=StatusListClipboard.text(selected,root:c.folder,statistics:[:],copy:.relativePaths)
        try require(selected.allSatisfy{copied.utf8.containsSubsequence($0.path.utf8)},"Copy projection lost original path bytes")
        let privateBoard=NSPasteboard.withUniqueName();defer{privateBoard.releaseGlobally()};privateBoard.setString(copied,forType:.string)
        try require(privateBoard.string(forType:.string)?.utf8.elementsEqual(copied.utf8)==true,"Private copy payload changed literal path bytes")
    }
    static func geometry(_ c:Context)async throws {
        // Keep the exact category replacement/checkbox workload which emitted
        // the baseline AppKit warning, including every original assertion.
        try await CommitCheckCategoriesVerification.categories(c)
        let owner=c.owners.last!;owner.showWindow(nil)
        try await installLongRows(c,owner)
        let adapter=try await probe(owner),table=adapter.nativeTable!
        try await verifyGeometry(owner,adapter,font:font(c.prefs))
        let files=adapter.rows.compactMap(\.entry),first=files[0].id,last=files.last!.id
        owner.model.checked=[last]
        let native=IndexSet(adapter.rows.indices.filter{adapter.rows[$0].entry?.id==first})
        table.selectRowIndexes(native,byExtendingSelection:false)
        try await wait(owner.window){owner.model.selection==GitPathSet([first])}
        try require(owner.model.checked==GitPathSet([last]),"Native highlight changed independent inclusion")
        try await wait(owner.window){views(table).compactMap{$0 as? NSButton}.contains{$0.accessibilityLabel()=="Include "+last && $0.isEnabled}}
        let button=views(table).compactMap{$0 as? NSButton}.first{$0.accessibilityLabel()=="Include "+last}!
        try require(NSApp.sendAction(button.action!,to:button.target,from:button),"Actual checkbox action refused")
        try await wait(owner.window){!owner.model.checked.contains(last)}
        try require(owner.model.selection==GitPathSet([first]),"Checkbox changed highlighted raw path")
        try await verifyGeometry(owner,adapter,font:font(c.prefs));try await c.unchanged()
    }
    static func capture(_ owner:CommitWindowController,name:String)async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_REPORT_ROW_CAPTURES"],let window=owner.window else{return}
        let target=URL(fileURLWithPath:folder,isDirectory:true).appendingPathComponent(name+".png")
        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        let frame=window.frame,animation=window.animationBehavior;window.animationBehavior = .none;captureWindow=window
        defer{window.orderOut(nil);window.alphaValue=0;window.setFrame(frame,display:false);window.animationBehavior=animation;captureWindow=nil}
        window.setFrameOrigin(.init(x:120,y:120));window.alphaValue=1;window.orderFrontRegardless();window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
        var serverReady=false
        for _ in 0..<300 {
            if window.isVisible,window.alphaValue==1,window.windowNumber>0,
               let records=CGWindowListCopyWindowInfo(.optionIncludingWindow,CGWindowID(window.windowNumber)) as? [[String:Any]],
               records.contains(where:{($0[kCGWindowNumber as String] as? NSNumber)?.intValue==window.windowNumber && ($0[kCGWindowIsOnscreen as String] as? Bool)==true}) {serverReady=true;break}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        try require(serverReady,"Owned capture window did not reach WindowServer: id=\(window.windowNumber) visible=\(window.isVisible) frame=\(window.frame)")
        // The WindowServer record can precede this window's backing contents.
        // Commit the owned view's display/CA work, then leave the main turn so
        // presentation completes before the one capture attempt.
        window.contentView?.needsDisplay=true;window.displayIfNeeded();CATransaction.flush()
        await flushSizingQueue()
        window.displayIfNeeded();CATransaction.flush()
        await flushSizingQueue()
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");process.arguments=["-x","-l",String(window.windowNumber),target.path]
        try process.run();process.waitUntilExit()
        let bytes=try Data(contentsOf:target)
        try require(process.terminationStatus==0 && bytes.count>1000,"Owned full-window capture failed")
        guard let bitmap=NSBitmapImageRep(data:bytes),bitmap.pixelsWide>0,bitmap.pixelsHigh>0 else{throw Failure(description:"Capture PNG could not be decoded")}
        var painted=0,lowest:CGFloat=1,highest:CGFloat=0
        for y in 0..<24 {for x in 0..<24 {
            guard let color=bitmap.colorAt(x:x*(bitmap.pixelsWide-1)/23,y:y*(bitmap.pixelsHigh-1)/23)?.usingColorSpace(.deviceRGB),color.alphaComponent>0.1 else{continue}
            let light=max(color.redComponent,max(color.greenComponent,color.blueComponent))
            if light>0.02 {painted += 1};lowest=min(lowest,light);highest=max(highest,light)
        }}
        try require(painted>20 && highest-lowest>0.08,"Capture contains no rendered native window pixels: painted=\(painted) range=\(lowest)...\(highest) file=\(target.path)")

    }
    static func fonts(_ c:Context)async throws {
        let owner=try await c.owner();owner.showWindow(nil);try await installLongRows(c,owner)
        let adapter=try await probe(owner),table=adapter.nativeTable!,before=table.rowHeight
        owner.window?.appearance=NSAppearance(named:.aqua)
        print("Font phase: default light height=\(table.rowHeight)");fflush(stdout)
        try await verifyGeometry(owner,adapter,font:font(c.prefs));if ProcessInfo.processInfo.environment["TURTLEGIT_REPORT_ROW_SKIP_DEFAULT_CAPTURE"] == nil {try await capture(owner,name:"commit-report-default-light")}
        c.prefs.set(true,forKey:"LogFontForFileListCtrl");c.prefs.set("Menlo",forKey:"LogFontName");c.prefs.set(26,forKey:"LogFontSize")
        owner.model.objectWillChange.send()
        try await wait(owner.window){table.rowHeight>before && !table.usesAutomaticRowHeights}
        print("Font phase: large height=\(table.rowHeight)");fflush(stdout)
        try await verifyGeometry(owner,adapter,font:font(c.prefs))
        let larger=table.rowHeight;owner.window?.setContentSize(.init(width:1000,height:720));owner.window?.appearance=NSAppearance(named:.darkAqua)
        if table.tableColumns.count>2 {table.moveColumn(2,toColumn:1)}
        try await verifyGeometry(owner,adapter,font:font(c.prefs));try require(table.rowHeight==larger,"Column reorder changed font-derived row height")
        try await capture(owner,name:"commit-report-large-dark")
        c.prefs.set(false,forKey:"LogFontForFileListCtrl");owner.model.objectWillChange.send()
        try await wait(owner.window){table.rowHeight<larger}
        print("Font phase: restored height=\(table.rowHeight)");fflush(stdout)
        try await verifyGeometry(owner,adapter,font:font(c.prefs));try await c.unchanged()
    }
    @MainActor final class ReplacementDelegate:NSObject,NSTableViewDelegate {}
    @MainActor final class Host:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        var rowIDs=[Data("zero".utf8),Data("one".utf8),Data("two".utf8)]
        let table=NSTableView(),scroll=NSScrollView(),window=NSWindow(contentRect:.init(x:-24000,y:-24000,width:400,height:220),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        override init(){super.init();window.isReleasedWhenClosed=false;window.alphaValue=0;table.addTableColumn(NSTableColumn(identifier:.init("path")));table.rowHeight=17;table.usesAutomaticRowHeights=true;table.intercellSpacing = .init(width:3,height:2);table.dataSource=self;table.delegate=self;scroll.documentView=table;window.contentView=scroll;window.orderFront(nil);table.reloadData()}
        func numberOfRows(in tableView:NSTableView)->Int{rowIDs.count}
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView?{NSTextField(labelWithString:String(decoding:rowIDs[row],as:UTF8.self))}
    }
    static func flushSizingQueue()async {
        // Drain actual queued sizing notifications/reconciliation, with no timer.
        for _ in 0..<2 {await withCheckedContinuation { continuation in DispatchQueue.main.async {continuation.resume()} }}
    }
    static func ownership(_ c:Context)async throws {
        let host=Host();defer{host.window.close()};let a=NSObject(),b=NSObject(),table=host.table
        func state(_ phase:String) {
            let delegate=table.delegate.map{String(describing:ObjectIdentifier($0 as AnyObject))} ?? "nil"
            let source=table.dataSource.map{String(describing:ObjectIdentifier($0 as AnyObject))} ?? "nil"
            fputs("Ownership \(phase): host=\(ObjectIdentifier(host)) delegate=\(delegate) source=\(source) selected=\(Array(table.selectedRowIndexes)) rows=\(table.numberOfRows) frame=\(table.frame) rowHeight=\(table.rowHeight) style=\(table.rowSizeStyle.rawValue) auto=\(table.usesAutomaticRowHeights)\n",stderr)
        }
        state("initial")
        table.rowSizeStyle = .medium
        state("style baseline")
        let baseline=table.rowHeight,automatic=table.usesAutomaticRowHeights,spacing=table.intercellSpacing,originalStyle=table.rowSizeStyle
        table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        state("selected before install")
        NativeReportRowGeometry.install(on:table,font:.systemFont(ofSize:13),client:a,rowIDs:{[weak host] in host?.rowIDs})
        state("installed A")
        try require(table.selectedRowIndexes==IndexSet(integer:1),"Owned initial sizing cleared accepted selection")
        let acceptedHeight=table.rowHeight
        table.rowHeight=acceptedHeight+7;state("external height");table.usesAutomaticRowHeights=true;state("external automatic");table.rowSizeStyle = .large;state("external style")
        try await wait(host.window){table.rowHeight==acceptedHeight && !table.usesAutomaticRowHeights && table.rowSizeStyle == .custom}
        state("reset settled")
        try require(table.selectedRowIndexes.isEmpty,"Geometry resurrected selection cleared by the caller's explicit automatic-row update")
        // Queue an old owner's notification before installing its successor.
        table.rowHeight=acceptedHeight+9
        table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        NativeReportRowGeometry.install(on:table,font:.systemFont(ofSize:28),client:b,rowIDs:{[weak host] in host?.rowIDs})
        let successorHeight=table.rowHeight
        state("installed B")
        NativeReportRowGeometry.remove(from:table,client:a)
        state("removed A")
        await flushSizingQueue()
        try require(!table.usesAutomaticRowHeights && table.rowHeight==successorHeight,"Old client removed successor geometry")
        state("handoff settled")
        try require(table.delegate === host && table.dataSource === host && table.selectedRowIndexes==IndexSet(integer:1) && table.numberOfRows==3,"Geometry handoff changed native data/delegate/selection")
        table.rowHeight=successorHeight+11
        NativeReportRowGeometry.remove(from:table,client:b)
        await flushSizingQueue()
        try require(table.rowHeight==baseline && table.usesAutomaticRowHeights==automatic && table.rowSizeStyle==originalStyle && table.intercellSpacing==spacing,"Detach did not restore exact native baseline")
        let originalIDs=host.rowIDs
        var remapped=false
        let identityChange=table.observe(\.rowHeight,options:[.new]) { table,_ in
            MainActor.assumeIsolated {
                guard !remapped,table.rowHeight>baseline else{return}
                remapped=true;host.rowIDs=[Data("other-zero".utf8),Data("other-one".utf8),Data("other-two".utf8)];table.reloadData()
            }
        }
        table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        NativeReportRowGeometry.install(on:table,font:.systemFont(ofSize:40),client:a,rowIDs:{[weak host] in host?.rowIDs})
        identityChange.invalidate();await flushSizingQueue()
        try require(remapped && table.numberOfRows==originalIDs.count && table.selectedRowIndexes.isEmpty,"Same-count replacement identities received old row-index selection")
        NativeReportRowGeometry.remove(from:table,client:a)
        host.rowIDs=originalIDs;table.reloadData()
        let replacement=ReplacementDelegate();var replacedDelegate=false
        let delegateChange=table.observe(\.rowHeight,options:[.new]) { table,_ in
            MainActor.assumeIsolated {
                guard !replacedDelegate,table.rowHeight>baseline else{return}
                replacedDelegate=true;table.delegate=replacement;table.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false)
            }
        }
        table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        NativeReportRowGeometry.install(on:table,font:.systemFont(ofSize:40),client:a,rowIDs:{[weak host] in host?.rowIDs})
        delegateChange.invalidate();await flushSizingQueue()
        try require(replacedDelegate && table.delegate === replacement && table.selectedRowIndexes==IndexSet(integer:2),"Sizing restored old selection over replacement delegate's accepted selection")
        NativeReportRowGeometry.remove(from:table,client:a);table.delegate=host
        NativeReportRowGeometry.install(on:table,font:.systemFont(ofSize:40),client:a,rowIDs:{[weak host] in host?.rowIDs})
        var handedOff=false,replacementHeight:CGFloat=0
        let restorationObserver=table.observe(\.rowHeight,options:[.new]) { table,_ in
            MainActor.assumeIsolated {
                guard !handedOff,table.rowHeight==baseline else{return}
                handedOff=true
                NativeReportRowGeometry.install(on:table,font:.systemFont(ofSize:30),client:b,rowIDs:{[weak host] in host?.rowIDs})
                replacementHeight=table.rowHeight
            }
        }
        NativeReportRowGeometry.remove(from:table,client:a)
        restorationObserver.invalidate()
        await flushSizingQueue()
        try require(handedOff && replacementHeight>baseline,"External sizing observer did not install a real successor during restoration")
        NativeReportRowGeometry.remove(from:table,client:a)
        try require(table.rowHeight==replacementHeight && table.rowSizeStyle == .custom && !table.usesAutomaticRowHeights,"Retiring owner's restoration/remove cleared the reentrant successor")
        NativeReportRowGeometry.remove(from:table,client:b)
        await flushSizingQueue()
        try require(table.rowHeight==baseline && table.rowSizeStyle==originalStyle && table.usesAutomaticRowHeights==automatic,"Reentrant successor did not inherit the original complete baseline")
        NativeReportRowGeometry.install(on:table,font:.systemFont(ofSize:20),client:a,rowIDs:{[weak host] in host?.rowIDs});table.rowHeight += 5;host.window.close();await flushSizingQueue()
        try require(table.rowHeight==baseline && table.usesAutomaticRowHeights==automatic && table.rowSizeStyle==originalStyle,"Close did not restore geometry")
        NativeReportRowGeometry.install(on:table,font:.systemFont(ofSize:40),client:a,rowIDs:{[weak host] in host?.rowIDs})
        try require(table.rowHeight==baseline && table.usesAutomaticRowHeights==automatic && table.rowSizeStyle==originalStyle,"Late closed-owner install revived fixed geometry")
        let fresh=NSWindow(contentRect:.init(x:-24000,y:-24000,width:400,height:220),styleMask:[.titled,.closable],backing:.buffered,defer:false);fresh.isReleasedWhenClosed=false;fresh.alphaValue=0;defer{fresh.close()};fresh.contentView=host.scroll;fresh.orderFront(nil)
        NativeReportRowGeometry.install(on:table,font:.systemFont(ofSize:22),client:a,rowIDs:{[weak host] in host?.rowIDs})
        try require(!table.usesAutomaticRowHeights && table.rowHeight>baseline,"Live reparent did not accept geometry")
        NativeReportRowGeometry.remove(from:table,client:a)
        try require(table.rowHeight==baseline && table.usesAutomaticRowHeights==automatic && table.rowSizeStyle==originalStyle,"Reparent detach lost original settings")
        let owner=try await c.owner();owner.showWindow(nil);let adapter=try await probe(owner),liveTable=adapter.nativeTable!
        try await verifyGeometry(owner,adapter,font:font(c.prefs));adapter.stopObserving()
        try require(liveTable.usesAutomaticRowHeights,"Commit adapter retirement retained its private fixed-height override")
        let oldHeight=liveTable.rowHeight;owner.close();owner.model.objectWillChange.send()
        await Task.yield();try require(liveTable.rowHeight==oldHeight && liveTable.usesAutomaticRowHeights,"Late retired Commit update changed restored table")
        try await c.unchanged()
    }
    static func main()async {
        let captures=ProcessInfo.processInfo.environment["TURTLEGIT_REPORT_ROW_CAPTURES"] != nil
        NSApp.setActivationPolicy(captures ? .accessory:.prohibited)
        let pairs=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.rowsFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.rowsOrder(_:relativeTo:))))]
        for(a,b)in pairs{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in pairs.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context(),name=CommandLine.arguments[3];c.prefs.set(false,forKey:"FullRowSelect");c.prefs.set(false,forKey:"Autocompletion");DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do{try await c.prepare();switch name{case "geometry":try await geometry(c);case "fonts":try await fonts(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown case")};await c.cleanup();try require(CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileOperations==0,"Owned Commit workers survived drain");print("PASS: Commit report rows "+name)}catch{await c.cleanup();fputs("\(error)\n",stderr);exit(1)}
    }
}
private extension Collection where Element==UInt8 {
    func containsSubsequence<C:Collection>(_ value:C)->Bool where C.Element==UInt8 {let needle=Array(value);return needle.isEmpty || indices.contains{start in self[start...].starts(with:needle)}}
}
