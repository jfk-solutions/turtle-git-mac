import AppKit
import UniformTypeIdentifiers
import SwiftUI
import TurtleGitCore
import Darwin

@main struct ImageOpenVerification {
    struct Failure:Error,CustomStringConvertible {let line:UInt;var detail="";var description:String {"Image Open line \(line): \(detail)"}}
    @MainActor static var phase="original Open",phaseState:()->String={""}
    @MainActor static var owned=[NSWindowController](),sessions=[ImageToolLaunchSession](),releaseHeld:(()->Void)?
    @MainActor static func beginPhase(_ name:String,_ state:@escaping()->String={""}) {phase=name;phaseState=state;print("Image Open phase: "+name+"; "+state());fflush(stdout)}
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws { if !value() { throw Failure(line: line) } }
    @MainActor static func wait(_ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(line:line,detail:"phase=\(phase); \(phaseState())")
    }
    @MainActor static func settle() async throws { try await Task.sleep(nanoseconds: 200_000_000) }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func png(_ channel: Int, width: Int = 80, height: Int = 60) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        for y in 0..<height { for x in 0..<width { let offset = y * bitmap.bytesPerRow + x * 4; bitmap.bitmapData![offset + channel] = 255; bitmap.bitmapData![offset + 3] = 255 } }
        return bitmap.representation(using: .png, properties: [:])!
    }
    @MainActor static func press(_ title:String,window:NSWindow,line:UInt=#line)throws {
        guard let button=descendants(window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title==title || $0.accessibilityLabel()==title}) else {throw Failure(line:line,detail:"Native button absent: "+title+"; phase="+phase+"; "+phaseState())}
        guard button.isEnabled else {throw Failure(line:line,detail:"Native button disabled: "+title+"; phase="+phase+"; "+phaseState())}
        print("PRESS", title); fflush(stdout); button.performClick(nil); print("PRESSED", title); fflush(stdout)
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await verify(); fflush(stdout); exit(0) }
            catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
        }
        // Native file panels require a live AppKit event loop. A successful
        // process exit before verify returns is never acceptance evidence.
        NSApplication.shared.run()
    }
    final class ScopeRecorder { var starts = 0; var stops = 0 }
    struct ScopeProvider: RepositoryBookmarkProvider {
        let recorder: ScopeRecorder
        func create(for url: URL) throws -> Data { Data() }
        func resolve(_ data: Data) throws -> ResolvedBookmark { throw Failure(line: #line) }
        func startAccessing(_ url: URL) -> Bool { recorder.starts += 1; return true }
        func stopAccessing(_ url: URL) { recorder.stops += 1 }
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Image Open Tests"])
        _ = try await repo.run(["config", "user.email", "image-open@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        let left = root.appendingPathComponent("left.png"), right = root.appendingPathComponent("right.png"), other = root.appendingPathComponent("other.dat")
        let a = png(0), b = png(2), c = png(1, width: 120, height: 40)
        try a.write(to: left); try b.write(to: right); try c.write(to: other)
        try await repo.stage(["left.png", "right.png", "other.dat"]); _ = try await repo.commit(message: "images")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.ImageOpen.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        DialogGeometry.install(preferences:prefs)
        defer {prefs.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)}
        let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: left, destination: right), permissions: [],preferences:prefs)
        let window = controller.window!; window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        defer { window.close() }
        var granted:ImageLoadWindowController?,standalone:FileComparisonWindowController?
        func cleanup()async throws {
            releaseHeld?();releaseHeld=nil
            for session in sessions {session.cancel()}
            for owner in owned {if let chooser=owner as? ImageLoadWindowController {chooser.retire()} else {owner.close()}}
            owned=[]
            granted?.retire();granted=nil;standalone?.close();standalone=nil;controller.close()
            try await wait {FileListComparisonSession.activeOperations == 0 && ImageComparisonViewModel.activeFileReads == 0 && ImageLoadWindowController.activeReleases == 0 && sessions.allSatisfy{!$0.hasPendingWork} && window.attachedSheet == nil && !window.isVisible}
            sessions=[]
        }
        do {
        controller.model.makeImageLoader = { path, leases in
            let loader = ImageLoadWindowController(leftPath: path, permissions: leases)
            loader.window!.alphaValue = 0
            loader.makeOpenPanel = { let panel = NSOpenPanel(); panel.alphaValue = 0; return panel }
            return loader
        }
        controller.model.load(); try await wait { !controller.model.busy }; window.contentView?.layoutSubtreeIfNeeded()
        try await wait { (window as? ImageComparisonKeyRouting)?.imageKeyModel != nil }
        window.orderFront(nil); window.orderOut(nil); try await settle()
        let pane = (window as! ImageComparisonKeyRouting).imageKeyModel!
        pane.vertical = true; pane.linked = false; pane.showInfo = true; pane.alpha = 0.75
        pane.toggleWidths(); pane.toggleHeights()
        try require(pane.fitWidths && pane.fitHeights)
        @MainActor func open() async throws -> ImageLoadWindowController {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31)!
            try require(window.performKeyEquivalent(with: event)); try await wait { window.attachedSheet != nil }
            window.orderOut(nil); window.attachedSheet!.orderOut(nil)
            guard let loader = window.attachedSheet!.delegate as? ImageLoadWindowController else { throw Failure(line: #line) }
            try require(!window.isVisible && !loader.window!.isVisible && !controller.windowShouldClose(window))
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
            try await wait{!loader.reading && loader.left.isEnabled && loader.right.isEnabled}
            return loader
        }
        let initial = controller.model.document!
        print("FIRST OPEN"); fflush(stdout)
        var loader = try await open()
        beginPhase("original cancel",{state(loader)})
        try require(loader.left.stringValue == left.path && loader.right.stringValue.isEmpty)
        if CommandLine.arguments.count > 3 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[3])
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                loader.window!.appearance = NSAppearance(named: appearance); loader.window!.makeFirstResponder(nil)
                loader.window!.orderFront(nil); loader.window!.orderOut(nil); try await settle()
                let host = loader.window!.contentView!, bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("image-open-native-" + mode + "-2026-10-10.png"))
            }
        }
        loader.left.stringValue = other.path; try press("Cancel", window: loader.window!); try await wait { window.attachedSheet == nil && ImageLoadWindowController.activeReleases == 0 }
        try require(controller.model.document?.base.bytes == initial.base.bytes && controller.model.document?.destination.bytes == initial.destination.bytes)
        loader=try await open();beginPhase("original missing path then identical replacement",{state(loader)})
        loader.left.stringValue=root.appendingPathComponent("missing.dat").path
        try press("OK", window: loader.window!); try require(!loader.retired && window.attachedSheet != nil)
        try require(controller.model.document?.base.bytes == a)
        try await wait{!loader.reading}
        loader.left.stringValue = other.path; loader.right.stringValue = other.path
        try press("OK", window: loader.window!); try await wait { window.attachedSheet == nil && ImageLoadWindowController.activeReleases == 0 && !controller.model.busy }; try await settle()
        try require(controller.model.document?.base.bytes == c && controller.model.document?.destination.bytes == c)
        try require(controller.model.imageComparison != nil && pane.vertical && !pane.linked && pane.showInfo && pane.alpha == 0.75 && pane.fit)
        try require(window.title.contains("other.dat") && (window as! ImageComparisonKeyRouting).imageKeyModel === pane)
        try require(pane.fitWidths && pane.fitHeights)
        try require(pane.displaySizing.base.pixels == CGSize(width: 120, height: 40))
        loader=try await open();beginPhase("original empty left / single right",{state(loader)})
        loader.left.stringValue="";loader.right.stringValue=right.path
        try press("OK", window: loader.window!); try await wait { window.attachedSheet == nil && ImageLoadWindowController.activeReleases == 0 && !controller.model.busy }; try await settle()
        try require(controller.model.imageComparison?.base == nil && controller.model.imageComparison?.destination != nil)
        try require(pane.fitWidths && pane.fitHeights)
        loader=try await open();beginPhase("original both sides empty",{state(loader)})
        try require(loader.left.stringValue.isEmpty && !loader.reading)
        loader.left.stringValue="";loader.right.stringValue=""
        try press("OK", window: loader.window!); try await wait { window.attachedSheet == nil && ImageLoadWindowController.activeReleases == 0 && !controller.model.busy }; try await settle()
        try require(controller.model.imageComparison != nil && controller.model.document?.base.bytes.isEmpty == true && controller.model.document?.destination.bytes.isEmpty == true)
        // An ungranted typed path must ask for a native file grant before acceptance.
        loader=try await open();beginPhase("original typed-path authorization",{state(loader)})
        loader.requiresScopes=true;loader.left.stringValue=left.path
        var accepted = false; loader.onAccepted = { _, _ in accepted = true }
        try press("OK", window: loader.window!); try await wait { loader.window?.attachedSheet != nil }
        print("AUTHORIZATION PICKER"); fflush(stdout)
        let picker = loader.window!.attachedSheet as! NSOpenPanel
        picker.orderOut(nil); loader.window!.orderOut(nil); window.orderOut(nil)
        try require(!accepted && picker.allowsOtherFileTypes && !picker.canChooseDirectories && !loader.windowShouldClose(loader.window!))
        let imageExtensions=Set(picker.allowedContentTypes.compactMap(\.preferredFilenameExtension))
        try require(imageExtensions.contains("wmf") && imageExtensions.contains("emf") && picker.alphaValue == loader.window?.alphaValue && picker.appearance == loader.window?.appearance)
        print("CANCEL PICKER"); fflush(stdout); picker.cancel(nil); print("CANCELLED PICKER"); fflush(stdout); try await wait { loader.window?.attachedSheet == nil }; try await settle()
        try require(!accepted && !loader.retired)
        try press("Cancel", window: loader.window!); try await wait { window.attachedSheet == nil && ImageLoadWindowController.activeReleases == 0 }
        // Granted standalone acceptance keeps the lease in the receiving viewer.
        let recorder = ScopeRecorder()
        var lease: RepositoryAccessLease? = RepositoryAccessLease(url: other, provider: ScopeProvider(recorder: recorder))
        weak var witness = lease
        granted = ImageLoadWindowController(leftPath: other.path, permissions: [lease!])
        granted!.requiresScopes = true; granted!.window!.alphaValue = 0
        granted!.window!.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        granted!.onAccepted = { inputs, permissions in
            standalone = FileComparisonWindowController(images: inputs, permissions: permissions,preferences:prefs)
            standalone!.window!.alphaValue = 0
            standalone!.window!.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            standalone!.model.load()
        }
        try press("OK", window: granted!.window!)
        try await wait { standalone != nil && standalone?.model.busy == false }
        try require(standalone?.model.imageComparison?.base != nil && standalone?.model.imageComparison?.destination == nil && recorder.starts == 1)
        granted = nil; lease = nil; try require(witness != nil && recorder.stops == 0)
        standalone?.window?.close(); standalone = nil
        try await wait { witness == nil }; try require(recorder.stops == 1)
        try await capturedInputFamily(root:root,git:URL(fileURLWithPath:CommandLine.arguments[2]),prefs:prefs,bytes:[a,b,c])
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout, finalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let finalA = try Data(contentsOf: left), finalB = try Data(contentsOf: right), finalC = try Data(contentsOf: other)
        try require(finalHead == head && finalIndex == index && finalA == a && finalB == b && finalC == c)
        try await cleanup()
        print("PASS: Native Cmd+O, left-only prefill, two path fields and actual OK/Cancel; missing path retains chooser/current images, identical and empty sides, replacement title/fit and retained view modes; ungranted typed path opens native file authorization and cancellation prevents acceptance; pregranted standalone acceptance retains and releases its lease; close/Quit guards; unchanged HEAD/index/file bytes. All owned windows closed.")
        } catch {let original=error;do {try await cleanup()}catch {throw NSError(domain:"Image Open cleanup: \(original); \(error)",code:1)};throw original}
    }
}

extension ImageOpenVerification {
    @MainActor static func state(_ chooser:ImageLoadWindowController)->String {
        "reading=\(chooser.reading) retired=\(chooser.retired) releases=\(ImageLoadWindowController.activeReleases) leftEnabled=\(chooser.left.isEnabled) left=\(chooser.left.stringValue) sheet=\(String(describing:chooser.window?.sheetParent))"
    }
    @MainActor static func hide(_ owner:NSWindowController) {owned.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-12000,y:-12000))}
    @MainActor static func chooser(_ owner:FileComparisonWindowController)async throws->ImageLoadWindowController {
        owner.model.chooseImageFiles()
        try await wait{owner.window?.attachedSheet?.delegate is ImageLoadWindowController}
        let value=owner.window!.attachedSheet!.delegate as! ImageLoadWindowController
        value.window?.orderOut(nil);owner.window?.orderOut(nil)
        try await wait{!value.reading};return value
    }
    @MainActor static func capturedInputFamily(root:URL,git:URL,prefs:UserDefaults,bytes:[Data])async throws {
        let directory=root.appendingPathComponent("captured image inputs",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let repository=GitRepository(root:directory,executable:git),file=directory.appendingPathComponent("historical.png")
        _=try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Captured Image QA"),("user.email","captured@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
        try bytes[0].write(to:file);try await repository.stage([file.lastPathComponent]);_=try await repository.commit(message:"original image")
        let first=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
        try bytes[1].write(to:file);try await repository.stage([file.lastPathComponent]);_=try await repository.commit(message:"second image")
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:directory.appendingPathComponent(".git/index"))
        try bytes[2].write(to:file)
        let snapshot=try await repository.revisionComparison(from:.revision(first),to:.revision("HEAD"),paths:[file.lastPathComponent])
        let historical=FileComparisonWindowController(repository:repository,access:nil,snapshot:snapshot,path:file.lastPathComponent,preferences:prefs)
        hide(historical);historical.model.load();try await wait{!historical.model.busy && historical.model.imageComparison != nil}
        let original=historical.model.document!.base
        try require(original.bytes==bytes[0] && original.revision == .revision(first) && original.objectID != nil)
        historical.model.makeImageLoader={path,permissions in let value=ImageLoadWindowController(leftPath:path,permissions:permissions);value.requiresScopes=false;return value}
        beginPhase("non-native historical leaf / exact immutable seed identity")
        let longName=String(repeating:"🐢",count:100)+".png"
        let tree=try await repository.run(["mktree","-z"],input:Data(("100644 blob "+original.objectID!+"\t"+longName+"\0").utf8)).text.trimmingCharacters(in:.newlines)
        let longContent=try await repository.historicalFile(revision:tree,path:longName)
        do {
            let seed=try await Task.detached{try ImageLoadSeed.capture(longContent,cancellation:OperationCancellation())}.value
            let document=try ImageFileComparison(base:seed.url,destination:nil).read()
            try seed.validate(document)
            try require(seed.url.lastPathComponent.utf8.count<100 && seed.original.path==longName && seed.original.objectID==original.objectID && document.base.bytes==bytes[0])
            let alias=directory.appendingPathComponent("private-seed-alias.png")
            try FileManager.default.linkItem(at:seed.url,to:alias)
            try require(seed.protects(alias) && !seed.contains(alias))
            try FileManager.default.removeItem(at:alias)
            // An inode replacement with the same bytes is not the captured seed.
            try bytes[0].write(to:seed.url,options:.atomic)
            let replacement=try ImageFileComparison(base:seed.url,destination:nil).read()
            var refused=false;do {try seed.validate(replacement)} catch {refused=true}
            try require(refused)
            try FileManager.default.removeItem(at:seed.url)
            try FileManager.default.createSymbolicLink(at:seed.url,withDestinationURL:file)
            let linked=try ImageFileComparison(base:seed.url,destination:nil).read()
            refused=false;do {try seed.validate(linked)} catch {refused=true}
            try require(refused)
        }
        beginPhase("historical seed / Cancel preserves current comparison")
        var value=try await chooser(historical)
        let cancelledSeed=URL(fileURLWithPath:value.left.stringValue)
        let seedBytes=try Data(contentsOf:cancelledSeed)
        try require(cancelledSeed != file && seedBytes==bytes[0] && value.left.toolTip?.contains(first)==true && value.right.stringValue.isEmpty)
        try press("Cancel",window:value.window!)
        try await wait{ImageLoadWindowController.activeReleases==0 && historical.window?.attachedSheet==nil && !FileManager.default.fileExists(atPath:cancelledSeed.path)}
        try require(historical.model.document?.base.objectID==original.objectID && historical.model.document?.base.bytes==bytes[0])

        beginPhase("historical seed accepted / retained identity / second Open")
        value=try await chooser(historical);value.requiresScopes=true
        let seedURL=URL(fileURLWithPath:value.left.stringValue)
        weak var seedWitness:ImageLoadSeed?
        let forward=value.onAcceptedReceipt
        value.onAcceptedReceipt={receipt,permissions in
            seedWitness=receipt.seeds.first
            try require(receipt.seeds.first?.original.objectID==original.objectID && receipt.seeds.first?.original.revision==original.revision && receipt.document.base.bytes==original.bytes)
            try forward?(receipt,permissions)
        }
        try press("OK",window:value.window!)
        try await wait{!historical.model.busy && historical.window?.attachedSheet==nil && ImageLoadWindowController.activeReleases==0}
        try require(historical.model.document?.base.bytes==bytes[0] && historical.model.document?.destination.bytes.isEmpty==true && seedWitness != nil && historical.window!.title.contains(first))
        historical.model.load();try await wait{!historical.model.busy}
        try require(historical.model.error==nil && historical.model.document?.base.bytes==bytes[0])
        value=try await chooser(historical);value.requiresScopes=true
        try require(value.left.stringValue==seedURL.path)
        try press("OK",window:value.window!)
        try await wait{value.retired && !historical.model.busy && historical.window?.attachedSheet==nil && ImageLoadWindowController.activeReleases==0}
        try require(historical.model.document?.base.bytes==bytes[0] && seedWitness != nil)
        // A changed app-owned seed must fail Reload, retaining the accepted image.
        try bytes[2].write(to:seedURL,options:.atomic)
        historical.model.load();try await wait{!historical.model.busy}
        try require(historical.model.error != nil && historical.model.document?.base.bytes==bytes[0])
        historical.close();try await wait{seedWitness==nil && !FileManager.default.fileExists(atPath:seedURL.path)}

        beginPhase("held authorized read / exact receipt / live Reload")
        let live=directory.appendingPathComponent("live.png");try bytes[0].write(to:live)
        let liveOwner=FileComparisonWindowController(images:try ImageFileComparison(base:live,destination:nil),permissions:[],preferences:prefs)
        hide(liveOwner);liveOwner.model.load();try await wait{!liveOwner.model.busy}
        var held:CheckedContinuation<Void,Never>?,token:OperationCancellation?,received=0
        liveOwner.model.makeImageLoader={path,permissions in
            let load=ImageLoadWindowController(leftPath:path,permissions:permissions),read=loadRead()
            load.requiresScopes=false
            load.readInputs={comparison,cancellation in
                token=cancellation;let document=try await read(comparison,cancellation)
                await withCheckedContinuation{held=$0};received+=1;return document
            };return load
        }
        value=try await chooser(liveOwner)
        beginPhase("held read before external replacement",{state(value)})
        releaseHeld={held?.resume();held=nil}
        try press("OK",window:value.window!);try await wait{held != nil}
        try require(value.reading && !value.left.isEnabled && !value.right.isEnabled && ImageLoadWindowController.activeReleases>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        // Snapshot validated by OK is accepted exactly once; Reload then reads live bytes.
        try bytes[1].write(to:live);held?.resume();held=nil;releaseHeld=nil
        try await wait{received==1 && value.retired && !liveOwner.model.busy && ImageLoadWindowController.activeReleases==0}
        try require(liveOwner.model.document?.base.bytes==bytes[0])
        liveOwner.model.load();try await wait{!liveOwner.model.busy}
        try require(liveOwner.model.document?.base.bytes==bytes[1])

        beginPhase("cancel held read / delayed drain / retry",{state(value)})
        value=try await chooser(liveOwner);let cancelled=value
        releaseHeld={held?.resume();held=nil}
        try press("OK",window:value.window!);try await wait{held != nil}
        try press("Cancel",window:value.window!)
        try require(cancelled.retired && cancelled.reading && token?.isCancelled==true && ImageLoadWindowController.activeReleases>0)
        liveOwner.model.chooseImageFiles();try require(liveOwner.window?.attachedSheet==nil)
        held?.resume();held=nil;releaseHeld=nil
        try await wait{!cancelled.reading && ImageLoadWindowController.activeReleases==0}
        try require(liveOwner.model.document?.base.bytes==bytes[1])
        liveOwner.model.makeImageLoader={path,permissions in let load=ImageLoadWindowController(leftPath:path,permissions:permissions);load.requiresScopes=false;return load}
        value=try await chooser(liveOwner);try press("OK",window:value.window!)
        try await wait{value.retired && !liveOwner.model.busy && ImageLoadWindowController.activeReleases==0}
        try require(liveOwner.model.document?.base.bytes==bytes[1]);liveOwner.close()

        beginPhase("retired seed creation / owned cleanup")
        let pending=ImageLoadWindowController(leftPath:"",permissions:[]);hide(pending)
        let capture=pending.createSeed
        var seedReply:CheckedContinuation<Void,Never>?,lateURL:URL?,closed=0,accepted=0
        pending.createSeed={content,cancellation in
            let seed=try await capture(content,cancellation);lateURL=seed.url
            await withCheckedContinuation{seedReply=$0};return seed
        }
        pending.onClosed={closed+=1};pending.onAccepted={_,_ in accepted+=1}
        pending.prepareSeed(original);releaseHeld={seedReply?.resume();seedReply=nil}
        try await wait{seedReply != nil};pending.retire()
        try require(pending.reading && closed==0 && accepted==0 && ImageLoadWindowController.activeReleases>0)
        seedReply?.resume();seedReply=nil;releaseHeld=nil
        try await wait{!pending.reading && closed==1 && ImageLoadWindowController.activeReleases==0 && lateURL.map{!FileManager.default.fileExists(atPath:$0.path)}==true}
        try require(accepted==0 && pending.left.stringValue.isEmpty)
        beginPhase("fixed feedback / long error / successful retry")
        let failed=ImageLoadWindowController(leftPath:file.path,permissions:[]);hide(failed);failed.requiresScopes=false
        let actual=failed.readInputs,longError=String(repeating:"Private image validation failed. ",count:80)
        var failedReply:CheckedContinuation<Void,Never>?,deliveries=0
        failed.readInputs={_,_ in await withCheckedContinuation{failedReply=$0};throw NSError(domain:"ImageOpen.QA",code:7,userInfo:[NSLocalizedDescriptionKey:longError])}
        failed.onAccepted={_,_ in deliveries+=1}
        let baseline=controlFrames(failed)
        failed.accept();releaseHeld={failedReply?.resume();failedReply=nil};try await wait{failedReply != nil}
        try require(controlFrames(failed)==baseline)
        failedReply?.resume();failedReply=nil;releaseHeld=nil;try await wait{!failed.reading}
        let feedback=descendants(failed.window!.contentView!).compactMap{$0 as? NSTextField}.first{$0.accessibilityLabel()=="Load images error"}
        try require(!failed.retired && deliveries==0 && feedback?.stringValue==longError && feedback?.toolTip==longError && controlFrames(failed)==baseline)
        failed.readInputs=actual;failed.accept();try await wait{failed.retired && !failed.reading && ImageLoadWindowController.activeReleases==0}
        try require(deliveries==1)
        let finalHead=try await repository.run(["rev-parse","HEAD"]).stdout,finalIndex=try Data(contentsOf:directory.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
        try require(finalHead==head && finalIndex==index && working==bytes[2])
        try await standaloneReceiptEntry(directory:directory,prefs:prefs,bytes:bytes)
        beginPhase("captured input family complete")
    }
    @MainActor static func imageModes(_ owner:FileComparisonWindowController)->String {
        let image=owner.model.imageViewerModel
        return "vertical=\(image.vertical) linked=\(image.linked) showInfo=\(image.showInfo) alpha=\(image.alpha) widths=\(image.fitWidths) heights=\(image.fitHeights) dark=\(owner.model.imagePresentation.darkMode) pixels=\(image.displaySizing.base.pixels) nativeAppearance=\(String(describing:owner.window?.appearance?.name)) effectiveAppearance=\(String(describing:owner.window?.effectiveAppearance.name))"
    }
    @MainActor static func preservedImageModes(_ owner:FileComparisonWindowController)->Bool {
        let image=owner.model.imageViewerModel
        return image.vertical && !image.linked && image.showInfo && image.alpha==0.75 && image.fitWidths && image.fitHeights && owner.model.imagePresentation.darkMode
    }
    @MainActor static func standaloneReceiptEntry(directory:URL,prefs:UserDefaults,bytes:[Data])async throws {
        beginPhase("actual standalone Open / deferred receipt replacement")
        let left=directory.appendingPathComponent("session-left.png"),next=directory.appendingPathComponent("session-next.png")
        try bytes[0].write(to:left);try bytes[1].write(to:next)
        guard let invocation=try ImageToolInvocation.parse(arguments:["--image-tool","--left",left.path],currentDirectory:directory.path) else {throw Failure(line:#line)}
        let session=ImageToolLaunchSession(invocation:invocation,preferences:prefs,owner:nil)
        sessions.append(session);session.requiresScopes=false
        var finished=0,errors=[String]()
        session.onFinished={_ in finished+=1};session.onError={errors.append($0);print("Image standalone error: "+$0);fflush(stdout)}
        session.presentation={owner in hide(owner);if let comparison=owner as? FileComparisonWindowController {comparison.model.load()}}
        session.start()
        try await wait{!session.preparing && (session.editor as? FileComparisonWindowController)?.model.document != nil && (session.editor as? FileComparisonWindowController)?.model.busy==false}
        let first=session.editor as! FileComparisonWindowController
        let firstImage=first.model.imageViewerModel
        firstImage.vertical=true;firstImage.linked=false;firstImage.showInfo=true;firstImage.alpha=0.75;firstImage.toggleWidths();firstImage.toggleHeights()
        first.window?.appearance=NSAppearance(named:.darkAqua)
        beginPhase("standalone initial modes before Open",{imageModes(first)})
        guard preservedImageModes(first),firstImage.currentImage(base:true) != nil else {throw Failure(line:#line,detail:imageModes(first))}
        session.showOpenImages();try await wait{session.opener != nil}
        let opener=session.opener!;opener.left.stringValue=next.path
        beginPhase("standalone modes while Open owns admission",{imageModes(first)+"; "+state(opener)})
        guard preservedImageModes(first) else {throw Failure(line:#line,detail:imageModes(first))}
        let accepted=opener.onAcceptedReceipt
        opener.onAcceptedReceipt={receipt,permissions in
            print("Image standalone receipt source modes: "+imageModes(first));fflush(stdout)
            guard preservedImageModes(first) else {throw Failure(line:#line,detail:imageModes(first))}
            try accepted?(receipt,permissions)
        }
        let read=opener.readInputs
        var held:CheckedContinuation<Void,Never>?
        opener.readInputs={comparison,token in let document=try await read(comparison,token);await withCheckedContinuation{held=$0};return document}
        releaseHeld={held?.resume();held=nil}
        opener.accept();try await wait{held != nil}
        try require(session.editor === first && opener.reading && session.hasPendingWork && !firstImage.frameControlsAllowed)
        try bytes[2].write(to:next);held?.resume();held=nil;releaseHeld=nil
        beginPhase("standalone accepted receipt / first display",{
            let current=session.editor as? FileComparisonWindowController
            return "openerNil=\(session.opener==nil) replaced=\(session.editor !== first) busy=\(String(describing:current?.model.busy)) document=\(current?.model.document != nil) pending=\(session.hasPendingWork) preparing=\(session.preparing) releases=\(ImageLoadWindowController.activeReleases) chooser={\(state(opener))} modelError=\(current?.model.error ?? "none") errors=\(errors) finished=\(finished)"
        })
        try await wait{session.opener==nil && session.editor !== first && (session.editor as? FileComparisonWindowController)?.model.busy==false}
        let replaced=session.editor as! FileComparisonWindowController
        try require(replaced.model.document?.base.bytes==bytes[1] && first.window?.isVisible==false && finished==0 && errors.isEmpty)
        beginPhase("standalone replacement preserved modes",{imageModes(replaced)})
        guard preservedImageModes(replaced) else {throw Failure(line:#line,detail:imageModes(replaced))}
        session.showOpenImages();try await wait{session.opener != nil}
        try require(session.opener?.left.stringValue==next.path)
        session.opener?.cancel();try await wait{session.opener==nil}
        replaced.model.load();try await wait{!replaced.model.busy}
        try require(replaced.model.document?.base.bytes==bytes[2])
        session.cancel();try await wait{!session.hasPendingWork && finished==1}
        try require(errors.isEmpty)
    }
    @MainActor static func controlFrames(_ loader:ImageLoadWindowController)->[NSRect] {
        let host=loader.window!.contentView!;host.layoutSubtreeIfNeeded()
        let buttons=descendants(host).compactMap{$0 as? NSButton}.filter{["OK","Cancel"].contains($0.title)}
        return ([loader.left,loader.right] as [NSView]).map{$0.convert($0.bounds,to:host)}+buttons.map{$0.convert($0.bounds,to:host)}
    }
    @MainActor static func loadRead()->(ImageFileComparison,OperationCancellation)async throws->FileComparisonDocument {
        {comparison,cancellation in try await Task.detached{try cancellation.check();let document=try comparison.read();try cancellation.check();return document}.value}
    }
}
