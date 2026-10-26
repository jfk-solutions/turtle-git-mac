// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func turtleGitBlameToolbarOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(NSPoint(x:-18000,y:-18000))
        turtleGitBlameToolbarOrder(place,relativeTo:number)
    }
}

@MainActor
@main struct BlameToolbarVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static var owners:[BlameWindowController]=[]
    static var otherWindows:[NSWindowController]=[]
    static var palettes:[NSToolbar]=[]
    static func phase(_ message:String){print("Blame toolbar phase: "+message);fflush(stdout)}
    static func finishPalette(_ toolbar:NSToolbar)throws {
        guard toolbar.customizationPaletteIsRunning else{return}
        let buttons=NSApp.windows.flatMap{views($0.contentView)}.compactMap{$0 as? NSButton}
        guard let done=buttons.first(where:{$0.title=="Done" && $0.action != nil}) else {
            phase("Palette native buttons: "+buttons.map{$0.title+":"+String(describing:$0.action)}.joined(separator:" | "))
            throw Failure(description:"AppKit customization palette has no native Done control")
        }
        done.performClick(nil)
    }
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {
        if !value {throw Failure(description:"Blame toolbar assertion at \(line): \(message)")}
    }
    static func wait(_ message:String,line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Blame toolbar timeout at \(line): \(message)")
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func identifier(_ id:String)->NSToolbarItem.Identifier {
        id=="space" ? .space:id=="flexibleSpace" ? .flexibleSpace:.init("TurtleGit.Blame.Command."+id)
    }
    static func item(_ id:String,in chrome:BlameToolbarController)throws->NSToolbarItem {
        guard let value=chrome.toolbar.items.first(where:{$0.itemIdentifier==identifier(id)}) else {throw Failure(description:"Missing native toolbar item: "+id)}
        return value
    }
    static func invoke(_ item:NSToolbarItem)throws {
        guard let action=item.action else {throw Failure(description:"Toolbar item has no native action")}
        try require(NSApp.sendAction(action,to:item.target,from:item),"Native toolbar target rejected dispatch")
    }
    static func invoke(_ item:NSMenuItem)throws {
        guard let action=item.action else {throw Failure(description:"Toolbar overflow item has no native action")}
        try require(NSApp.sendAction(action,to:item.target,from:item),"Native overflow target rejected dispatch")
    }
    static func drained()->Bool {
        BlameWindowModel.activeHistoryOperations==0 && BlameWindowModel.activeSyntaxRequests==0 && BlameDocumentOpener.activeReads==0
    }
    static func cleanup()async {
        phase("cleanup begin")
        for toolbar in palettes {try? finishPalette(toolbar)}
        for owner in owners {owner.model.busy=false;owner.close()}
        for owner in otherWindows {owner.close()}
        try? await wait("Owned Blame toolbar workers, palettes and windows drain") {
            drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}
        }
        phase("cleanup drained")
    }
    static func source(_ owner:BlameWindowController)throws->NSTextView {
        guard let value=views(owner.window?.contentView).compactMap({$0 as? NSTextView}).first(where:{$0.accessibilityLabel()=="Blame source text"}) else {throw Failure(description:"Blame source editor missing")}
        return value
    }
    static func settle(_ owner:BlameWindowController)async throws {
        try await wait("Blame document and actual source controls") {
            !owner.model.busy && !owner.model.syntaxWorking && owner.model.lines.count==3 && views(owner.window?.contentView).contains{($0 as? NSTextView)?.accessibilityLabel()=="Blame source text"}
        }
        owner.window?.contentView?.layoutSubtreeIfNeeded()
    }
    static func main()async {
        NSApp.setActivationPolicy(.prohibited)
        let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitBlameToolbarOrder(_:relativeTo:)))!
        method_exchangeImplementations(normal,hidden)
        do {try await verify();await cleanup();try require(drained(),"Final Blame workers survived cleanup");try require(NSApp.windows.allSatisfy{!$0.isVisible && $0.sheetParent==nil && $0.attachedSheet==nil},"Final owned panel/window survived cleanup")}
        catch {await cleanup();fputs("Blame toolbar failed: \(error)\n",stderr);method_exchangeImplementations(normal,hidden);exit(1)}
        method_exchangeImplementations(normal,hidden)
        print("PASS Blame toolbar: native defaults/icons, customization/palette/overflow, persistent named bars, live document routing and owned cleanup; Git HEAD/index/files unchanged")
    }
    static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repository=GitRepository(root:root,executable:git)
        _ = try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Blame Toolbar QA"),("user.email","toolbar@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repository.run(["config",key,value])}
        let firstPath="toolbar A 雪.txt",secondPath="toolbar B.txt",firstURL=root.appendingPathComponent(firstPath),secondURL=root.appendingPathComponent(secondPath)
        try Data("A first\nA original\nA last\n".utf8).write(to:firstURL)
        try Data("B original\nB middle\nB last\n".utf8).write(to:secondURL)
        try await repository.stage([firstPath,secondPath]);_ = try await repository.commit(message:"Toolbar parent")
        try Data("A first\nA changed\nA last\n".utf8).write(to:firstURL)
        try Data("B changed\nB middle\nB last\n".utf8).write(to:secondURL)
        try await repository.stage([firstPath,secondPath]);_ = try await repository.commit(message:"Toolbar current")
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),firstBytes=try Data(contentsOf:firstURL),secondBytes=try Data(contentsOf:secondURL)
        let suite="TurtleGit.BlameToolbar.Native."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"Blame.EnableLexer");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        DialogGeometry.install(preferences:prefs)
        defer {DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
        func owner(_ path:String)->BlameWindowController {
            let owner=BlameWindowController(repository:repository,access:nil,path:path,revision:"HEAD",options:GitBlameOptions(),preferences:prefs,requireScope:false)
            owners.append(owner);owner.commandKeyWindow={ [weak owner] in owner?.window };owner.window?.orderFront(nil);return owner
        }
        phase("open private documents")
        let first=owner(firstPath),second=owner(secondPath)
        try await settle(first);try await settle(second)
        guard let chrome=first.toolbarChrome,let other=second.toolbarChrome,let window=first.window else {throw Failure(description:"Native Blame toolbar owner missing")}
        let expected=["open","space","previousChange","nextChange","space","copy","space","about"]
        let store=BlameToolbarConfigurationStore(defaults:prefs)
        try require(chrome.toolbar !== other.toolbar && chrome.toolbar.identifier != other.toolbar.identifier,"Documents shared native toolbar ownership")
        try require(chrome.toolbar.items.map(\.itemIdentifier)==expected.map(identifier),"Pinned source five-button order/separators changed")
        try require(chrome.toolbarDefaultItemIdentifiers(chrome.toolbar)==expected.map(identifier),"Native palette default composition differs from source")
        try require(chrome.toolbar.allowsUserCustomization && !chrome.toolbar.autosavesConfiguration,"Native customization or private configuration ownership missing")
        let sourceIcons:[String:MenuIcon]=["open":.open,"previousChange":.jumpUp,"nextChange":.jumpDown,"copy":.copy,"about":.turtle]
        for id in ["open","previousChange","nextChange","copy","about"] {
            let native=try item(id,in:chrome)
            try require(native.image != nil && native.image?.tiffRepresentation==sourceIcons[id]!.image(size:20)?.tiffRepresentation,"Wrong source icon for \(id)")
            try require(native.menuFormRepresentation?.image != nil && native.menuFormRepresentation?.action != nil,"Overflow command missing native icon/action: \(id)")
        }
        let allowed=chrome.toolbarAllowedItemIdentifiers(chrome.toolbar)
        try require(BlameToolbarCommand.availableItemIDs.allSatisfy{allowed.contains(identifier($0))} && allowed.contains(.flexibleSpace),"Customization palette omits commands/encoding/spacers")
        for id in ["find","encoding.65001","wrap"] {
            let palette=chrome.toolbar(chrome.toolbar,itemForItemIdentifier:identifier(id),willBeInsertedIntoToolbar:false)
            try require(palette?.image != nil && palette?.paletteLabel.isEmpty==false,"Palette command/icon missing: \(id)")
        }
        // Exercise the real AppKit customization palette. NSWindow ordering is
        // intercepted before AppKit can put its panel onto the user's desktop.
        phase("open real AppKit customization palette")
        palettes.append(chrome.toolbar);chrome.customize()
        try await wait("Actual NSToolbar customization palette") {chrome.toolbar.customizationPaletteIsRunning}
        try require(NSApp.windows.allSatisfy{!$0.isVisible || $0.alphaValue==0},"Customization palette became visible")
        phase("finish palette through native Done control")
        try finishPalette(chrome.toolbar)
        try await wait("Native palette released its owner") {!chrome.toolbar.customizationPaletteIsRunning && window.attachedSheet==nil}
        phase("palette finished; reorder, display persistence and Open cancellation")
        let oldOpen=try item("open",in:chrome),oldOverflow=try item("open",in:chrome).menuFormRepresentation!
        chrome.toolbar.removeItem(at:0);chrome.toolbar.insertItem(withItemIdentifier:identifier("open"),at:chrome.toolbar.items.count)
        chrome.toolbar.displayMode = .iconOnly
        try await wait("AppKit reorder and display mode persistence") {store.load().standard.items.last=="open" && store.load().standard.displayMode == .icons}
        var pickerCalls=0
        var reply:((URL?)->Void)?
        first.chooseFile={panel,owner,completion in
            pickerCalls += 1;reply=completion
            panel.alphaValue=0;panel.setFrameOrigin(NSPoint(x:-18000,y:-18000))
            precondition(owner === window)
        }
        try invoke(oldOpen);try invoke(oldOverflow)
        try require(pickerCalls==0,"Removed native item retained its action authority")
        let liveOpen=try item("open",in:chrome)
        try invoke(liveOpen)
        try require(pickerCalls==1 && first.model.openingDocument,"Live Open failed to route to its own document")
        let cancelReply=reply;cancelReply?(nil)
        try require(!first.model.openingDocument,"Cancelled native Open left owner blocked")
        chrome.toolbar.displayMode = .labelOnly
        try await wait("Label-only mode saved") {store.load().standard.displayMode == .labels}
        chrome.reset()
        try require(chrome.toolbar.items.map(\.itemIdentifier)==expected.map(identifier) && store.load()==BlameToolbarConfiguration.defaults,"Reset did not restore source defaults")

        // Named bars are simultaneous native rows; editor sessions are the only
        // configuration receipts permitted while their owner has a sheet.
        phase("named toolbar editor and native rows")
        chrome.edit()
        guard let editor=chrome.editor,let editorWindow=editor.window else {throw Failure(description:"Toolbar editor missing")}
        try await wait("Owned toolbar editor sheet") {editorWindow.sheetParent === window}
        try require(editorWindow.alphaValue==0 && !chrome.available,"Editor sheet did not hide/block its owning commands")
        let session=editor.sessionID
        let beforeUnauthorized=chrome.configuration
        var unauthorized=chrome.configuration.standard;unauthorized.items=["about"]
        chrome.update(unauthorized)
        try require(chrome.configuration==beforeUnauthorized,"Sessionless edit mutated attached customization sheet")
        guard let review=chrome.createBar(name:"Review",session:session),let inspect=chrome.createBar(name:"Inspect",session:session) else {throw Failure(description:"Named toolbar creation failed")}
        var reviewBar=chrome.configuration.customBars.first{$0.id==review}!
        reviewBar.items=["find","space","wrap","copy","about"];reviewBar.displayMode = .iconsAndLabels;chrome.update(reviewBar,session:session)
        var inspectBar=chrome.configuration.customBars.first{$0.id==inspect}!
        inspectBar.items=["open","encoding.65001","zoomIn"];inspectBar.displayMode = .labels;chrome.update(inspectBar,session:session)
        reviewBar.name="Review tools";chrome.update(reviewBar,session:session)
        var invalid=reviewBar;invalid.name="";chrome.update(invalid,session:session)
        try require(chrome.configuration.customBars.first{$0.id==review}?.name=="Review tools","Temporary empty rename removed or corrupted toolbar")
        invalid.name="Inspect";chrome.update(invalid,session:session)
        try require(chrome.configuration.customBars.count==2 && chrome.configuration.customBars.first{$0.id==review}?.name=="Review tools","Duplicate rename corrupted toolbar")
        chrome.moveBar(inspect,offset:-1,session:session)
        try require(chrome.configuration.customBars.map(\.id)==[inspect,review],"Named toolbar order did not change")
        try require(chrome.createBar(name:"Expired",session:UUID())==nil,"Unknown editor session mutated layout")
        editor.closeEditor()
        try await wait("Toolbar editor released") {chrome.editor==nil && window.attachedSheet==nil}
        try require(chrome.createBar(name:"Expired",session:session)==nil,"Closed editor receipt retained mutation authority")
        try await wait("Simultaneous named native rows installed") {views(window.contentView).filter{$0 is BlameToolbarStrip}.count==2}
        let strip=BlameToolbarStrip(frame:NSRect(x:0,y:0,width:900,height:34))
        strip.configure(chrome:chrome,bar:reviewBar);strip.layoutSubtreeIfNeeded()
        let namedButtons=strip.subviews.compactMap{$0 as? NSButton}.filter{!($0 is NSPopUpButton)}
        try require(namedButtons.map(\.title)==["find","wrap","copy","about"].map(BlameToolbarController.title),"Named native controls lost composition/order")
        try require(namedButtons.allSatisfy{$0.image != nil},"Named icon-and-label controls lack icons")
        guard let attachedStrip=views(window.contentView).compactMap({$0 as? BlameToolbarStrip}).first(where:{$0.barID==review && $0.window === window}) else {throw Failure(description:"Actual attached named toolbar missing")}
        let attachedSize=attachedStrip.frame.size
        attachedStrip.setFrameSize(NSSize(width:180,height:34));attachedStrip.needsLayout=true;attachedStrip.layoutSubtreeIfNeeded()
        guard let overflow=attachedStrip.subviews.compactMap({$0 as? NSPopUpButton}).first,let overflowMenu=overflow.menu else {throw Failure(description:"Actual named overflow menu missing")}
        try require(!overflow.isHidden && overflowMenu.items.count>1 && overflowMenu.items.dropFirst().allSatisfy{$0.image != nil && $0.action != nil},"Narrow named bar lost native overflow icons/actions")
        var aboutCalls=0;chrome.showAbout={aboutCalls += 1}
        let overflowAbout=overflowMenu.items.first{$0.title==BlameToolbarController.title("about")}!
        try invoke(overflowAbout);try require(aboutCalls==1,"Named overflow About failed bound-owner dispatch")
        reviewBar.isVisible=false;chrome.update(reviewBar)
        try invoke(overflowAbout);try require(aboutCalls==1,"Hidden named bar retained overflow action authority")
        reviewBar.isVisible=true;chrome.update(reviewBar)
        try invoke(overflowAbout);try require(aboutCalls==1,"Obsolete custom layout receipt remained active")
        attachedStrip.setFrameSize(attachedSize)
        reviewBar.displayMode = .icons;chrome.update(reviewBar)
        func currentNamedButton()->NSButton? {
            views(window.contentView).compactMap{$0 as? BlameToolbarStrip}.filter{$0.barID==review && $0.window === window}.flatMap{$0.subviews.compactMap{$0 as? NSButton}}.first{$0.toolTip==BlameToolbarController.title("about") && $0.title.isEmpty && chrome.authenticatedPointerSource($0)}
        }
        try await wait("Attached current icon-only named button") {currentNamedButton() != nil}
        guard let currentButton=currentNamedButton() else {throw Failure(description:"Current attached named button missing")}
        try require(currentButton.title.isEmpty && currentButton.image != nil && currentButton.window === window,"Icon-only named control lost native ownership/display mode")
        try require(NSApp.sendAction(currentButton.action!,to:currentButton.target,from:currentButton),"Custom button target missing")
        try require(aboutCalls==2,"Current named button failed dispatch")
        chrome.removeBar(inspect)
        try require(chrome.configuration.customBars.map(\.id)==[review],"Named toolbar deletion failed")
        let restored=owner(secondPath);try await settle(restored)
        guard let reopened=restored.toolbarChrome else {throw Failure(description:"Reopened toolbar missing")}
        try require(reopened.configuration==chrome.configuration && reopened.configuration.customBars.first?.items==reviewBar.items,"Named bars did not survive document reopen")
        restored.close()
        try require(store.load().customBars.map(\.id)==[review],"Closing a second document erased another document's saved custom bars")
        var flexBar=reviewBar;flexBar.items=["find","flexibleSpace","about"]
        chrome.update(flexBar);strip.setFrameSize(NSSize(width:900,height:34));strip.configure(chrome:chrome,bar:flexBar);strip.layoutSubtreeIfNeeded()
        let flexButtons=strip.subviews.compactMap{$0 as? NSButton}.filter{!($0 is NSPopUpButton)}
        try require(flexButtons.count==2 && flexButtons[1].frame.minX-flexButtons[0].frame.maxX>200,"Flexible spacer failed to absorb custom-row slack")
        chrome.update(reviewBar)
        let toggle=chrome.button("wrap",mode:.icons,barID:review)
        try require(toggle.state==(chrome.checked("wrap") ? .on:.off),"Custom toggle failed to reflect live checked state")
        let encodingButton=chrome.button("encoding.automatic",mode:.icons,barID:review)
        try require(encodingButton.state == .on,"Automatic encoding choice lost checked state")

        // Hidden toolbars retain menu access; native targets stay document-bound
        // while the menu context resolves whichever live window is focused.
        phase("hidden menus, private source Copy and command blocking")
        var standard=chrome.configuration.standard;standard.isVisible=false;chrome.update(standard)
        let context=BlameMenuContext(keyWindow:{second.window})
        let firstWrap=first.model.wrapLongLines,secondWrap=second.model.wrapLongLines
        context.perform(.wrap)
        try require(second.model.wrapLongLines != secondWrap && first.model.wrapLongLines==firstWrap,"Menu context changed the wrong live document")
        let hiddenContext=BlameMenuContext(keyWindow:{first.window});hiddenContext.perform(.toolbar)
        try await wait("Hidden toolbar restored through View menu") {first.model.showToolbar && chrome.toolbar.isVisible}
        var changed=chrome.configuration.standard;changed.items += ["find","wrap"];chrome.update(changed)
        try invoke(try item("find",in:chrome))
        try await wait("Native toolbar Find panel") {first.findWindow?.window != nil}
        try require(first.findWindow?.model === first.model && second.findWindow==nil,"Toolbar Find opened against wrong model")
        first.findWindow?.close()
        let editorView=try source(first),pasteboard=NSPasteboard.withUniqueName()
        defer {pasteboard.releaseGlobally()}
        first.model.writeClipboard={value in pasteboard.clearContents();pasteboard.setString(value,forType:.string)}
        editorView.setSelectedRange(NSRange(location:0,length:7));window.makeFirstResponder(editorView);chrome.refresh()
        try require(chrome.enabled("copy"),"Copy target failed owner source validation")
        try invoke(try item("copy",in:chrome))
        try require(pasteboard.string(forType:.string)=="A first","Toolbar Copy did not use private owner source clipboard")
        first.model.busy=true;chrome.refresh()
        let blockedWrap=first.model.wrapLongLines
        try invoke(try item("wrap",in:chrome));chrome.perform("about");chrome.edit();chrome.customize()
        try require(first.model.wrapLongLines==blockedWrap && aboutCalls==2 && chrome.editor==nil && !chrome.available,"Busy document accepted toolbar commands")
        first.model.busy=false;chrome.refresh()
        let blocking=NSPanel(contentRect:NSRect(x:0,y:0,width:220,height:100),styleMask:.titled,backing:.buffered,defer:false);blocking.alphaValue=0
        window.beginSheet(blocking,completionHandler:nil);chrome.refresh()
        try invoke(try item("open",in:chrome));chrome.perform("about")
        try require(pickerCalls==1 && aboutCalls==2,"Attached sheet allowed document command reentry")
        window.endSheet(blocking);blocking.close()
        try await wait("Blocking sheet released") {window.attachedSheet==nil}
        phase("same-window replacement and stale toolbar targets")
        let oldModel=first.model,oldItem=try item("open",in:chrome),oldMenu=chrome.menuItem("about")
        try invoke(oldItem)
        try require(pickerCalls==2 && first.model.openingDocument,"Second native Open did not begin")
        reply?(secondURL)
        try await wait("Same window receives new Blame document") {first.model !== oldModel && !first.model.busy && first.model.path==secondPath}
        try await settle(first)
        guard let replacement=first.toolbarChrome else {throw Failure(description:"Replacement toolbar missing")}
        try require(!chrome.live && oldModel.retired && replacement !== chrome && window.toolbar === replacement.toolbar,"Document replacement retained old toolbar/model ownership")
        try invoke(oldItem);try invoke(oldMenu);chrome.update(reviewBar);chrome.edit()
        try require(pickerCalls==2 && aboutCalls==2 && chrome.editor==nil,"Retired toolbar retained native target/editor authority")
        let replacementWrap=first.model.wrapLongLines
        replacement.perform("wrap")
        try require(first.model.wrapLongLines != replacementWrap && second.model.wrapLongLines != secondWrap,"Replacement command failed live-model binding")
        // A background document's active editor must merge the current shared
        // standard layout before saving a new custom bar or closing its owner.
        phase("two-owner configuration merge and editor cleanup")
        other.edit()
        guard let otherEditor=other.editor else {throw Failure(description:"Second document editor missing")}
        var latestStandard=replacement.configuration.standard
        latestStandard.items=["about","space","open","copy"]
        replacement.update(latestStandard)
        guard let merged=other.createBar(name:"Merged owner",session:otherEditor.sessionID) else {throw Failure(description:"Background editor merge failed")}
        try require(other.toolbar.items.map(\.itemIdentifier)==latestStandard.items.map(identifier),"Background editor did not reconcile adopted standard native items")
        second.close()
        try require(store.load().standard.items==latestStandard.items && store.load().customBars.contains{$0.id==merged},"Closing background editor clobbered shared standard/custom composition")
        replacement.edit();let closingEditor=replacement.editor
        first.close()
        try await wait("Closing document retires customization child") {replacement.editor==nil && closingEditor?.window?.sheetParent==nil && closingEditor?.window?.isVisible != true}
        try require(!replacement.live && first.model.retired,"Closed document retained toolbar authority")
        // Malformed/unknown saved commands restore only known native items.
        phase("unknown restore and late picker close")
        var unknown=BlameToolbarConfiguration.defaults;unknown.standard.items=["unknown.future","open","open","space","about"]
        prefs.set(try JSONEncoder().encode(unknown),forKey:BlameToolbarConfigurationStore.defaultKey)
        let sanitized=owner(firstPath);try await settle(sanitized)
        try require(sanitized.toolbarChrome?.configuration.standard.items==["open","space","about"],"Unknown stored item broke bounded native restore")
        sanitized.toolbarChrome?.reset();sanitized.close()
        let deferred=owner(firstPath);try await settle(deferred)
        var lateReply:((URL?)->Void)?
        deferred.chooseFile={_,_,completion in lateReply=completion}
        guard let deferredChrome=deferred.toolbarChrome else {throw Failure(description:"Deferred owner toolbar missing")}
        deferredChrome.perform("open")
        try require(deferred.model.openingDocument && lateReply != nil,"Deferred injected picker did not begin")
        deferred.close()
        lateReply?(secondURL)
        try require(deferred.model.retired && !deferredChrome.live && deferred.toolbarChrome==nil,"Late picker completion resurrected closed toolbar/document")
        strip.clear()
        phase("Git preservation and completed workflow")
        try require(NSApp.windows.allSatisfy{!$0.isVisible || $0.alphaValue==0},"Owned toolbar workflow exposed a window")
        try require(try await repository.run(["rev-parse","HEAD"]).stdout==head,"Toolbar workflows changed HEAD")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Toolbar workflows changed index bytes")
        try require(try Data(contentsOf:firstURL)==firstBytes && Data(contentsOf:secondURL)==secondBytes,"Toolbar workflows changed working files")
    }
}
