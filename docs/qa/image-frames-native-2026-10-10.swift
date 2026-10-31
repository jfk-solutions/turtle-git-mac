import AppKit
import SwiftUI
import Combine
import ImageIO
import TurtleGitCore
import Darwin

@main struct ImageFramesVerification {
    struct Failure: Error,CustomStringConvertible {let line:UInt;var detail="";var description:String {"Image frames line \(line): \(detail)"}}
    @MainActor static var phase="setup",phaseState:()->String={""}
    @MainActor static var availabilityOwners=[NSWindowController](),heldRelease:(()->Void)?
    @MainActor static func beginPhase(_ name:String,state:@escaping()->String={""}) {phase=name;phaseState=state;print("Image frames phase: "+name+"; "+state());fflush(stdout)}
    @MainActor static func cleanAvailability()async {
        heldRelease?();heldRelease=nil
        for owner in availabilityOwners {if let sheet=owner.window?.attachedSheet {owner.window?.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil)};owner.close()}
        for _ in 0..<2000 {if ImageConflictWindowModel.activeOperations==0 && ImageSelectionWindowModel.activeOperations==0 && ImageComparisonViewModel.activeFileReads==0 {break};try? await Task.sleep(nanoseconds:10_000_000)}
        availabilityOwners=[]
    }
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws { if !value() { throw Failure(line: line) } }
    @MainActor static func settle() async throws { for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) } }
    @MainActor static func wait(_ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(line:line,detail:"phase=\(phase); \(phaseState())")
    }
    static func sequence(type: CFString, colors: [NSColor], sizes: [CGSize]? = nil) throws -> Data {
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data,type,colors.count,nil) else { throw Failure(line: #line) }
        for (index,color) in colors.enumerated() {
            let size = sizes?[index] ?? CGSize(width: 80,height: 60)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: Int(size.width),pixelsHigh: Int(size.height),bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0)!
            let rgb = color.usingColorSpace(.deviceRGB)!
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * 4
                bitmap.bitmapData![offset] = UInt8(rgb.redComponent * 255); bitmap.bitmapData![offset + 1] = UInt8(rgb.greenComponent * 255)
                bitmap.bitmapData![offset + 2] = UInt8(rgb.blueComponent * 255); bitmap.bitmapData![offset + 3] = 255
            } }
            let metadata: [CFString: Any] = type as String == "com.compuserve.gif" ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.35]] : [:]
            CGImageDestinationAddImage(writer,bitmap.cgImage!,metadata as CFDictionary)
        }
        try require(CGImageDestinationFinalize(writer)); return data as Data
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func pixel(_ view: NSView) -> NSColor {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds,to: bitmap)
        return bitmap.colorAt(x: bitmap.pixelsWide / 2,y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
    }
    @MainActor static func main() async {
        do { try await verify() } catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func verify() async throws {
        do {try await verifyBody();await cleanAvailability()}
        catch {let original=error;await cleanAvailability();throw original}
    }
    @MainActor static func verifyBody() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let captureDirectory = CommandLine.arguments.count > 3 && Int(CommandLine.arguments[3]) == nil ? URL(fileURLWithPath: CommandLine.arguments[3]) : root.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let repo = GitRepository(root: root,executable: git)
        _ = try await repo.run(["init","-b","main"])
        _ = try await repo.run(["config","user.name","Image Frame Tests"])
        _ = try await repo.run(["config","user.email","image-frames@example.invalid"])
        _ = try await repo.run(["config","commit.gpgsign","false"])
        let left = root.appendingPathComponent("first.gif"), right = root.appendingPathComponent("second.gif")
        let a = try sequence(type: "com.compuserve.gif" as CFString,colors: [.red,.green,.blue])
        let b = try sequence(type: "com.compuserve.gif" as CFString,colors: [.blue,.red])
        try a.write(to: left); try b.write(to: right); try await repo.stage(["first.gif","second.gif"]); _ = try await repo.commit(message: "frames")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: left,destination: right),permissions: [])
        let window = controller.window!
        window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: -10000,y: -10000)); window.appearance = NSAppearance(named: .aqua)
        defer { (window as? ImageComparisonKeyRouting)?.imageKeyModel?.stopAllPlayback(); window.close() }
        controller.model.load(); try await wait { !controller.model.busy }
        window.contentView?.layoutSubtreeIfNeeded()
        try await wait { (window as? ImageComparisonKeyRouting)?.imageKeyModel != nil }
        let model = (window as! ImageComparisonKeyRouting).imageKeyModel!, host = window.contentView!
        window.orderFront(nil); window.orderOut(nil); try await settle()
        func button(_ title: String) throws -> NSButton {
            guard let button = descendants(host).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == title }) else { throw Failure(line: #line) }
            return button
        }
        func press(_ title: String) throws { try button(title).performClick(nil) }
        func frame(_ base: Bool) -> Int { model.currentImage(base: base)!.frameIndex }
        func scrolls() -> [ImageComparisonScrollView] { descendants(host).compactMap { $0 as? ImageComparisonScrollView } }
        try require(frame(true) == 0 && frame(false) == 0)
        try press("Next image (Base)"); try await settle()
        try require(frame(true) == 1 && frame(false) == 1)
        let green = pixel(scrolls()[0].documentView!), red = pixel(scrolls()[1].documentView!)
        try require(green.greenComponent > 0.9 && red.redComponent > 0.9)
        try press("Next image (Base)"); try press("Next image (Base)")
        try require(frame(true) == 2 && frame(false) == 1)
        try press("Previous image (Base)"); try require(frame(true) == 1 && frame(false) == 0)
        model.linked = false
        try press("Next image (Second image)"); try require(frame(false) == 1 && frame(true) == 1)
        try press("Previous image (Base)"); try require(frame(true) == 0 && frame(false) == 1)
        try press("Previous image (Second image)"); try require(frame(false) == 0)
        if CommandLine.arguments.count > 3 {
            let directory = captureDirectory
            for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: appearance); model.showInfo = true
                try await settle(); host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds,to: bitmap)
                try bitmap.representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("image-frames-native-" + name + "-2026-10-10.png"))
            }
            model.showInfo = false; window.appearance = NSAppearance(named: .aqua)
        }
        try press("Play images (Base)")
        try require(model.playing == [true])
        try await wait { frame(true) == 1 }; try await wait { frame(true) == 2 }; try await wait { frame(true) == 0 }
        try await settle(); try press("Stop images (Base)")
        let stopped = frame(true); try await Task.sleep(nanoseconds: 450_000_000)
        try require(model.playing.isEmpty && frame(true) == stopped && frame(false) == 0)
        model.linked = true; try press("Play images (Base)")
        try require(model.playing == [true,false]); try await wait { frame(true) == 1 && frame(false) == 1 }
        try await settle(); try press("Stop images (Second image)")
        let linkedLeft = frame(true), linkedRight = frame(false)
        try await Task.sleep(nanoseconds: 450_000_000)
        try require(model.playing.isEmpty && frame(true) == linkedLeft && frame(false) == linkedRight)
        try press("Play images (Base)"); model.overlay = true
        let overlayLeft = frame(true), overlayRight = frame(false)
        try await Task.sleep(nanoseconds: 450_000_000)
        try require(model.playing.isEmpty && frame(true) == overlayLeft && frame(false) == overlayRight)
        model.overlay = false; try await settle()
        let priorImage = model.currentImage(base: true)?.id
        let priorKeyOwner = (window as? ImageComparisonKeyRouting)?.imageKeyOwner
        try press("Play images (Base)"); controller.model.load()
        // The native toolbar and pane now share a stable window-owned model.
        // Require new decoded input and a new live key bridge, not model churn.
        try await wait { !controller.model.busy && (window as? ImageComparisonKeyRouting)?.imageKeyModel === model && model.currentImage(base: true)?.id != priorImage && (window as? ImageComparisonKeyRouting)?.imageKeyOwner != priorKeyOwner }
        try await wait { model.playing.isEmpty }
        let replacement = (window as! ImageComparisonKeyRouting).imageKeyModel!
        replacement.togglePlayback(base: true); try require(!replacement.playing.isEmpty)
        window.close(); try require(replacement.playing.isEmpty)
        // TIFF pages and ICO variants share navigation; ICO has no Play button.
        let pages = root.appendingPathComponent("pages.tiff"), icon = root.appendingPathComponent("icon.ico")
        try sequence(type: "public.tiff" as CFString,colors: [.red,.blue],sizes: [CGSize(width: 80,height: 60),CGSize(width: 20,height: 90)]).write(to: pages)
        let sourceRelative = "Sources/TurtleGitCore/Resources/Icons/fitinwindow.ico"
        let sourceCandidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(sourceRelative)
        let sourceIcon = FileManager.default.fileExists(atPath: sourceCandidate.path) ? sourceCandidate : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(sourceRelative)
        try Data(contentsOf: sourceIcon).write(to: icon)
        let pageController = FileComparisonWindowController(comparison: try WorkingFileComparison(base: pages,destination: icon),permissions: [])
        let pageWindow = pageController.window!
        pageWindow.alphaValue = 0; pageWindow.setFrameOrigin(NSPoint(x: -10000,y: -10000))
        defer { (pageWindow as? ImageComparisonKeyRouting)?.imageKeyModel?.stopAllPlayback(); pageWindow.close() }
        pageController.model.load(); try await wait { !pageController.model.busy }
        pageWindow.contentView?.layoutSubtreeIfNeeded()
        try await wait { (pageWindow as? ImageComparisonKeyRouting)?.imageKeyModel != nil }
        let pageModel = (pageWindow as! ImageComparisonKeyRouting).imageKeyModel!, pageHost = pageWindow.contentView!
        try await settle(); pageModel.linked = false; pageModel.originalSize()
        let controls = descendants(pageHost).compactMap { $0 as? NSButton }
        try require(!controls.contains { $0.accessibilityLabel() == "Play images (Second image)" })
        controls.first { $0.accessibilityLabel() == "Next image (Base)" }!.performClick(nil)
        controls.first { $0.accessibilityLabel() == "Next image (Second image)" }!.performClick(nil)
        try await settle()
        try require(pageModel.currentImage(base: true)?.size == CGSize(width: 20,height: 90))
        try require(pageModel.currentImage(base: false)?.size == CGSize(width: 24,height: 24) && pageModel.zoom == 1)
        let blue = pixel(descendants(pageHost).compactMap { $0 as? ImageComparisonScrollView }[0].documentView!)
        try require(blue.blueComponent > 0.9)
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterA = try Data(contentsOf: left), afterB = try Data(contentsOf: right)
        try require(afterHead == head && afterIndex == index && afterA == a && afterB == b)
        // CUR shares ICO's representations, but its directory words are hotspots.
        // The encoded file must remain unchanged when selecting a representation.
        let cursorFile = root.appendingPathComponent("cursor.cur")
        var cursorBytes = try Data(contentsOf: sourceIcon); cursorBytes[2] = 2
        let variants = Int(cursorBytes[4]) | Int(cursorBytes[5]) << 8
        for entry in 0..<variants { let offset = 6 + entry * 16; cursorBytes[offset + 4] = 2; cursorBytes[offset + 5] = 0; cursorBytes[offset + 6] = 3; cursorBytes[offset + 7] = 0 }
        try cursorBytes.write(to: cursorFile)
        let cursorController = FileComparisonWindowController(comparison: try WorkingFileComparison(base: cursorFile, destination: cursorFile), permissions: [])
        defer { cursorController.close() }
        cursorController.model.load(); try await wait { !cursorController.model.busy }
        cursorController.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait { (cursorController.window as? ImageComparisonKeyRouting)?.imageKeyModel != nil }
        let cursorModel = (cursorController.window as! ImageComparisonKeyRouting).imageKeyModel!
        try require(cursorModel.currentImage(base: true)?.isIconVariants == true && cursorModel.currentImage(base: true)?.cursorHotspot == CGPoint(x: 2, y: 3))
        cursorModel.togglePlayback(base: true); try require(cursorModel.playing.isEmpty)
        if variants > 1 { cursorModel.stepImage(base: true, forward: true); try require(cursorModel.currentImage(base: true)?.cursorHotspot == CGPoint(x: 2, y: 3)) }
        let cursorAfter = try Data(contentsOf: cursorFile); try require(cursorAfter == cursorBytes)
        cursorController.close()
        // A real multi-frame conflict: selecting a later visible frame must
        // copy the original full GIF and retain unmerged stages on No.
        _ = try await repo.run(["switch","-c","frame-side"])
        try b.write(to: left); try await repo.stage(["first.gif"]); _ = try await repo.commit(message: "theirs frames")
        _ = try await repo.run(["switch","main"])
        let mine = try sequence(type: "com.compuserve.gif" as CFString,colors: [.green,.red,.blue])
        try mine.write(to: left); try await repo.stage(["first.gif"]); _ = try await repo.commit(message: "mine frames")
        do { _ = try await repo.run(["merge","frame-side"]); throw Failure(line: #line) } catch is GitFailure {}
        let conflictHead = try await repo.run(["rev-parse","HEAD"]).stdout
        let conflictIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        guard let document = try await repo.imageConflictDocument(path: "first.gif") else { throw Failure(line: #line) }
        let conflict = ImageConflictWindowController(repository: repo,access: nil,document: document)
        let conflictWindow = conflict.window!, conflictHost = conflictWindow.contentView!
        conflictWindow.alphaValue = 0; conflictWindow.setFrameOrigin(NSPoint(x: -10000,y: -10000))
        defer { if let sheet = conflictWindow.attachedSheet { conflictWindow.endSheet(sheet,returnCode: .abort) }; conflictWindow.close() }
        conflictWindow.orderFront(nil);try await wait {!conflict.model.busy}; try await settle()
        func conflictButton(_ title: String) throws -> NSButton {
            guard let button = descendants(conflictHost).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == title }) else { throw Failure(line: #line) }
            return button
        }
        let minePane = conflict.model.panes[.mine]!, basePane = conflict.model.panes[.base]!, theirsPane = conflict.model.panes[.theirs]!
        try conflictButton("Next image (Mine)").performClick(nil); try await settle()
        try require(minePane.currentImage(base: true)?.frameIndex == 1 && basePane.currentImage(base: true)?.frameIndex == 0 && theirsPane.currentImage(base: true)?.frameIndex == 0)
        let minePixel = pixel(descendants(conflictHost).compactMap { $0 as? ImageComparisonScrollView }[0].documentView!)
        try require(minePixel.redComponent > 0.9)
        try conflictButton("Play images (Mine)").performClick(nil)
        try require(minePane.playing == [true] && basePane.playing.isEmpty && theirsPane.playing.isEmpty)
        try await wait { minePane.currentImage(base: true)?.frameIndex == 2 }; try await settle()
        try conflictButton("Stop images (Mine)").performClick(nil); try require(minePane.playing.isEmpty)
        try conflictButton("Select Mine").performClick(nil)
        try await wait { conflictWindow.attachedSheet != nil }
        let sheet = conflictWindow.attachedSheet!
        sheet.alphaValue = 0
        try require(conflictWindow.isVisible && sheet.isVisible)
        guard let no = descendants(sheet.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == "No" }) else { throw Failure(line: #line) }
        beginPhase("original conflict Select Mine / No detach",state:{ownerState(conflictWindow,panes:conflict.model.panes,busy:conflict.model.busy,retired:conflict.model.retired)})
        no.performClick(nil); try await wait { !conflict.model.busy && conflictWindow.attachedSheet==nil && sheet.sheetParent==nil }
        let copied = try Data(contentsOf: left), unmergedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try require(conflict.model.error == nil && copied == mine && ComparisonImage(bytes: copied)?.frameCount == 3 && unmergedIndex == conflictIndex)
        try await wait { (try? conflictButton("Play images (Mine)").isEnabled) == true }
        try conflictButton("Play images (Mine)").performClick(nil); try require(!minePane.playing.isEmpty)
        conflictWindow.close(); try require(conflict.model.retired && conflict.model.panes.values.allSatisfy { $0.playing.isEmpty })
        let finalHead = try await repo.run(["rev-parse","HEAD"]).stdout, untouched = try Data(contentsOf: right)
        try require(finalHead == conflictHead && untouched == b)
        try await verifyOwnerAvailability(root:root,git:git,base:a,mine:mine,theirs:b)
        print("PASS: Native linked/unlinked frame buttons with unequal counts and actual GIF frame pixels; Play/Stop, wrapping, independent/linked timers, stop from second pane, overlay/source replacement/window-close retirement; TIFF page pixels and dimensions, ICO variants without Play, unchanged HEAD/index/encoded files; real multi-frame conflict with independent Mine controls, original full-GIF selection on No, unmerged stages and close cancellation. All owned windows closed.")
    }
}

extension ImageFramesVerification {
    @MainActor static func frameButton(_ window:NSWindow,_ title:String)throws->NSButton {
        guard let value=descendants(window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.accessibilityLabel()==title && $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.action != nil && $0.target != nil}) else {throw Failure(line:#line,detail:"Live frame button absent: "+title+"; "+phaseState())}
        return value
    }
    @MainActor static func frameButtonEnabled(_ window:NSWindow,_ title:String)->Bool {
        guard let host=window.contentView else{return false}
        return descendants(host).compactMap{$0 as? NSButton}.contains{$0.accessibilityLabel()==title && $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.action != nil && $0.target != nil && $0.isEnabled}
    }
    @MainActor static func playbackControlEnabled(_ window:NSWindow,_ pane:String)->Bool? {
        guard let host=window.contentView else{return nil}
        return descendants(host).compactMap{$0 as? NSButton}.first{["Play images ("+pane+")","Stop images ("+pane+")"].contains($0.accessibilityLabel() ?? "") && $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.action != nil && $0.target != nil}?.isEnabled
    }
    @MainActor static func ownerState(_ window:NSWindow,panes:[ImageConflictSide:ImageComparisonViewModel],busy:Bool,retired:Bool)->String {
        let controls=descendants(window.contentView!).compactMap{$0 as? NSButton}.filter{($0.accessibilityLabel() ?? "").contains("images (Mine)")}.map {"label=\($0.accessibilityLabel() ?? "none") enabled=\($0.isEnabled) hidden=\($0.isHiddenOrHasHiddenAncestor) attached=\($0.window === window) target=\(String(describing:$0.target)) action=\(String(describing:$0.action))"}
        let frames=ImageConflictSide.allCases.map{side in "\(side.rawValue):allowed=\(panes[side]?.frameControlsAllowed==true),playing=\(String(describing:panes[side]?.playing)),frame=\(panes[side]?.currentImage(base:true)?.frameIndex ?? -1)"}
        return "busy=\(busy) retired=\(retired) sheet=\(String(describing:window.attachedSheet)) sheetParent=\(String(describing:window.attachedSheet?.sheetParent)) conflictOps=\(ImageConflictWindowModel.activeOperations) selectionOps=\(ImageSelectionWindowModel.activeOperations) dropReads=\(ImageComparisonViewModel.activeFileReads) panes={\(frames.joined(separator:";"))} controls={\(controls.joined(separator:";"))}"
    }
    @MainActor static func paneBoundaryChecks(_ window:NSWindow,panes:[ImageConflictSide:ImageComparisonViewModel],drop:URL,state:@escaping()->String)async throws {
        beginPhase("pane native sheet admission/detachment",state:state)
        try await wait{frameButtonEnabled(window,"Play images (Mine)")}
        let mine=panes[.mine]!,peer=panes[.base]!
        try frameButton(window,"Play images (Mine)").performClick(nil)
        peer.togglePlayback(base:true)
        try require(mine.playing==[true] && peer.playing==[true])
        let sheet=NSWindow(contentRect:.init(x:-12000,y:-12000,width:280,height:120),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0;sheet.setFrameOrigin(.init(x:-12000,y:-12000))
        window.beginSheet(sheet,completionHandler:{_ in})
        try require(mine.playing.isEmpty && peer.playing.isEmpty && !mine.frameControlsAllowed && !peer.frameControlsAllowed)
        let frames=panes.mapValues{$0.currentImage(base:true)?.frameIndex}
        NotificationCenter.default.post(name:NSWindow.didEndSheetNotification,object:window)
        try await settle()
        try require(window.attachedSheet === sheet && sheet.sheetParent === window && !mine.frameControlsAllowed && playbackControlEnabled(window,"Mine")==false)
        mine.togglePlayback(base:true);mine.stepImage(base:true,forward:true)
        try require(mine.playing.isEmpty && panes.mapValues{$0.currentImage(base:true)?.frameIndex}==frames)
        window.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil)
        try await wait{window.attachedSheet==nil && sheet.sheetParent==nil}
        sheet.close()
        try await wait{mine.frameControlsAllowed && frameButtonEnabled(window,"Play images (Mine)")}
        try await settle()
        try require(panes.values.allSatisfy{$0.playing.isEmpty} && panes.mapValues{$0.currentImage(base:true)?.frameIndex}==frames)

        beginPhase("peer drop blocks/restores playback without resuming",state:state)
        let original=peer.currentImage(base:true),decode=peer.decodeDroppedImage
        var reply:CheckedContinuation<ComparisonImage?,Never>?
        peer.requiresDropScope=false
        peer.decodeDroppedImage={_,_ in await withCheckedContinuation{reply=$0}}
        heldRelease={reply?.resume(returning:nil);reply=nil}
        mine.togglePlayback(base:true);try require(mine.playing==[true])
        try require(peer.dropFile(drop,base:true));try await wait{reply != nil}
        try await wait{mine.playing.isEmpty && !mine.frameControlsAllowed && playbackControlEnabled(window,"Mine")==false}
        let heldFrame=mine.currentImage(base:true)?.frameIndex
        mine.togglePlayback(base:true);mine.stepImage(base:true,forward:true)
        try require(mine.playing.isEmpty && mine.currentImage(base:true)?.frameIndex==heldFrame)
        reply?.resume(returning:original);reply=nil;heldRelease=nil;peer.decodeDroppedImage=decode
        try await wait{!peer.receivingDrop && ImageComparisonViewModel.activeFileReads==0 && mine.frameControlsAllowed && frameButtonEnabled(window,"Play images (Mine)")}
        try require(mine.playing.isEmpty && mine.currentImage(base:true)?.frameIndex==heldFrame && peer.dropError==nil && peer.droppedFiles[true] != nil)
        peer.configureImages(base:original,destination:nil,force:true)
        // There is no publisher relay loop while the same admission remains true.
        var publications=0
        let observations=panes.values.map{$0.objectWillChange.sink{publications += 1}}
        try await settle();let settled=publications;try await settle()
        try require(publications==settled)
        withExtendedLifetime(observations) {}
    }
    @MainActor static func verifyOwnerAvailability(root:URL,git:URL,base:Data,mine:Data,theirs:Data)async throws {
        beginPhase("connected conflict and standalone availability fixture")
        let directory=root.appendingPathComponent("availability repository",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let repository=GitRepository(root:directory,executable:git),file=directory.appendingPathComponent("frames.gif")
        _=try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Private playback QA"),("user.email","playback@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
        try base.write(to:file);try await repository.stage(["frames.gif"]);_=try await repository.commit(message:"base")
        _=try await repository.run(["switch","-c","incoming"]);try theirs.write(to:file);try await repository.stage(["frames.gif"]);_=try await repository.commit(message:"incoming")
        _=try await repository.run(["switch","main"]);try mine.write(to:file);try await repository.stage(["frames.gif"]);_=try await repository.commit(message:"local")
        do {_=try await repository.run(["merge","incoming"]);throw Failure(line:#line)} catch is GitFailure {}
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:directory.appendingPathComponent(".git/index"))
        guard let document=try await repository.imageConflictDocument(path:"frames.gif") else {throw Failure(line:#line)}
        let suite="TurtleGit.ImageFrames.Availability."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        let owner=ImageConflictWindowController(repository:repository,access:nil,document:document,preferences:prefs)
        availabilityOwners.append(owner);let window=owner.window!
        window.alphaValue=0;window.setFrameOrigin(.init(x:-12000,y:-12000));window.orderFront(nil)
        try await wait{!owner.model.busy};window.contentView?.layoutSubtreeIfNeeded()
        let state={ownerState(window,panes:owner.model.panes,busy:owner.model.busy,retired:owner.model.retired)}
        try await paneBoundaryChecks(window,panes:owner.model.panes,drop:file,state:state)

        beginPhase("conflict held reload parent gate",state:state)
        let decoded=owner.model.images,decode=owner.model.decodeImages,minePane=owner.model.panes[.mine]!
        var reload:CheckedContinuation<[ImageConflictSide:ComparisonImage],Error>?,reloadToken:OperationCancellation?
        owner.model.decodeImages={_,token in reloadToken=token;return try await withCheckedThrowingContinuation{reload=$0}}
        heldRelease={reload?.resume(throwing:OperationCancellationFailure.cancelled);reload=nil}
        minePane.togglePlayback(base:true);try require(!minePane.playing.isEmpty)
        owner.model.reload();try await wait{reload != nil}
        let heldFrame=minePane.currentImage(base:true)?.frameIndex
        try await wait{minePane.playing.isEmpty && !minePane.frameControlsAllowed && playbackControlEnabled(window,"Mine")==false}
        minePane.togglePlayback(base:true);minePane.stepImage(base:true,forward:true)
        try require(minePane.playing.isEmpty && minePane.currentImage(base:true)?.frameIndex==heldFrame && reloadToken?.isCancelled==false)
        reload?.resume(returning:decoded);reload=nil;heldRelease=nil;owner.model.decodeImages=decode
        try await wait{!owner.model.busy && minePane.frameControlsAllowed && frameButtonEnabled(window,"Play images (Mine)")}
        try require(minePane.playing.isEmpty)

        // The injectable presenter returns No before the real native sheet is
        // detached. The production image confirmation must keep Select/Quit
        // ownership until both AppKit parent links have actually cleared.
        beginPhase("actual image confirmation early No callback / physical sheet drain",state:state)
        let session=ExternalMergeSession(owner:window)
        var response:((NSApplication.ModalResponse)->Void)?,question:NSAlert?
        session.presentConfirmation={parent,alert,reply in question=alert;response=reply;alert.window.alphaValue=0;alert.window.setFrameOrigin(.init(x:-12000,y:-12000));parent.beginSheet(alert.window)}
        owner.model.askMarkResolved={path in await session.confirmImageResolution(path:path)}
        owner.model.select(.mine);try await wait{response != nil && window.attachedSheet != nil}
        response?(.alertSecondButtonReturn);await Task.yield();try await settle()
        try require(owner.model.busy && ImageConflictWindowModel.activeOperations==1 && window.attachedSheet === question?.window && !minePane.frameControlsAllowed && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        let questionWindow=question!.window
        window.endSheet(questionWindow,returnCode:.cancel);questionWindow.orderOut(nil)
        try await wait{!owner.model.busy && window.attachedSheet==nil && questionWindow.sheetParent==nil && frameButtonEnabled(window,"Play images (Mine)")}
        let selectedBytes=try Data(contentsOf:file),selectedIndex=try Data(contentsOf:directory.appendingPathComponent(".git/index"))
        try require(minePane.playing.isEmpty && selectedBytes==mine && selectedIndex==index)
        response?(.alertFirstButtonReturn);session.retire(cancelWork:false)
        try require(!owner.model.busy && minePane.playing.isEmpty)
        owner.close()

        // The standalone Mine/Base/Theirs owner uses the same pane controls and
        // real resolution question; its copied result remains a full GIF.
        let paths=[directory.appendingPathComponent("source-base.gif"),directory.appendingPathComponent("source-mine.gif"),directory.appendingPathComponent("source-theirs.gif")]
        for (path,bytes) in zip(paths,[base,mine,theirs]) {try bytes.write(to:path)}
        guard let invocation=try ImageToolInvocation.parse(arguments:["--image-tool","--base",paths[0].path,"--mine",paths[1].path,"--theirs",paths[2].path,"--result",file.path],currentDirectory:directory.path) else {throw Failure(line:#line)}
        let selectionDocument=try ImageSelectionDocument.capture(invocation:invocation)
        let selection=ImageSelectionWindowController(document:selectionDocument,permissions:[],preferences:prefs)
        availabilityOwners.append(selection);selection.model.requiresScopes=false;selection.model.newOutputResolution.executable={git}
        let selectedWindow=selection.window!;selectedWindow.alphaValue=0;selectedWindow.setFrameOrigin(.init(x:-12000,y:-12000));selectedWindow.orderFront(nil)
        try await wait{!selection.model.busy};selectedWindow.contentView?.layoutSubtreeIfNeeded()
        let selectedState={ownerState(selectedWindow,panes:selection.model.panes,busy:selection.model.busy,retired:selection.model.retired)}
        try await paneBoundaryChecks(selectedWindow,panes:selection.model.panes,drop:paths[0],state:selectedState)
        beginPhase("standalone Select Mine / native No restore",state:selectedState)
        selection.model.select(.mine);try await wait{selectedWindow.attachedSheet != nil}
        let selectedSheet=selectedWindow.attachedSheet!
        guard let no=descendants(selectedSheet.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title=="No"}) else {throw Failure(line:#line)}
        no.performClick(nil)
        try await wait{!selection.model.busy && selectedWindow.attachedSheet==nil && selectedSheet.sheetParent==nil && frameButtonEnabled(selectedWindow,"Play images (Mine)")}
        let standaloneBytes=try Data(contentsOf:file),standaloneIndex=try Data(contentsOf:directory.appendingPathComponent(".git/index"))
        try require(selection.model.panes.values.allSatisfy{$0.playing.isEmpty} && standaloneBytes==mine && standaloneIndex==index)
        try frameButton(selectedWindow,"Play images (Mine)").performClick(nil)
        try require(selection.model.panes[.mine]!.playing==[true])
        selection.close();try require(selection.model.retired && selection.model.panes.values.allSatisfy{$0.playing.isEmpty})
        // No stale notification or retained frame action may revive playback.
        NotificationCenter.default.post(name:NSWindow.didEndSheetNotification,object:selectedWindow)
        selection.model.panes[.mine]!.togglePlayback(base:true);await Task.yield()
        try require(selection.model.panes.values.allSatisfy{$0.playing.isEmpty})
        let finalHead=try await repository.run(["rev-parse","HEAD"]).stdout,finalIndex=try Data(contentsOf:directory.appendingPathComponent(".git/index"))
        try require(finalHead==head && finalIndex==index)
        for (path,bytes) in zip(paths,[base,mine,theirs]) {let actual=try Data(contentsOf:path);try require(actual==bytes)}
        try await wait{ImageConflictWindowModel.activeOperations==0 && ImageSelectionWindowModel.activeOperations==0 && ImageComparisonViewModel.activeFileReads==0}
        beginPhase("connected image availability complete")
    }
}
