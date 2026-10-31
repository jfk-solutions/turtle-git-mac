import AppKit
import Darwin
import ScreenCaptureKit
import TurtleGitCore

struct ImageToolbarVerification {
    @MainActor static weak var keyOwner:NSWindow?
    @MainActor static var phase="existing toolbar",diagnostics:()->String={""}
    @MainActor static func begin(_ name:String,_ state:@escaping()->String={""}) {phase=name;diagnostics=state;print("Image main-menu phase: "+name+"; "+state());fflush(stdout)}
    @MainActor static func require(_ value: @autoclosure () throws -> Bool, line: Int = #line) throws {
        let accepted:Bool
        do {accepted=try value()}
        catch {
            print("Image main-menu assertion threw: line=\(line) phase=\(phase); \(diagnostics()); error=\(error)");fflush(stdout)
            throw error
        }
        if !accepted {
            let state="line=\(line) phase=\(phase); \(diagnostics())"
            print("Image main-menu assertion failed: "+state);fflush(stdout)
            throw NSError(domain:"ImageToolbar assertion",code:line,userInfo:[NSLocalizedDescriptionKey:state])
        }
    }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw NSError(domain:"ImageToolbar timeout",code:line,userInfo:[NSLocalizedDescriptionKey:"\(phase); \(diagnostics())"])
    }
    @MainActor static func item(_ command: ImageEditorCommand, _ owner: ImageEditorToolbar) throws -> NSToolbarItem {
        guard let item = owner.toolbar.items.first(where: { $0.itemIdentifier == command.identifier }) else { throw NSError(domain: "Missing " + command.rawValue, code: 1) }
        return item
    }
    @MainActor static func commandIsEnabled(_ command:ImageEditorCommand,_ owner:ImageEditorToolbar)->Bool {
        guard let native=try? item(command,owner),native.isEnabled,let control=native.view as? NSControl else{return false}
        return control.isEnabled
    }
    @MainActor static func send(_ item: NSMenuItem) throws {
        try require(NSApp.sendAction(item.action!, to: item.target, from: item))
    }
    @MainActor static func send(_ item: NSToolbarItem) throws {
        if let button = item.view as? NSButton { button.performClick(nil) }
        else { try require(NSApp.sendAction(item.action!, to: item.target, from: item)) }
    }
    @MainActor static func capture(_ owner: NSWindowController, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["TURTLEGIT_IMAGE_TOOLBAR_CAPTURE"], let window = owner.window else { return }
        guard #available(macOS 14.4, *) else { throw NSError(domain: "Capture requires macOS 14.4", code: 1) }
        NSApp.setActivationPolicy(.accessory); owner.showWindow(nil); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for (appearance, suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named: appearance); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 300_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw NSError(domain: "Missing owned image window", code: 1) }
            let options = SCStreamConfiguration(); options.width = Int(window.frame.width * window.backingScaleFactor); options.height = Int(window.frame.height * window.backingScaleFactor)
            options.showsCursor = false; options.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            let bitmap = NSBitmapImageRep(cgImage: image)
            var coloredPixels = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       (c.redComponent > 0.8 && c.greenComponent < 0.2 && c.blueComponent < 0.2) || (c.blueComponent > 0.8 && c.redComponent < 0.2 && c.greenComponent < 0.2) { coloredPixels += 1 }
                }
            }
            try require(coloredPixels > 20)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + "-" + suffix + ".png"))
        }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.ImageToolbar." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        let originalMain=NSApp.mainMenu
        defer {keyOwner=nil;NSApp.mainMenu=originalMain;diagnostics={""};prefs.removePersistentDomain(forName:suite)}
        prefs.set(true,forKey:"ShowAppContextMenuIcons")
        UserDefaults.standard.setVolatileDomain(["TurtleGit.DiffTools": try JSONEncoder().encode(DiffToolPreferences())], forName: "NSArgumentDomain")
        let left = root.appendingPathComponent("left.png"), right = root.appendingPathComponent("right.png")
        let a = ImageOpenVerification.png(0), b = ImageOpenVerification.png(2)
        try a.write(to: left); try b.write(to: right)
        let owner = FileComparisonWindowController(images: try ImageFileComparison(base: left, destination: right), permissions: [], preferences: prefs)
        defer { owner.close() }
        let window=owner.window!,parent=owner.model,image=parent.imageViewerModel,toolbar=owner.imageToolbar!
        window.alphaValue=0;window.ignoresMouseEvents=true;keyOwner=window
        toolbar.keyWindow={keyOwner};toolbar.commandMenu.keyWindow={keyOwner}
        parent.load(); try await wait { !parent.busy && parent.imageComparison != nil }
        window.contentView?.layoutSubtreeIfNeeded()
        try await wait { image.nativeToolbarInstalled && toolbar.toolbar.items.count > 10 && (window as? ImageComparisonKeyRouting)?.imageKeyModel === image }
        try require(window.toolbar === toolbar.toolbar && owner.editorToolbar?.toolbar !== window.toolbar)
        let expected: [ImageEditorCommand] = [.overlay, .blend, .link, .widths, .heights, .fit, .original, .zoomIn, .zoomOut, .info, .vertical, .fileMenu, .viewMenu]
        try require(toolbar.toolbar.items.filter { $0.itemIdentifier != .space && $0.itemIdentifier != .flexibleSpace }.map(\.itemIdentifier) == expected.map(\.identifier))
        for command in expected where command.icon != nil {
            let entry = try item(command, toolbar)
            try require(entry.image != nil && entry.menuFormRepresentation?.image != nil && entry.toolTip == command.title)
        }
        try require(!toolbar.validateToolbarItem(try item(.blend, toolbar)))
        let staleBlend = try item(.blend, toolbar).menuFormRepresentation!
        let blend = image.blendAlpha; try send(staleBlend); try require(image.blendAlpha == blend)
        try send(try item(.overlay, toolbar)); try require(image.overlay && image.linked && image.alpha == 0.5)
        try require(!toolbar.validateToolbarItem(try item(.vertical, toolbar)) && !toolbar.validateToolbarItem(try item(.link, toolbar)))
        let oldVertical = image.vertical
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        try require(!window.performKeyEquivalent(with:key) && image.vertical==oldVertical)
        try send(staleBlend); try require(image.blendAlpha != blend)
        try send(try item(.overlay, toolbar)); try require(!image.overlay)
        let oldInfo = image.showInfo
        owner.editorOpenWorkflow = MergeEditorOpenWorkflow(window: window, permissions: [], preferences: prefs)
        toolbar.refresh(); try send(try item(.info, toolbar).menuFormRepresentation!)
        let infoKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34)!
        _ = window.performKeyEquivalent(with: infoKey)
        owner.openMergeDocument(nil)
        try require(window.attachedSheet == nil)
        try require(image.showInfo == oldInfo && !toolbar.validateToolbarItem(try item(.info, toolbar)))
        owner.editorOpenWorkflow?.retire(); owner.editorOpenWorkflow = nil
        parent.busy = true; toolbar.refresh(); try send(try item(.info, toolbar).menuFormRepresentation!); try require(image.showInfo == oldInfo)
        parent.busy = false; toolbar.refresh()
        let sheet = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 200,height: 100), styleMask: .titled, backing: .buffered, defer: false)
        sheet.alphaValue=0;sheet.ignoresMouseEvents=true
        window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -10000,y: -10000)); window.beginSheet(sheet, completionHandler: { _ in })
        toolbar.refresh(); try require(!toolbar.validateToolbarItem(try item(.info, toolbar)))
        try send(try item(.info, toolbar).menuFormRepresentation!); try require(image.showInfo == oldInfo)
        window.endSheet(sheet);sheet.orderOut(nil);try await wait{sheet.sheetParent==nil && window.attachedSheet==nil};sheet.close();window.orderOut(nil);toolbar.refresh()
        try send(try item(.info, toolbar)); try require(image.showInfo != oldInfo)
        try send(try item(.widths, toolbar)); try require(image.fitWidths)
        let viewMenu = ((try item(.viewMenu, toolbar)).view as! NSPopUpButton).menu!
        viewMenu.update(); try require(viewMenu.items.first(where: { $0.title == "Fit image widths" })?.state == .on)
        let wasDark = image.presentation.darkMode
        try send(viewMenu.items.first(where: { $0.title == "Dark Mode" })!); try require(image.presentation.darkMode != wasDark)
        try await mainMenuFamily(owner:owner,toolbar:toolbar,selection:false,files:(left,right),preferences:prefs,info:{image.showInfo},vertical:{image.vertical},busy:{parent.busy},heldReady:{parent.busy},holdBusy:{parent.busy=true},releaseBusy:{parent.busy=false})
        // Retained native overflow leaves must become inert when the owner closes.
        let retainedInfo = try item(.info, toolbar).menuFormRepresentation!
        let beforeBytes = [try Data(contentsOf: left), try Data(contentsOf: right)]
        try await capture(owner, name: "image-toolbar-comparison")
        window.close(); let after = image.showInfo; try send(retainedInfo)
        try require(image.showInfo == after && !toolbar.validateMenuItem(retainedInfo) && image.playing.isEmpty)
        try require([try Data(contentsOf: left), try Data(contentsOf: right)] == beforeBytes)

        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"]); _ = try await repo.run(["config", "user.name", "Image Toolbar"])
        _ = try await repo.run(["config", "user.email", "image-toolbar@example.invalid"]); _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try await repo.stage(["left.png", "right.png"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["switch", "-c", "side"]); try b.write(to: left); try await repo.stage(["left.png"]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch", "main"]); try ImageOpenVerification.png(1).write(to: left); try await repo.stage(["left.png"]); _ = try await repo.commit(message: "mine")
        do { _ = try await repo.run(["merge", "side"]); throw NSError(domain: "Expected conflict", code: 1) } catch is GitFailure {}
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let document = try await repo.imageConflictDocument(path: "left.png")!
        let conflict = ImageConflictWindowController(repository: repo, access: nil, document: document, preferences: prefs)
        defer { conflict.close() }
        let selection=conflict.imageToolbar!,selectionModel=conflict.model
        conflict.window?.alphaValue=0;conflict.window?.ignoresMouseEvents=true;keyOwner=conflict.window
        selection.keyWindow={keyOwner};selection.commandMenu.keyWindow={keyOwner}
        conflict.window?.contentView?.layoutSubtreeIfNeeded(); try await wait { !selectionModel.busy && selectionModel.nativeToolbarInstalled && selection.toolbar.items.count >= 8 && commandIsEnabled(.info,selection) && commandIsEnabled(.vertical,selection) }
        try require(selection.toolbar.items.filter { $0.itemIdentifier != .space && $0.itemIdentifier != .flexibleSpace }.map(\.itemIdentifier) == expected.filter { ![.overlay,.blend,.link,.widths,.heights].contains($0) }.map(\.identifier))
        try send(try item(.info, selection)); try require(selectionModel.showInfo)
        try send(try item(.vertical, selection)); try require(selectionModel.vertical)
        let stale = try item(.info, selection).menuFormRepresentation!
        selectionModel.reload(); let old = selectionModel.showInfo
        try send(stale); try require(selectionModel.showInfo == old && !selection.validateMenuItem(stale))
        try await wait { !selectionModel.busy && commandIsEnabled(.vertical,selection) }
        try send(try item(.vertical, selection)); try require(!selectionModel.vertical)
        var conflictReply:CheckedContinuation<[ImageConflictSide:ComparisonImage],Error>?,releaseConflictEarly=false
        let originalConflictDecode=selectionModel.decodeImages,conflictImages=selectionModel.images
        try await mainMenuFamily(owner:conflict,toolbar:selection,selection:true,files:(left,right),preferences:prefs,info:{selectionModel.showInfo},vertical:{selectionModel.vertical},busy:{selectionModel.busy},heldReady:{selectionModel.busy && conflictReply != nil},holdBusy:{releaseConflictEarly=false;selectionModel.decodeImages={_,_ in if releaseConflictEarly{return conflictImages};return try await withCheckedThrowingContinuation{conflictReply=$0}};selectionModel.reload()},releaseBusy:{releaseConflictEarly=true;conflictReply?.resume(returning:conflictImages);conflictReply=nil;selectionModel.decodeImages=originalConflictDecode})
        try await capture(conflict, name: "image-toolbar-selection")
        conflict.close(); try send(stale); try require(selectionModel.retired && selectionModel.showInfo == old && !selection.validateMenuItem(stale))
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index)
        guard let request=try ImageToolInvocation.parse(arguments:["--image-tool","--base",left.path,"--mine",right.path,"--theirs",left.path],currentDirectory:root.path) else {throw NSError(domain:"Missing local selection invocation",code:1)}
        let selectionDocument=try await Task.detached{try ImageSelectionDocument.capture(invocation:request)}.value
        let standalone=ImageSelectionWindowController(document:selectionDocument,permissions:[],preferences:prefs)
        defer{standalone.close()};standalone.window?.alphaValue=0;standalone.window?.ignoresMouseEvents=true;keyOwner=standalone.window
        let standaloneToolbar=standalone.imageToolbar!,standaloneModel=standalone.model
        standaloneToolbar.keyWindow={keyOwner};standaloneToolbar.commandMenu.keyWindow={keyOwner}
        try await wait{!standaloneModel.busy && standaloneModel.nativeToolbarInstalled}
        var standaloneReply:CheckedContinuation<[ImageConflictSide:ComparisonImage],Error>?,releaseStandaloneEarly=false
        let originalStandaloneDecode=standaloneModel.decodeImages,standaloneImages=standaloneModel.images
        try await mainMenuFamily(owner:standalone,toolbar:standaloneToolbar,selection:true,files:(left,right),preferences:prefs,info:{standaloneModel.showInfo},vertical:{standaloneModel.vertical},busy:{standaloneModel.busy},heldReady:{standaloneModel.busy && standaloneReply != nil},holdBusy:{releaseStandaloneEarly=false;standaloneModel.decodeImages={_,_ in if releaseStandaloneEarly{return standaloneImages};return try await withCheckedThrowingContinuation{standaloneReply=$0}};standaloneModel.reload()},releaseBusy:{releaseStandaloneEarly=true;standaloneReply?.resume(returning:standaloneImages);standaloneReply=nil;standaloneModel.decodeImages=originalStandaloneDecode})
        standalone.close();try await wait{!standaloneModel.hasPendingWork}
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(finalHead == head)
        print("PASS: Image toolbar completed: native source order/artwork, check states, overlay/menu/key gates, busy/sheet/retired refusal, source preview controls and selection mode, immutable input/HEAD/index. Owners closed.")
    }
}

@MainActor private final class ImageMenuNativeSentinel:NSObject {
    var opens=0,pastes=0
    var pasteAction:()->Void={}
    @objc func openDocument(_ sender:Any?) {opens+=1}
    @objc func paste(_ sender:Any?) {pastes+=1;pasteAction()}
}
extension ImageToolbarVerification {
    @MainActor static func key(_ window:NSWindow,_ text:String,_ code:UInt16,_ modifiers:NSEvent.ModifierFlags=[])->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
    }
    @MainActor static func leaf(_ command:ImageEditorCommand,_ menu:NSMenu)throws->NSMenuItem {
        guard let value=menu.items.first(where:{$0.identifier?.rawValue=="TurtleGit.Image."+command.rawValue}) else {throw NSError(domain:"Missing real main-menu leaf "+command.rawValue,code:1)};return value
    }
    @MainActor static func mainMenuFamily(owner:NSWindowController,toolbar:ImageEditorToolbar,selection:Bool,files:(URL,URL),preferences:UserDefaults,info:@escaping()->Bool,vertical:@escaping()->Bool,busy:@escaping()->Bool,heldReady:()->Bool,holdBusy:()->Void,releaseBusy:()->Void)async throws {
        let window=owner.window!,menuOwner=toolbar.commandMenu!,previous=NSApp.mainMenu
        let originalMenuSource=menuOwner.applicationMenu,originalKeySource=menuOwner.keyWindow
        let main=NSMenu(title:"Private image menu"),file=NSMenu(title:"Dateien QA"),edit=NSMenu(title:"Bearbeiten QA"),view=NSMenu(title:"Ansicht QA"),help=NSMenu(title:"Aide QA")
        let pasteboard=NSPasteboard.withUniqueName()
        defer{pasteboard.releaseGlobally()}
        try require(pasteboard.setString("PRIVATE-PASTE",forType:.string))
        let fileRoot=NSMenuItem(title:"Dateien QA",action:nil,keyEquivalent:""),viewRoot=NSMenuItem(title:"Ansicht QA",action:nil,keyEquivalent:""),helpRoot=NSMenuItem(title:"Aide QA",action:nil,keyEquivalent:"")
        let editRoot=NSMenuItem(title:"Bearbeiten QA",action:nil,keyEquivalent:"");editRoot.identifier = .init("org.turtlegit.merge.menu.edit")
        fileRoot.submenu=file;editRoot.submenu=edit;viewRoot.submenu=view;helpRoot.submenu=help
        let sentinel=ImageMenuNativeSentinel(),nativeOpen=NSMenuItem(title:"QA native Open",action:#selector(ImageMenuNativeSentinel.openDocument(_:)),keyEquivalent:"o")
        nativeOpen.target=sentinel;nativeOpen.keyEquivalentModifierMask = .command
        let nativePaste=NSMenuItem(title:"QA native Paste",action:#selector(ImageMenuNativeSentinel.paste(_:)),keyEquivalent:"v")
        nativePaste.target=sentinel;nativePaste.keyEquivalentModifierMask = .command;edit.addItem(nativePaste)
        let nativeClose=NSMenuItem(title:"QA native Close",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        nativeClose.keyEquivalentModifierMask = .command
        let nativeView=NSMenuItem(title:"QA native Full Screen",action:#selector(NSWindow.toggleFullScreen(_:)),keyEquivalent:""),nativeHelp=NSMenuItem(title:"QA retained Help",action:nil,keyEquivalent:"")
        file.addItem(nativeOpen);file.addItem(nativeClose);view.addItem(nativeView);help.addItem(nativeHelp)
        let decoyFile=NSMenuItem(title:"File",action:nil,keyEquivalent:""),decoyView=NSMenuItem(title:"View",action:nil,keyEquivalent:"")
        decoyFile.submenu=NSMenu(title:"Decoy File");decoyView.submenu=NSMenu(title:"Decoy View")
        for root in [decoyFile,fileRoot,editRoot,decoyView,viewRoot,helpRoot] {main.addItem(root)}
        var foreign:FileComparisonWindowController?,sheet:NSWindow?
        defer {
            releaseBusy()
            if let sheet {window.endSheet(sheet);sheet.orderOut(nil);sheet.close()}
            foreign?.close();keyOwner=window
            menuOwner.keyWindow={nil};toolbar.removeMainMenu()
            menuOwner.applicationMenu=originalMenuSource;menuOwner.keyWindow=originalKeySource;NSApp.mainMenu=previous
            // NSMenuItem targets are nonowning. Keep the private native action
            // owner and host menu alive through scoped shortcut restoration,
            // after the later field-editor cleanup defer has released them.
            withExtendedLifetime((sentinel,main)) {}
        }
        keyOwner=window;NSApp.mainMenu=main
        // AppKit may synthesize the standard Close All alternate while adopting
        // a main menu. Snapshot that real host before our image contribution.
        let baseFile=file.items.map(ObjectIdentifier.init),baseEdit=edit.items.map(ObjectIdentifier.init),baseView=view.items.map(ObjectIdentifier.init),baseRoots=main.items.map(ObjectIdentifier.init)
        menuOwner.applicationMenu={main};menuOwner.keyWindow={keyOwner};toolbar.installMainMenu()
        begin(selection ? "selection native File/View roles":"comparison native File/View roles",{"busy=\(busy()) keySame=\(keyOwner === window) sheet=\(String(describing:window.attachedSheet)) file=\(file.items.map{$0.title}) view=\(view.items.map{$0.title})"})
        let expectedFile:[ImageEditorCommand?]=selection ? [.reload]:[.open,.reload]
        let comparePrefix:[ImageEditorCommand?]=selection ? []:[.overlay,.blend,.link,.widths,.heights]
        let expectedView:[ImageEditorCommand?]=comparePrefix+[.fit,.original,.transparentColor,nil,.zoomOut,.zoomIn,nil,.info,.vertical,nil,.dark]
        func verifyRecipe(_ menu:NSMenu,_ expected:[ImageEditorCommand?])throws {
            let indices=menu.items.indices.filter{menu.items[$0].identifier?.rawValue.hasPrefix("TurtleGit.Image.")==true}
            guard let first=indices.first,let last=indices.last else {throw NSError(domain:"Empty owned image menu recipe",code:1)}
            let actual=menu.items[first...last].map{$0.isSeparatorItem ? "separator":$0.identifier?.rawValue ?? "foreign"}
            try require(actual==expected.map{$0.map{"TurtleGit.Image."+$0.rawValue} ?? "separator"})
            for command in expected.compactMap({$0}) {
                let entry=try leaf(command,menu)
                try require(entry.title==Bundle.main.localizedString(forKey:command.title,value:command.title,table:nil) && entry.image != nil && entry.target === menuOwner && entry.action != nil)
                let expectedKey:(String,NSEvent.ModifierFlags)
                switch command {
                case .open:expectedKey=("o",.command);case .vertical:expectedKey=("v",.command)
                case .overlay:expectedKey=("o",[]);case .fit:expectedKey=("f",[]);case .original:expectedKey=("s",[])
                case .widths:expectedKey=("w",[]);case .heights:expectedKey=("h",[]);case .info:expectedKey=("i",[])
                case .dark:expectedKey=("d",[]);case .zoomIn:expectedKey=("+",[]);case .zoomOut:expectedKey=("-",[])
                default:expectedKey=("",[])
                }
                let flags:NSEvent.ModifierFlags=[.command,.control,.option,.shift]
                let observedMask=entry.keyEquivalentModifierMask.intersection(flags)
                let keyState="command=\(command.rawValue) logical=\(String(reflecting:expectedKey.0))/\(expectedKey.1.rawValue) observed=\(String(reflecting:entry.keyEquivalent))/\(observedMask.rawValue)"
                print("Image menu key: "+keyState);fflush(stdout)
                try require(entry.keyEquivalent==expectedKey.0 && observedMask==expectedKey.1)
            }
        }
        try require(fileRoot.identifier == .init("org.turtlegit.merge.menu.file") && viewRoot.identifier == .init("org.turtlegit.merge.menu.view"))
        try verifyRecipe(file,expectedFile);try verifyRecipe(view,expectedView)
        begin("source recipes complete / native shortcut baseline",{"selection=\(selection) open=\(String(reflecting:nativeOpen.keyEquivalent)) paste=\(String(reflecting:nativePaste.keyEquivalent)) openTarget=\(nativeOpen.target === sentinel) pasteTarget=\(nativePaste.target === sentinel)"})
        try require(nativeOpen.keyEquivalent==(selection ? "o":"") && nativePaste.keyEquivalent.isEmpty && nativeOpen.target === sentinel && nativePaste.target === sentinel)
        begin("retained native roots and Help",{"decoyFile=\(decoyFile.submenu!.items.count) decoyView=\(decoyView.submenu!.items.count) help=\(help.items.map{$0.title}) retainedHelp=\(help.items.first === nativeHelp)"})
        try require(decoyFile.submenu!.items.isEmpty && decoyView.submenu!.items.isEmpty && help.items.count==1 && help.items[0] === nativeHelp)
        var infoItem=try leaf(.info,view)
        let initialInfo=info(),initialVertical=vertical()
        begin("first native Info action",{"info=\(info()) initial=\(initialInfo) state=\(infoItem.state.rawValue) enabled=\(menuOwner.validateMenuItem(infoItem))"})
        try send(infoItem);toolbar.refresh();try require(info() != initialInfo && infoItem.state == (info() ? .on:.off))
        begin("direct native View Info key equivalent",{"info=\(info()) initial=\(initialInfo) state=\(infoItem.state.rawValue) enabled=\(menuOwner.validateMenuItem(infoItem))"})
        try require(view.performKeyEquivalent(with:key(window,"i",34)));toolbar.refresh();try require(info()==initialInfo && infoItem.state == (initialInfo ? .on:.off))
        begin("owned native window Arrange keys",{"vertical=\(vertical()) initial=\(initialVertical) busy=\(busy())"})
        try require(window.performKeyEquivalent(with:key(window,"v",9,.command)));toolbar.refresh();try require(vertical() != initialVertical)
        try require(window.performKeyEquivalent(with:key(window,"v",9,.command)));toolbar.refresh();try require(vertical()==initialVertical)
        begin("native Reload and held busy dispatch",{"busy=\(busy()) info=\(info()) opens=\(sentinel.opens)"})
        let reload=try leaf(.reload,file)
        try send(reload);try require(busy());try await wait{!busy()};toolbar.refresh()
        holdBusy();try await wait{heldReady()};toolbar.refresh();try send(infoItem)
        try require(!menuOwner.validateMenuItem(infoItem) && info()==initialInfo && !window.performKeyEquivalent(with:key(window,"i",34)))
        try require(nativeOpen.keyEquivalent==(selection ? "o":"") && nativePaste.keyEquivalent.isEmpty)
        if !selection {
            let ownedOpen=try leaf(.open,file)
            // NSMenu consumes a matched disabled shortcut; the scoped owner
            // must refuse the action without falling through to native Open.
            try require(main.performKeyEquivalent(with:key(window,"o",31,.command)) && !menuOwner.validateMenuItem(ownedOpen) && sentinel.opens==0 && info()==initialInfo && vertical()==initialVertical && window.attachedSheet==nil)
        }
        releaseBusy();try await wait{!busy()};toolbar.refresh();try require(menuOwner.validateMenuItem(infoItem))
        begin("actual attached sheet disables image commands",{"busy=\(busy()) info=\(info()) sheet=\(String(describing:window.attachedSheet))"})
        let modal=NSWindow(contentRect:.init(x:-14000,y:-14000,width:220,height:100),styleMask:.titled,backing:.buffered,defer:false)
        modal.isReleasedWhenClosed=false;modal.alphaValue=0;modal.ignoresMouseEvents=true;sheet=modal
        window.beginSheet(modal,completionHandler:{_ in});toolbar.refresh();try send(infoItem)
        try require(!menuOwner.validateMenuItem(infoItem) && info()==initialInfo && !window.performKeyEquivalent(with:key(window,"i",34)))
        window.endSheet(modal);modal.orderOut(nil);try await wait{modal.sheetParent==nil && window.attachedSheet==nil};modal.close();sheet=nil;toolbar.refresh()
        begin("actual sheet detached / owner command gate drains",{"busy=\(busy()) infoEnabled=\(menuOwner.validateMenuItem(infoItem)) sheet=\(String(describing:window.attachedSheet))"})
        // Conflict/selection pane owners resume only after their asynchronous
        // sheet-observer drain, beyond the native sheet's physical detachment.
        try await wait{!busy() && menuOwner.validateMenuItem(infoItem)};toolbar.refresh()
        begin("actual field editor restores native Paste chord")
        let field=NSTextField(frame:.init(x:8,y:8,width:200,height:24));field.stringValue="PRIVATE-FIELD-";field.isEditable=true;field.isSelectable=true
        window.contentView!.addSubview(field)
        defer{_ = window.makeFirstResponder(nil);field.removeFromSuperview();sentinel.pasteAction={}}
        try require(window.makeFirstResponder(field));field.selectText(nil)
        guard let editor=window.firstResponder as? NSTextView,editor.isFieldEditor else {throw NSError(domain:"Private native field editor did not mount",code:#line)}
        sentinel.pasteAction={ [weak editor] in guard let editor,let value=pasteboard.string(forType:.string) else{return};editor.insertText(value,replacementRange:editor.selectedRange())}
        menuOwner.refresh()
        let verticalItem=try leaf(.vertical,view)
        try require(verticalItem.keyEquivalent.isEmpty && !menuOwner.validateMenuItem(verticalItem) && nativePaste.keyEquivalent=="v" && nativePaste.keyEquivalentModifierMask.intersection([.command,.control,.option,.shift]) == .command)
        let beforePasteInfo=info(),beforePasteVertical=vertical()
        try require(main.performKeyEquivalent(with:key(window,"v",9,.command)))
        try require(sentinel.pastes==1 && editor.string.contains("PRIVATE-PASTE") && info()==beforePasteInfo && vertical()==beforePasteVertical)
        try require(window.makeFirstResponder(nil));field.removeFromSuperview();sentinel.pasteAction={};menuOwner.refresh()
        begin("field editor ended / image shortcut restored",{"verticalKey=\(String(reflecting:verticalItem.keyEquivalent))/\(verticalItem.keyEquivalentModifierMask.rawValue) nativePaste=\(String(reflecting:nativePaste.keyEquivalent))/\(nativePaste.keyEquivalentModifierMask.rawValue) firstResponder=\(window.firstResponder.map{String(reflecting:type(of:$0))} ?? "nil") infoEnabled=\(menuOwner.validateMenuItem(infoItem)) busy=\(busy()) sheet=\(String(describing:window.attachedSheet))"})
        try require(try leaf(.vertical,view).keyEquivalent=="v" && nativePaste.keyEquivalent.isEmpty && menuOwner.validateMenuItem(infoItem))
        if !selection {
            try require(window.performKeyEquivalent(with:key(window,"o",31,.command)))
            try await wait{window.attachedSheet?.delegate is ImageLoadWindowController}
            let chooser=window.attachedSheet!.delegate as! ImageLoadWindowController
            try require(sentinel.opens==0);chooser.retire();try await wait{ImageLoadWindowController.activeReleases==0 && window.attachedSheet==nil};toolbar.refresh()
        }
        // A real second viewer claims this same native menu. Old A entries must
        // never dispatch to either its original model or the new key model.
        let other=FileComparisonWindowController(images:try ImageFileComparison(base:files.0,destination:files.1),permissions:[],preferences:preferences)
        foreign=other;other.window?.alphaValue=0;other.window?.ignoresMouseEvents=true
        other.imageToolbar?.keyWindow={keyOwner};other.imageToolbar?.commandMenu.keyWindow={keyOwner};other.imageToolbar?.commandMenu.applicationMenu={main}
        other.model.load();try await wait{!other.model.busy && other.model.imageComparison != nil}
        let otherImage=other.model.imageViewerModel,otherBefore=otherImage.showInfo
        try require(!window.performKeyEquivalent(with:key(other.window!,"i",34)) && info()==initialInfo)
        keyOwner=other.window;toolbar.refresh();other.imageToolbar?.installMainMenu()
        try send(infoItem);try require(info()==initialInfo && otherImage.showInfo==otherBefore && !menuOwner.validateMenuItem(infoItem))
        let otherInfo=try leaf(.info,view);try send(otherInfo);try require(otherImage.showInfo != otherBefore && info()==initialInfo)
        other.close();foreign=nil;keyOwner=window;toolbar.installMainMenu()
        try send(infoItem);try require(info()==initialInfo && !menuOwner.validateMenuItem(infoItem))
        infoItem=try leaf(.info,view)
        // A renamed/localized host root is resolved by native role identity.
        fileRoot.title="Fichiers QA";viewRoot.title="Visualisation QA";file.title=fileRoot.title;view.title=viewRoot.title
        toolbar.installMainMenu();try send(infoItem);try require(info()==initialInfo && !menuOwner.validateMenuItem(infoItem))
        try verifyRecipe(file,expectedFile);try verifyRecipe(view,expectedView)
        let afterRename=try leaf(.info,view);try send(afterRename);try require(info() != initialInfo);try send(afterRename);try require(info()==initialInfo)
        keyOwner=nil;toolbar.refresh()
        try require(file.items.map(ObjectIdentifier.init)==baseFile && edit.items.map(ObjectIdentifier.init)==baseEdit && view.items.map(ObjectIdentifier.init)==baseView && main.items.map(ObjectIdentifier.init)==baseRoots && nativeOpen.target === sentinel && nativeOpen.keyEquivalent=="o" && nativeClose.keyEquivalent=="w" && nativePaste.keyEquivalent=="v" && nativePaste.target === sentinel)
        try send(afterRename);try require(info()==initialInfo && !menuOwner.validateMenuItem(afterRename))
        // A later native shortcut edit is its new owner; retirement must not
        // overwrite it with the old leased Paste chord.
        keyOwner=window;toolbar.installMainMenu();nativePaste.keyEquivalent="x";nativePaste.keyEquivalentModifierMask = .command
        menuOwner.refresh();keyOwner=nil;toolbar.refresh()
        try require(nativePaste.keyEquivalent=="x" && nativePaste.target === sentinel && nativeOpen.keyEquivalent=="o" && file.items.map(ObjectIdentifier.init)==baseFile && edit.items.map(ObjectIdentifier.init)==baseEdit && view.items.map(ObjectIdentifier.init)==baseView)
        keyOwner=window
        print("PASS image native menus: role IDs with renamed roots, literal source recipes/icons/keys, real actions/checks, window-event admission, busy/sheet gates, actual foreign viewer/epoch fences and restored baseline objects; toolbar keyWindow seam only, no physical OS key-priority claim")
    }
}
