import AppKit
import TurtleGitCore

@main struct ImageConflictOwnedVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value{throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool,line:Int = #line) async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Image conflict family timeout at \(line)")
    }
    @MainActor static func main() async {do{try await verify()}catch{fputs("Image conflict family failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),path="picture 雪.png"
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:320,pixelsHigh:200,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        func png(_ color:NSColor)->Data {
            let rgb=color.usingColorSpace(.deviceRGB)!,pixels=bitmap.bitmapData!
            for y in 0..<200 {for x in 0..<320 {
                let offset=y*bitmap.bytesPerRow+x*4,factor:CGFloat=(x/40+y/40)%2==0 ? 1 : 0.55
                pixels[offset]=UInt8(rgb.redComponent*255*factor);pixels[offset+1]=UInt8(rgb.greenComponent*255*factor);pixels[offset+2]=UInt8(rgb.blueComponent*255*factor);pixels[offset+3]=255
            }}
            return bitmap.representation(using:.png,properties:[:])!
        }
        let base=png(.blue),mine=png(.red),theirs=Data("undecodable incoming image\n".utf8)
        func fixture(_ name:String,addAdd:Bool=false) async throws -> GitRepository {
            let folder=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let repo=GitRepository(root:folder,executable:git);_ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Conflict family QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
            if !addAdd {try base.write(to:folder.appendingPathComponent(path));try await repo.stage([path])}
            _ = try await repo.run(["commit","--allow-empty","-m","base"])
            _ = try await repo.run(["switch","-c","side"]);try theirs.write(to:folder.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"incoming")
            _ = try await repo.run(["switch","main"]);try mine.write(to:folder.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"mine")
            do {_ = try await repo.run(["merge","--no-edit","side"]);throw Failure(description:"Expected image conflict")}catch is GitFailure{}
            return repo
        }
        let suite="TurtleGit.ImageConflictOwned."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        var owners:[NSWindowController]=[]
        defer{for owner in owners{owner.close()};prefs.removePersistentDomain(forName:suite)}
        func owner(_ repo:GitRepository) async throws -> ImageConflictWindowController {
            guard let document=try await repo.imageConflictDocument(path:path) else{throw Failure(description:"Mixed image conflict did not route")}
            let controller=ImageConflictWindowController(repository:repo,access:nil,document:document,preferences:prefs);owners.append(controller)
            controller.window!.alphaValue=0;controller.showWindow(nil);controller.window!.contentView?.layoutSubtreeIfNeeded();return controller
        }
        func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
        func press(_ side:ImageConflictSide,_ controller:ImageConflictWindowController) async throws {
            var button:NSButton?
            try await wait{button=descendants(controller.window!.contentView!).compactMap{$0 as? NSButton}.first{$0.accessibilityLabel()=="Select "+side.rawValue};return button?.isEnabled==true}
            button!.performClick(nil);try await wait{controller.window!.attachedSheet != nil}
            try require(controller.model.panes.values.allSatisfy{!$0.commandsAllowed()},"Conflict question left image input active")
            try await wait { descendants(controller.window!.contentView!).compactMap{$0 as? ImageComparisonScrollView}.allSatisfy{!$0.inputAllowed()} }
        }
        func reply(_ value:NSApplication.ModalResponse,_ controller:ImageConflictWindowController) async throws {
            guard let sheet=controller.window!.attachedSheet else{throw Failure(description:"Missing production resolution sheet")}
            NSApp.endSheet(sheet,returnCode:value.rawValue);sheet.orderOut(nil);try await wait{!controller.model.busy}
        }
        let repo=try await fixture("mixed"),file=repo.root.appendingPathComponent(path)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        let mixed=try await owner(repo),window=mixed.window!
        try require(mixed.model.images[.theirs]==nil && mixed.model.canSelect(.theirs),"Decoder failure disabled exact incoming content selection")
        mixed.model.showInfo=true
        if let directory=ProcessInfo.processInfo.environment["TURTLEGIT_IMAGE_CONFLICT_CAPTURE"] {
            NSApp.setActivationPolicy(.accessory);window.alphaValue=1;window.setFrameOrigin(.init(x:70,y:100));window.orderFront(nil)
            for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
                window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:350_000_000)
                let output=URL(fileURLWithPath:directory).appendingPathComponent("image-conflict-undecodable-"+name+".png")
                let number=window.windowNumber
                try await Task.detached{let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");process.arguments=["-x","-o","-l",String(number),output.path];try process.run();process.waitUntilExit();guard process.terminationStatus==0 else{throw Failure(description:"Owned-window capture failed")}}.value
            }
            window.alphaValue=0;window.orderOut(nil);window.orderFront(nil)
        }
        let preview=root.appendingPathComponent("conflict-preview.png");try mine.write(to:preview)
        let pane=mixed.model.panes[.theirs]!
        try require(pane.dropFile(preview,base:true),"Conflict pane refused preview drop")
        try require(!mixed.model.canSelect(.theirs),"Select raced a preview read")
        try await wait {!pane.receivingDrop && pane.currentImage(base:true) != nil}
        try require(mixed.model.document.contents[.theirs]==theirs && pane.droppedFiles[true]?.bytes==mine,"Preview changed captured conflict selection bytes")
        try await press(.theirs,mixed)
        try require(try Data(contentsOf:file)==theirs && Data(contentsOf:repo.root.appendingPathComponent(".git/index"))==index,"Raw side selection changed bytes or staged before confirmation")
        try require(ImageConflictWindowModel.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Owned question lost Quit lifetime")
        window.performClose(nil);try require(!mixed.model.retired && window.attachedSheet != nil,"Ordinary Close bypassed owned question")
        try await reply(.alertSecondButtonReturn,mixed)
        try require(ImageConflictWindowModel.activeOperations==0 && mixed.model.canSelect(.mine),"No failed to settle/re-enable selection")
        try await press(.mine,mixed);window.close()
        try await wait{ImageConflictWindowModel.activeOperations==0 && !mixed.model.busy}
        try require(mixed.model.retired && window.attachedSheet==nil && mixed.model.error==nil,"Forced close left a production question/worker hanging")
        try require(try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))==index,"Forced question retirement marked resolved")
        let held=try await owner(repo);var answer:CheckedContinuation<Bool,Never>?,changes=0
        held.model.onChanged={_ in changes += 1}
        held.model.askMarkResolved={_ in await withCheckedContinuation{answer=$0}}
        held.model.select(.theirs);try await wait{answer != nil};held.close()
        try require(ImageConflictWindowModel.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired noncooperative question released actual operation lifetime")
        answer?.resume(returning:true);answer=nil;try await wait{ImageConflictWindowModel.activeOperations==0}
        try require(changes==1 && held.model.error==nil && (try Data(contentsOf:repo.root.appendingPathComponent(".git/index")))==index,"Late Yes/error escaped retired owner")
        let immediate=try await owner(repo);immediate.model.reload();immediate.close()
        try await wait{ImageConflictWindowModel.activeOperations==0 && !immediate.model.busy}
        try require(immediate.model.retired && immediate.model.error==nil,"Pre-start retirement stranded busy/count state")
        let add=try await fixture("add-add",addAdd:true),addOwner=try await owner(add),addFile=add.root.appendingPathComponent(path)
        let addIndex=try Data(contentsOf:add.root.appendingPathComponent(".git/index")),addHead=try await add.run(["rev-parse","HEAD"]).stdout
        try require(addOwner.model.document.contents[.base]==nil && addOwner.model.canSelect(.base),"Absent source Base did not expose empty-file selection")
        try await press(.base,addOwner);try await reply(.alertSecondButtonReturn,addOwner)
        try require(try Data(contentsOf:addFile).isEmpty && Data(contentsOf:add.root.appendingPathComponent(".git/index"))==addIndex,"Empty Base selection did not retain unmerged index on No")
        try await press(.theirs,addOwner);try await reply(.alertFirstButtonReturn,addOwner)
        let conflicts=try await add.conflicts(),staged=try await add.run(["show",":"+path]).stdout,afterAddHead=try await add.run(["rev-parse","HEAD"]).stdout
        try require(conflicts.isEmpty && staged==theirs && afterAddHead==addHead && addOwner.model.retired,"Explicit Yes did not stage exact selected content without committing")
        // Capture owner preferences and Shift before a suspended entry read.
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false);workspace.fileComparisonPreferences=prefs
        var original=MergeToolPreferences();original.program.enabled=true;original.program.applicationPath="/Applications/Frozen.app";try original.save(to:prefs)
        var release:(()->Void)?,observed:MergeToolPreferences?,observedAlternate:Bool?,routed=false
        workspace.readConflictEditorEntry={repo,path,token in let entry=try await repo.conflictEditorEntry(path:path,cancellation:token);await withCheckedContinuation{continuation in release={continuation.resume()}};return entry}
        workspace.openExternalConflict={_,_,_,alternate,_,_,_,_,tools in observed=tools;observedAlternate=alternate;return false}
        workspace.conflictEditorPresentation={route,_,_,_ in routed=route == .image}
        let parent=NSWindow(contentRect:.init(x:0,y:0,width:400,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false);parent.isReleasedWhenClosed=false;parent.alphaValue=0;parent.orderFront(nil);defer{parent.close();workspace.cancelConflictEditorPreparations()}
        ComparisonToolInvocation.$alternate.withValue(true){workspace.showConflictEditor(repository:repo,access:nil,path:path,owner:parent)}
        try await wait{release != nil};try MergeToolPreferences().save(to:prefs);release?()
        try await wait{workspace.conflictEditorPreparationCount==0}
        try require(observed==original && observedAlternate==true && routed && workspace.error==nil,"Conflict handoff reread tool settings or lost captured Shift")
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && (try Data(contentsOf:repo.root.appendingPathComponent(".git/index")))==index && ImageConflictWindowModel.activeOperations==0,"Image family changed HEAD/index outside explicit resolution")
        print("PASS: image conflict source routing/raw Select/empty Base, real owned No/Yes and forced-close retirement, retained actual Quit lifetime, captured merge Settings/Shift and unchanged HEAD; explicit resolution stages exact bytes")
    }
}
