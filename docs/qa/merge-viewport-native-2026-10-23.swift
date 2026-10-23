// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum MergeViewportVerification {
    typealias Base=MergePaneInputVerification
    static func require(_ value:Bool,_ message:String)throws{try Base.require(value,message)}
    static func views(_ window:NSWindow?)->[NSTextView] {
        MergeMarkedWordInterface.panes(in:window?.contentView).filter{!$0.isHiddenOrHasHiddenAncestor && ($0 as? MergePaneInputTextView)?.paneInputAllowed==true}
    }
    static func allItems(_ menu:NSMenu)->[NSMenuItem] {menu.items.flatMap{[$0]+($0.submenu.map(allItems) ?? [])}}
    static func item(_ title:String,in menu:NSMenu)throws->NSMenuItem {
        guard let found=allItems(menu).first(where:{$0.title==title}) else{throw Base.Failure(description:"Missing viewport menu: "+title)};return found
    }
    static func invoke(_ item:NSMenuItem) {
        if let target=item.target,let action=item.action {_=NSApp.sendAction(action,to:target,from:item)}
    }
    @MainActor struct Snapshot {
        let bytes:[Data],ranges:[NSRange],focus:NSResponder?,history:[Bool]
        init(_ views:[NSTextView],window:NSWindow){bytes=views.map{Data($0.string.utf8)};ranges=views.map{$0.selectedRange()};focus=window.firstResponder;history=views.flatMap{[$0.undoManager?.canUndo==true,$0.undoManager?.canRedo==true]}}
        func assertUnchanged(_ views:[NSTextView],window:NSWindow)throws {
            try require(bytes==views.map{Data($0.string.utf8)} && ranges==views.map{$0.selectedRange()} && focus === window.firstResponder,"Viewport command changed text, selection or focus")
            try require(history==views.flatMap{[$0.undoManager?.canUndo==true,$0.undoManager?.canRedo==true]},"Viewport command changed Undo/Redo state")
        }
    }
    static func exercise(_ window:NSWindow,menu:MergeEditorCommandMenu,preferences:UserDefaults,ready:()->Bool,dirty:()->Bool)async throws {
        try await Base.wait{ready()}
        FileHandle.standardError.write(Data("Viewport exercise: \(window.title) wrapped=\(views(window).map{$0.textContainer?.widthTracksTextView==true})\n".utf8))
        let panes=views(window);try require(panes.count>=2,"Actual multi-pane editors not registered")
        let scrolls=panes.compactMap{$0.enclosingScrollView};try require(scrolls.count==panes.count,"Pane lost its real viewport")
        let main=NSMenu(title:"Private merge viewport menu")
        menu.applicationMenu={main};menu.keyWindow={window};menu.install(in:main)
        defer{menu.remove();menu.applicationMenu={NSApp.mainMenu};menu.keyWindow={NSApp.keyWindow}}
        for direction in MergeViewportScrollCommand.allCases {
            let command=try item(direction.title,in:main)
            try require(command.keyEquivalent.isEmpty,"Viewport adaptation stole a native caret shortcut")
            try require(command.image != nil,"Viewport command omitted its directional icon")
            preferences.set(false,forKey:"ShowAppContextMenuIcons");_=menu.validateMenuItem(command)
            try require(command.image==nil,"Viewport icon ignored the owning menu preference")
            preferences.set(true,forKey:"ShowAppContextMenuIcons");_=menu.validateMenuItem(command)
            try require(menu.validateMenuItem(command),"Source viewport command disabled on ready editor")
        }
        window.makeFirstResponder(panes.last)
        func caret(in pane:NSTextView)->Int {
            guard let cells=try? Base.cells(pane),let fold=try? Base.layout(pane) else{return min(2,pane.string.utf16.count)}
            let row=fold.controller?.folding.visibility.firstIndex(of:.shown) ?? 0
            return Base.offset(row,cells)+min(2,cells[row].displayText.utf16.count)
        }
        for pane in panes {pane.setSelectedRange(NSRange(location:caret(in:pane),length:0))}
        try await Base.wait{ready()}
        // Put all views away from each edge; commands must advance every pane
        // exactly once rather than cascading linked-scroll notifications.
        for scroll in scrolls {
            let origin=scroll.contentView.constrainBoundsRect(NSRect(origin:CGPoint(x:40,y:60),size:scroll.contentView.bounds.size)).origin
            scroll.contentView.scroll(to:origin);scroll.reflectScrolledClipView(scroll.contentView)
        }
        let snapshot=Snapshot(panes,window:window),wasDirty=dirty()
        for direction in [MergeViewportScrollCommand.down,.up,.right,.left] {
            let before=scrolls.map{$0.contentView.bounds.origin}
            let expected=scrolls.enumerated().map{index,scroll->CGPoint in
                let view=panes[index],font=view.font!,line=view.layoutManager!.defaultLineHeight(for:font)
                let cell=("X" as NSString).size(withAttributes:[.font:font]).width
                var origin=before[index]
                switch direction {case .up:origin.y-=max(1,line);case .down:origin.y+=max(1,line);case .left:origin.x-=max(1,cell);case .right:origin.x+=max(1,cell)}
                return scroll.contentView.constrainBoundsRect(NSRect(origin:origin,size:scroll.contentView.bounds.size)).origin
            }
            invoke(try item(direction.title,in:main))
            try require(scrolls.map{$0.contentView.bounds.origin}==expected,"All-pane one-cell viewport increment differs: \(direction)")
            try snapshot.assertUnchanged(panes,window:window);try require(dirty()==wasDirty,"Viewport movement dirtied the document")
        }
        // Each axis clamps at its own clip boundary; repeating an edge command
        // leaves every source record and caret intact.
        // A ruler contributes a positive leading clip inset. Zero is then
        // inside the horizontal scroll range, not the native leading edge.
        for scroll in scrolls {scroll.contentView.scroll(to:scroll.contentView.constrainBoundsRect(NSRect(origin:CGPoint(x:-1000000,y:-1000000),size:scroll.contentView.bounds.size)).origin)}
        let edge=scrolls.map{$0.contentView.bounds.origin}
        invoke(try item("Line Up",in:main));let afterUp=scrolls.map{$0.contentView.bounds.origin}
        invoke(try item("Line Left",in:main));let afterLeft=scrolls.map{$0.contentView.bounds.origin}
        if afterLeft != edge {
            let geometry=scrolls.map{scroll in
                "min=\(scroll.contentView.constrainBoundsRect(NSRect(origin:CGPoint(x:-1000000,y:-1000000),size:scroll.contentView.bounds.size)).origin),insets=\(scroll.contentView.contentInsets),frame=\(String(describing:scroll.documentView?.frame)),clip=\(scroll.contentView.bounds)"
            }.joined(separator:"; ")
            FileHandle.standardError.write(Data("Viewport edge diagnostic window=\(window.title) wrap=\(panes.map{$0.textContainer?.widthTracksTextView==true}) edge=\(edge) up=\(afterUp) left=\(afterLeft) geometry=[\(geometry)]\n".utf8))
        }
        try require(afterLeft==edge,"Viewport scrolled before the leading edge")
        try snapshot.assertUnchanged(panes,window:window)
        // No source accelerator exists. The ordinary arrow still moves a caret.
        guard let active=panes.last else{return}
        let start=caret(in:active)
        active.setSelectedRange(NSRange(location:start,length:0));active.moveRight(nil)
        try require(active.selectedRange()==NSRange(location:start+1,length:0),"Ordinary caret arrow was intercepted by viewport scrolling")
        let stale=try item("Line Down",in:main)
        menu.remove();menu.install(in:main)
        let settled=scrolls.map{$0.contentView.bounds.origin}
        invoke(stale)
        try require(scrolls.map{$0.contentView.bounds.origin}==settled,"Retained menu action revived across a focus epoch")
    }
    static func blocked(_ window:NSWindow,menu:MergeEditorCommandMenu,ready:()->Bool,setBusy:(Bool)->Void,setQuit:(Bool)->Void,perform:()->Void)async throws {
        try await Base.wait{ready()}
        let scrolls=views(window).compactMap{$0.enclosingScrollView},main=NSMenu(title:"Private blocked viewport menu")
        menu.applicationMenu={main};menu.keyWindow={window};menu.install(in:main)
        defer{menu.remove();menu.applicationMenu={NSApp.mainMenu};menu.keyWindow={NSApp.keyWindow}}
        let command=try item("Line Down",in:main)
        for kind in 0..<3 {
            let sheet=NSWindow(contentRect:NSRect(x:0,y:0,width:180,height:80),styleMask:.titled,backing:.buffered,defer:false)
            sheet.isReleasedWhenClosed=false
            FileHandle.standardError.write(Data("Viewport blocked ownership case: \(kind) \(window.title)\n".utf8))
            if kind==0 {setBusy(true)} else if kind==1 {setQuit(true)} else {window.beginSheet(sheet,completionHandler:{_ in})}
            let before=scrolls.map{$0.contentView.bounds.origin}
            invoke(command);perform()
            try require(scrolls.map{$0.contentView.bounds.origin}==before && !menu.validateMenuItem(command),"Busy/Quit/sheet owner accepted viewport input")
            if kind==0 {setBusy(false)} else if kind==1 {setQuit(false)} else {window.endSheet(sheet,returnCode:.cancel);sheet.close();try await Base.wait{sheet.sheetParent==nil && window.attachedSheet==nil}}
            try await Base.wait{ready()}
        }
        menu.retire();let before=scrolls.map{$0.contentView.bounds.origin};invoke(command)
        try require(scrolls.map{$0.contentView.bounds.origin}==before,"Retired menu moved a viewport")
    }
    static func verify()async throws {
        let fixture=try Base.Fixture()
        do {
            let texts=Base.contents(),pair=try await fixture.pair("viewport-pair",texts.0,texts.1)
            guard let pairWindow=pair.window,let pairMenu=pair.editorCommandMenu else{throw Base.Failure(description:"Compare menu owner missing")}
            try await exercise(pairWindow,menu:pairMenu,preferences:fixture.prefs,ready:{pair.model.canScrollViewport},dirty:{pair.model.dirty})
            pair.model.setCollapsed(true)
            try await Base.wait{pair.model.canScrollViewport && pair.model.folding.collapsed}
            let pairFold=pair.model.folding.folding.visibility
            try await exercise(pairWindow,menu:pairMenu,preferences:fixture.prefs,ready:{pair.model.canScrollViewport},dirty:{pair.model.dirty})
            try require(pair.model.folding.folding.visibility==pairFold,"Viewport scroll expanded Compare folds")
            pair.model.setWrapLines(true)
            try await Base.wait{pair.model.canScrollViewport && Base.wrapReady(views(pairWindow),wrapped:true)}
            try await exercise(pairWindow,menu:pairMenu,preferences:fixture.prefs,ready:{pair.model.canScrollViewport},dirty:{pair.model.dirty})
            try await blocked(pairWindow,menu:pairMenu,ready:{pair.model.canScrollViewport},setBusy:{pair.model.busy=$0},setQuit:{pair.model.confirmingQuit=$0},perform:{pair.model.scrollViewport(.down)})
            let merge=try await fixture.merge("viewport-merge",texts.0,texts.1)
            guard let mergeWindow=merge.window,let mergeMenu=merge.editorCommandMenu else{throw Base.Failure(description:"Merge menu owner missing")}
            try await exercise(mergeWindow,menu:mergeMenu,preferences:fixture.prefs,ready:{merge.model.canScrollViewport},dirty:{merge.model.dirty})
            merge.model.setCollapsed(true);merge.model.setWrapLines(true)
            try await Base.wait{merge.model.canScrollViewport && Base.wrapReady(views(mergeWindow),wrapped:true)}
            let sourceFold=merge.model.folding.folding.visibility,resultFold=merge.model.resultFolding.folding.visibility
            try await exercise(mergeWindow,menu:mergeMenu,preferences:fixture.prefs,ready:{merge.model.canScrollViewport},dirty:{merge.model.dirty})
            try require(merge.model.folding.folding.visibility==sourceFold && merge.model.resultFolding.folding.visibility==resultFold,"Viewport scroll expanded Merge folds")
            try await blocked(mergeWindow,menu:mergeMenu,ready:{merge.model.canScrollViewport},setBusy:{merge.model.busy=$0},setQuit:{merge.model.confirmingQuit=$0},perform:{merge.model.scrollViewport(.down)})
            try await fixture.cleanup()
        }catch{let error=error;try await fixture.cleanup();throw error}
    }
}
