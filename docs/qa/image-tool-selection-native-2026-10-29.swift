// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ImageIO
import CryptoKit
import ObjectiveC
import Darwin
import TurtleGitCore

@MainActor private enum ImageToolQAKeyOwner {
    static var enabled=false
    static weak var window:NSWindow?
    static func set(_ next:NSWindow?) {
        let prior=window;enabled=true;window=next
        if let prior {NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:prior)}
        if let next {NotificationCenter.default.post(name:NSWindow.didBecomeKeyNotification,object:next)}
        NSApp.updateWindows()
    }
}
private extension NSApplication {
    @objc func imageToolSelectionQAKeyWindow()->NSWindow? {
        ImageToolQAKeyOwner.enabled ? ImageToolQAKeyOwner.window:imageToolSelectionQAKeyWindow()
    }
}
private extension NSWindow {
    @objc func imageToolSelectionQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));imageToolSelectionQAOrder(mode,relativeTo:number)}
}
private final class ImageToolQABookmarks:RepositoryBookmarkProvider {
    func create(for url:URL)throws->Data{Data(url.path.utf8)}
    func resolve(_ bytes:Data)throws->ResolvedBookmark{.init(url:URL(fileURLWithPath:String(decoding:bytes,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool{true}
    func stopAccessing(_ url:URL){}
}
@MainActor @main enum ImageToolSelectionVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value{throw Failure(description:"line \(line): \(message)")}}
    static func wait(_ message:String,line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"ImageTool timeout at line \(line): "+message)
    }
    static func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func key(_ window:NSWindow,_ characters:String,_ code:UInt16,_ flags:NSEvent.ModifierFlags=[])->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
    }
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),assets=URL(fileURLWithPath:CommandLine.arguments[3])
        let suite="TurtleGit.ImageToolSelection.QA."+UUID().uuidString
        let preferences:UserDefaults,board=NSPasteboard.withUniqueName()
        fileprivate let provider=ImageToolQABookmarks()
        var owners:[ImageSelectionWindowController]=[],sessions:[ImageToolLaunchSession]=[]
        init(){preferences=UserDefaults(suiteName:suite)!;preferences.set(true,forKey:"ShowAppContextMenuIcons");preferences.set(false,forKey:"UseLibgit2")}
        func fixture(_ name:String,output:Bool=true)throws->(URL,[ImageConflictSide:URL],URL?) {
            let directory=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let paths:[ImageConflictSide:URL]=[.mine:directory.appendingPathComponent("Mine animated.gif"),.base:directory.appendingPathComponent("Base metafile.wmf"),.theirs:directory.appendingPathComponent("Theirs opaque.bin")]
            try Data(contentsOf:assets.appendingPathComponent("compressed-raster-source-gif-two-frames.gif")).write(to:paths[.mine]!)
            try Data(contentsOf:assets.appendingPathComponent("wmf-bitmap16-rop-cc.wmf")).write(to:paths[.base]!)
            try Data("intentionally undecodable image bytes\0\u{fffd}\n".utf8).write(to:paths[.theirs]!)
            return (directory,paths,output ? directory.appendingPathComponent("selected folder/result.image"):nil)
        }
        func request(_ directory:URL,_ paths:[ImageConflictSide:URL],_ output:URL?,flags:[String]=[])throws->ImageToolInvocation {
            var args=["--image-tool","--base",paths[.base]!.path,"--mine",paths[.mine]!.path,"--theirs",paths[.theirs]!.path,"--mine-title","Local GIF","--base-title","Ancestor WMF","--theirs-title","Incoming opaque"]+flags
            if let output {args += ["--result",output.path]}
            return try ImageToolSelectionVerification.unwrap(ImageToolInvocation.parse(arguments:args,currentDirectory:directory.path),"Missing actual ImageTool invocation")
        }
        func document(_ request:ImageToolInvocation)async throws->ImageSelectionDocument {try await Task.detached{try ImageSelectionDocument.capture(invocation:request)}.value}
        func clean()async throws {
            for session in sessions {session.cancel()}
            for owner in owners {
                if let sheet=owner.window?.attachedSheet {owner.window?.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil)}
                owner.model.cancelWork();owner.close()
            }
            try await ImageToolSelectionVerification.wait("owned ImageTool work drains"){owners.allSatisfy{!$0.model.hasPendingWork && !$0.model.busy && !$0.model.decoding && $0.window?.attachedSheet==nil && $0.window?.isVisible != true} && sessions.allSatisfy{!$0.hasPendingWork}}
            preferences.removePersistentDomain(forName:suite);board.releaseGlobally()
        }
    }
    static func owner(_ c:Context,_ document:ImageSelectionDocument,decoder:ImageSelectionWindowModel.Decoder?=nil)async throws->ImageSelectionWindowController {
        let value=ImageSelectionWindowController(document:document,permissions:[RepositoryAccessLease(url:c.root,provider:c.provider)],preferences:c.preferences,decodeImages:decoder)
        c.owners.append(value);value.model.requiresScopes=false;value.model.saveFolderAccess.requireScope=false
        value.window?.alphaValue=0;value.showWindow(nil)
        if decoder==nil {try await wait("actual three-image preview ready"){!value.model.busy && !value.model.decoding}}
        return value
    }
    static func press(_ owner:ImageSelectionWindowController,_ side:ImageConflictSide)async throws {
        let window=try unwrap(owner.window,"Missing ImageTool window")
        var control:NSButton?
        try await wait("actual Select \(side.rawValue) button enabled") {
            window.contentView?.layoutSubtreeIfNeeded()
            control=descendants(window.contentView!).compactMap{$0 as? NSButton}.first{$0.accessibilityLabel()=="Select "+side.rawValue}
            return control?.isEnabled==true
        }
        control!.performClick(nil)
    }
    static func rawSelections(_ c:Context)async throws {
        for side in ImageConflictSide.allCases {
            let (directory,paths,output)=try c.fixture("raw-"+side.rawValue)
            let original=try paths.mapValues{try Data(contentsOf:$0)},request=try c.request(directory,paths,output),document=try await c.document(request)
            try require(CGImageSourceCreateWithData(original[.mine]! as CFData,nil).map{CGImageSourceGetCount($0)>1}==true,"Animated GIF source fixture lost its additional frames")
            let view=try await owner(c,document),model=view.model
            var statuses:[Int32]=[];view.onFinished={statuses.append($0)}
            try require(model.title(for:.mine)=="Local GIF" && model.title(for:.base)=="Ancestor WMF" && model.title(for:.theirs)=="Incoming opaque","ImageTool titles replaced or lost source names")
            try require(model.images[.mine] != nil && model.images[.base] != nil && model.images[.theirs]==nil && model.canSelect(.theirs),"Undecodable raw input became unselectable or container previews failed")
            let selects=descendants(view.window!.contentView!).compactMap{$0 as? NSButton}.filter{$0.title=="Select"}.sorted{$0.convert(NSPoint.zero,to:nil).x<$1.convert(NSPoint.zero,to:nil).x}
            try require(selects.map{$0.accessibilityLabel() ?? ""}==["Select Mine","Select Base","Select Theirs"],"Three source Select buttons lost Mine/Base/Theirs order")
            try await press(view,side)
            try await wait("raw choice output and owned completion"){!model.hasPendingWork && !model.busy && statuses.count==1}
            try require(statuses==[ImageToolInvocation.selectionExitCode(side)] && model.completedStatus==statuses.first && model.error==nil && (try Data(contentsOf:output!))==original[side],"Native choice changed original multi-frame/metafile/opaque container bytes or exit side")
            for(candidate,file)in paths{try require((try Data(contentsOf:file))==original[candidate],"Selection rewrote an input")}
            view.close();try await wait("raw-choice window closed"){view.window?.isVisible != true}
            try require(statuses.count==1,"Close repeated accepted selection completion")
        }
        for side in ImageConflictSide.allCases {
            let (directory,paths,_)=try c.fixture("status-only-"+side.rawValue,output:false),request=try c.request(directory,paths,nil)
            let document=try await c.document(request),view=try await owner(c,document);var statuses:[Int32]=[];view.onFinished={statuses.append($0)}
            let before=try paths.mapValues{try Data(contentsOf:$0)}
            try await press(view,side);try await wait("selection-only native status"){statuses.count==1 && !view.model.hasPendingWork}
            try require(statuses==[ImageToolInvocation.selectionExitCode(side)] && view.model.document.output==nil,"Selection-only invocation created an output or lost side code")
            for(candidate,file)in paths{try require((try Data(contentsOf:file))==before[candidate],"Status-only choice changed source bytes")}
        }
    }
    static func outputAliases(_ c:Context)async throws {
        for hardlink in [false,true] {
            let (directory,paths,_)=try c.fixture(hardlink ? "hardlink-output":"same-input-output",output:false)
            let mine=try Data(contentsOf:paths[.mine]!),theirs=try Data(contentsOf:paths[.theirs]!)
            let output=hardlink ? directory.appendingPathComponent("linked-output.bin"):paths[.mine]!
            if hardlink {try FileManager.default.linkItem(at:paths[.mine]!,to:output)}
            let document=try await c.document(c.request(directory,paths,output)),view=try await owner(c,document)
            var statuses:[Int32]=[];view.onFinished={statuses.append($0)}
            try await press(view,.theirs);try await wait("explicit aliased result choice drains"){statuses.count==1 && !view.model.hasPendingWork}
            try require(statuses==[2] && (try Data(contentsOf:output))==theirs && view.model.document.selectionBytes(.mine)==mine,"Explicit alias output lost chosen bytes or mutated captured source plane")
            try require((try Data(contentsOf:paths[.mine]!))==(hardlink ? mine:theirs),"Hardlink result modified source inode instead of atomically replacing output")
        }
    }
    static func changedSnapshots(_ c:Context)async throws {
        for changeInput in [false,true] {
            let (directory,paths,output)=try c.fixture(changeInput ? "changed-input":"changed-output")
            try FileManager.default.createDirectory(at:output!.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data("captured output\n".utf8).write(to:output!)
            let document=try await c.document(c.request(directory,paths,output)),view=try await owner(c,document)
            var statuses:[Int32]=[];view.onFinished={statuses.append($0)}
            let changed=changeInput ? paths[.mine]!:output!,external=Data("external replacement retained\n".utf8)
            try external.write(to:changed,options:.atomic)
            try await press(view,.mine);try await wait("external snapshot refusal"){!view.model.busy && !view.model.hasPendingWork && view.model.error != nil}
            try require(statuses.isEmpty && view.model.completedStatus==nil && (try Data(contentsOf:changed))==external,"Changed source/output was overwritten or reported accepted")
            if changeInput {try require((try Data(contentsOf:output!))==Data("captured output\n".utf8),"Changed input selection touched output")}
            view.model.error=nil;view.close();try await wait("refused owner drained"){!view.model.hasPendingWork}
        }
        let (directory,paths,output)=try c.fixture("missing-side")
        try FileManager.default.removeItem(at:paths[.base]!)
        let view=try await owner(c,try await c.document(c.request(directory,paths,output)))
        try require(!view.model.canSelect(.base) && view.model.canSelect(.theirs),"Absent source and undecodable present source were conflated")
        view.close()
        let (emptyDirectory,emptyPaths,emptyOutput)=try c.fixture("empty-side")
        try Data().write(to:emptyPaths[.theirs]!)
        let empty=try await owner(c,try await c.document(c.request(emptyDirectory,emptyPaths,emptyOutput)))
        var emptyStatuses:[Int32]=[];empty.onFinished={emptyStatuses.append($0)}
        try require(empty.model.canSelect(.theirs),"Existing zero-byte image source became unavailable")
        try await press(empty,.theirs);try await wait("actual empty container selection"){emptyStatuses==[2] && !empty.model.hasPendingWork}
        try require((try Data(contentsOf:emptyOutput!)).isEmpty,"Empty chosen source was re-encoded or rejected")
    }
    static func nativePresentation(_ c:Context)async throws {
        let (directory,paths,output)=try c.fixture("native-controls")
        let view=try await owner(c,try await c.document(c.request(directory,paths,output,flags:["--show-info"])))
        let model=view.model,window=view.window!
        try await wait("selection toolbar installed"){model.nativeToolbarInstalled && window.toolbar != nil}
        try require(model.showInfo && window.title.contains("TurtleGitIDiff"),"Initial source info/title policy lost")
        try require(window.toolbar!.items.contains{$0.itemIdentifier==ImageEditorCommand.fit.identifier} && window.toolbar!.items.allSatisfy{$0.itemIdentifier != ImageEditorCommand.overlay.identifier},"Selection toolbar used two-image comparison actions")
        let zoom=model.panes[.mine]!.zoom
        try require(window.performKeyEquivalent(with:key(window,"+",24)) && model.panes.values.allSatisfy{$0.zoom>zoom},"Actual native IDiff zoom key did not update all panes")
        try require(window.performKeyEquivalent(with:key(window,"v",9,.command)) && model.vertical,"Actual Arrange Vertical key refused")
        model.perform(.transparentColor);try await wait("owned transparency chooser"){window.attachedSheet != nil}
        let sheet=window.attachedSheet!
        let closeAllowed=view.windowShouldClose(window),selectAllowed=model.canSelect(.mine),quitReply=TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp)
        try require(!closeAllowed && !selectAllowed && quitReply == .terminateCancel,"Color chooser ownership: Close=\(closeAllowed) Select=\(selectAllowed) Quit=\(quitReply.rawValue) sheetParentMatches=\(sheet.sheetParent === window) windowRegistered=\(NSApp.windows.contains{$0 === window})")
        let well=try unwrap(descendants(sheet.contentView!).compactMap{$0 as? NSColorWell}.first,"Missing actual color well")
        well.color=NSColor(deviceRed:0.2,green:0.4,blue:0.6,alpha:1)
        let okay=try unwrap(descendants(sheet.contentView!).compactMap{$0 as? NSButton}.first{$0.title=="OK"},"Missing actual color response")
        okay.performClick(nil);try await wait("color sheet detached"){window.attachedSheet==nil}
        try require(abs((model.presentation.transparentColor?.usingColorSpace(.deviceRGB)?.greenComponent ?? -1)-0.4)<0.01,"Shared pane transparency choice not retained")
        model.perform(.reload);try await wait("actual native reload settled"){!model.busy && !model.decoding}
        try require(model.images[.mine] != nil && model.canSelect(.theirs),"Reload changed raw-choice eligibility")
        let popup=try unwrap(window.toolbar?.items.first{$0.itemIdentifier==ImageEditorCommand.viewMenu.identifier}?.view as? NSPopUpButton,"Missing actual toolbar View menu")
        popup.menu?.update()
        try await wait("actual toolbar menu enabled after reload") {popup.menu?.items.first{$0.title==ImageEditorCommand.info.title}?.isEnabled==true}
        let heldInfo=try unwrap(popup.menu?.items.first{$0.title==ImageEditorCommand.info.title},"Missing captured Image info menu command")
        try require(heldInfo.image != nil && heldInfo.target != nil && heldInfo.action != nil && heldInfo.isEnabled,"Actual image View command: enabled=\(heldInfo.isEnabled) image=\(heldInfo.image != nil) target=\(heldInfo.target != nil) action=\(heldInfo.action != nil)")
        let beforeInfo=model.showInfo;_=NSApp.sendAction(heldInfo.action!,to:heldInfo.target,from:heldInfo)
        try require(model.showInfo != beforeInfo,"Actual toolbar menu command refused active selection owner")
        let old=model.showInfo;try require(window.performKeyEquivalent(with:key(window,"\u{1b}",53)),"Native Escape did not close standalone IDiff");try await wait("presentation retired"){model.retired && !model.hasPendingWork}
        _=NSApp.sendAction(heldInfo.action!,to:heldInfo.target,from:heldInfo);model.perform(.info);try require(model.showInfo==old && (model.commandState(.fit)==nil || model.commandState(.fit)?.enabled==false),"Retired image command revived")
    }
    @MainActor final class Gate {
        var answer:CheckedContinuation<Void,Never>?,entered=false
        func hold()async {await withCheckedContinuation{answer=$0;entered=true}}
        func release(){let reply=answer;answer=nil;reply?.resume()}
    }
    static func lifetime(_ c:Context)async throws {
        let (directory,paths,output)=try c.fixture("held-decode"),document=try await c.document(c.request(directory,paths,output)),gate=Gate()
        let decoder:ImageSelectionWindowModel.Decoder={document,token in
            let actual=try await Task.detached {
                var images:[ImageConflictSide:ComparisonImage]=[:]
                for side in ImageConflictSide.allCases {try token.check();images[side]=document.image(side,cancellation:token)}
                return images
            }.value
            await gate.hold();return actual
        }
        let view=try await owner(c,document,decoder:decoder);var status:[Int32]=[],closed=0;view.onFinished={status.append($0)};view.onClosed={closed+=1}
        do {
            try await wait("actual decoding result held"){gate.entered && view.model.decoding && view.model.hasPendingWork}
            try require(!view.model.canSelect(.mine) && view.windowShouldClose(view.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Preview preparation lost cancellable Close/owned Quit accounting")
            view.window?.performClose(nil)
            try require(view.model.retired && view.model.hasPendingWork,"Visual close released held decoding worker")
            gate.release();try await wait("retired actual decoder drains"){!view.model.hasPendingWork && !view.model.decoding}
            try require(view.model.images.isEmpty && status.isEmpty && closed==1 && !FileManager.default.fileExists(atPath:output!.path),"Retired decoder published images/output or successful selection")
        }catch{gate.release();throw error}
        let (dropDirectory,dropPaths,dropOutput)=try c.fixture("held-preview-drop")
        let dropped=try await owner(c,try await c.document(c.request(dropDirectory,dropPaths,dropOutput))),dropGate=Gate(),pane=dropped.model.panes[.mine]!
        let actualRead=pane.readDroppedFile
        pane.readDroppedFile={url,token in let value=try await actualRead(url,token);await dropGate.hold();return value}
        pane.requiresDropScope=true;pane.makeDropPermission={RepositoryAccessLease(url:$0,provider:c.provider)}
        let scroll=try unwrap(descendants(dropped.window!.contentView!).compactMap{$0 as? ImageComparisonScrollView}.sorted{$0.convert(NSPoint.zero,to:nil).x<$1.convert(NSPoint.zero,to:nil).x}.first,"Missing actual Mine image drop surface")
        c.board.clearContents();c.board.writeObjects([dropPaths[.base]! as NSURL])
        do {
            try require(scroll.receiveFileDrop(c.board),"Actual selection-pane preview drop refused")
            try await wait("actual pane file read held"){dropGate.entered && dropped.model.hasPendingWork}
            try require(!dropped.model.canSelect(.mine),"Preview drop left source selection active")
            dropped.window?.performClose(nil);try require(dropped.model.retired && dropped.model.hasPendingWork,"Retired pane released actual preview reader")
            dropGate.release();try await wait("retired pane file read drained"){!dropped.model.hasPendingWork}
            try require(pane.droppedFiles.isEmpty && !FileManager.default.fileExists(atPath:dropOutput!.path),"Retired preview drop published or selected content")
        }catch{dropGate.release();throw error}
        let (scopeDirectory,scopePaths,scopeOutput)=try c.fixture("held-output-grant")
        let scopeDocument=try await c.document(c.request(scopeDirectory,scopePaths,scopeOutput))
        let scoped=ImageSelectionWindowController(document:scopeDocument,permissions:scopePaths.values.map{RepositoryAccessLease(url:$0,provider:c.provider)},preferences:c.preferences)
        c.owners.append(scoped);scoped.model.requiresScopes=true;scoped.model.saveFolderAccess.requireScope=true
        scoped.model.saveFolderAccess.makeLease={RepositoryAccessLease(url:$0,provider:c.provider)}
        var scopeReply:CheckedContinuation<URL?,Never>?,scopeCalls=0,statuses:[Int32]=[],scopeClosed=0
        scoped.model.saveFolderAccess.chooseFolder={_,_ in scopeCalls+=1;return await withCheckedContinuation{scopeReply=$0}}
        scoped.onFinished={statuses.append($0)};scoped.onClosed={scopeClosed+=1};scoped.showWindow(nil)
        do {
            try await wait("scoped preview ready"){!scoped.model.busy && !scoped.model.decoding}
            try await press(scoped,.mine);try await wait("actual result folder authority held"){scopeReply != nil}
            try require(scopeCalls==1 && scoped.model.hasPendingWork && !scoped.windowShouldClose(scoped.window!),"Held result authority did not retain busy selection owner")
            scoped.model.select(.base);try require(scopeCalls==1,"Duplicate selection started another folder authority attempt")
            scoped.close();try require(scoped.model.hasPendingWork,"Closed authority owner released pending chooser continuation")
            scopeReply?.resume(returning:scopeOutput!.deletingLastPathComponent().deletingLastPathComponent());scopeReply=nil
            try await wait("retired folder choice drains"){!scoped.model.hasPendingWork}
            try require(statuses.isEmpty && scopeClosed==1 && !FileManager.default.fileExists(atPath:scopeOutput!.path),"Late folder grant wrote selected output after retirement")
        }catch{scopeReply?.resume(returning:nil);scopeReply=nil;throw error}
        let cancelled=ImageSelectionWindowController(document:scopeDocument,permissions:scopePaths.values.map{RepositoryAccessLease(url:$0,provider:c.provider)},preferences:c.preferences)
        c.owners.append(cancelled);cancelled.model.requiresScopes=true;cancelled.model.saveFolderAccess.requireScope=true
        var cancelledChoices=0;cancelled.model.saveFolderAccess.chooseFolder={_,_ in cancelledChoices+=1;return nil}
        cancelled.showWindow(nil);try await wait("permission-cancel preview ready"){!cancelled.model.busy && !cancelled.model.decoding}
        try await press(cancelled,.base);try await wait("permission cancellation drains"){!cancelled.model.busy && !cancelled.model.hasPendingWork}
        try require(cancelledChoices==1 && cancelled.model.completedStatus==nil && !FileManager.default.fileExists(atPath:scopeOutput!.path),"Canceled folder permission selected or wrote output")
        cancelled.close()
    }
    static func png(_ color:NSColor)->Data {
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:3,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let rgb=color.usingColorSpace(.deviceRGB)!,pixels=bitmap.bitmapData!
        for y in 0..<3 {for x in 0..<4 {let offset=y*bitmap.bytesPerRow+x*4
            pixels[offset]=UInt8((rgb.redComponent*255).rounded());pixels[offset+1]=UInt8((rgb.greenComponent*255).rounded());pixels[offset+2]=UInt8((rgb.blueComponent*255).rounded());pixels[offset+3]=255
        }}
        return bitmap.representation(using:.png,properties:[:])!
    }
    static func gitResolution(_ c:Context)async throws {
        for scenario in ["declined","approved","changed-during-question","scope-hidden-root"] {
            let scoped=scenario == "scope-hidden-root",approved=scenario != "declined" && scenario != "scope-hidden-root",changed=scenario == "changed-during-question"
            let directory=c.root.appendingPathComponent("git-resolve-"+scenario)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let repo=GitRepository(root:directory,executable:c.git,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","ImageTool QA"),("user.email","image-tool@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repo.run(["config",key,value])}
            let relative=scoped ? "nested/image.png":"image.png",file=directory.appendingPathComponent(relative),base=png(.blue),mine=png(.red),theirs=png(.green)
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try require(base != mine && base != theirs && mine != theirs,"Private Git image fixture colors produced identical PNG packets")
            try base.write(to:file);try await repo.stage([relative]);_=try await repo.commit(message:"base")
            _=try await repo.run(["switch","-c","incoming"]);try theirs.write(to:file);try await repo.stage([relative]);_=try await repo.commit(message:"incoming")
            _=try await repo.run(["switch","main"]);try mine.write(to:file);try await repo.stage([relative]);_=try await repo.commit(message:"local")
            do{_=try await repo.run(["merge","--no-edit","incoming"]);throw Failure(description:"Private image merge did not conflict")}catch is GitFailure{}
            let peer=directory.appendingPathComponent("unrelated.txt"),peerBytes=Data("unrelated staged image-tool sentinel\n".utf8)
            try peerBytes.write(to:peer);try await repo.stage([peer.lastPathComponent])
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:directory.appendingPathComponent(".git/index")),peerPacket=try await repo.run(["ls-files","--stage","-z","--",peer.lastPathComponent]).stdout
            let paths:[ImageConflictSide:URL]=[.base:directory.appendingPathComponent("source-base.bin"),.mine:directory.appendingPathComponent("source-mine.bin"),.theirs:directory.appendingPathComponent("source-theirs.bin")]
            for(side,data)in [(ImageConflictSide.base,base),(.mine,mine),(.theirs,theirs)]{try data.write(to:paths[side]!)}
            let document=try await c.document(c.request(directory,paths,file)),view:ImageSelectionWindowController
            if scoped {
                view=ImageSelectionWindowController(document:document,permissions:paths.values.map{RepositoryAccessLease(url:$0,provider:c.provider)}+[RepositoryAccessLease(url:file.deletingLastPathComponent(),provider:c.provider)],preferences:c.preferences)
                c.owners.append(view);view.model.requiresScopes=true;view.showWindow(nil);try await wait("narrow root-hidden preview ready"){!view.model.busy && !view.model.decoding}
            } else {view=try await owner(c,document)}
            let model=view.model;var executableLookups=0,rootChoices=0
            model.newOutputResolution.executable={executableLookups+=1;return c.git};model.newOutputResolution.requiresScope=scoped
            model.newOutputResolution.chooseRepository={_,_ in rootChoices+=1;return nil}
            var questions:[String]=[],statuses:[Int32]=[]
            let external=Data("externally replaced while resolution question is owned\n".utf8)
            model.askMarkResolved={path in questions.append(path);if changed{try? external.write(to:file,options:.atomic)};return approved};view.onFinished={statuses.append($0)}
            try await press(view,.theirs);try await wait("actual optional Git resolution drains"){!model.busy && !model.hasPendingWork && questions.count==(scoped ? 0:1)}
            try require(questions.count==(scoped ? 0:1) && statuses==((approved && !changed) || scoped ? [2]:[]) && (try Data(contentsOf:file))==(changed ? external:theirs) && (changed ? model.error != nil:model.error==nil),"Optional resolution did not preserve chosen raw image/status")
            let currentHead=try await repo.run(["rev-parse","HEAD"]).stdout,currentPeer=try await repo.run(["ls-files","--stage","-z","--",peer.lastPathComponent]).stdout
            try require(currentHead==head && currentPeer==peerPacket && (try Data(contentsOf:peer))==peerBytes,"Optional resolution changed HEAD/unrelated stage/work bytes")
            if scoped {
                try require(executableLookups==0 && rootChoices==0 && (try Data(contentsOf:directory.appendingPathComponent(".git/index")))==index,"Optional Git discovery widened narrow output authority or ran Git across hidden root")
            } else if changed {
                try require((try Data(contentsOf:directory.appendingPathComponent(".git/index")))==index && model.canRetryResolution && model.completedStatus==nil,"Changed saved output was staged or lost guarded resolution retry")
                model.error=nil;model.askMarkResolved={path in questions.append(path);return true};model.retryResolution()
                try await wait("stale saved output Retry Resolve refuses"){!model.hasPendingWork && model.error != nil}
                try require((try Data(contentsOf:file))==external && (try Data(contentsOf:directory.appendingPathComponent(".git/index")))==index && statuses.isEmpty,"Retry Resolve silently acknowledged external output replacement")
                view.close()
            } else if approved {
                let unresolved=try await repo.run(["ls-files","-u","-z","--",relative]).stdout,saved=try await repo.run(["show",":"+relative]).stdout
                try require(unresolved.isEmpty && saved==theirs,"Approved optional Resolve did not actually stage selected bytes")
            } else {
                try require((try Data(contentsOf:directory.appendingPathComponent(".git/index")))==index && model.completedStatus==nil && view.window?.isVisible==true,"Declined optional Resolve changed conflict index or closed source selection")
                var closed=0;view.onClosed={closed+=1};view.close();try await wait("declined resolution window close"){closed==1 && !model.hasPendingWork}
            }
            for(side,data)in [(ImageConflictSide.base,base),(.mine,mine),(.theirs,theirs)]{try require((try Data(contentsOf:paths[side]!))==data,"Optional Resolve rewrote original input container")}
        }
    }
    static func launches(_ c:Context)async throws {
        let (directory,paths,_)=try c.fixture("launch-grants",output:false),request=try c.request(directory,paths,nil)
        let session=ImageToolLaunchSession(invocation:request,preferences:c.preferences,owner:nil)
        c.sessions.append(session);session.requiresScopes=true
        var grants:[URL]=[],statuses:[Int32]=[],errors:[String]=[]
        session.authorize={url,_ in grants.append(url);return RepositoryAccessLease(url:url,provider:c.provider)}
        session.onFinished={statuses.append($0)};session.onError={errors.append($0)}
        session.presentation={controller in controller.window?.alphaValue=0;controller.showWindow(nil)}
        session.start()
        try await wait("actual authorized selection launch"){session.editor is ImageSelectionWindowController && !session.preparing}
        let selection=try unwrap(session.editor as? ImageSelectionWindowController,"Launch did not adopt actual selection controller")
        c.owners.append(selection);try await wait("launched selection decode"){!selection.model.busy && !selection.model.decoding}
        try require(Set(grants.map(\.path))==Set(paths.values.map(\.path)) && errors.isEmpty,"Launch widened source grants or lost an input")
        try await press(selection,.base);try await wait("selection launch exact side result"){statuses.count==1 && !session.hasPendingWork}
        try require(statuses==[3] && errors.isEmpty,"Waiting launch did not return Base status exactly once after drain")

        let gate=Gate(),held=ImageToolLaunchSession(invocation:request,preferences:c.preferences,owner:nil,permissions:[RepositoryAccessLease(url:directory,provider:c.provider)])
        c.sessions.append(held);held.requiresScopes=true;var heldStatuses:[Int32]=[]
        held.captureSelection={request,token in let document=try await Task.detached{try ImageSelectionDocument.capture(invocation:request,cancellation:token)}.value;await gate.hold();return document}
        held.onFinished={heldStatuses.append($0)};held.start()
        do {
            try await wait("actual launch capture held"){gate.entered && held.hasPendingWork && held.preparing}
            held.cancel();try require(held.hasPendingWork && heldStatuses.isEmpty,"Canceled launch released held capture/leases before actual drain")
            gate.release();try await wait("canceled launch read drains"){!held.hasPendingWork && heldStatuses.count==1}
            try require(heldStatuses==[0] && held.editor==nil,"Retired launch adopted an editor or returned selection success")
        }catch{gate.release();throw error}

        let denied=ImageToolLaunchSession(invocation:request,preferences:c.preferences,owner:nil);c.sessions.append(denied)
        denied.requiresScopes=true;var deniedStatuses:[Int32]=[],deniedCalls=0
        denied.authorize={_,_ in deniedCalls+=1;return nil};denied.onFinished={deniedStatuses.append($0)};denied.start()
        try await wait("denied input launch drains"){!denied.hasPendingWork && deniedStatuses.count==1}
        try require(deniedCalls==1 && deniedStatuses==[64] && denied.editor==nil,"Declined source authorization launched a window or side success")

        let pairRequest=try unwrap(ImageToolInvocation.parse(arguments:["--image-tool","--left",paths[.mine]!.path,"--right",paths[.base]!.path,"--left-title","Animated local","--right-title","Metafile ancestor","--overlay","--fit-widths","--show-info"],currentDirectory:directory.path),"Missing two-image invocation")
        let pair=ImageToolLaunchSession(invocation:pairRequest,preferences:c.preferences,owner:nil,permissions:[RepositoryAccessLease(url:directory,provider:c.provider)])
        c.sessions.append(pair);pair.requiresScopes=true;var pairStatuses:[Int32]=[];pair.onFinished={pairStatuses.append($0)}
        pair.presentation={controller in controller.window?.alphaValue=0;controller.showWindow(nil)};pair.start()
        try await wait("actual two-image launch"){pair.editor is FileComparisonWindowController && !pair.preparing}
        let comparison=try unwrap(pair.editor as? FileComparisonWindowController,"Pair launch adopted wrong editor")
        try await wait("actual launched pair decode"){!comparison.model.busy && comparison.model.imageComparison != nil}
        try require(comparison.window?.title.contains("Animated local")==true && comparison.window?.title.contains("Metafile ancestor")==true && comparison.model.imageViewerModel.overlay && comparison.model.imageViewerModel.showInfo && comparison.model.imageViewerModel.fitWidths,"Two-image launch: title=\(comparison.window?.title ?? "nil") overlay=\(comparison.model.imageViewerModel.overlay) info=\(comparison.model.imageViewerModel.showInfo) widths=\(comparison.model.imageViewerModel.fitWidths)")
        do {
        let nativeKey=class_getInstanceMethod(NSApplication.self,#selector(getter:NSApplication.keyWindow))!,fixtureKey=class_getInstanceMethod(NSApplication.self,#selector(NSApplication.imageToolSelectionQAKeyWindow))!
        method_exchangeImplementations(nativeKey,fixtureKey);defer{ImageToolQAKeyOwner.enabled=false;ImageToolQAKeyOwner.window=nil;method_exchangeImplementations(nativeKey,fixtureKey)}
        comparison.window?.makeKeyAndOrderFront(nil);ImageToolQAKeyOwner.set(comparison.window)
        func diagnoseKey(_ phase:String) {
            let key=NSApp.keyWindow,w=comparison.window
            print("KEY \(phase) witnessEnabled=\(ImageToolQAKeyOwner.enabled) witnessSame=\(ImageToolQAKeyOwner.window === w) keySame=\(key === w) keyClass=\(key.map{String(describing:type(of:$0))} ?? "nil") visible=\(w?.isVisible == true) alpha=\(w?.alphaValue ?? -1) actualIsKey=\(w?.isKeyWindow == true) modal=\(NSApp.modalWindow != nil) sheet=\(w?.attachedSheet != nil) owns=\(pair.ownsCurrentFrame) canOpen=\(pair.canOpenImages) preparing=\(pair.preparing) sessionPending=\(pair.hasPendingWork) comparisonPending=\(comparison.model.mergeToolHasPendingWork) comparisonBusy=\(comparison.model.busy) dropPending=\(comparison.model.imageViewerModel.hasPendingFileRead) contextOpen=\(ImageToolMenuContext.shared.canOpen)")
        }
        diagnoseKey("before")
        try await wait("actual pair preparation drains before app update"){!comparison.model.mergeToolHasPendingWork && !comparison.model.imageViewerModel.hasPendingFileRead}
        // This private async receiver does not run NSApplication.run; deliver
        // the normal native update cycle observed by the production menu owner.
        NSApp.updateWindows()
        do {try await wait("active standalone File Open owner"){NSApp.updateWindows();return ImageToolMenuContext.shared.canOpen}}
        catch {diagnoseKey("timeout");throw error}
        let foreign=try await owner(c,try await c.document(request));foreign.window?.makeKeyAndOrderFront(nil);ImageToolQAKeyOwner.set(foreign.window)
        try await wait("foreign key window revokes standalone File menu"){NSApp.updateWindows();return !ImageToolMenuContext.shared.canOpen}
        ImageToolMenuContext.shared.open();try require(pair.opener==nil,"Standalone File Open targeted a background session")
        foreign.close();comparison.window?.makeKeyAndOrderFront(nil);ImageToolQAKeyOwner.set(comparison.window)
        try await wait("original standalone File owner restored"){NSApp.updateWindows();return ImageToolMenuContext.shared.canOpen}
        ImageToolMenuContext.shared.open();try await wait("actual File Open chooser"){pair.opener != nil}
        let chooser=try unwrap(pair.opener,"Missing actual image replacement chooser")
        chooser.left.stringValue=paths[.base]!.path;chooser.right.stringValue=paths[.mine]!.path
        let okay=try unwrap(descendants(chooser.window!.contentView!).compactMap{$0 as? NSButton}.first{$0.title=="OK"},"Missing native Open Images OK")
        okay.performClick(nil)
        try await wait("actual image editor replacement adopts"){pair.opener==nil && pair.editor != nil && pair.editor !== comparison}
        let replacement=try unwrap(pair.editor as? FileComparisonWindowController,"Image Open adopted wrong replacement")
        try await wait("replacement image read and retired owner drain"){!replacement.model.busy && !comparison.model.mergeToolHasPendingWork}
        try require(pairStatuses.isEmpty && comparison.window?.isVisible != true && replacement.model.imageComparison != nil,"Replacing image editor prematurely completed session or retained old visible editor")
        ImageToolQAKeyOwner.set(replacement.window)
        try await wait("replacement owns native File menu"){NSApp.updateWindows();return ImageToolMenuContext.shared.canOpen}
        replacement.close();try await wait("two-image launch close drains"){pairStatuses==[0] && !pair.hasPendingWork}
        }

        let emptyRequest=try unwrap(ImageToolInvocation.parse(arguments:["--image-tool"],currentDirectory:directory.path),"Missing no-input image invocation")
        let opener=ImageToolLaunchSession(invocation:emptyRequest,preferences:c.preferences,owner:nil);c.sessions.append(opener)
        opener.presentation={controller in controller.window?.alphaValue=0;controller.showWindow(nil)};var openStatuses:[Int32]=[];opener.onFinished={openStatuses.append($0)};opener.start()
        try await wait("actual no-input Image Open chooser"){opener.opener != nil && !opener.preparing}
        try require(opener.editor==nil,"No-input invocation fabricated an image editor")
        opener.cancel();try await wait("no-input chooser cancellation drains"){openStatuses==[0] && !opener.hasPendingWork}

        let baseRequest=try unwrap(ImageToolInvocation.parse(arguments:["--image-tool","--base",paths[.mine]!.path],currentDirectory:directory.path),"Missing base-only chooser invocation")
        let baseOnly=ImageToolLaunchSession(invocation:baseRequest,preferences:c.preferences,owner:nil,permissions:[RepositoryAccessLease(url:directory,provider:c.provider)])
        c.sessions.append(baseOnly);baseOnly.requiresScopes=true;var baseStatuses:[Int32]=[];baseOnly.onFinished={baseStatuses.append($0)}
        baseOnly.presentation={controller in controller.window?.alphaValue=0;controller.showWindow(nil)};baseOnly.start()
        try await wait("actual base-only Image Open chooser"){baseOnly.opener != nil && !baseOnly.preparing}
        let baseChooser=try unwrap(baseOnly.opener,"Base-only invocation omitted native chooser")
        try require(baseOnly.editor==nil && baseChooser.left.stringValue==paths[.mine]!.path,"Base-only chooser lost seeded left input or bypassed chooser")
        baseChooser.right.stringValue=paths[.base]!.path
        let accept=try unwrap(descendants(baseChooser.window!.contentView!).compactMap{$0 as? NSButton}.first{$0.title=="OK"},"Base-only chooser missing actual OK")
        accept.performClick(nil);try await wait("base-only native chooser adopts pair"){baseOnly.opener==nil && baseOnly.editor is FileComparisonWindowController}
        let basePair=try unwrap(baseOnly.editor as? FileComparisonWindowController,"Base-only chooser adopted wrong native editor")
        try await wait("base-only accepted pair ready"){!basePair.model.busy && basePair.model.imageComparison != nil}
        try require(baseStatuses.isEmpty,"Base-only chooser prematurely completed waiting session")
        basePair.close();try await wait("base-only accepted pair closes"){baseStatuses==[0] && !baseOnly.hasPendingWork}

        let (errorDirectory,errorPaths,_)=try c.fixture("launch-output-directory-error",output:false)
        let invalidOutput=errorDirectory.appendingPathComponent("output-is-a-directory");try FileManager.default.createDirectory(at:invalidOutput,withIntermediateDirectories:true)
        let failed=ImageToolLaunchSession(invocation:try c.request(errorDirectory,errorPaths,invalidOutput),preferences:c.preferences,owner:nil,permissions:[RepositoryAccessLease(url:errorDirectory,provider:c.provider)])
        c.sessions.append(failed);var failureStatuses:[Int32]=[],failureErrors:[String]=[]
        failed.onFinished={failureStatuses.append($0)};failed.onError={failureErrors.append($0)};failed.start()
        try await wait("actual invalid output setup fails"){failureStatuses.count==1 && !failed.hasPendingWork}
        try require(failureStatuses==[64] && failureErrors.count==1 && !failureErrors[0].isEmpty && failed.editor==nil,"ImageTool setup failure collided with selected-side result or silently launched")

        let (cleanupDirectory,cleanupPaths,_)=try c.fixture("launch-temp-cleanup",output:false)
        let cleanupRequest=try c.request(cleanupDirectory,cleanupPaths,nil,flags:["--delete-inputs-on-close"])
        let cleanup=ImageToolLaunchSession(invocation:cleanupRequest,preferences:c.preferences,owner:nil,permissions:[RepositoryAccessLease(url:cleanupDirectory,provider:c.provider)])
        c.sessions.append(cleanup);cleanup.presentation={controller in controller.window?.alphaValue=0;controller.showWindow(nil)}
        var cleanupStatuses:[Int32]=[];cleanup.onFinished={cleanupStatuses.append($0)};cleanup.start()
        try await wait("actual cleanup selection launched"){cleanup.editor is ImageSelectionWindowController && !cleanup.preparing}
        let external=Data("external changed temporary input\n".utf8);try external.write(to:cleanupPaths[.mine]!,options:.atomic)
        cleanup.cancel();try await wait("owned unchanged temporary cleanup drains"){cleanupStatuses==[0] && !cleanup.hasPendingWork}
        try require((try Data(contentsOf:cleanupPaths[.mine]!))==external && !FileManager.default.fileExists(atPath:cleanupPaths[.base]!.path) && !FileManager.default.fileExists(atPath:cleanupPaths[.theirs]!.path),"Cleanup deleted replaced input or failed to remove captured unchanged temporaries")
    }
    static func captures(_ c:Context)async throws {
        guard let requested=ProcessInfo.processInfo.environment["TURTLEGIT_IMAGE_SELECTION_CAPTURE"] else{return}
        let folder=URL(fileURLWithPath:requested,isDirectory:true),source=c.root.appendingPathComponent("native-capture-patterns")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
        func pattern(_ role:Int)->Data {
            let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:480,pixelsHigh:320,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            let pixels=bitmap.bitmapData!
            for y in 0..<320 {for x in 0..<480 {
                let checker=(x/32+y/32)%2==0,band=x>185+role*12 && x<265+role*12,diagonal=abs(x-(y+45+role*18))<7
                let r=role==0 ? CGFloat(x)/480:0.15,g=role==1 ? CGFloat(y)/320:0.3,b=role==2 ? CGFloat(x+y)/800:0.55
                let shade:CGFloat=checker ? 1:0.65
                let offset=y*bitmap.bytesPerRow+x*4,highlight=band || diagonal
                pixels[offset]=UInt8(((highlight ? 0.95:r*shade)*255).rounded())
                pixels[offset+1]=UInt8(((highlight ? 0.8:g*shade)*255).rounded())
                pixels[offset+2]=UInt8(((highlight ? 0.2:b*shade)*255).rounded())
                pixels[offset+3]=highlight || x>=45 && y>=35 ? 255:89
            }}
            return bitmap.representation(using:.png,properties:[:])!
        }
        var paths:[ImageConflictSide:URL]=[:],sources:[[String:Any]]=[]
        for (role,side) in [ImageConflictSide.mine,.base,.theirs].enumerated() {
            let bytes=pattern(role),name="input-"+side.rawValue.lowercased()+".png",url=source.appendingPathComponent(name)
            try bytes.write(to:url);try bytes.write(to:folder.appendingPathComponent(name))
            paths[side]=url;sources.append(["side":side.rawValue,"file":name,"sha256":hash(bytes),"width":480,"height":320,"authored":"private native fixture RGBA checker/gradient/diagonal pattern"])
        }
        let request=try unwrap(ImageToolInvocation.parse(arguments:["--image-tool","--mine",paths[.mine]!.path,"--base",paths[.base]!.path,"--theirs",paths[.theirs]!.path,"--result",source.appendingPathComponent("chosen.png").path,"--mine-title","Local image","--base-title","Common ancestor","--theirs-title","Incoming image","--show-info"],currentDirectory:source.path),"Missing capture selection invocation")
        let view=try await owner(c,try await c.document(request)),window=view.window!
        let host=try unwrap(window.contentView,"Missing actual native image selection content")
        var records:[[String:Any]]=[]
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
            window.appearance=NSAppearance(named:appearance)
            for _ in 0..<6 {await withCheckedContinuation{(reply:CheckedContinuation<Void,Never>)in DispatchQueue.main.async{reply.resume()}};host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:20_000_000)}
            try require(window.alphaValue==0 && window.isVisible && view.model.images.count==3 && view.model.showInfo && host.bounds.width>700 && host.bounds.height>300,"Native capture owner is visible on desktop or actual three-pane layout is incomplete")
            let bitmap=try unwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds),"Native content cache bitmap unavailable")
            host.cacheDisplay(in:host.bounds,to:bitmap)
            let bytes=try unwrap(bitmap.representation(using:.png,properties:[:]),"Native content PNG unavailable"),file="image-tool-selection-"+name+"-2026-10-29.png"
            try bytes.write(to:folder.appendingPathComponent(file),options:.atomic)
            records.append(["file":file,"sha256":hash(bytes),"pixelsWide":bitmap.pixelsWide,"pixelsHigh":bitmap.pixelsHigh,"contentWidth":host.bounds.width,"contentHeight":host.bounds.height,"appearance":appearance.rawValue,"rootViewClass":String(describing:type(of:host)),"capture":"NSView.cacheDisplay of actual window.contentView; native content only; window frame/title/toolbar excluded"])
        }
        let receipt:[String:Any]=["schema":1,"capturedAt":ISO8601DateFormatter().string(from:Date()),"gitExecutable":c.git.path,"fixture":"docs/qa/image-tool-selection-native-2026-10-29.swift","method":"actual offscreen alpha-zero native content cacheDisplay","desktopCapture":false,"toolbarIncluded":false,"physicalVisualAcceptance":false,"menuKeyOwnership":"receiver-only injected NSApplication.keyWindow witness/native key notifications and explicit NSApp.updateWindows delivery; application remains inactive","sourceInputs":sources,"captures":records]
        try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("provenance.json"),options:.atomic)
        view.close();try await wait("native capture owner closes"){view.model.retired && !view.model.hasPendingWork && view.window?.isVisible != true}
    }
    static func main()async {
        let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.imageToolSelectionQAOrder(_:relativeTo:)))!
        method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let c=Context()
        do {
            if ProcessInfo.processInfo.environment["TURTLEGIT_IMAGE_SELECTION_ONLY"]=="launches" {try await launches(c)}
            else {try await rawSelections(c);try await outputAliases(c);try await changedSnapshots(c);try await nativePresentation(c);try await lifetime(c);try await gitResolution(c);try await launches(c);try await captures(c)}
            try await c.clean()
            print("Menu ownership uses private key-window witness/native notifications and explicit native app update delivery; no physical key/activation acceptance")
            print("PASS standalone ImageTool selection: native Mine/Base/Theirs raw containers/statuses, output CAS, controls/color/ownership, scoped cancellation/drain and real optional Git resolution")
        }catch{try? await c.clean();fputs("Standalone ImageTool selection failed: \(error)\n",stderr);exit(1)}
    }
}
