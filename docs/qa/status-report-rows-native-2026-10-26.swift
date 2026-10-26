// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func reportFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect {rect}
    @objc func reportOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));reportOrder(mode,relativeTo:number)
    }
}
private extension NSView {
    @objc func reportAddToolTip(_ rect:NSRect,owner:Any,userData:UnsafeMutableRawPointer?)->NSView.ToolTipTag {
        let tag=reportAddToolTip(rect,owner:owner,userData:userData)
        StatusReportRowsVerification.Tooltips.add(view:self,rect:rect,owner:owner as AnyObject,data:userData,tag:tag)
        return tag
    }
    @objc func reportRemoveToolTip(_ tag:NSView.ToolTipTag) {
        StatusReportRowsVerification.Tooltips.remove(view:self,tag:tag);reportRemoveToolTip(tag)
    }
    @objc func reportRemoveAllToolTips() {
        StatusReportRowsVerification.Tooltips.remove(view:self,tag:nil);reportRemoveAllToolTips()
    }
}
@MainActor @main enum StatusReportRowsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor enum Tooltips {
        final class Entry {
            weak var view:NSView?
            weak var owner:AnyObject?
            let rect:NSRect,tag:NSView.ToolTipTag,data:UnsafeMutableRawPointer?
            init(view:NSView,rect:NSRect,owner:AnyObject,data:UnsafeMutableRawPointer?,tag:NSView.ToolTipTag) {self.view=view;self.rect=rect;self.owner=owner;self.data=data;self.tag=tag}
        }
        static var entries=[Entry]()
        static func add(view:NSView,rect:NSRect,owner:AnyObject,data:UnsafeMutableRawPointer?,tag:NSView.ToolTipTag) {
            entries.removeAll{$0.view==nil || $0.owner==nil || $0.view === view && $0.tag==tag}
            entries.append(Entry(view:view,rect:rect,owner:owner,data:data,tag:tag))
        }
        static func remove(view:NSView,tag:NSView.ToolTipTag?) {entries.removeAll{$0.view==nil || $0.view === view && (tag==nil || $0.tag==tag)}}
        static func query(_ window:NSWindow?,table:NSTableView,path:String)->(help:[String],diagnostics:[String]) {
            guard let window,let column=table.tableColumns.firstIndex(where:{$0.title=="Path"}),
                  let row=(0..<table.numberOfRows).first(where:{NativeListSelection.labelDrawing(in:table,row:$0)?.cell.stringValue.utf8.elementsEqual(path.utf8)==true}) else {return ([],["Actual path row/column unavailable"])}
            let cell=table.frameOfCell(atColumn:column,row:row)
            let selector=NSSelectorFromString("view:stringForToolTip:point:userData:")
            typealias Getter=@convention(c)(AnyObject,Selector,NSView,NSView.ToolTipTag,NSPoint,UnsafeMutableRawPointer?)->Unmanaged<NSString>?
            var help=[String](),diagnostics=[String]()
            // Snapshot current registrations, but recheck membership before a
            // callback: native tooltip owners and userData remain native-owned.
            for entry in entries {
                guard let view=entry.view,let owner=entry.owner as? NSObject,view.window === window,!view.isHiddenOrHasHiddenAncestor else {continue}
                let target=table.convert(cell,to:view),intersection=target.intersection(entry.rect)
                guard !intersection.isNull,intersection.width>0,intersection.height>0 else {continue}
                let point=NSPoint(x:intersection.midX,y:intersection.midY)
                guard cell.contains(view.convert(point,to:table)),entries.contains(where:{$0 === entry}) else {continue}
                let text:String?
                if owner.responds(to:selector) {
                    text=unsafeBitCast(owner.method(for:selector),to:Getter.self)(owner,selector,view,entry.tag,point,entry.data).map{$0.takeUnretainedValue() as String}
                } else {text=owner.description}
                if let text {help.append(text)}
                diagnostics.append("registered \(type(of:view)) owner=\(type(of:owner)) tag=\(entry.tag) rect=\(entry.rect) point=\(point) pathCell=\(cell) text=\((text ?? "nil").debugDescription)")
            }
            diagnostics.append("registrations=\(entries.count) matched=\(help.count) row=\(row) cell=\(cell)")
            return (help,diagnostics)
        }
    }
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"Status report rows \(line): "+message)}}
    static func views(_ view:NSView?)->[NSView] {
        guard let view else {return []}
        // Snapshot public ObjC children before traversing SwiftUI's native cells.
        typealias Getter=@convention(c)(AnyObject,Selector)->Unmanaged<NSArray>
        let selector=#selector(getter:NSView.subviews),get=unsafeBitCast(view.method(for:selector),to:Getter.self)
        let children=get(view,selector).takeUnretainedValue().copy() as! NSArray
        var result=[view]
        for index in 0..<children.count {
            let object=children.object(at:index) as AnyObject
            guard let native=object as? NSObject,native.isKind(of:NSView.self) else {continue}
            result += views(unsafeBitCast(object,to:NSView.self))
        }
        return result
    }
    struct AccessibilitySnapshot {var help:[String]=[],diagnostics:[String]=[]}
    static func accessibilitySnapshot(_ roots:[Any])->AccessibilitySnapshot {
        var result=AccessibilitySnapshot(),seen=Set<ObjectIdentifier>(),remaining=4096
        func property(_ object:NSObject,_ name:String)->AnyObject? {
            let selector=NSSelectorFromString(name)
            guard object.responds(to:selector) else{return nil}
            return object.perform(selector)?.takeUnretainedValue()
        }
        func visit(_ value:Any,_ depth:Int) {
            guard depth<48,remaining>0 else{return}
            remaining -= 1
            let help:String?,role:String?,label:String?,children:[Any],navigation:[Any]
            if let element=value as? NSAccessibilityProtocol {
                guard seen.insert(ObjectIdentifier(element as AnyObject)).inserted else{return}
                help=element.accessibilityHelp();role=element.accessibilityRole()?.rawValue;label=element.accessibilityLabel()
                children=element.accessibilityChildren() ?? []
                // AppKit can return reparenting cell proxies despite this getter's
                // typed Swift [NSAccessibilityElement] import. Read its NSArray
                // through the public Objective-C selector to retain those nodes.
                navigation=(value as? NSObject).flatMap{property($0,"accessibilityChildrenInNavigationOrder") as? [Any]} ?? []
            } else if let object=value as? NSObject {
                guard seen.insert(ObjectIdentifier(object)).inserted else{return}
                help=property(object,"accessibilityHelp") as? String;role=property(object,"accessibilityRole") as? String;label=property(object,"accessibilityLabel") as? String
                children=property(object,"accessibilityChildren") as? [Any] ?? [];navigation=property(object,"accessibilityChildrenInNavigationOrder") as? [Any] ?? []
            } else {
                if result.diagnostics.count<200{result.diagnostics.append("Dropped public AX node type=\(type(of:value)) depth=\(depth)")}
                return
            }
            if let help,!help.isEmpty{result.help.append(help)}
            if result.diagnostics.count<200{result.diagnostics.append("\(type(of:value)): role=\(role ?? "nil") label=\((label ?? "nil").debugDescription) help=\((help ?? "nil").debugDescription) children=\(children.count) navigation=\(navigation.count)")}
            for child in children+navigation{visit(child,depth+1)}
        }
        for root in roots{visit(root,0)}
        return result
    }
    static var helpUnverified=false,helpObserved=false,reportedHelpUnavailable=false
    static var helpStatus:String {helpUnverified ? "unverified-offscreen":(helpObserved ? "verified":"not-reached")}
    static func verifyHelp(_ window:NSWindow?,_ table:NSTableView,path:String,enabled:Bool=true)throws {
        let tableSnapshot=accessibilitySnapshot(views(table)),windowSnapshot=accessibilitySnapshot(views(window?.contentView))
        let tips=views(table).compactMap(\.toolTip)
        let registered=Tooltips.query(window,table:table,path:path)
        let actual=tableSnapshot.help+tips+registered.help
        let absolute=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(path).standardizedFileURL.path
        let hasRegistrations = !registered.help.isEmpty
        let observable=actual.contains{!$0.isEmpty} || hasRegistrations
        // This offscreen mode may expose no SwiftUI virtual text/help and no
        // public tooltip registration at all. That is an observation limit,
        // not evidence that a missing expected help string is acceptable.
        if !observable && !helpObserved {
            helpUnverified=true
            if !reportedHelpUnavailable {
                reportedHelpUnavailable=true
                print("UNVERIFIED: repository-file tooltip help; offscreen SwiftUI exposes no text AX/help, native tooltip or tooltip registration surface")
            }
            return
        }
        helpObserved=true
        let diagnostic="Full raw pathname tooltip/accessibility help disappeared; expected=\(path.debugDescription) expectedUTF8=\(Array(path.utf8)); absolute=\(absolute.debugDescription); tableHelp=\(tableSnapshot.help.map(\.debugDescription)); windowHelp=\(windowSnapshot.help.map(\.debugDescription)); toolTips=\(tips.map(\.debugDescription)); registered=\(registered.diagnostics); tableAX=\(tableSnapshot.diagnostics); windowAX=\(windowSnapshot.diagnostics)"
        if enabled {try require(actual.contains{$0.utf8.containsSubsequence(path.utf8)} && actual.contains{$0.utf8.containsSubsequence(absolute.utf8)},diagnostic)}
        else {try require(!actual.contains{$0.utf8.containsSubsequence(absolute.utf8)},"Disabled full-path help remained registered; "+diagnostic)}
    }
    static func wait(_ window:NSWindow?=nil,line:Int = #line,_ predicate:()->Bool)async throws {
        for _ in 0..<3000 {window?.contentView?.layoutSubtreeIfNeeded();if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Status report rows timeout \(line)")
    }
    static func flush()async {for _ in 0..<2 {await withCheckedContinuation {reply in DispatchQueue.main.async{reply.resume()}}}}
    static var drained:Bool {
        StatusWindowModel.activeOperations==0 && ResolveWindowModel.activeOperations==0 && RevertWindowModel.activeOperations==0 && ResolveWindowController.activeReleases==0 &&
        NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}
    }
    static func table(_ window:NSWindow?)async throws->NSTableView {
        try await wait(window){views(window?.contentView).compactMap{$0 as? NSTableView}.contains{$0.numberOfRows>=3 && $0.tableColumns.contains{$0.title=="Path"}}}
        return views(window?.contentView).compactMap{$0 as? NSTableView}.first{$0.numberOfRows>=3 && $0.tableColumns.contains{$0.title=="Path"}}!
    }
    static func expectedFont(_ prefs:UserDefaults)->NSFont {
        prefs.bool(forKey:"LogFontForFileListCtrl") ? MessageEditorFont.resolve(name:prefs.string(forKey:"LogFontName") ?? MessageEditorFont.defaultName,size:prefs.integer(forKey:"LogFontSize")):NSFont.systemFont(ofSize:NSFont.systemFontSize)
    }
    static func geometry(_ window:NSWindow?,_ table:NSTableView,_ prefs:UserDefaults,verb:String?)async throws {
        let font=expectedFont(prefs),bold=NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask),manager=NSLayoutManager()
        let required=max(manager.defaultLineHeight(for:font),manager.defaultLineHeight(for:bold))
        let visible=table.rows(in:table.visibleRect)
        if visible.location != NSNotFound {
            for row in visible.location..<min(NSMaxRange(visible),table.numberOfRows) {
                _=table.rowView(atRow:row,makeIfNecessary:true)
                for column in table.tableColumns.indices where !table.tableColumns[column].isHidden {_=table.view(atColumn:column,row:row,makeIfNecessary:true)}
            }
        }
        await flush()
        try await wait(window){!table.usesAutomaticRowHeights && table.rowSizeStyle == .custom && table.rowHeight>=required}
        // SwiftUI schedules native row placement after the public sizing
        // properties settle. Wait for that layout before judging clipping.
        try await wait(window){
            (0..<table.numberOfRows).allSatisfy {row in
                guard let native=table.rowView(atRow:row,makeIfNecessary:false) else{return true}
                let frame=native.convert(native.bounds,to:table),rect=table.rect(ofRow:row)
                return abs(frame.minY-rect.minY)<0.5 && abs(frame.height-rect.height)<0.5
            }
        }
        let spacing=table.intercellSpacing
        for row in 0..<table.numberOfRows {
            let rect=table.rect(ofRow:row)
            try require(abs(rect.height-table.rowHeight)<0.5,"Variable report row at \(row): \(rect)")
            if let native=table.rowView(atRow:row,makeIfNecessary:false) {
                let frame=native.convert(native.bounds,to:table)
                try require(abs(frame.minY-rect.minY)<0.5 && abs(frame.height-rect.height)<0.5,"Native row frame \(frame) disagrees with report row \(row): \(rect), font=\(font)")
            }
        }
        let markers=views(table).compactMap{$0 as? NativeListSelectionLabelMarker.Probe}.filter{!$0.retired}
        try require(!markers.isEmpty,"Real single-line report caption markers absent")
        var visibleMarkers=0
        for marker in markers where !marker.isHiddenOrHasHiddenAncestor {
            let frame=marker.convert(marker.bounds,to:table),row=table.row(for:marker)
            guard row>=0,NSLocationInRange(row,table.rows(in:table.visibleRect)),frame.height>0 else {continue}
            visibleMarkers += 1;let rect=table.rect(ofRow:row)
            try require(frame.height<=required+2 && frame.minY>=rect.minY-1 && frame.maxY<=rect.maxY+1,"Caption is multiline or clipped: \(frame) row \(rect)")
        }
        try require(visibleMarkers>0,"No visible report caption geometry checked")
        if let verb {
            let buttons=views(table).compactMap{$0 as? NSButton}.filter{($0.accessibilityLabel() ?? "").hasPrefix(verb+" ") && !$0.isHiddenOrHasHiddenAncestor}
            try require(!buttons.isEmpty,"Actual accessible \(verb) checkboxes absent")
            for button in buttons {
                let row=table.row(for:button);guard row>=0,NSLocationInRange(row,table.rows(in:table.visibleRect)) else {continue}
                let frame=button.convert(button.bounds,to:table),rect=table.rect(ofRow:row)
                try require(frame.minY>=rect.minY-1 && frame.maxY<=rect.maxY+1,"Checkbox clipped: \(frame) row \(rect)")
            }
        }
        for image in views(table).compactMap({$0 as? NSImageView}) where image.image != nil && !image.isHiddenOrHasHiddenAncestor {
            let row=table.row(for:image);guard row>=0,NSLocationInRange(row,table.rows(in:table.visibleRect)),image.bounds.height>0 else {continue}
            let frame=image.convert(image.bounds,to:table),rect=table.rect(ofRow:row)
            try require(frame.minY>=rect.minY-1 && frame.maxY<=rect.maxY+1,"Source icon exceeds report row")
        }
        try require(table.intercellSpacing==spacing,"Geometry altered native spacing")
    }
    @MainActor final class Context {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        let git=URL(fileURLWithPath:CommandLine.arguments[2]),suite="TurtleGit.StatusReportRows."+UUID().uuidString
        lazy var prefs=UserDefaults(suiteName:suite)!
        lazy var repo=GitRepository(root:directory,executable:git)
        let names=["alpha.txt",String(repeating:"long_雪_",count:15)+".txt","line\nbreak\tcafe\u{301}.txt"]
        var beforeHead=Data(),beforeIndex=Data(),beforeFiles=[Data](),owners=[NSWindowController]()
        func prepare(conflict:Bool)async throws {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            prefs.set(false,forKey:"LogFontForFileListCtrl");prefs.set(false,forKey:"FullRowSelect");prefs.set(1,forKey:"ShowListFullPathTooltip")
            prefs.set(true,forKey:"ShowListBackgroundImage");prefs.set(false,forKey:"Autocompletion")
            DialogGeometry.install(preferences:prefs)
            _=try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Report Rows"),("user.email","rows@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
            for name in names {try Data("base\n".utf8).write(to:directory.appendingPathComponent(name))}
            try await repo.stage(names);_=try await repo.commit(message:"base")
            if conflict {
                _=try await repo.run(["switch","-c","side"])
                for name in names {try Data("side\n".utf8).write(to:directory.appendingPathComponent(name))}
                try await repo.stage(names);_=try await repo.commit(message:"side")
                _=try await repo.run(["switch","main"])
            }
            for name in names {try Data("main\n".utf8).write(to:directory.appendingPathComponent(name))}
            if conflict {try await repo.stage(names);_=try await repo.commit(message:"main");_=try await repo.run(["merge","--no-edit","side"],successfulExitCodes:0...1)}
            beforeHead=try await repo.run(["rev-parse","HEAD"]).stdout;beforeIndex=try await repo.run(["ls-files","--stage","-z"]).stdout
            beforeFiles=try names.map{try Data(contentsOf:directory.appendingPathComponent($0))}
        }
        func unchanged()async throws {
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try await repo.run(["ls-files","--stage","-z"]).stdout
            try require(head==beforeHead && index==beforeIndex && names.map{try Data(contentsOf:directory.appendingPathComponent($0))}==beforeFiles,"Report layout mutated HEAD/index/working bytes")
        }
        func cleanup()async {
            for owner in owners.reversed(){owner.close()}
            for _ in 0..<3000 {if StatusReportRowsVerification.drained {break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)
        }
    }
    struct Owner {
        let controller:NSWindowController
        let update:()->Void
        let ready:()->Bool
        let selected:()->GitPathSet
        let copy:(NSPasteboard)->Void
        let verb:String?
    }
    static func makeOwner(_ c:Context,_ kind:String)async throws->Owner {
        if kind=="resolve" {
            let owner=ResolveWindowController(repository:c.repo,access:nil,paths:[],preferences:c.prefs),model=owner.model;c.owners.append(owner)
            owner.showWindow(nil);model.load();try await wait(owner.window){!model.busy && model.entries.count==c.names.count}
            return Owner(controller:owner,update:{model.objectWillChange.send()},ready:{!model.busy},selected:{model.selection},copy:{board in model.writeFileClipboard={board.clearContents();board.setString($0,forType:.string)};model.copyFileMenu(model.fileMenu([c.names[2]]),copy:.relativePaths)},verb:"Resolve")
        }
        if kind=="revert" {
            let owner=RevertWindowController(repository:c.repo,access:nil,preferences:c.prefs),model=owner.model;c.owners.append(owner)
            owner.showWindow(nil);model.setScope([]);try await wait(owner.window){!model.busy && model.entries.count==c.names.count}
            for column in model.availableColumns where column != .path {model.setColumn(column,visible:true)}
            return Owner(controller:owner,update:{model.objectWillChange.send()},ready:{!model.busy},selected:{model.highlighted},copy:{board in model.commands.clipboard=board;model.commands.copy([c.names[2]],information:.relativePaths)},verb:"Revert")
        }
        let owner=StatusWindowController(repository:c.repo,access:nil,defaults:c.prefs),model=owner.model;c.owners.append(owner)
        owner.showWindow(nil);model.reload();try await wait(owner.window){!model.busy && model.files.count==c.names.count}
        model.hasLFS=true;model.fileColumns.visible=Set(StatusListColumn.allCases)
        model.lfsOwners=[c.names[1]:"Long owner 雪\n"+String(repeating:"metadata ",count:16)]
        return Owner(controller:owner,update:{model.objectWillChange.send()},ready:{!model.busy},selected:{model.selection},copy:{board in model.clipboard=board;model.copy([c.names[2]],information:.relativePaths)},verb:nil)
    }
    static func selectionProbe(_ window:NSWindow?)throws->NativeListSelectionProbe.Probe {
        guard let probe=views(window?.contentView).compactMap({$0 as? NativeListSelectionProbe.Probe}).first else {throw Failure(description:"Actual Resolve selection/geometry adapter absent")}
        return probe
    }
    static func verify(_ c:Context,_ kind:String)async throws {
        let owner=try await makeOwner(c,kind),window=owner.controller.window,table=try await Self.table(window)
        try await geometry(window,table,c.prefs,verb:owner.verb)
        let initialHeight=table.rowHeight
        // Choose an actual file row, never a group heading. Resolve owns its
        // ordered conflict rows; the shared adapters expose exact original IDs.
        let adapters=views(window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}
        let selectedRow=adapters.first?.rows.firstIndex(where:{$0.entry != nil}) ?? 0
        table.selectRowIndexes(IndexSet(integer:selectedRow),byExtendingSelection:false)
        try await wait(window){!owner.selected().isEmpty && !table.selectedRowIndexes.isEmpty}
        let selected=owner.selected(),indexes=table.selectedRowIndexes
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};owner.copy(board)
        try require(board.string(forType:.string)?.utf8.elementsEqual((c.names[2]+"\n").utf8)==true,"Actual private clipboard changed original newline/Unicode bytes")
        if let verb=owner.verb {
            try require(views(table).compactMap{$0 as? NSButton}.contains{$0.accessibilityLabel()==verb+" "+c.names[2]},"Checkbox accessibility lost original raw pathname")
        }
        try verifyHelp(window,table,path:c.names[2])
        c.prefs.set(0,forKey:"ShowListFullPathTooltip");owner.update();await flush()
        try verifyHelp(window,table,path:c.names[2],enabled:false)
        c.prefs.set(1,forKey:"ShowListFullPathTooltip");owner.update();await flush()
        try verifyHelp(window,table,path:c.names[2])
        try require((kind=="resolve" ? FileState.conflicted:FileState.modified).icon.image() != nil,"Original source status icon missing")
        let primary=table.tableColumns.first{$0.title=="Path"}!
        primary.width=primary.minWidth
        c.prefs.set(true,forKey:"LogFontForFileListCtrl");c.prefs.set("Menlo",forKey:"LogFontName");c.prefs.set(26,forKey:"LogFontSize");owner.update()
        try await wait(window){table.rowHeight>initialHeight}
        try await geometry(window,table,c.prefs,verb:owner.verb)
        try require(owner.selected()==selected && table.selectedRowIndexes==indexes,"Live larger font lost nonempty selection")
        let large=table.rowHeight
        window?.appearance=NSAppearance(named:.darkAqua);window?.setContentSize(.init(width:1200,height:740))
        try await geometry(window,table,c.prefs,verb:owner.verb)
        c.prefs.set(false,forKey:"LogFontForFileListCtrl");owner.update();try await wait(window){table.rowHeight<large}
        try await geometry(window,table,c.prefs,verb:owner.verb)
        try require(owner.selected()==selected && table.selectedRowIndexes==indexes,"Font toggle restored height but dropped selection")
        try verifyHelp(window,table,path:c.names[2])
        try await c.unchanged()
        let originalDelegate=NativeListSelection.originalDelegate(of:table)
        let nativeRows=(0..<table.numberOfRows).compactMap{table.rowView(atRow:$0,makeIfNecessary:false)}
        func usesAdapterSubclass(_ row:NSTableRowView)->Bool {
            var cls:AnyClass?=object_getClass(row)
            while let current=cls {
                if String(cString:class_getName(current)).hasPrefix("TurtleGitLabelSelectionRow_"){return true}
                cls=class_getSuperclass(current)
            }
            return false
        }
        try require(!nativeRows.isEmpty && !nativeRows.contains(where:usesAdapterSubclass),"Selection adapter replaced native row class")
        if kind=="resolve" {
            let probe=try selectionProbe(window)
            probe.retire()
        } else {adapters.first?.stopObserving()}
        await flush()
        try require(table.usesAutomaticRowHeights && table.delegate === originalDelegate,"Adapter detach did not restore SwiftUI automatic sizing/original delegate")
        // AppKit may change its own observation classes while restoring sizing;
        // the adapter must never introduce its former isa-swapped subclass.
        try require(!nativeRows.contains(where:usesAdapterSubclass),"Selection detach introduced an adapter row subclass")
        owner.controller.close();try await wait{owner.controller.window?.contentViewController==nil};await flush()
        let closedHeight=table.rowHeight,closedAutomatic=table.usesAutomaticRowHeights
        c.prefs.set(true,forKey:"LogFontForFileListCtrl");c.prefs.set(32,forKey:"LogFontSize");owner.update();await flush()
        try require(table.rowHeight==closedHeight && table.usesAutomaticRowHeights==closedAutomatic,"Retired table accepted late geometry")
        let reopened=try await makeOwner(c,kind),fresh=try await Self.table(reopened.controller.window)
        try require(fresh !== table,"Reopen reused retired native table")
        try await geometry(reopened.controller.window,fresh,c.prefs,verb:reopened.verb)
        let freshDelegate=NativeListSelection.originalDelegate(of:fresh)
        let freshProbe:NativeListSelectionProbe.Probe?
        if kind=="resolve" {freshProbe=try selectionProbe(reopened.controller.window)} else {freshProbe=nil}
        reopened.controller.close()
        try await wait {reopened.controller.window?.contentViewController==nil && fresh.usesAutomaticRowHeights && fresh.delegate === freshDelegate && (freshProbe==nil || freshProbe?.settings==nil)}
        let retiredHeight=fresh.rowHeight
        c.prefs.set(40,forKey:"LogFontSize");reopened.update();await flush()
        try require(fresh.rowHeight==retiredHeight && fresh.usesAutomaticRowHeights && fresh.delegate === freshDelegate && (freshProbe==nil || freshProbe?.settings==nil),"Actual owner close failed to retire geometry/settings or accepted late update")
        try await c.unchanged()
    }
    static func main()async {
        NSApp.setActivationPolicy(.prohibited)
        let pairs=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.reportFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.reportOrder(_:relativeTo:)))),(class_getInstanceMethod(NSView.self,#selector(NSView.addToolTip(_:owner:userData:))),class_getInstanceMethod(NSView.self,#selector(NSView.reportAddToolTip(_:owner:userData:)))),(class_getInstanceMethod(NSView.self,#selector(NSView.removeToolTip(_:))),class_getInstanceMethod(NSView.self,#selector(NSView.reportRemoveToolTip(_:)))),(class_getInstanceMethod(NSView.self,#selector(NSView.removeAllToolTips)),class_getInstanceMethod(NSView.self,#selector(NSView.reportRemoveAllToolTips)))]
        for(a,b)in pairs {if let a,let b {method_exchangeImplementations(a,b)}}
        defer {for(a,b)in pairs.reversed() {if let a,let b {method_exchangeImplementations(a,b)}}}
        let c=Context(),kind=CommandLine.arguments[3]
        do {try await c.prepare(conflict:kind=="resolve");try await verify(c,kind);await c.cleanup();try require(drained,"Owned native report workers/windows survived cleanup");print("PASS: Status report rows "+kind+" native_geometry_pass help_status="+helpStatus)}
        catch {await c.cleanup();fputs("\(error)\n",stderr);exit(1)}
    }
}

private extension Collection where Element==UInt8 {
    func containsSubsequence<C:Collection>(_ value:C)->Bool where C.Element==UInt8 {let needle=Array(value);return needle.isEmpty || indices.contains{self[$0...].starts(with:needle)}}
}
