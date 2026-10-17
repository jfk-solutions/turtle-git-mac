import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import TurtleGitCore

@main struct ImportSourceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Import source wait at \(line)")
    }
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap {views($0)}}
    @MainActor static func capture(_ window:NSWindow)async throws {
        guard let output=ProcessInfo.processInfo.environment["TURTLEGIT_IMPORT_SOURCE_CAPTURE"] else{return}
        if #available(macOS 14.4,*) {
            let directory=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            for (appearance,theme) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
                let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
                guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned Import capture absent")}
                let config=SCStreamConfiguration();config.includeChildWindows=false;config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
                let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
                guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(description:"No Import PNG")}
                try png.write(to:directory.appendingPathComponent("import-patch-source-"+theme+".png"))
            };window.alphaValue=0
        } else{throw Failure(description:"Capture needs macOS 14.4")}
    }
    @MainActor static func cleanup()async {
        for window in NSApp.windows {
            if let owner=window.delegate as? ImportPatchWindowController {owner.close()}
            if let owner=window.delegate as? WorkingTreePatchWindowController {owner.close()}
        }
        for _ in 0..<3000 {if ImportPatchWindowModel.activeWorkers==0{return};try? await Task.sleep(nanoseconds:10_000_000)}
    }
    @MainActor static func main()async {NSApp.setActivationPolicy(.prohibited);do{try await verify();await cleanup()}catch{await cleanup();fputs("FAIL Import source: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let (repo,files)=try await ImportPatchVerification.fixture(root.appendingPathComponent("source"),git)
        let suite="TurtleGit.ImportSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        let owner=ImportPatchWindowController(repository:repo,access:nil,preferences:prefs);defer{owner.close()}
        owner.window!.alphaValue=0;owner.window!.orderFront(nil);let model=owner.model
        model.add(files+[files[0]])
        try await wait {views(owner.window?.contentView).compactMap {$0 as? ImportPatchNativeTable}.first?.numberOfRows==3}
        let table=views(owner.window?.contentView).compactMap {$0 as? ImportPatchNativeTable}.first!
        try require(table.headerView==nil && table.allowsMultipleSelection,"Source headerless checked list defaults")
        let ids=model.items.map(\.id)
        func checkbox(_ row:Int)->ImportPatchCheckButton? {(table.view(atColumn:0,row:row,makeIfNecessary:true) as? NSTableCellView)?.subviews.compactMap {$0 as? ImportPatchCheckButton}.first}
        guard let duplicate=checkbox(2),let action=duplicate.action else{throw Failure(description:"No native checkbox")}
        duplicate.state = .off;_ = NSApp.sendAction(action,to:duplicate.target,from:duplicate)
        try require(!model.items[2].checked,"Native checkbox did not check its captured item")
        try await wait {checkbox(2) !== duplicate && checkbox(2)?.state == .off}
        if let tabs=views(owner.window?.contentView).compactMap({$0 as? NSTabView}).first {
            try require(tabs.tabViewType == .topTabsBezelBorder && tabs.tabViewItems.map(\.label)==["Patch","Log"],"Source tabs escaped preview pane")
            tabs.selectTabViewItem(at:1);try require(model.tab==1,"Native Log tab not routed")
            tabs.selectTabViewItem(at:0);try require(model.tab==0,"Native Patch tab not routed")
        } else{throw Failure(description:"No native preview tabs")}
        table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        try require(model.selection==[ids[1]] && model.canMoveUp && model.canMoveDown,"Native selection/movement gates")
        model.move(-1,context:model.formContext);try await wait {model.items[0].id==ids[1] && table.numberOfRows==3}
        model.move(1,context:model.formContext)
        try require(model.items.map(\.id)==ids,"Stable order restore")
        model.select([ids[2]],context:model.formContext);model.check(ids[2],false,context:model.formContext)
        try await wait {views(owner.window?.contentView).compactMap {$0 as? ImportPatchCheckButton}.contains { !$0.isEnabled || $0.state == .off }}
        let context=model.formContext,flag=model.option(\.signOff,context:context)
        model.confirmingQuit=true;flag.wrappedValue=true;model.confirmingQuit=false;flag.wrappedValue=true
        try require(!model.options.signOff,"Quit lifetime revived an option")
        // All picker replies belong to the original panel, input catalog and options.
        var replies:[(NSApplication.ModalResponse)->Void]=[]
        owner.presentFiles={_,_,reply in replies.append(reply)};owner.selectedFiles={_ in [files[0]]}
        model.addFiles(context:model.formContext)
        try require(model.pickingFiles && !model.editable && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Add panel lost control/Close/Quit gate")
        let pending=model.formContext;model.option(\.signOff,context:pending).wrappedValue=true
        replies[0](.cancel);model.addFiles(context:model.formContext);replies[0](.OK)
        try require(model.pickingFiles && model.items.count==3,"Obsolete Add panel settled replacement")
        replies[1](.cancel)
        try require(!model.pickingFiles && !model.options.signOff,"Cancelled picker changed input")
        // Retained native context menu owns its original IDs and catalog lifetime.
        model.select([ids[0]],context:model.formContext)
        try await wait {table.selectedRowIndexes==IndexSet(integer:0)}
        let menu=table.buildMenu()!
        try require(menu.items.count==3 && menu.items.allSatisfy {$0.image != nil},"Source app context commands/icons")
        model.move(1,context:model.formContext)
        var opened=0;model.showPatch={_,_,_ in opened+=1}
        let entry=menu.items[0];_ = NSApp.sendAction(entry.action!,to:entry.target,from:entry)
        try require(!model.openingViewer && opened==0,"Old native menu opened replacement catalog")
        model.move(-1,context:model.formContext)
        model.select([ids[0]],context:model.formContext)
        try await wait {!model.preview.isEmpty}
        try await capture(owner.window!)
        // Real two-patch import: source defaults, captured sign-off and unchecked duplicate.
        model.option(\.signOff,context:model.formContext).wrappedValue=true;model.apply(context:model.formContext)
        try await wait {!model.busy}
        try require(model.items.map(\.state)==[.success,.success,.skipped] && model.error==nil,"Real serial import/state colors")
        let log=try await repo.run(["log","-2","--format=%B"]).text
        try require(log.components(separatedBy:"Signed-off-by:").count==3,"Captured Sign-off not applied to both commits")
        // Owned actual recovery alert: forced Close settles it before retained/duplicate replies.
        let (conflict,conflictFiles)=try await ImportPatchVerification.fixture(root.appendingPathComponent("conflict"),git,conflict:true)
        let recovery=ImportPatchWindowController(repository:conflict,access:nil,preferences:prefs);defer {recovery.close()}
        recovery.window?.contentViewController=nil
        recovery.model.add([conflictFiles[0]]);recovery.model.apply();try await wait {!recovery.model.busy}
        recovery.model.error=nil
        var question:((NSApplication.ModalResponse)->Void)?,buttons:[String]=[]
        recovery.presentQuestion={alert,_,reply in buttons=alert.buttons.map(\.title);question=reply;return true}
        recovery.model.apply();try await wait {question != nil}
        try require(buttons==["Abort","Skip","Resolved","Cancel"] && recovery.model.busy,"Source recovery options/ownership")
        let head=try await conflict.run(["rev-parse","HEAD"]).stdout
        recovery.close();question?(.alertFirstButtonReturn);question?(.alertFirstButtonReturn)
        try await wait {ImportPatchWindowModel.activeWorkers==0}
        let after=try await conflict.run(["rev-parse","HEAD"]).stdout,session=try await conflict.mailPatchSession()
        try require(head==after && session == .applying,"Retired recovery reply mutated session")
        // Held provider survives a forced close but retains Quit ownership until its reply drains.
        let dropping=ImportPatchWindowController(repository:repo,access:nil,preferences:prefs);defer {dropping.close()}
        let provider=NSItemProvider(),providerProgress=Progress(totalUnitCount:1);var providerReply:((Data?,Error?)->Void)?
        provider.registerDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier,visibility:.all) {reply in providerReply=reply;return providerProgress}
        try require(dropping.model.receiveDrop([provider]),"Held provider was refused")
        try await wait {providerReply != nil};dropping.close()
        try require(providerProgress.isCancelled && ImportPatchWindowModel.activeWorkers>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired provider lost worker/Quit lifetime")
        providerReply?(files[0].dataRepresentation,nil);try await wait {ImportPatchWindowModel.activeWorkers==0}
        try require(dropping.model.items.isEmpty && dropping.model.error==nil,"Late drop published into closed owner")
        // Forced closure cancels the actual owned picker and ignores late OK.
        model.addFiles(context:model.formContext);let late=replies.last!;owner.close();late(.OK)
        try require(owner.filePanel==nil && model.closed && model.items.isEmpty,"Closed picker accepted late files")
        print("PASS Import source: headerless native checks/order/menu targets, source option/default layout, exact real serial import/signoff, owned file/recovery replies and retired provider Quit lifetime")
    }
}
