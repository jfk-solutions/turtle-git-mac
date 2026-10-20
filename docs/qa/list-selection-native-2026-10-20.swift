// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor enum ListSelectionVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func wait(_ ready:()->Bool)async throws {for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Native selection wait expired")}
    static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    @MainActor final class Rows:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        var notifications=0,checks=0
        func numberOfRows(in tableView:NSTableView)->Int {3}
        func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
            let cell=NSTableCellView(),field=NSTextField(labelWithString:column?.identifier.rawValue == "name" ? "Primary \(row) 雪":"Other \(row)")
            field.frame=NSRect(x:column?.identifier.rawValue == "name" ? 28:4,y:2,width:160,height:20);field.textColor=column?.identifier.rawValue == "name" ? .systemRed:.systemGreen
            field.font = .systemFont(ofSize:13);cell.textField=field;cell.addSubview(field)
            if column?.identifier.rawValue == "name" {let check=NSButton(checkboxWithTitle:"",target:self,action:#selector(toggle(_:)));check.frame=NSRect(x:2,y:2,width:22,height:20);cell.addSubview(check)}
            return cell
        }
        func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView? {let view=ColorRow();view.backgroundColor = .controlBackgroundColor;return view}
        func tableViewSelectionDidChange(_ notification:Notification){notifications+=1}
        @objc func toggle(_ sender:NSButton){checks+=1}
    }
    @MainActor final class ColorRow:NSTableRowView {
        override func drawBackground(in dirtyRect:NSRect){NSColor.systemYellow.withAlphaComponent(0.12).setFill();dirtyRect.fill()}
    }
    struct Item:Identifiable {let id:Int;let name:String}
    @MainActor struct SwiftUITable:View {
        let preferences:UserDefaults
        let items=[Item(id:0,name:"Actual SwiftUI label"),Item(id:1,name:"Second label")]
        @State private var selected:Set<Int>=[]
        var body:some View {Table(items,selection:$selected) {TableColumn("Name",value:\.name);TableColumn("Other"){_ in Text("Secondary")}}
            .background(NativeListSelectionProbe(preferences:preferences,primaryTitle:"Name",labelText:{index in items.indices.contains(index) ? items[index].name:nil}))}
    }
    static func capture(_ table:NSTableView,owner:NSWindow,preferences:UserDefaults,directory:URL,name:String)async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let origin=owner.frame.origin
        var partial:[String:URL]=[:]
        defer {owner.alphaValue=0;owner.setFrameOrigin(origin)}
        for full in [false,true] {
            preferences.set(full,forKey:"FullRowSelect");NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:preferences)
            for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                owner.alphaValue=0;owner.appearance=NSAppearance(named:appearance);owner.contentView?.appearance=owner.appearance
                owner.contentView?.layoutSubtreeIfNeeded();owner.displayIfNeeded();try await Task.sleep(nanoseconds:300_000_000)
                let screen=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:900)
                owner.setFrameOrigin(.init(x:screen.midX-owner.frame.width/2,y:screen.midY-owner.frame.height/2));owner.makeKey();owner.makeFirstResponder(table);owner.alphaValue=1;owner.displayIfNeeded()
                let hide=Task { @MainActor in try? await Task.sleep(nanoseconds:1_800_000_000);owner.alphaValue=0 }
                defer {hide.cancel();owner.alphaValue=0}
                try await Task.sleep(nanoseconds:120_000_000)
                let destination=directory.appendingPathComponent("list-selection-\(name)-\(full ? "full":"label")-\(suffix).png")
                try require(NativeListSelection.usesFullRowSelection(in:table)==full && table.selectedRowIndexes.contains(0),"Capture did not retain requested mode/selection")
                print("CAPTURE \(name) \(suffix) full=\(full) nativeStyle=\(table.selectionHighlightStyle.rawValue) selected=\(table.selectedRowIndexes) label=\(String(describing:NativeListSelection.labelRect(in:table,row:0)))")
                let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");process.arguments=["-x","-o","-l",String(owner.windowNumber),destination.path]
                process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
                try process.run();let deadline=Date().addingTimeInterval(5)
                while process.isRunning && Date()<deadline {try await Task.sleep(nanoseconds:10_000_000)}
                if process.isRunning {owner.alphaValue=0;process.terminate();process.waitUntilExit();throw Failure(description:"Owned selection capture timed out")}
                owner.alphaValue=0;hide.cancel();try require(process.terminationStatus==0,"WindowServer selection capture failed")
                try require(NSBitmapImageRep(data:Data(contentsOf:destination)) != nil,"Actual WindowServer selection PNG missing")
                if !full {partial[suffix]=destination}
                else if let previous=partial[suffix] {
                    let before=NSBitmapImageRep(data:try Data(contentsOf:previous))!,after=NSBitmapImageRep(data:try Data(contentsOf:destination))!
                    let row=table.rect(ofRow:0)
                    // A blank part of the secondary column is deliberately
                    // outside all primary text. Native full-row paint must
                    // differ here from the label-only WindowServer image.
                    let windowPoint=table.convert(NSPoint(x:min(table.visibleRect.maxX,row.maxX)-28,y:row.midY),to:nil)
                    let scale=CGFloat(after.pixelsWide)/owner.frame.width
                    let x=Int(windowPoint.x*scale),y=Int((owner.frame.height-windowPoint.y)*scale)
                    var changed=0
                    for dy in -3...3 {for dx in -3...3 {
                        guard let a=before.colorAt(x:x+dx,y:y+dy)?.usingColorSpace(.deviceRGB),let b=after.colorAt(x:x+dx,y:y+dy)?.usingColorSpace(.deviceRGB) else{continue}
                        if abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent)>0.05 {changed+=1}
                    }}
                    try require(changed>20,"\(name) \(suffix): actual WindowServer full/label paint identical outside primary label")
                }
            }
        }
        preferences.set(false,forKey:"FullRowSelect");NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:preferences)
    }
    static func verify(root:URL,captureDirectory:URL?=nil,captureOnly:Bool=false)async throws {
        let suite="TurtleGit.ListSelection.Adapter."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"FullRowSelect")
        var windows=[NSWindow]()
        defer {windows.forEach{$0.contentView=nil;$0.close()};prefs.removePersistentDomain(forName:suite)}
        @MainActor func window(_ content:NSView)->NSWindow {let w=NSWindow(contentRect:.init(x:-16000,y:-16000,width:640,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false);w.isReleasedWhenClosed=false;w.alphaValue=0;w.contentView=content;w.orderFront(nil);windows.append(w);return w}
        let rows=Rows(),table=NativeListSelectionTableView(),scroll=NSScrollView()
        table.dataSource=rows;table.delegate=rows;table.rowHeight=24;table.allowsMultipleSelection=true
        let primary=NSTableColumn(identifier:.init("name")),other=NSTableColumn(identifier:.init("other"));primary.width=300;other.width=300;table.addTableColumn(primary);table.addTableColumn(other)
        scroll.documentView=table;scroll.hasVerticalScroller=true
        let owner=window(scroll);table.reloadData();table.layoutSubtreeIfNeeded()
        let beforeRow=table.rowView(atRow:0,makeIfNecessary:true)!,originalClass:AnyClass=object_getClass(beforeRow)!
        let originalTableStyle=table.selectionHighlightStyle,originalRowStyle=beforeRow.selectionHighlightStyle
        NativeListSelection.install(on:table,preferences:prefs,primaryColumn:primary)
        let host=NSHostingView(rootView:SwiftUITable(preferences:prefs)),swiftOwner=window(host)
        try await wait {host.layoutSubtreeIfNeeded();return views(host).compactMap{$0 as? NSTableView}.contains{NativeListSelection.usesFullRowSelection(in:$0)==false && $0.numberOfRows==2}}
        let swiftTable=views(host).compactMap{$0 as? NSTableView}.first{NativeListSelection.usesFullRowSelection(in:$0)==false}!
        swiftTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        if captureOnly {
            guard let captureDirectory else{throw Failure(description:"Capture-only requires destination")}
            table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)
            try await capture(table,owner:owner,preferences:prefs,directory:captureDirectory,name:"appkit")
            try await capture(swiftTable,owner:swiftOwner,preferences:prefs,directory:captureDirectory,name:"swiftui")
            NativeListSelection.remove(from:table);return
        }
        table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)
        try await wait {NativeListSelection.labelRect(in:table,row:0) != nil}
        let label=NativeListSelection.labelRect(in:table,row:0)!,cell=table.frameOfCell(atColumn:0,row:0)
        try require(label.minX>=cell.minX+24 && label.width<cell.width-80,"Highlight covered checkbox/icon or full primary column")
        try require(beforeRow.interiorBackgroundStyle == .normal && table.selectedRowIndexes==IndexSet([0,2]) && rows.notifications>0,"Label presentation altered native semantic selection/delegate")
        let check=views(table).compactMap{$0 as? NSButton}.first!;check.performClick(nil)
        try require(rows.checks==1,"Label overlay intercepted embedded checkbox")
        prefs.set(true,forKey:"FullRowSelect");NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:prefs)
        try require(NativeListSelection.usesFullRowSelection(in:table)==true && table.selectedRowIndexes==IndexSet([0,2]),"Default full row changed selection")
        prefs.set(false,forKey:"FullRowSelect");NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:prefs)
        table.moveColumn(0,toColumn:1)
        try await wait {table.layoutSubtreeIfNeeded();return NativeListSelection.labelRect(in:table,row:0)?.intersects(table.frameOfCell(atColumn:1,row:0))==true}
        let moved=NativeListSelection.labelRect(in:table,row:0)!
        try require(moved.intersects(table.frameOfCell(atColumn:1,row:0)),"Primary label identity lost after column reorder")
        owner.makeFirstResponder(table);table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let down=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:owner.windowNumber,context:nil,characters:"\u{f701}",charactersIgnoringModifiers:"\u{f701}",isARepeat:false,keyCode:125)!
        table.keyDown(with:down);try require(table.selectedRow==1,"Adapter intercepted native keyboard selection")
        NativeListSelection.remove(from:table)
        try require(object_getClass(beforeRow).map(ObjectIdentifier.init) == ObjectIdentifier(originalClass) && table.delegate === rows && table.selectedRow==1,"Detach failed to restore original row class/delegate/selection")
        try require(table.selectionHighlightStyle==originalTableStyle && beforeRow.selectionHighlightStyle==originalRowStyle,"Detach lost native table/row selection styles")
        swiftTable.layoutSubtreeIfNeeded()
        let swiftRow=swiftTable.rowView(atRow:0,makeIfNecessary:true)!
        try require(swiftRow.interiorBackgroundStyle == .normal && NativeListSelection.labelRect(in:swiftTable,row:0)!.width<swiftTable.rect(ofRow:0).width-40,"Actual SwiftUI Table ignored label-only style")
        let textRect=NativeListSelection.labelTextRect(in:swiftTable,row:0)!,rowRect=swiftTable.rect(ofRow:0)
        try require(textRect.height>0 && textRect.height<=rowRect.height && abs(textRect.midY-rowRect.midY)<0.5,"Fallback selected caption is not vertically centered in its native row")
        if let captureDirectory {
            table.moveColumn(1,toColumn:0);NativeListSelection.install(on:table,preferences:prefs,primaryColumn:primary)
            table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)
            try await capture(table,owner:owner,preferences:prefs,directory:captureDirectory,name:"appkit")
            try await capture(swiftTable,owner:swiftOwner,preferences:prefs,directory:captureDirectory,name:"swiftui")
            NativeListSelection.remove(from:table)
        }
        swiftOwner.close();owner.close()
        try require(NativeListSelection.originalDelegate(of:table) === rows,"Closed owner lost delegate restoration")
    }
}
